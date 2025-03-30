// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}

interface IRateOracle {
    function getRate(address asset) external view returns (uint256, uint256);
}

contract DerivativeToken is ERC20, Ownable {
    address public immutable collateralAsset;
    uint256 public immutable exercisePrice;
    uint256 public immutable expiryTime;
    bool public immutable isBuyOption;
    bool public isExercised;
    address public immutable creator;

    event OptionExercised();

    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        address _collateralAsset,
        uint256 _exercisePrice,
        uint256 _expiryTime,
        bool _isBuyOption
    ) ERC20(tokenName, tokenSymbol) {
        require(_collateralAsset != address(0), "Invalid collateral asset");
        require(_exercisePrice > 0, "Exercise price must be positive");
        require(_expiryTime > block.timestamp, "Expiry must be in the future");

        collateralAsset = _collateralAsset;
        exercisePrice = _exercisePrice;
        expiryTime = _expiryTime;
        isBuyOption = _isBuyOption;
        creator = msg.sender;
        isExercised = false;
    }

    function issueTokens(address recipient, uint256 amount) external onlyOwner {
        require(!isExercised, "Option already exercised");
        require(block.timestamp < expiryTime, "Option expired");
        _mint(recipient, amount);
    }

    function revokeTokens(address holder, uint256 amount) external onlyOwner {
        _burn(holder, amount);
    }

    function markExercised() external onlyOwner {
        require(!isExercised, "Already exercised");
        require(block.timestamp < expiryTime, "Option expired");
        isExercised = true;
        emit OptionExercised();
    }
}

contract DerivativeVault is Ownable, ReentrancyGuard {
    INonfungiblePositionManager public immutable liquidityManager;
    IRateOracle public rateOracle;

    struct DerivativeInfo {
        address derivativeToken;
        address collateralAsset;
        uint256 exercisePrice;
        uint256 expiryTime;
        bool isBuyOption;
        bool exercised;
        uint256 collateralAmount;
    }

    // Mapping from derivative token address to option details
    mapping(address => DerivativeInfo) public derivativeRecords;
    // Additional mapping from user address to their derivative token
    mapping(address => address) public userDerivativeTokens;
    mapping(address => bool) public validatedOracles;

    event OptionExercised(address indexed derivativeToken, address indexed user, uint256 earnings);
    event OracleUpdated(address indexed newOracle);
    event OptionCreated(
        address indexed derivativeToken,
        address indexed creator,
        address collateralAsset,
        uint256 exercisePrice,
        uint256 expiryTime,
        bool isBuyOption,
        uint256 issueAmount
    );

    constructor(address _liquidityManager, address _rateOracle) {
        require(_liquidityManager != address(0), "Invalid manager");
        require(_rateOracle != address(0), "Invalid oracle");

        liquidityManager = INonfungiblePositionManager(_liquidityManager);
        rateOracle = IRateOracle(_rateOracle);
        validatedOracles[_rateOracle] = true;
    }

    function updateOracle(address _rateOracle) external onlyOwner {
        require(_rateOracle != address(0), "Invalid oracle");
        rateOracle = IRateOracle(_rateOracle);
        validatedOracles[_rateOracle] = true;
        emit OracleUpdated(_rateOracle);
    }

    function generateOptions(
        address collateralAsset,
        uint256 exercisePrice,
        uint256 expiryTime,
        bool isBuyOption,
        uint256 issueAmount
    ) external nonReentrant {
        require(collateralAsset != address(0), "Invalid collateral asset");
        require(exercisePrice > 0, "Exercise price must be positive");
        require(expiryTime > block.timestamp, "Invalid expiry");
        require(issueAmount > 0, "Amount must be positive");

        // Deploy a new DerivativeToken contract
        DerivativeToken derivativeToken = new DerivativeToken(
            "Derivative Option",
            "OPT",
            collateralAsset,
            exercisePrice,
            expiryTime,
            isBuyOption
        );

        // Store derivative information in the mapping
        derivativeRecords[address(derivativeToken)] = DerivativeInfo({
            derivativeToken: address(derivativeToken),
            collateralAsset: collateralAsset,
            exercisePrice: exercisePrice,
            expiryTime: expiryTime,
            isBuyOption: isBuyOption,
            exercised: false,
            collateralAmount: issueAmount
        });

        // Store the user's derivative token for lookup
        userDerivativeTokens[msg.sender] = address(derivativeToken);

        // Issue the derivative tokens
        derivativeToken.issueTokens(msg.sender, issueAmount);

        // Emit an event with more details
        emit OptionCreated(
            address(derivativeToken),
            msg.sender,
            collateralAsset,
            exercisePrice,
            expiryTime,
            isBuyOption,
            issueAmount
        );
    }

    // Helper function to get a user's derivative token
    function getUserDerivativeToken(address user) public view returns (address) {
        return userDerivativeTokens[user];
    }

    function exerciseOption(address user, uint256 amount) external nonReentrant {
        // Get the derivative token address for the user
        address derivativeToken = userDerivativeTokens[user];
        require(derivativeToken != address(0), "Invalid option");

        DerivativeInfo storage option = derivativeRecords[derivativeToken];
        require(!option.exercised, "Already exercised");
        require(block.timestamp < option.expiryTime, "Option expired");

        DerivativeToken token = DerivativeToken(derivativeToken);
        require(token.balanceOf(msg.sender) >= amount, "Insufficient balance");

        (uint256 currentPrice, uint256 timestamp) = rateOracle.getRate(option.collateralAsset);
        require(validatedOracles[address(rateOracle)], "Oracle not validated");
        require(block.timestamp - timestamp <= 30 minutes, "Stale price data");

        uint8 decimals = IERC20Metadata(option.collateralAsset).decimals();
        uint256 precision = 10 ** uint256(decimals);
        uint256 earnings = 0;

        if (option.isBuyOption) {
            if (currentPrice > option.exercisePrice) {
                earnings = ((currentPrice - option.exercisePrice) * amount) / precision;
            }
        } else {
            if (currentPrice < option.exercisePrice) {
                earnings = ((option.exercisePrice - currentPrice) * amount) / precision;
            }
        }

        uint256 maxPayout = (option.collateralAmount * amount) / token.totalSupply();
        earnings = earnings > maxPayout ? maxPayout : earnings;

        require(_transferToken(option.collateralAsset, msg.sender, earnings), "Transfer failed");

        token.revokeTokens(msg.sender, amount);
        if (token.totalSupply() == 0) {
            option.exercised = true;
            token.markExercised();
        }

        emit OptionExercised(derivativeToken, msg.sender, earnings);
    }

    function _transferToken(address token, address to, uint256 amount) internal returns (bool) {
        if (amount == 0) {
            return true; // No need to transfer if amount is 0
        }
        
        require(to != address(0), "Invalid recipient");
        
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
        return true;
    }

    function cleanupExpiredOptions(address derivativeToken) external {
        DerivativeInfo storage option = derivativeRecords[derivativeToken];
        require(option.derivativeToken != address(0), "Option does not exist");
        require(block.timestamp > option.expiryTime, "Option not expired");
        require(option.exercised || block.timestamp > option.expiryTime, "Cannot clean active option");

        // Find and remove the user mapping if it exists
        for (address user = address(0); userDerivativeTokens[user] == derivativeToken; ) {
            delete userDerivativeTokens[user];
            break;  // This is a simplified approach for cleanup
        }

        delete derivativeRecords[derivativeToken];
    }
}
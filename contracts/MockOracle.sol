// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IRateOracle {
    function getRate(address asset) external view returns (uint256, uint256);
}

contract UniswapV3Oracle is Ownable, IRateOracle {

    function getRate(address asset) external view override returns (uint256, uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(asset).slot0();

        // Convert sqrtPriceX96 to token price
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (2 ** 192);
        
        return (price, block.timestamp);
    }
}

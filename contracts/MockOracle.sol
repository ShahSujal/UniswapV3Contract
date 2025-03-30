// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
contract MockRateOracle {
    mapping(address => uint256) private prices;
    mapping(address => uint256) private timestamps;
    
    constructor(uint256 initialPrice) {
        // Initialize with default values
        prices[address(0)] = initialPrice;
        timestamps[address(0)] = block.timestamp;
    }
    
    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
        timestamps[asset] = block.timestamp;
    }
    
    function getRate(address asset) external view returns (uint256, uint256) {
        return (prices[asset], timestamps[asset]);
    }
}

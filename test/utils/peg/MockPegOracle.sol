// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockPegOracle {
    uint256 internal currentPrice;

    constructor(uint256 price_) {
        currentPrice = price_;
    }

    function setPrice(uint256 price_) external {
        currentPrice = price_;
    }

    function price() external view returns (uint256) {
        return currentPrice;
    }
}

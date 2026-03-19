// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IPegStateView {
    function pegCore() external view returns (address);

    function maxMintable(bytes32 id, address account) external view returns (uint256);
}

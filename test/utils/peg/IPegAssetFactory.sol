// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IPegAssetFactory {
    function pegCore() external view returns (address);

    function createPegAsset(string calldata name, string calldata symbol) external returns (address pegAsset);
}

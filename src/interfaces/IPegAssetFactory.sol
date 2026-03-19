// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title  IPegAssetFactory — Deploys PegAsset ERC-20 synthetic tokens.
interface IPegAssetFactory {
    /// @notice Deploy a new PegAsset ERC-20 contract backed by PegCore.
    /// @param name    Token name   (e.g. "Peg Japanese Yen").
    /// @param symbol  Token symbol (e.g. "pegJPY").
    /// @return        Address of the deployed PegAsset contract.
    function createPegAsset(string calldata name, string calldata symbol)
        external
        returns (address);
}

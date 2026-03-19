// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IPegCore — Minimal interface consumed by PegHook
/// @notice PegCore is the singleton lending/swap engine. PegHook only needs
///         oracle prices and PegAsset deployment validation.
interface IPegCore {
    /// @notice Oracle price for a market, denominated in sUSDS (WAD-scaled).
    /// @dev    Reads the cached Chainlink price from Market struct slot S3.
    ///         Reverts if `marketId` does not exist.
    /// @param  marketId  The protocol-assigned market identifier.
    /// @return price     WAD-scaled price (1e18 = 1 sUSDS).
    function marketPrice(uint256 marketId) external view returns (uint256 price);
}

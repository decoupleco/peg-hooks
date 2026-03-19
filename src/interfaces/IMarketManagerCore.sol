// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// ── Types ────────────────────────────────────────────────────────────────────

/// @dev PegCore market identifier — keccak256(abi.encode(MarketParams)).
type Id is bytes32;

/// @dev Parameters that uniquely identify a PegCore market.
struct MarketParams {
    address collateralToken;
    address loanToken;   // PegAsset address (synthetic)
    address oracle;
    address model;
}

// ── Interface ─────────────────────────────────────────────────────────────────

/// @title  IMarketManagerCore — PegCore surface consumed by MarketManager.
/// @notice Minimal interface for market creation and cap management.
///         Caller must be PegCore admin for privileged functions.
interface IMarketManagerCore {
    /// @notice Register a new market in PegCore (borrowCap initialised to 0).
    ///         Permissionless — any caller may create a market.
    function createMarket(MarketParams calldata marketParams) external;

    /// @notice Set the per-market borrow cap.
    ///         0 = frozen (no new minting), >0 = live.
    ///         Caller must be PegCore admin.
    function setBorrowCap(Id id, uint112 cap) external;
}

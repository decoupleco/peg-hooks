// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @dev PegCore market identifier — keccak256(abi.encode(MarketParams)).
type Id is bytes32;

/// @dev Parameters that uniquely identify a PegCore market.
struct MarketParams {
    address collateralToken;
    address loanToken;
    address oracle;
    address model;
}

/// @title IPegCore — PegCore surface consumed by PegHook and MarketManager
/// @notice PegCore is the singleton lending/swap engine. PegHook reads oracle
///         prices while MarketManager creates markets and manages borrow caps.
interface IPegCore {
    /// @notice Oracle price for a market, denominated in sUSDS (WAD-scaled).
    /// @dev    Reverts if `marketId` does not exist.
    /// @param  marketId  The PegCore market identifier.
    /// @return price     WAD-scaled price (1e18 = 1 sUSDS).
    function marketPrice(Id marketId) external view returns (uint256 price);

    /// @notice Register a new market in PegCore with borrowCap initialised to 0.
    function createMarket(MarketParams calldata marketParams) external;

    /// @notice Set the per-market borrow cap.
    function setBorrowCap(Id id, uint112 cap) external;
}

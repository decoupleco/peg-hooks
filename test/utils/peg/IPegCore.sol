// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Id, MarketParams} from "./PegTypes.sol";

interface IPegCore {
    function admin() external view returns (address);

    function setModel(address model, bool approved) external;

    function setBorrowCap(Id id, uint112 cap) external;

    function createMarket(MarketParams calldata marketParams) external;

    function supply(Id id, uint256 assets, address onBehalf) external returns (uint256 assetsSupplied);

    function withdraw(Id id, uint256 assets, address onBehalf, address receiver)
        external
        returns (uint256 assetsWithdrawn);

    function mint(Id id, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256 assetsMinted, uint256 sharesMinted);

    function burn(Id id, uint256 assets, uint256 shares, address onBehalf)
        external
        returns (uint256 assetsBurnt, uint256 sharesBurnt);

    function enableSwap(Id id, bool enabled) external;

    function swap(Id idIn, Id idOut, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut);

    function quote(Id idIn, Id idOut, uint256 amountIn) external view returns (uint256 amountOut, uint256 fee);

    function models(address model) external view returns (bool);

    function position(Id id, address user)
        external
        view
        returns (
            uint128 collateral,
            uint128 borrowShares,
            bool swapEnabled,
            uint112 lastFeePerShare,
            uint128 lockCollateral
        );

    function market(Id id)
        external
        view
        returns (
            uint32 timestamp,
            uint112 feePerShare,
            int128 flowDelta,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint112 spareCapacity,
            uint112 totalCollateral,
            uint112 borrowCap
        );

    function idToMarketParams(Id id)
        external
        view
        returns (address collateralToken, address loanToken, address oracle, address model);
}

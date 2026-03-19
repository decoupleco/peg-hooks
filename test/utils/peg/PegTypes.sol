// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

type Id is bytes32;

struct MarketParams {
    address collateralToken;
    address loanToken;
    address oracle;
    address model;
}

struct Market {
    uint32 timestamp;
    uint112 feePerShare;
    int128 flowDelta;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint112 spareCapacity;
    uint112 totalCollateral;
    uint112 borrowCap;
}

library PegMarketParamsLib {
    function id(MarketParams memory marketParams) internal pure returns (Id) {
        return Id.wrap(
            keccak256(
                abi.encode(
                    marketParams.collateralToken, marketParams.loanToken, marketParams.oracle, marketParams.model
                )
            )
        );
    }
}

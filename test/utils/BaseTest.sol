// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PegDeployers} from "./PegDeployers.sol";

contract BaseTest is Test, PegDeployers {
    function deployArtifactsAndLabel() internal {
        deployArtifacts();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");
    }

    function deployPegArtifactsAndLabel() internal {
        deployPegArtifacts();

        vm.label(address(pegCore), "PegCore");
        vm.label(address(pegModel), "PegModel");
        vm.label(address(pegAssetFactory), "PegAssetFactory");
    }

    function deployCurrencyPair() internal virtual override returns (Currency currency0, Currency currency1) {
        (currency0, currency1) = super.deployCurrencyPair();

        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");
    }

    function _etch(address target, bytes memory bytecode) internal override {
        vm.etch(target, bytecode);
    }
}

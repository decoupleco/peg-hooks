// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Id, Market} from "./PegTypes.sol";

interface IPegModel {
    function admin() external view returns (address);

    function setCollateralToken(address collateralToken) external;

    function validCollateral(address collateralToken) external view returns (bool);

    function setLltv(Id id, uint256 lltv) external;

    function setSwapFee(Id id, uint256 swapFeeBps) external;

    function lltv(Id id) external view returns (uint256);

    function swapFee(Id id, Market calldata market) external view returns (uint256);
}

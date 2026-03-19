// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC4626Like {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

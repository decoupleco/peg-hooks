// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title PegMath — Pure helpers for PegHook price & fee logic
/// @notice All prices are WAD-scaled (1e18 = 1 unit).
library PegMath {
    uint256 internal constant WAD = 1e18;

    // ─── Median ──────────────────────────────────────────────────────────

    /// @notice Median of three uint256 values (no allocation, branchless-ish).
    function median(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        if (a <= b) {
            if (b <= c) return b;      // a ≤ b ≤ c
            if (a <= c) return c;      // a ≤ c < b
            return a;                  // c < a ≤ b
        } else {
            if (a <= c) return a;      // b < a ≤ c
            if (b <= c) return c;      // b ≤ c < a
            return b;                  // c < b, b ≤ a → b is median
        }
    }

    // ─── sqrtPriceX96 → WAD price ────────────────────────────────────────

    /// @notice Convert UniV4 sqrtPriceX96 to a WAD-scaled price.
    /// @dev    sqrtPriceX96 = sqrt(token1/token0) × 2^96.
    ///         price(token1 per token0) = sqrtPriceX96² / 2^192.
    ///         If `invert` is true, returns token0-per-token1 instead.
    /// @param sqrtPriceX96 Current pool sqrt price in Q64.96.
    /// @param invert       If true, return the reciprocal (token0/token1).
    /// @return rate WAD-scaled price.
    function sqrtPriceToWad(uint160 sqrtPriceX96, bool invert) internal pure returns (uint256 rate) {
        uint256 sqrtP = uint256(sqrtPriceX96);
        uint256 priceX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);

        if (!invert) {
            // price = sqrtP² × 1e18 / 2^192
            rate = FullMath.mulDiv(priceX128, WAD, 1 << 128);
        } else {
            // price = 2^192 × 1e18 / sqrtP²
            rate = FullMath.mulDiv(1 << 128, WAD, priceX128);
        }
    }

    // ─── Fee ramp ────────────────────────────────────────────────────────

    /// @notice Linear fee ramp: 0 at 0 deviation → maxFee at maxDev.
    /// @dev    fee = min(|dev| × maxFee / maxDev, maxFee).
    ///         All values WAD-scaled except the returned fee (hundredths of bip).
    /// @param absDev  Absolute deviation (WAD-scaled, e.g. 0.005e18 = 0.5%).
    /// @param maxDev  Deviation at which fee caps (WAD-scaled, e.g. 0.01e18 = 1%).
    /// @param maxFee  Maximum fee in hundredths of a bip (e.g. 10_000 = 100 bps).
    /// @return fee    Fee in hundredths of a bip, clamped to maxFee.
    function linearFee(uint256 absDev, uint256 maxDev, uint24 maxFee) internal pure returns (uint24 fee) {
        if (absDev >= maxDev) return maxFee;
        fee = uint24(absDev * uint256(maxFee) / maxDev);
    }

    // ─── VW-EMA ──────────────────────────────────────────────────────────

    /// @notice Volume-weighted EMA update.
    /// @dev    ema_new = ema_old × V₀/(V+V₀) + price × V/(V+V₀)
    ///         Rational approximation — no exp(), no ln().
    /// @param emaOld  Previous EMA value (WAD).
    /// @param price   Current swap price (WAD).
    /// @param volume  Absolute swap volume (token units, WAD).
    /// @param v0      Reference volume constant (WAD).
    /// @return emaNew Updated EMA value (WAD).
    function vwEma(uint256 emaOld, uint256 price, uint256 volume, uint256 v0) internal pure returns (uint256 emaNew) {
        uint256 denom = volume + v0;
        // ema_new = (ema_old × v0 + price × volume) / denom
        emaNew = FullMath.mulDiv(emaOld, v0, denom) + FullMath.mulDiv(price, volume, denom);
    }
}

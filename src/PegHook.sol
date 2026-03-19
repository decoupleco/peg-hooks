// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {IPegCore} from "./interfaces/IPegCore.sol";
import {PegMath} from "./libraries/PegMath.sol";

/// @title PegHook — Dynamic-fee UniV4 hook for peg-anchored channel pools
///
/// @notice Each "channel pool" pairs a PegAsset (CREATE2-deployed synthetic) with
///         an anchor token (e.g. sUSDS).  The hook reads three independent price
///         sources — Chainlink oracle (via PegCore), pool spot (sqrtPriceX96),
///         and a volume-weighted EMA — and uses the **median** to compute a
///         manipulation-resistant deviation.
///
///         Fee schedule:
///           • Healing trade (pushes price → oracle):  0 bps
///           • Toxic  trade (pushes price ← oracle):   linear ramp 0 → 100 bps
///             at MAX_DEVIATION (1%).
///
///         VW-EMA is updated in afterSwap with α = V/(V+V₀).
///
/// @dev    Follows the OpenZeppelin BaseHook override pattern:
///           _beforeSwap   → classify & override fee
///           _afterSwap    → update VW-EMA
///         Channel registration is a separate call (registerChannel) because
///         beforeInitialize does not receive hookData in UniV4.
contract PegHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev 100 bps expressed in hundredths-of-a-bip (UniV4 fee unit).
    uint24 public constant MAX_FEE = 10_000;

    /// @dev 1% deviation (WAD-scaled) at which fee caps at MAX_FEE.
    uint256 public constant MAX_DEVIATION = 0.01e18;

    /// @dev Reference volume for VW-EMA smoothing (WAD-scaled).
    ///      Higher V₀ ⇒ slower EMA ⇒ harder to manipulate.
    uint256 public constant V0 = 1000e18;

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice PegCore singleton — source of oracle cross-rates.
    IPegCore public immutable core;

    /// @notice CREATE2 init-code hash for PegAsset deployments.
    bytes32 public immutable PEGASSET_INIT_CODE_HASH;

    /// @notice Hub numeraire market (e.g. USD).  Used to compute cross-rates:
    ///         trueRate = core.marketPrice(mktId) / core.marketPrice(USD_MARKET_ID)
    uint256 public immutable USD_MARKET_ID;

    // ═══════════════════════════════════════════════════════════════════════
    //  Storage — 1 slot per channel pool
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Packed into a single 256-bit slot:
    ///        emaPrice    (uint128)  — VW-EMA price, WAD-scaled
    ///        marketId    (uint48)   — PegCore market id for oracle lookups
    ///        lastUpdate  (uint48)   — block.timestamp of last EMA touch
    ///        pegIsToken0 (bool)     — layout flag for price conversion
    ///                                 7 bits spare
    struct ChannelState {
        uint128 emaPrice;
        uint48 marketId;
        uint48 lastUpdate;
        bool pegIsToken0;
    }

    mapping(PoolId => ChannelState) public channels;

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    event ChannelRegistered(PoolId indexed poolId, uint48 marketId, bool pegIsToken0);
    event EmaUpdated(PoolId indexed poolId, uint128 newEma, uint256 volume);

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error InvalidChannel();
    error ChannelNotRegistered();
    error ChannelAlreadyRegistered();
    error NotDynamicFee();

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        IPoolManager _poolManager,
        IPegCore _core,
        bytes32 _pegAssetInitCodeHash,
        uint256 _usdMarketId
    ) BaseHook(_poolManager) {
        core = _core;
        PEGASSET_INIT_CODE_HASH = _pegAssetInitCodeHash;
        USD_MARKET_ID = _usdMarketId;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Permissions
    // ═══════════════════════════════════════════════════════════════════════

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Channel registration
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Register a channel pool.  Permissionless but validated:
    ///         CREATE2 derivation proves the pegAsset is genuine.
    /// @param key         The UniV4 PoolKey (must reference this hook).
    /// @param marketId    PegCore market id for oracle lookups.
    /// @param currencyId  CREATE2 salt used when PegCore deployed the PegAsset
    ///                    (e.g. keccak256("AUD")).
    function registerChannel(PoolKey calldata key, uint48 marketId, bytes32 currencyId) external {
        PoolId poolId = key.toId();
        if (channels[poolId].emaPrice != 0) revert ChannelAlreadyRegistered();

        // Derive expected PegAsset address via CREATE2
        address pegAsset = _computePegAsset(currencyId);

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        bool isPeg0 = (token0 == pegAsset);
        bool isPeg1 = (token1 == pegAsset);
        if (!isPeg0 && !isPeg1) revert InvalidChannel();

        // Seed EMA from oracle
        uint256 oracleRate = _trueRate(marketId);

        channels[poolId] = ChannelState({
            emaPrice: uint128(oracleRate),
            marketId: marketId,
            lastUpdate: uint48(block.timestamp),
            pegIsToken0: isPeg0
        });

        emit ChannelRegistered(poolId, marketId, isPeg0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Hook: beforeInitialize — validate dynamic fee
    // ═══════════════════════════════════════════════════════════════════════

    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return this.beforeInitialize.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Hook: beforeSwap — three-source deviation → dynamic fee
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Fee logic:
    ///   1. Read three independent price sources.
    ///   2. Take median → manipulation-resistant "robust rate".
    ///   3. deviation = |oracle − robust|.
    ///   4. Classify swap as healing (→ 0 fee) or toxic (→ linear ramp).
    ///   5. Return fee with OVERRIDE_FEE_FLAG so UniV4 uses it as the LP fee.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        ChannelState storage ch = channels[poolId];
        if (ch.emaPrice == 0) revert ChannelNotRegistered();

        // ── Source 1: Oracle (PegCore cross-rate) ────────────────────────
        uint256 oracleRate = _trueRate(ch.marketId);

        // ── Source 2: Pool spot (sqrtPriceX96 → WAD) ────────────────────
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        //   sqrtPriceX96²/2^192 gives token1-per-token0.
        //   If pegIsToken0 we want anchor-per-peg = token1/token0 ✓
        //   If pegIsToken1 we want anchor-per-peg = token0/token1 → invert
        uint256 poolRate = PegMath.sqrtPriceToWad(sqrtPriceX96, !ch.pegIsToken0);

        // ── Source 3: VW-EMA ────────────────────────────────────────────
        uint256 emaRate = uint256(ch.emaPrice);

        // ── Robust deviation (median of 3) ──────────────────────────────
        uint256 robustRate = PegMath.median(oracleRate, poolRate, emaRate);

        uint256 absDev;
        bool poolBelowOracle;
        if (robustRate < oracleRate) {
            absDev = oracleRate - robustRate;
            poolBelowOracle = true;
        } else {
            absDev = robustRate - oracleRate;
            poolBelowOracle = false;
        }

        // ── Healing vs Toxic classification ─────────────────────────────
        //   buyingPeg  = acquiring pegAsset from the pool
        //   Pool below oracle → buying peg heals → fee = 0
        //   Pool above oracle → selling peg heals → fee = 0
        bool buyingPeg = ch.pegIsToken0 ? !params.zeroForOne : params.zeroForOne;
        bool isHealing = (poolBelowOracle && buyingPeg) || (!poolBelowOracle && !buyingPeg);

        uint24 fee = isHealing ? 0 : PegMath.linearFee(absDev, MAX_DEVIATION, MAX_FEE);

        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Hook: afterSwap — update VW-EMA
    // ═══════════════════════════════════════════════════════════════════════

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal virtual override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        ChannelState storage ch = channels[poolId];

        // Skip EMA update for unregistered pools (should not happen, but safe)
        if (ch.emaPrice == 0) return (this.afterSwap.selector, 0);

        // Swap volume = absolute pegAsset delta
        int128 pegDelta = ch.pegIsToken0 ? delta.amount0() : delta.amount1();
        uint256 volume = pegDelta >= 0 ? uint256(int256(pegDelta)) : uint256(-int256(pegDelta));

        // Post-swap pool price as the "current observation"
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 postPrice = PegMath.sqrtPriceToWad(sqrtPriceX96, !ch.pegIsToken0);

        // Update EMA
        uint128 newEma = uint128(PegMath.vwEma(uint256(ch.emaPrice), postPrice, volume, V0));
        ch.emaPrice = newEma;
        ch.lastUpdate = uint48(block.timestamp);

        emit EmaUpdated(poolId, newEma, volume);

        return (this.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev  trueRate = core.marketPrice(mktId) / core.marketPrice(USD_MARKET_ID)
    ///       Both prices are WAD-scaled sUSDS prices.  Division cancels sUSDS
    ///       numeraire → pure FX cross-rate (WAD-scaled, e.g. 0.0067e18 for JPY/USD).
    function _trueRate(uint48 marketId) internal view returns (uint256) {
        uint256 mktPrice = core.marketPrice(uint256(marketId));
        uint256 usdPrice = core.marketPrice(USD_MARKET_ID);
        // mktPrice / usdPrice, WAD-scaled
        return (mktPrice * 1e18) / usdPrice;
    }

    /// @dev  Derive PegAsset address via CREATE2:
    ///       addr = CREATE2(core, currencyId, PEGASSET_INIT_CODE_HASH)
    function _computePegAsset(bytes32 currencyId) internal view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(core), currencyId, PEGASSET_INIT_CODE_HASH)
                    )
                )
            )
        );
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {IPegCore} from "./interfaces/IPegCore.sol";
import {PegMath} from "./libraries/PegMath.sol";

interface IPegAsset {
    function currency() external view returns (bytes32);
}

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

    /// @dev 0.5% around peg is ~49.9 ticks at 1bp tick granularity.
    int24 internal constant MAX_PEG_DEVIATION_TICK = 50;

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice PegCore singleton — source of oracle cross-rates.
    IPegCore public immutable core;

    /// @notice CREATE2 init-code hash for PegAsset deployments.
    bytes32 public immutable PEGASSET_INIT_CODE_HASH;

    /// @notice Hub numeraire market (e.g. USD).  Used to compute cross-rates:
    ///         oracle = core.marketPrice(mktId) / core.marketPrice(USD_MARKET_ID)
    uint256 public immutable USD_MARKET_ID;

    // ═══════════════════════════════════════════════════════════════════════
    //  Storage — 1 slot per channel pool
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Packed into a single 256-bit slot (96 + 32 + 128 = 256):
    ///        emaPrice   (uint96)   — VW-EMA price, WAD-scaled
    ///        timestamp  (uint32)   — block.timestamp of last EMA touch
    ///        marketId   (uint128)  — PegCore market id; MSB = pegIsToken0 flag
    struct Channel {
        uint96 emaPrice;
        uint32 timestamp;
        uint128 marketId;
    }

    /// @dev MSB of marketId encodes the pegIsToken0 layout flag.
    uint128 private constant _PEG_IS_TOKEN0_BIT = 1 << 127;

    mapping(PoolId => Channel) public channels;

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    event ChannelRegistered(PoolId indexed poolId, uint128 marketId, bool pegIsToken0);
    event EmaUpdated(PoolId indexed poolId, uint96 newEma, uint256 volume);

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error InvalidChannel();
    error ChannelNotRegistered();
    error ChannelAlreadyRegistered();
    error NotDynamicFee();
    error InvalidLiquidityRange();

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    constructor(IPoolManager _poolManager, IPegCore _core, bytes32 _pegAssetInitCodeHash, uint256 _usdMarketId)
        BaseHook(_poolManager)
    {
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
            beforeAddLiquidity: true,
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
    function registerChannel(PoolKey calldata key, uint128 marketId, bytes32 currencyId) external {
        PoolId poolId = key.toId();
        if (channels[poolId].emaPrice != 0) revert ChannelAlreadyRegistered();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        bool isPeg0 = _isPegAsset(token0);
        bool isPeg1 = _isPegAsset(token1);
        if (isPeg0 == isPeg1) revert InvalidChannel();

        address pegAsset = _computePegAsset(currencyId);
        if ((isPeg0 && token0 != pegAsset) || (isPeg1 && token1 != pegAsset)) revert InvalidChannel();

        // Seed EMA from oracle
        uint256 oracleRate = _oracle(marketId);

        channels[poolId] = Channel({
            emaPrice: uint96(oracleRate),
            timestamp: uint32(block.timestamp),
            marketId: marketId | (isPeg0 ? _PEG_IS_TOKEN0_BIT : uint128(0))
        });

        emit ChannelRegistered(poolId, marketId, isPeg0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Hook: beforeInitialize — validate dynamic fee
    // ═══════════════════════════════════════════════════════════════════════

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        bool token0IsPeg = _isPegAsset(Currency.unwrap(key.currency0));
        bool token1IsPeg = _isPegAsset(Currency.unwrap(key.currency1));
        if (token0IsPeg == token1IsPeg) revert InvalidChannel();

        return this.beforeInitialize.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Hook: beforeAddLiquidity — enforce in-band channel ranges
    // ═══════════════════════════════════════════════════════════════════════

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (channels[key.toId()].emaPrice == 0) revert ChannelNotRegistered();

        int24 maxTickOffset = _maxTickOffset(key.tickSpacing);
        if (params.tickLower < -maxTickOffset || params.tickUpper > maxTickOffset) {
            revert InvalidLiquidityRange();
        }

        return this.beforeAddLiquidity.selector;
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
        Channel storage ch = channels[poolId];
        if (ch.emaPrice == 0) revert ChannelNotRegistered();

        // Unpack layout flag from marketId MSB
        bool pegIsToken0 = (ch.marketId & _PEG_IS_TOKEN0_BIT) != 0;

        // Three price sources → median → deviation → fee
        uint256 oracleRate = _oracle(ch.marketId & ~_PEG_IS_TOKEN0_BIT);
        uint256 poolRate;
        {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            poolRate = PegMath.sqrtPriceToWad(sqrtPriceX96, !pegIsToken0);
        }
        uint256 robustRate = PegMath.median(oracleRate, poolRate, uint256(ch.emaPrice));

        // Deviation + healing/toxic classification
        bool isHealing;
        uint256 absDev;
        {
            bool poolBelowOracle = robustRate < oracleRate;
            absDev = poolBelowOracle ? oracleRate - robustRate : robustRate - oracleRate;
            bool buyingPeg = pegIsToken0 ? !params.zeroForOne : params.zeroForOne;
            isHealing = (poolBelowOracle && buyingPeg) || (!poolBelowOracle && !buyingPeg);
        }

        uint24 fee = isHealing ? 0 : PegMath.linearFee(absDev, MAX_DEVIATION, MAX_FEE);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Hook: afterSwap — update VW-EMA
    // ═══════════════════════════════════════════════════════════════════════

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        Channel storage ch = channels[poolId];

        // Skip EMA update for unregistered pools (should not happen, but safe)
        if (ch.emaPrice == 0) return (this.afterSwap.selector, 0);

        // Unpack layout flag from marketId MSB
        bool pegIsToken0 = (ch.marketId & _PEG_IS_TOKEN0_BIT) != 0;

        // Swap volume = absolute pegAsset delta
        int128 pegDelta = pegIsToken0 ? delta.amount0() : delta.amount1();
        uint256 volume = pegDelta >= 0 ? uint256(int256(pegDelta)) : uint256(-int256(pegDelta));

        // Post-swap pool price as the "current observation"
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 postPrice = PegMath.sqrtPriceToWad(sqrtPriceX96, !pegIsToken0);

        // Update EMA
        uint96 newEma = uint96(PegMath.vwEma(uint256(ch.emaPrice), postPrice, volume, V0));
        ch.emaPrice = newEma;
        ch.timestamp = uint32(block.timestamp);

        emit EmaUpdated(poolId, newEma, volume);

        return (this.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════════════════════

    function oracle(PoolId poolId) external view returns (uint256) {
        Channel storage ch = _channel(poolId);
        return _oracle(_baseMarketId(ch));
    }

    function deviation(PoolId poolId) external view returns (int256) {
        Channel storage ch = _channel(poolId);
        uint256 oracleRate = _oracle(_baseMarketId(ch));
        uint256 robustRate = _robustPrice(poolId, ch);
        return int256(oracleRate) - int256(robustRate);
    }

    function price(PoolId poolId) external view returns (uint256) {
        Channel storage ch = _channel(poolId);
        return _robustPrice(poolId, ch);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _channel(PoolId poolId) internal view returns (Channel storage ch) {
        ch = channels[poolId];
        if (ch.emaPrice == 0) revert ChannelNotRegistered();
    }

    function _baseMarketId(Channel storage ch) internal view returns (uint128) {
        return ch.marketId & ~_PEG_IS_TOKEN0_BIT;
    }

    function _robustPrice(PoolId poolId, Channel storage ch) internal view returns (uint256) {
        uint256 oracleRate = _oracle(_baseMarketId(ch));
        uint256 poolRate = _poolRate(poolId, ch);
        return PegMath.median(oracleRate, poolRate, uint256(ch.emaPrice));
    }

    function _poolRate(PoolId poolId, Channel storage ch) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        return PegMath.sqrtPriceToWad(sqrtPriceX96, !_pegIsToken0(ch));
    }

    function _pegIsToken0(Channel storage ch) internal view returns (bool) {
        return (ch.marketId & _PEG_IS_TOKEN0_BIT) != 0;
    }

    /// @dev  oracle = core.marketPrice(mktId) / core.marketPrice(USD_MARKET_ID)
    ///       Both prices are WAD-scaled sUSDS prices.  Division cancels sUSDS
    ///       numeraire → pure FX cross-rate (WAD-scaled, e.g. 0.0067e18 for JPY/USD).
    function _oracle(uint128 marketId) internal view returns (uint256) {
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
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(core), currencyId, PEGASSET_INIT_CODE_HASH)))
            )
        );
    }

    function _isPegAsset(address token) internal view returns (bool) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IPegAsset.currency, ()));
        if (!ok || data.length != 32) return false;

        bytes32 currencyId = abi.decode(data, (bytes32));
        return token == _computePegAsset(currencyId);
    }

    function _maxTickOffset(int24 tickSpacing) internal pure returns (int24 maxTickOffset) {
        maxTickOffset = (MAX_PEG_DEVIATION_TICK / tickSpacing) * tickSpacing;
        if (maxTickOffset < MAX_PEG_DEVIATION_TICK) {
            maxTickOffset += tickSpacing;
        }
    }
}

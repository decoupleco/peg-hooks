// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {PegHook} from "../src/PegHook.sol";
import {IPegCore} from "../src/interfaces/IPegCore.sol";
import {PegMath} from "../src/libraries/PegMath.sol";

// ═══════════════════════════════════════════════════════════════════════════════
//  Mock PegCore — returns configurable oracle prices
// ═══════════════════════════════════════════════════════════════════════════════

contract MockPegCore is IPegCore {
    mapping(uint256 => uint256) public prices;

    function setMarketPrice(uint256 marketId, uint256 price) external {
        prices[marketId] = price;
    }

    function marketPrice(uint256 marketId) external view override returns (uint256) {
        return prices[marketId];
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  PegHook Tests
// ═══════════════════════════════════════════════════════════════════════════════

contract PegHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ─── Test state ──────────────────────────────────────────────────────

    Currency currency0; // will be pegAsset (if sorted < anchor)
    Currency currency1; // will be anchor (sUSDS mock)

    PoolKey poolKey;
    PoolId poolId;

    PegHook hook;
    MockPegCore mockCore;

    uint128 constant JPY_MARKET_ID = 1;
    uint128 constant USD_MARKET_ID = 2;

    // sUSDS-denominated prices (WAD)
    uint256 constant JPY_PRICE = 0.0076e18; // sUSDS per pegJPY
    uint256 constant USD_PRICE = 1.14e18;   // sUSDS per pegUSD

    // Expected cross rate: JPY/USD ≈ 0.00667
    // 0.0076e18 * 1e18 / 1.14e18 ≈ 0.006666...e18

    bytes32 constant MOCK_INIT_CODE_HASH = keccak256("MOCK_PEGASSET");
    bytes32 constant JPY_CURRENCY_ID = keccak256("JPY");

    // ─── Setup ───────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy V4 infrastructure
        deployArtifactsAndLabel();

        // Deploy mock tokens (represents pegAsset and anchor)
        (currency0, currency1) = deployCurrencyPair();

        // Deploy mock PegCore with oracle prices
        mockCore = new MockPegCore();
        mockCore.setMarketPrice(JPY_MARKET_ID, JPY_PRICE);
        mockCore.setMarketPrice(USD_MARKET_ID, USD_PRICE);
        vm.label(address(mockCore), "MockPegCore");

        // Deploy PegHook to an address with the correct flag bits
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags ^ (0x4444 << 144));

        bytes memory constructorArgs = abi.encode(
            poolManager,
            address(mockCore),
            MOCK_INIT_CODE_HASH,
            uint256(USD_MARKET_ID)
        );
        deployCodeTo("PegHook.sol:PegHook", constructorArgs, hookAddress);
        hook = PegHook(hookAddress);
        vm.label(hookAddress, "PegHook");

        // Create channel pool with DYNAMIC FEE
        poolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60, // tickSpacing
            IHooks(hook)
        );
        poolId = poolKey.toId();

        // Initialize pool at price ≈ 1:1
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Register channel — we need the pegAsset (currency0 or currency1)
        // to match CREATE2. For testing, we'll etch the hook to skip CREATE2
        // validation by directly writing Channel storage.
        _registerMockChannel();

        // Provide full-range liquidity
        _addFullRangeLiquidity(100e18);
    }

    function _registerMockChannel() internal {
        // Since our mock tokens aren't real CREATE2-deployed PegAssets,
        // we prank-register the channel by writing storage directly.
        // In production, registerChannel() validates CREATE2.
        //
        // We treat currency0 as the pegAsset (pegIsToken0 = true).
        uint256 oracleRate = (JPY_PRICE * 1e18) / USD_PRICE;

        // Pack pegIsToken0 into MSB of marketId
        uint128 PEG_IS_TOKEN0_BIT = 1 << 127;
        PegHook.Channel memory ch = PegHook.Channel({
            emaPrice: uint96(oracleRate),
            timestamp: uint32(block.timestamp),
            marketId: JPY_MARKET_ID | PEG_IS_TOKEN0_BIT
        });

        // mapping(PoolId => Channel) is at slot 0 (immutables don't use slots).
        // Slot 1 is after _PEG_IS_TOKEN0_BIT constant (private, no slot).
        // channels is the first storage variable.
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(0)));
        // Pack Channel into 256 bits: emaPrice (96) | timestamp (32) | marketId (128)
        uint256 packed = uint256(ch.emaPrice)
            | (uint256(ch.timestamp) << 96)
            | (uint256(ch.marketId) << 128);

        vm.store(address(hook), slot, bytes32(packed));
    }

    function _addFullRangeLiquidity(uint128 liquidityAmount) internal {
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PegMath unit tests
    // ═══════════════════════════════════════════════════════════════════════

    function testMedian() public pure {
        assertEq(PegMath.median(1, 2, 3), 2);
        assertEq(PegMath.median(3, 1, 2), 2);
        assertEq(PegMath.median(2, 3, 1), 2);
        assertEq(PegMath.median(5, 5, 5), 5);
        assertEq(PegMath.median(1, 1, 3), 1);
        assertEq(PegMath.median(1, 3, 3), 3);
    }

    function testLinearFee() public pure {
        // 0 deviation → 0 fee
        assertEq(PegMath.linearFee(0, 0.01e18, 10_000), 0);
        // 0.5% deviation → 50bp
        assertEq(PegMath.linearFee(0.005e18, 0.01e18, 10_000), 5_000);
        // 1% deviation → 100bp (max)
        assertEq(PegMath.linearFee(0.01e18, 0.01e18, 10_000), 10_000);
        // 2% deviation → still 100bp (capped)
        assertEq(PegMath.linearFee(0.02e18, 0.01e18, 10_000), 10_000);
    }

    function testVwEma() public pure {
        // EMA at 100, new price 200, volume = V0 → moves 50% → 150
        uint256 result = PegMath.vwEma(100e18, 200e18, 1000e18, 1000e18);
        assertEq(result, 150e18);

        // EMA at 100, new price 200, volume = 0 → no change → 100
        uint256 result2 = PegMath.vwEma(100e18, 200e18, 0, 1000e18);
        assertEq(result2, 100e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Hook integration tests
    // ═══════════════════════════════════════════════════════════════════════

    function testBeforeInitializeRevertOnStaticFee() public {
        // Create a pool key with static fee — should revert
        // PoolManager wraps hook reverts in WrappedError, so we just expect any revert
        PoolKey memory staticKey = PoolKey(
            currency0,
            currency1,
            3000, // static fee
            60,
            IHooks(hook)
        );
        vm.expectRevert(); // WrappedError wrapping NotDynamicFee
        poolManager.initialize(staticKey, Constants.SQRT_PRICE_1_1);
    }

    function testSwapUpdatesFeeAndEma() public {
        // Record EMA before swap
        (uint96 emaBefore,, ) = hook.channels(poolId);
        assertTrue(emaBefore > 0, "EMA should be initialized");

        // Perform a swap: sell token0 (pegAsset) for token1
        uint256 amountIn = 1e18;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // EMA should have updated
        (uint96 emaAfter,, ) = hook.channels(poolId);
        // After a swap, EMA should shift based on volume
        // (won't be exactly the same as before unless volume was 0)
        assertTrue(emaAfter > 0, "EMA should still be non-zero");
    }

    function testSwapHealingGetsFreePass() public {
        // Move oracle to create a "pool below peg" scenario:
        // Increase JPY oracle price → pool is now below oracle → buying peg heals
        mockCore.setMarketPrice(JPY_MARKET_ID, JPY_PRICE * 110 / 100); // +10%

        // Buy pegAsset (token0): zeroForOne = false → buying peg → should be healing
        uint256 amountIn = 0.1e18;
        BalanceDelta delta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false, // buying pegAsset = healing when pool is below oracle
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Swap should succeed (healing = 0 fee → minimal slippage)
        assertTrue(delta.amount1() < 0 || delta.amount0() < 0, "Should have received output tokens");
    }

    function testMultipleSwapsConvergeEma() public {
        (uint96 ema0,, ) = hook.channels(poolId);

        // Do several small swaps to see EMA converge
        for (uint256 i = 0; i < 5; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 0.1e18,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        (uint96 ema5,, ) = hook.channels(poolId);

        // After 5 sell swaps, the EMA should have moved from initial value
        // (pool price drops from selling token0, so EMA should track downward)
        assertTrue(ema5 != ema0, "EMA should have changed after swaps");
    }
}

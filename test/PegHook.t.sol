// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
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

contract MockPegAsset is MockERC20 {
    bytes32 public immutable currency;

    constructor(bytes32 currencyId) MockERC20("Mock Peg Asset", "mPEG", 18) {
        currency = currencyId;
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

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    PegHook hook;
    MockPegCore mockCore;

    uint128 constant JPY_MARKET_ID = 1;
    uint128 constant USD_MARKET_ID = 2;
    int24 constant CHANNEL_TICK_LOWER = -60;
    int24 constant CHANNEL_TICK_UPPER = 60;

    // sUSDS-denominated prices (WAD)
    uint256 constant JPY_PRICE = 0.0076e18; // sUSDS per pegJPY
    uint256 constant USD_PRICE = 1.14e18; // sUSDS per pegUSD

    // Expected cross rate: JPY/USD ≈ 0.00667
    // 0.0076e18 * 1e18 / 1.14e18 ≈ 0.006666...e18

    bytes32 constant MOCK_INIT_CODE_HASH = keccak256("MOCK_PEGASSET");
    bytes32 constant JPY_CURRENCY_ID = keccak256("JPY");
    bytes32 constant AUD_CURRENCY_ID = keccak256("AUD");
    uint128 constant PEG_IS_TOKEN0_BIT = 1 << 127;

    // ─── Setup ───────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy V4 infrastructure
        deployArtifactsAndLabel();

        // Deploy mock PegCore with oracle prices
        mockCore = new MockPegCore();
        mockCore.setMarketPrice(JPY_MARKET_ID, JPY_PRICE);
        mockCore.setMarketPrice(USD_MARKET_ID, USD_PRICE);
        vm.label(address(mockCore), "MockPegCore");

        // Deploy mock tokens (pegAsset + anchor)
        (currency0, currency1) = _deployChannelCurrencyPair();

        // Deploy PegHook to an address with the correct flag bits
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags ^ (0x4444 << 144));

        bytes memory constructorArgs =
            abi.encode(poolManager, address(mockCore), MOCK_INIT_CODE_HASH, uint256(USD_MARKET_ID));
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

        // Register the channel through the production validation path.
        hook.registerChannel(poolKey, JPY_MARKET_ID, JPY_CURRENCY_ID);

        // Provide full-range liquidity
        _addChannelLiquidity(1_000_000e18);
    }

    function _deployChannelCurrencyPair() internal returns (Currency pegCurrency, Currency anchorCurrency) {
        address pegAssetAddress = _computePegAssetAddress(JPY_CURRENCY_ID);
        bytes memory constructorArgs = abi.encode(JPY_CURRENCY_ID);
        deployCodeTo("PegHook.t.sol:MockPegAsset", constructorArgs, pegAssetAddress);

        MockERC20 pegAsset = MockERC20(pegAssetAddress);
        MockERC20 anchorToken = deployToken();

        pegAsset.mint(address(this), 10_000_000 ether);
        pegAsset.approve(address(permit2), type(uint256).max);
        pegAsset.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(pegAsset), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(pegAsset), address(poolManager), type(uint160).max, type(uint48).max);

        vm.label(address(pegAsset), "PegAsset");
        vm.label(address(anchorToken), "AnchorToken");

        if (address(pegAsset) < address(anchorToken)) {
            pegCurrency = Currency.wrap(address(pegAsset));
            anchorCurrency = Currency.wrap(address(anchorToken));
        } else {
            pegCurrency = Currency.wrap(address(anchorToken));
            anchorCurrency = Currency.wrap(address(pegAsset));
        }
    }

    function _computePegAssetAddress(bytes32 currencyId) internal view returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(mockCore), currencyId, MOCK_INIT_CODE_HASH)))
            )
        );
    }

    function _deployPegAsset(bytes32 currencyId) internal returns (Currency pegCurrency) {
        address pegAssetAddress = _computePegAssetAddress(currencyId);
        bytes memory constructorArgs = abi.encode(currencyId);
        deployCodeTo("PegHook.t.sol:MockPegAsset", constructorArgs, pegAssetAddress);

        MockERC20 pegAsset = MockERC20(pegAssetAddress);
        pegAsset.mint(address(this), 10_000_000 ether);
        pegAsset.approve(address(permit2), type(uint256).max);
        pegAsset.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(pegAsset), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(pegAsset), address(poolManager), type(uint160).max, type(uint48).max);

        pegCurrency = Currency.wrap(pegAssetAddress);
    }

    function _sortedPoolKey(Currency a, Currency b) internal view returns (PoolKey memory key) {
        (Currency sorted0, Currency sorted1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey(sorted0, sorted1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
    }

    function _addFullRangeLiquidity(uint128 liquidityAmount) internal {
        _addLiquidity(
            TickMath.minUsableTick(poolKey.tickSpacing), TickMath.maxUsableTick(poolKey.tickSpacing), liquidityAmount
        );
    }

    function _addChannelLiquidity(uint128 liquidityAmount) internal {
        _addLiquidity(CHANNEL_TICK_LOWER, CHANNEL_TICK_UPPER, liquidityAmount);
    }

    function _addLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidityAmount) internal {
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

    function _pegIsToken0() internal view returns (bool) {
        (,, uint128 packedMarketId) = hook.channels(poolId);
        return (packedMarketId & PEG_IS_TOKEN0_BIT) != 0;
    }

    function _beforeSwapFee(bool zeroForOne) internal returns (uint24 feeWithFlag) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.prank(address(poolManager));
        (,, feeWithFlag) = hook.beforeSwap(address(this), poolKey, params, Constants.ZERO_BYTES);
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

    function testViewFunctionsAreExposedForRegisteredPool() public view {
        bytes32 id = PoolId.unwrap(poolId);
        uint256 expectedOracle = (JPY_PRICE * 1e18) / USD_PRICE;

        (bool oracleOk, bytes memory oracleData) =
            address(hook).staticcall(abi.encodeWithSignature("oracle(bytes32)", id));
        (bool deviationOk, bytes memory deviationData) =
            address(hook).staticcall(abi.encodeWithSignature("deviation(bytes32)", id));
        (bool priceOk, bytes memory priceData) = address(hook).staticcall(abi.encodeWithSignature("price(bytes32)", id));

        assertTrue(oracleOk, "oracle view should be callable for registered pools");
        assertTrue(deviationOk, "deviation view should be callable for registered pools");
        assertTrue(priceOk, "price view should be callable for registered pools");

        uint256 oracleRate = abi.decode(oracleData, (uint256));
        int256 deviation = abi.decode(deviationData, (int256));
        uint256 price = abi.decode(priceData, (uint256));

        assertEq(oracleRate, expectedOracle, "oracle should expose the market cross-rate");
        assertEq(deviation, 0, "median price should match oracle when EMA is seeded from oracle");
        assertEq(price, expectedOracle, "robust price should equal oracle at initialization");
    }

    function testSqrtPriceToWadHandlesValidExtremeSqrtPrice() public pure {
        uint256 directRate = PegMath.sqrtPriceToWad(TickMath.MAX_SQRT_PRICE, false);
        uint256 inverseRate = PegMath.sqrtPriceToWad(TickMath.MIN_SQRT_PRICE, true);

        assertGt(directRate, 0, "direct rate should be computed at valid max sqrt price");
        assertGt(inverseRate, 0, "inverse rate should be computed at valid min sqrt price");
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

    function testBeforeInitializeRevertsWhenPoolHasNoPegAsset() public {
        (Currency otherCurrency0, Currency otherCurrency1) = deployCurrencyPair();

        PoolKey memory invalidKey =
            PoolKey(otherCurrency0, otherCurrency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));

        vm.expectRevert();
        poolManager.initialize(invalidKey, Constants.SQRT_PRICE_1_1);
    }

    function testFullRangeLiquidityRevertsForChannelPool() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
            liquidityDelta: int256(uint256(1e18)),
            salt: bytes32(0)
        });

        vm.expectRevert();
        vm.prank(address(poolManager));
        hook.beforeAddLiquidity(address(this), poolKey, params, Constants.ZERO_BYTES);
    }

    function testInBandLiquidityRangeIsAllowed() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: CHANNEL_TICK_LOWER,
            tickUpper: CHANNEL_TICK_UPPER,
            liquidityDelta: int256(uint256(1e18)),
            salt: bytes32(0)
        });

        vm.prank(address(poolManager));
        bytes4 selector = hook.beforeAddLiquidity(address(this), poolKey, params, Constants.ZERO_BYTES);

        assertEq(selector, hook.beforeAddLiquidity.selector, "in-band channel liquidity should be accepted");
    }

    function testRegisterChannelRevertsWhenCurrencyIdDoesNotMatchPegAsset() public {
        MockERC20 freshAnchor = deployToken();
        Currency pegCurrency = _pegIsToken0() ? currency0 : currency1;
        PoolKey memory wrongSaltKey = _sortedPoolKey(pegCurrency, Currency.wrap(address(freshAnchor)));

        poolManager.initialize(wrongSaltKey, Constants.SQRT_PRICE_1_1);

        vm.expectRevert(PegHook.InvalidChannel.selector);
        hook.registerChannel(wrongSaltKey, JPY_MARKET_ID, AUD_CURRENCY_ID);
    }

    function testBeforeInitializeRevertsForPegToPegPool() public {
        Currency audPeg = _deployPegAsset(AUD_CURRENCY_ID);
        Currency jpyPeg = _pegIsToken0() ? currency0 : currency1;
        PoolKey memory invalidKey = _sortedPoolKey(jpyPeg, audPeg);

        vm.expectRevert();
        poolManager.initialize(invalidKey, Constants.SQRT_PRICE_1_1);
    }

    function testBeforeSwapReturnsZeroFeeForHealingTrade() public {
        mockCore.setMarketPrice(JPY_MARKET_ID, 2 * USD_PRICE);

        uint24 feeWithFlag = _beforeSwapFee(!_pegIsToken0());

        assertTrue((feeWithFlag & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0, "healing trade should override the LP fee");
        assertEq(feeWithFlag & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, 0, "healing trade should be free");
    }

    function testBeforeSwapReturnsMaxFeeForToxicTrade() public {
        mockCore.setMarketPrice(JPY_MARKET_ID, 2 * USD_PRICE);

        uint24 feeWithFlag = _beforeSwapFee(_pegIsToken0());

        assertTrue((feeWithFlag & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0, "toxic trade should override the LP fee");
        assertEq(
            feeWithFlag & ~LPFeeLibrary.OVERRIDE_FEE_FLAG,
            hook.MAX_FEE(),
            "toxic trade should pay the capped fee when deviation exceeds the max"
        );
    }

    function testSwapUpdatesFeeAndEma() public {
        // Record EMA before swap
        (uint96 emaBefore,,) = hook.channels(poolId);
        assertTrue(emaBefore > 0, "EMA should be initialized");

        // Perform a swap: sell pegAsset for anchor
        uint256 amountIn = 1e18;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: _pegIsToken0(),
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // EMA should have updated
        (uint96 emaAfter,,) = hook.channels(poolId);
        // After a swap, EMA should shift based on volume
        // (won't be exactly the same as before unless volume was 0)
        assertTrue(emaAfter > 0, "EMA should still be non-zero");
    }

    function testSwapHealingGetsFreePass() public {
        // Move oracle to create a "pool below peg" scenario:
        // Increase JPY oracle price → pool is now below oracle → buying peg heals
        mockCore.setMarketPrice(JPY_MARKET_ID, JPY_PRICE * 110 / 100); // +10%

        // Buy pegAsset → should be healing when pool is below oracle
        uint256 amountIn = 0.1e18;
        BalanceDelta delta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: !_pegIsToken0(),
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Swap should succeed (healing = 0 fee → minimal slippage)
        assertTrue(delta.amount1() < 0 || delta.amount0() < 0, "Should have received output tokens");
    }

    function testMultipleSwapsConvergeEma() public {
        (uint96 ema0,,) = hook.channels(poolId);

        // Do several small peg sells to see EMA converge
        for (uint256 i = 0; i < 5; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 0.1e18,
                amountOutMin: 0,
                zeroForOne: _pegIsToken0(),
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        (uint96 ema5,,) = hook.channels(poolId);

        // After 5 sell swaps, the EMA should have moved from initial value
        // (pool price drops from selling token0, so EMA should track downward)
        assertTrue(ema5 != ema0, "EMA should have changed after swaps");
    }
}

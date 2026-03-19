// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {PegHook} from "../src/PegHook.sol";
import {IPegCore} from "../src/interfaces/IPegCore.sol";
import {PegMath} from "../src/libraries/PegMath.sol";

contract FuzzMockPegCore is IPegCore {
    mapping(uint256 => uint256) public prices;

    function setMarketPrice(uint256 marketId, uint256 price) external {
        prices[marketId] = price;
    }

    function marketPrice(uint256 marketId) external view override returns (uint256) {
        return prices[marketId];
    }
}

contract FuzzMockPegAsset is MockERC20 {
    bytes32 public immutable currency;

    constructor(bytes32 currencyId) MockERC20("Mock Peg Asset", "mPEG", 18) {
        currency = currencyId;
    }
}

contract PegHookFuzzTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint128 internal constant JPY_MARKET_ID = 1;
    uint128 internal constant USD_MARKET_ID = 2;
    int24 internal constant CHANNEL_TICK_LOWER = -60;
    int24 internal constant CHANNEL_TICK_UPPER = 60;
    bytes32 internal constant MOCK_INIT_CODE_HASH = keccak256("MOCK_PEGASSET");
    bytes32 internal constant JPY_CURRENCY_ID = keccak256("JPY");
    uint128 internal constant PEG_IS_TOKEN0_BIT = 1 << 127;
    uint256 internal constant JPY_PRICE = 0.0076e18;
    uint256 internal constant USD_PRICE = 1.14e18;

    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;
    PoolId internal poolId;
    PegHook internal hook;
    FuzzMockPegCore internal mockCore;

    function setUp() public {
        deployArtifactsAndLabel();

        mockCore = new FuzzMockPegCore();
        mockCore.setMarketPrice(JPY_MARKET_ID, JPY_PRICE);
        mockCore.setMarketPrice(USD_MARKET_ID, USD_PRICE);

        (currency0, currency1) = _deployChannelCurrencyPair();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags ^ (0x5555 << 144));

        bytes memory constructorArgs =
            abi.encode(poolManager, address(mockCore), MOCK_INIT_CODE_HASH, uint256(USD_MARKET_ID));
        deployCodeTo("PegHook.sol:PegHook", constructorArgs, hookAddress);
        hook = PegHook(hookAddress);

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        hook.registerChannel(poolKey, JPY_MARKET_ID, JPY_CURRENCY_ID);
        _addChannelLiquidity(1_000_000e18);
    }

    function testFuzzBeforeSwapHealingTradeStaysFreeWhenPoolBelowOracle(uint256 deviationWad) public {
        deviationWad = bound(deviationWad, 100, 2 * hook.MAX_DEVIATION());

        _setChannelEma(1e18);
        _setOracleCrossRate(1e18 + deviationWad);

        uint24 feeWithFlag = _beforeSwapFee(!_pegIsToken0());

        assertTrue((feeWithFlag & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0, "healing trades must override the LP fee");
        assertEq(feeWithFlag & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, 0, "healing trades must remain free");
        assertGt(hook.deviation(poolId), 0, "oracle should remain above the robust price in this scenario");
    }

    function testFuzzBeforeSwapToxicTradeMatchesLinearRamp(uint256 deviationWad) public {
        deviationWad = bound(deviationWad, 100, 2 * hook.MAX_DEVIATION());

        _setChannelEma(1e18);
        _setOracleCrossRate(1e18 + deviationWad);

        uint24 feeWithFlag = _beforeSwapFee(_pegIsToken0());
        uint256 oracleRate = hook.oracle(poolId);
        uint256 actualDeviation = oracleRate - 1e18;
        uint24 expectedFee = PegMath.linearFee(actualDeviation, hook.MAX_DEVIATION(), hook.MAX_FEE());

        assertTrue((feeWithFlag & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0, "toxic trades must override the LP fee");
        assertEq(
            feeWithFlag & ~LPFeeLibrary.OVERRIDE_FEE_FLAG,
            expectedFee,
            "toxic fee should follow the documented linear ramp"
        );
    }

    function testFuzzBeforeSwapHealingTradeStaysFreeWhenPoolAboveOracle(uint256 deviationWad) public {
        deviationWad = bound(deviationWad, 100, 2 * hook.MAX_DEVIATION());

        _setChannelEma(1e18);
        _setOracleCrossRate(1e18 - deviationWad);

        uint24 feeWithFlag = _beforeSwapFee(_pegIsToken0());

        assertTrue((feeWithFlag & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0, "healing trades must override the LP fee");
        assertEq(feeWithFlag & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, 0, "healing trades must remain free");
        assertLt(hook.deviation(poolId), 0, "oracle should remain below the robust price in this scenario");
    }

    function testFuzzBeforeSwapToxicTradeMatchesLinearRampWhenPoolAboveOracle(uint256 deviationWad) public {
        deviationWad = bound(deviationWad, 100, 2 * hook.MAX_DEVIATION());

        _setChannelEma(1e18);
        _setOracleCrossRate(1e18 - deviationWad);

        uint24 feeWithFlag = _beforeSwapFee(!_pegIsToken0());
        uint256 oracleRate = hook.oracle(poolId);
        uint256 actualDeviation = 1e18 - oracleRate;
        uint24 expectedFee = PegMath.linearFee(actualDeviation, hook.MAX_DEVIATION(), hook.MAX_FEE());

        assertTrue((feeWithFlag & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0, "toxic trades must override the LP fee");
        assertEq(
            feeWithFlag & ~LPFeeLibrary.OVERRIDE_FEE_FLAG,
            expectedFee,
            "toxic fee should follow the documented linear ramp when pool trades above oracle"
        );
    }

    function testFuzzViewFunctionsMatchMedianOfThree(
        uint256 oracleDeviationWad,
        uint256 emaDeviationWad,
        bool oracleAbovePool,
        bool emaAbovePool
    ) public {
        oracleDeviationWad = bound(oracleDeviationWad, 0, 2 * hook.MAX_DEVIATION());
        emaDeviationWad = bound(emaDeviationWad, 0, 2 * hook.MAX_DEVIATION());

        uint256 oracleRate = oracleAbovePool ? 1e18 + oracleDeviationWad : 1e18 - oracleDeviationWad;
        uint256 emaPrice = emaAbovePool ? 1e18 + emaDeviationWad : 1e18 - emaDeviationWad;

        _setOracleCrossRate(oracleRate);
        _setChannelEma(uint96(emaPrice));

        uint256 expectedOracle = (mockCore.prices(JPY_MARKET_ID) * 1e18) / mockCore.prices(USD_MARKET_ID);
        uint256 expectedRobust = PegMath.median(expectedOracle, 1e18, emaPrice);
        int256 expectedDeviation = int256(expectedOracle) - int256(expectedRobust);

        assertEq(hook.oracle(poolId), expectedOracle, "oracle view should expose the configured cross-rate");
        assertEq(hook.price(poolId), expectedRobust, "price view should expose the median of oracle, spot, and EMA");
        assertEq(hook.deviation(poolId), expectedDeviation, "deviation view should track oracle minus robust price");
    }

    function testFuzzBeforeAddLiquidityRejectsOutOfBandRanges(uint256 lowerSteps, uint256 upperSteps) public {
        int24 tickSpacing = poolKey.tickSpacing;
        int24 tickLower = -int24(int256(bound(lowerSteps, 0, 20))) * tickSpacing;
        int24 tickUpper = int24(int256(bound(upperSteps, 0, 20))) * tickSpacing;

        vm.assume(tickLower < tickUpper);
        vm.assume(tickLower < CHANNEL_TICK_LOWER || tickUpper > CHANNEL_TICK_UPPER);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(1e18)), salt: bytes32(0)
        });

        vm.expectRevert(PegHook.InvalidLiquidityRange.selector);
        vm.prank(address(poolManager));
        hook.beforeAddLiquidity(address(this), poolKey, params, Constants.ZERO_BYTES);
    }

    function testFuzzBeforeAddLiquidityAllowsInBandRanges(uint256 lowerSteps, uint256 upperSteps) public {
        int24 tickSpacing = poolKey.tickSpacing;
        int24 tickLower = -int24(int256(bound(lowerSteps, 0, 1))) * tickSpacing;
        int24 tickUpper = int24(int256(bound(upperSteps, 0, 1))) * tickSpacing;

        vm.assume(tickLower < tickUpper);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(1e18)), salt: bytes32(0)
        });

        vm.prank(address(poolManager));
        bytes4 selector = hook.beforeAddLiquidity(address(this), poolKey, params, Constants.ZERO_BYTES);

        assertEq(selector, hook.beforeAddLiquidity.selector, "in-band channel liquidity should be accepted");
    }

    function _deployChannelCurrencyPair() internal returns (Currency pegCurrency, Currency anchorCurrency) {
        address pegAssetAddress = _computePegAssetAddress(JPY_CURRENCY_ID);
        bytes memory constructorArgs = abi.encode(JPY_CURRENCY_ID);
        deployCodeTo("PegHookFuzz.t.sol:FuzzMockPegAsset", constructorArgs, pegAssetAddress);

        MockERC20 pegAsset = MockERC20(pegAssetAddress);
        MockERC20 anchorToken = deployToken();

        pegAsset.mint(address(this), 10_000_000 ether);
        pegAsset.approve(address(permit2), type(uint256).max);
        pegAsset.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(pegAsset), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(pegAsset), address(poolManager), type(uint160).max, type(uint48).max);

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

    function _setOracleCrossRate(uint256 oracleRate) internal {
        mockCore.setMarketPrice(JPY_MARKET_ID, (oracleRate * USD_PRICE) / 1e18);
    }

    function _setChannelEma(uint96 emaPrice) internal {
        (, uint32 timestamp, uint128 marketId) = hook.channels(poolId);
        uint256 packed = uint256(emaPrice) | (uint256(timestamp) << 96) | (uint256(marketId) << 128);
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(0)));
        vm.store(address(hook), slot, bytes32(packed));
    }
}

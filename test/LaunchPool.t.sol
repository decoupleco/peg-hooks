// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {BaseTest} from "./utils/BaseTest.sol";

import {LaunchPool} from "../src/LaunchPool.sol";

contract MockLaunchPoolHook is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return this.beforeAddLiquidity.selector;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  LaunchPool Tests
// ═══════════════════════════════════════════════════════════════════════════

contract LaunchPoolTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Test tokens ─────────────────────────────────────────────────────

    MockERC20 anchorToken; // e.g. USDC
    MockERC20 pegToken; // e.g. pegJPY — paired with anchor

    Currency anchorCurrency;
    Currency pegCurrency;

    // ─── Hook ─────────────────────────────────────────────────────────────

    MockLaunchPoolHook hook;

    // ─── LaunchPool ───────────────────────────────────────────────────────

    LaunchPool pool;

    uint256 constant SEED_TARGET = 10_000e18; // 10k anchor units
    uint40 constant SEED_DURATION = 7 days;

    // ─── Pool geometry ────────────────────────────────────────────────────

    // Single-sided, anchor = token1, range below peg (tick=0): (-240, 0)
    // With tickSpacing=60: {-240, -180, -120, -60, 0} are all valid.
    int24 constant TICK_LOWER = -240;
    int24 constant TICK_UPPER = 0;

    // ─── Users ────────────────────────────────────────────────────────────

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // ─── Setup ────────────────────────────────────────────────────────────

    function setUp() public {
        deployArtifactsAndLabel();

        // Deploy anchor and peg tokens — anchor sorts below peg if addr < pegAddr.
        // We need anchor = currency1 for the single-sided-below-peg constraint.
        // We'll force layout by choosing addresses.
        anchorToken = new MockERC20("USD Coin", "USDC", 18);
        pegToken = new MockERC20("Peg JPY", "pegJPY", 18);

        // Mint to test users and self.
        anchorToken.mint(alice, 100_000e18);
        anchorToken.mint(bob, 100_000e18);
        anchorToken.mint(address(this), 100_000e18);

        // Ensure anchor > pegToken in address sort so anchor = currency1.
        // If not, we swap. We check after construction.
        if (address(anchorToken) < address(pegToken)) {
            // anchorToken is currency0 — re-deploy to flip.
            // Easier: just accept the order and set the correct TICK bounds.
            anchorCurrency = Currency.wrap(address(anchorToken));
            pegCurrency = Currency.wrap(address(pegToken));
        } else {
            anchorCurrency = Currency.wrap(address(anchorToken));
            pegCurrency = Currency.wrap(address(pegToken));
        }

        // Approve permit2 for test contract and users.
        _approvePermit2(address(this));
        _approvePermit2(alice);
        _approvePermit2(bob);

        // Deploy a permissive hook at a flag-encoded address.
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        address hookAddr = address(flags ^ (0x5555 << 144));
        deployCodeTo("LaunchPool.t.sol:MockLaunchPoolHook", abi.encode(poolManager), hookAddr);
        hook = MockLaunchPoolHook(hookAddr);
        vm.label(hookAddr, "MockLaunchPoolHook");

        // Deploy LaunchPool — owner = address(this).
        pool = new LaunchPool(
            IERC20(address(anchorToken)), SEED_TARGET, SEED_DURATION, poolManager, positionManager, permit2
        );
        vm.label(address(pool), "LaunchPool");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _approvePermit2(address user) internal {
        vm.startPrank(user);
        anchorToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(anchorToken), address(pool), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _depositAs(address user, uint256 amount) internal {
        vm.startPrank(user);
        anchorToken.approve(address(pool), amount);
        pool.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Build a valid PoolKey for the anchor/peg pair using PegHook.
    function _buildKey() internal view returns (PoolKey memory key) {
        Currency c0;
        Currency c1;
        if (address(anchorToken) < address(pegToken)) {
            c0 = Currency.wrap(address(anchorToken));
            c1 = Currency.wrap(address(pegToken));
        } else {
            c0 = Currency.wrap(address(pegToken));
            c1 = Currency.wrap(address(anchorToken));
        }
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
    }

    /// @dev Figure out tick bounds appropriate for single-sided anchor.
    ///      If anchor = currency1 → range below peg (tickUpper=0).
    ///      If anchor = currency0 → range above peg (tickLower=0).
    function _singleSidedTicks(PoolKey memory key) internal view returns (int24 tl, int24 tu) {
        if (Currency.unwrap(key.currency1) == address(anchorToken)) {
            tl = -240;
            tu = 0;
        } else {
            tl = 0;
            tu = 240;
        }
    }

    /// @dev Compute liquidity for the single-sided anchor position.
    function _computeLiquidity(PoolKey memory key, int24 tl, int24 tu) internal view returns (uint128) {
        bool anchorIs1 = Currency.unwrap(key.currency1) == address(anchorToken);
        if (anchorIs1) {
            // Single-sided token1: getLiquidityForAmount1
            return LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), pool.totalDeposits()
            );
        } else {
            // Single-sided token0: getLiquidityForAmount0
            return LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), pool.totalDeposits()
            );
        }
    }

    /// @dev Deposit exactly `target` from `alice` then activate.
    function _meetTargetAndActivate() internal {
        _depositAs(alice, SEED_TARGET);

        PoolKey memory key = _buildKey();
        (int24 tl, int24 tu) = _singleSidedTicks(key);
        uint128 liq = _computeLiquidity(key, tl, tu);

        // Approve the LaunchPool's anchor for PositionManager (done via permit2).
        // LaunchPool calls permit2.approve internally, so we just activate.
        pool.activate(key, tl, tu, liq);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: deposit
    // ═══════════════════════════════════════════════════════════════════════

    function testDeposit() public {
        uint256 amount = 1_000e18;
        _depositAs(alice, amount);

        assertEq(pool.deposits(alice), amount, "alice deposit mismatch");
        assertEq(pool.totalDeposits(), amount, "totalDeposits mismatch");
        assertEq(anchorToken.balanceOf(address(pool)), amount, "pool balance mismatch");
    }

    function testMultipleDepositors() public {
        _depositAs(alice, 6_000e18);
        _depositAs(bob, 4_000e18);

        assertEq(pool.totalDeposits(), 10_000e18);
        assertEq(uint256(pool.stage()), uint256(LaunchPool.Stage.Seeding));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: deposit blocked after deadline
    // ═══════════════════════════════════════════════════════════════════════

    function testDepositAfterDeadlineReverts() public {
        vm.warp(block.timestamp + SEED_DURATION + 1);
        vm.startPrank(alice);
        anchorToken.approve(address(pool), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchPool.InvalidStage.selector, LaunchPool.Stage.Seeding, LaunchPool.Stage.Failed)
        );
        pool.deposit(1e18, alice);
        vm.stopPrank();
    }

    function testDepositAfterActivationReverts() public {
        _meetTargetAndActivate();

        vm.startPrank(alice);
        anchorToken.approve(address(pool), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchPool.InvalidStage.selector, LaunchPool.Stage.Seeding, LaunchPool.Stage.Active)
        );
        pool.deposit(1e18, alice);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: withdraw after failure
    // ═══════════════════════════════════════════════════════════════════════

    function testWithdrawAfterFailure() public {
        uint256 amount = 1_000e18; // below target
        _depositAs(alice, amount);

        vm.warp(block.timestamp + SEED_DURATION + 1);

        assertEq(uint256(pool.stage()), uint256(LaunchPool.Stage.Failed));

        uint256 balBefore = anchorToken.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw();
        uint256 balAfter = anchorToken.balanceOf(alice);

        assertEq(balAfter - balBefore, amount, "withdraw amount mismatch");
        assertEq(pool.deposits(alice), 0, "deposit not cleared");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: withdraw blocked during seeding
    // ═══════════════════════════════════════════════════════════════════════

    function testWithdrawDuringSeedingReverts() public {
        _depositAs(alice, 1_000e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchPool.InvalidStage.selector, LaunchPool.Stage.Failed, LaunchPool.Stage.Seeding)
        );
        pool.withdraw();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: activation
    // ═══════════════════════════════════════════════════════════════════════

    function testActivate() public {
        _meetTargetAndActivate();

        assertTrue(pool.activated(), "pool should be activated");
        assertGt(pool.lpTokenId(), 0, "lpTokenId should be assigned");
        assertGt(uint256(pool.lpLiquidity()), 0, "lpLiquidity should be > 0");
        assertEq(uint256(pool.stage()), uint256(LaunchPool.Stage.Active));
    }

    function testActivateBelowTargetReverts() public {
        _depositAs(alice, SEED_TARGET / 2); // only half the target

        PoolKey memory key = _buildKey();
        (int24 tl, int24 tu) = _singleSidedTicks(key);

        vm.expectRevert(abi.encodeWithSelector(LaunchPool.TargetNotMet.selector, SEED_TARGET / 2, SEED_TARGET));
        pool.activate(key, tl, tu, 1000);
    }

    function testActivateByNonOwnerReverts() public {
        _depositAs(alice, SEED_TARGET);

        PoolKey memory key = _buildKey();
        (int24 tl, int24 tu) = _singleSidedTicks(key);

        vm.prank(alice);
        vm.expectRevert(LaunchPool.Unauthorized.selector);
        pool.activate(key, tl, tu, 1000);
    }

    function testActivateWrongTicksReverts() public {
        _depositAs(alice, SEED_TARGET);

        PoolKey memory key = _buildKey();
        // Pass ticks that are NOT single-sided for the anchor currency.
        int24 badLower = -120;
        int24 badUpper = 120; // straddles peg — NOT single-sided

        vm.expectRevert(LaunchPool.TicksNotSingleSided.selector);
        pool.activate(key, badLower, badUpper, 1000);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: redeem pro-rata shares
    // ═══════════════════════════════════════════════════════════════════════

    function testRedeemAfterActivation() public {
        // Alice 60%, Bob 40%
        _depositAs(alice, 6_000e18);
        _depositAs(bob, 4_000e18);

        PoolKey memory key = _buildKey();
        (int24 tl, int24 tu) = _singleSidedTicks(key);
        uint128 liq = _computeLiquidity(key, tl, tu);
        pool.activate(key, tl, tu, liq);

        // Alice redeems
        vm.prank(alice);
        pool.redeem();
        assertEq(pool.deposits(alice), 0, "alice deposit not cleared");

        // Bob redeems
        vm.prank(bob);
        pool.redeem();
        assertEq(pool.deposits(bob), 0, "bob deposit not cleared");

        // Both should have received some output tokens (anchor + maybe peg).
        // Single-sided position → primarily anchor returned.
        assertTrue(anchorToken.balanceOf(alice) > 100_000e18 - 6_000e18, "alice should receive anchor back");
    }

    function testRedeemWithNothingReverts() public {
        _meetTargetAndActivate();

        // bob never deposited
        vm.prank(bob);
        vm.expectRevert(LaunchPool.NothingToRedeem.selector);
        pool.redeem();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: PendingActivation stage (blocking issue #1 fix)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev After deadline, if target was met, stage = PendingActivation.
    ///      Deposits must be rejected even though contract is not yet activated.
    function testDepositAfterDeadlineTargetMetReverts() public {
        _depositAs(alice, SEED_TARGET);
        vm.warp(block.timestamp + SEED_DURATION + 1);

        assertEq(uint256(pool.stage()), uint256(LaunchPool.Stage.PendingActivation));

        vm.startPrank(alice);
        anchorToken.approve(address(pool), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchPool.InvalidStage.selector, LaunchPool.Stage.Seeding, LaunchPool.Stage.PendingActivation
            )
        );
        pool.deposit(1e18, alice);
        vm.stopPrank();
    }

    /// @dev Owner can call activate() from PendingActivation (post-deadline).
    function testActivateInPendingStage() public {
        _depositAs(alice, SEED_TARGET);
        vm.warp(block.timestamp + SEED_DURATION + 1);

        assertEq(uint256(pool.stage()), uint256(LaunchPool.Stage.PendingActivation));

        PoolKey memory key = _buildKey();
        (int24 tl, int24 tu) = _singleSidedTicks(key);
        uint128 liq = _computeLiquidity(key, tl, tu);
        pool.activate(key, tl, tu, liq);

        assertTrue(pool.activated(), "should be active after deadline activation");
        assertEq(uint256(pool.stage()), uint256(LaunchPool.Stage.Active));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: ERC-4626 view surface
    // ═══════════════════════════════════════════════════════════════════════

    function testERC4626Views() public {
        assertEq(pool.asset(), address(anchorToken), "asset");
        assertEq(pool.totalAssets(), 0, "totalAssets empty");
        assertEq(pool.convertToShares(1_000e18), 1_000e18, "convertToShares 1:1");
        assertEq(pool.convertToAssets(1_000e18), 1_000e18, "convertToAssets 1:1");
        assertEq(pool.maxDeposit(alice), type(uint256).max, "maxDeposit open");

        _depositAs(alice, 5_000e18);
        assertEq(pool.totalAssets(), 5_000e18, "totalAssets after deposit");

        // After deadline without hitting target: maxDeposit = 0
        vm.warp(block.timestamp + SEED_DURATION + 1);
        assertEq(pool.maxDeposit(alice), 0, "maxDeposit closed after deadline");
    }
}

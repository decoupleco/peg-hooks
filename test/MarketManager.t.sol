// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {BaseTest} from "./utils/BaseTest.sol";

import {MarketManager} from "../src/MarketManager.sol";
import {LaunchPool} from "../src/LaunchPool.sol";
import {IMarketManagerCore, Id, MarketParams} from "../src/interfaces/IMarketManagerCore.sol";
import {IPegAssetFactory} from "../src/interfaces/IPegAssetFactory.sol";

// ═══════════════════════════════════════════════════════════════════════════
//  Mock: PegCore (no access control — records calls only)
// ═══════════════════════════════════════════════════════════════════════════

contract MockMMCore is IMarketManagerCore {
    mapping(bytes32 => bool) public created;
    mapping(bytes32 => uint112) public borrowCaps;

    function createMarket(MarketParams calldata p) external {
        bytes32 id = keccak256(abi.encode(p.collateralToken, p.loanToken, p.oracle, p.model));
        created[id] = true;
    }

    function setBorrowCap(Id id, uint112 cap) external {
        borrowCaps[Id.unwrap(id)] = cap;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Mock: PegAssetFactory (returns a caller-configured address)
// ═══════════════════════════════════════════════════════════════════════════

contract MockMMFactory is IPegAssetFactory {
    address public nextAsset;

    function setNextAsset(address asset) external {
        nextAsset = asset;
    }

    function createPegAsset(string calldata, string calldata) external returns (address) {
        return nextAsset;
    }
}

contract MockMarketManagerHook is BaseHook {
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
//  MarketManager Tests
// ═══════════════════════════════════════════════════════════════════════════

contract MarketManagerTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    // ─── Constants ────────────────────────────────────────────────────────

    uint256 constant SEED_TARGET = 10_000e18;
    uint40 constant SEED_DURATION = 7 days;
    uint112 constant BORROW_CAP = 1_000_000e18;

    // ─── Shared state ─────────────────────────────────────────────────────

    MockMMCore mockCore;
    MockMMFactory mockFactory;
    MockERC20 anchorToken;
    MockERC20 pegToken;
    MockMarketManagerHook hook;
    MarketManager mm;

    // Sort-order-dependent tick bounds (set in setUp after address comparison)
    bool anchorIsToken0;
    int24 tickLower;
    int24 tickUpper;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // ─── Setup ────────────────────────────────────────────────────────────

    function setUp() public {
        deployArtifactsAndLabel();

        // Deploy mock core + factory.
        mockCore = new MockMMCore();
        mockFactory = new MockMMFactory();

        // Deploy anchor + peg tokens.  Their relative address order determines
        // which token is currency0 and therefore which tick-side is "single-sided".
        anchorToken = new MockERC20("USD Coin", "USDC", 18);
        pegToken = new MockERC20("Peg JPY", "pegJPY", 18);

        // Wire factory to return the pre-deployed pegToken.
        mockFactory.setNextAsset(address(pegToken));

        // Derive tick bounds from the sort order so LaunchPool's single-sided
        // constraint is satisfied.
        anchorIsToken0 = address(anchorToken) < address(pegToken);
        if (anchorIsToken0) {
            // anchor = currency0 → range at and above tick 0 (all token0)
            tickLower = 0;
            tickUpper = 240;
        } else {
            // anchor = currency1 → range at and below tick 0 (all token1)
            tickLower = -240;
            tickUpper = 0;
        }

        // Deploy a permissive hook at the correct flag-encoded address.
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        address hookAddr = address(flags ^ (0x4444 << 144));
        deployCodeTo("MarketManager.t.sol:MockMarketManagerHook", abi.encode(poolManager), hookAddr);
        hook = MockMarketManagerHook(hookAddr);
        vm.label(hookAddr, "MockMarketManagerHook");

        // Deploy MarketManager — address(this) is the owner.
        mm = new MarketManager(
            IMarketManagerCore(address(mockCore)),
            IPegAssetFactory(address(mockFactory)),
            poolManager,
            positionManager,
            permit2,
            address(hook)
        );
        vm.label(address(mm), "MarketManager");

        // Fund alice, approve permit2 globally for anchor → LaunchPool.
        anchorToken.mint(alice, 100_000e18);
        anchorToken.mint(bob, 100_000e18);
        _approvePermit2(alice);
        _approvePermit2(bob);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _approvePermit2(address user) internal {
        vm.startPrank(user);
        anchorToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev MarketConfig with correct tick bounds for the current token sort order.
    function _config() internal view returns (MarketManager.MarketConfig memory) {
        return MarketManager.MarketConfig({
            anchor: IERC20(address(anchorToken)),
            launchTarget: SEED_TARGET,
            launchDuration: SEED_DURATION,
            tickLower: tickLower,
            tickUpper: tickUpper,
            initialBorrowCap: BORROW_CAP
        });
    }

    /// @dev Dummy MarketParams — loanToken is overwritten by mm.create().
    function _params() internal pure returns (MarketParams memory) {
        return MarketParams({
            collateralToken: address(0x1111), loanToken: address(0), oracle: address(0x2222), model: address(0x3333)
        });
    }

    /// @dev Create market, return its Id.
    function _createMarket() internal returns (Id marketId) {
        marketId = mm.create(_config(), _params(), "Peg JPY", "pegJPY");
    }

    /// @dev Create market, deposit full target, warp to PendingActivation.
    function _reachPendingActivation() internal returns (Id marketId, LaunchPool lp) {
        marketId = _createMarket();
        MarketManager.MarketRecord memory rec = mm.getMarket(marketId);
        lp = LaunchPool(rec.launchPool);

        vm.startPrank(alice);
        anchorToken.approve(address(lp), type(uint256).max);
        permit2.approve(address(anchorToken), address(lp), type(uint160).max, type(uint48).max);
        lp.deposit(SEED_TARGET, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + SEED_DURATION + 1);
        assertEq(uint256(lp.stage()), uint256(LaunchPool.Stage.PendingActivation));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  create()
    // ═════════════════════════════════════════════════════════════════════

    function testCreate() public {
        Id marketId = _createMarket();
        MarketManager.MarketRecord memory rec = mm.getMarket(marketId);

        // LaunchPool deployed.
        assertTrue(rec.launchPool != address(0), "launchPool zero");

        // PegAsset is our pre-deployed mock.
        assertEq(rec.pegAsset, address(pegToken));

        // Not yet active.
        assertFalse(rec.active);

        // Market count incremented.
        assertEq(mm.marketCount(), 1);

        // PegCore was notified (createMarket called).
        assertTrue(mockCore.created(Id.unwrap(marketId)));
    }

    function testCreateByNonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(MarketManager.Unauthorized.selector);
        mm.create(_config(), _params(), "Peg JPY", "pegJPY");
    }

    function testCreateLaunchPoolOwnerIsManager() public {
        Id marketId = _createMarket();
        MarketManager.MarketRecord memory rec = mm.getMarket(marketId);
        LaunchPool lp = LaunchPool(rec.launchPool);
        assertEq(lp.owner(), address(mm));
    }

    function testCreateBorrowCapIsZero() public {
        Id marketId = _createMarket();
        // borrowCap not set during create — market is inactive.
        assertEq(mockCore.borrowCaps(Id.unwrap(marketId)), 0);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  activate()
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Key test: alice deposits, BOB (not owner) triggers graduation.
    function testActivatePermissionless() public {
        (Id marketId, LaunchPool lp) = _reachPendingActivation();

        // Bob activates — permissionless, no access control.
        vm.prank(bob);
        mm.activate(marketId);

        // LaunchPool is now Active.
        assertEq(uint256(lp.stage()), uint256(LaunchPool.Stage.Active));

        // MarketRecord updated.
        MarketManager.MarketRecord memory rec = mm.getMarket(marketId);
        assertTrue(rec.active);

        // BorrowCap set on PegCore.
        assertEq(mockCore.borrowCaps(Id.unwrap(marketId)), BORROW_CAP);
    }

    function testActivateBeforeDeadlineReverts() public {
        Id marketId = _createMarket();
        MarketManager.MarketRecord memory rec = mm.getMarket(marketId);
        LaunchPool lp = LaunchPool(rec.launchPool);

        // Deposit target but don't warp — stage is still Seeding.
        vm.startPrank(alice);
        anchorToken.approve(address(lp), type(uint256).max);
        permit2.approve(address(anchorToken), address(lp), type(uint160).max, type(uint48).max);
        lp.deposit(SEED_TARGET, alice);
        vm.stopPrank();

        assertEq(uint256(lp.stage()), uint256(LaunchPool.Stage.Seeding));

        vm.expectRevert(abi.encodeWithSelector(MarketManager.NotReady.selector, LaunchPool.Stage.Seeding));
        mm.activate(marketId);
    }

    function testActivateTargetNotMetReverts() public {
        Id marketId = _createMarket();
        MarketManager.MarketRecord memory rec = mm.getMarket(marketId);
        LaunchPool lp = LaunchPool(rec.launchPool);

        // Deposit less than target then warp — stage = Failed.
        vm.startPrank(alice);
        anchorToken.approve(address(lp), type(uint256).max);
        permit2.approve(address(anchorToken), address(lp), type(uint160).max, type(uint48).max);
        lp.deposit(SEED_TARGET - 1e18, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + SEED_DURATION + 1);
        assertEq(uint256(lp.stage()), uint256(LaunchPool.Stage.Failed));

        vm.expectRevert(abi.encodeWithSelector(MarketManager.NotReady.selector, LaunchPool.Stage.Failed));
        mm.activate(marketId);
    }

    function testActivateAlreadyActiveReverts() public {
        (Id marketId,) = _reachPendingActivation();
        mm.activate(marketId);

        vm.expectRevert(MarketManager.MarketAlreadyActive.selector);
        mm.activate(marketId);
    }

    function testActivateUnknownMarketReverts() public {
        Id fakeId = Id.wrap(bytes32(uint256(0xdead)));
        vm.expectRevert(MarketManager.MarketNotFound.selector);
        mm.activate(fakeId);
    }

    function testActivateSetsLpPositionOnLaunchPool() public {
        (Id marketId, LaunchPool lp) = _reachPendingActivation();
        mm.activate(marketId);

        // LP position was minted with real liquidity.
        assertTrue(lp.lpLiquidity() > 0, "no liquidity minted");
        assertTrue(lp.lpTokenId() > 0, "no token id");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  disable()
    // ═════════════════════════════════════════════════════════════════════

    function testDisableSetsCapToZero() public {
        (Id marketId,) = _reachPendingActivation();
        mm.activate(marketId);

        mm.disable(marketId);
        assertEq(mockCore.borrowCaps(Id.unwrap(marketId)), 0);
    }

    function testDisableByNonOwnerReverts() public {
        Id marketId = _createMarket();
        vm.prank(alice);
        vm.expectRevert(MarketManager.Unauthorized.selector);
        mm.disable(marketId);
    }

    function testDisableUnknownMarketReverts() public {
        Id fakeId = Id.wrap(bytes32(uint256(0xbeef)));
        vm.expectRevert(MarketManager.MarketNotFound.selector);
        mm.disable(fakeId);
    }
}

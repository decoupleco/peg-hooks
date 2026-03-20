// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {IPegCore as FixturePegCore} from "./utils/peg/IPegCore.sol";
import {Id as FixtureId, MarketParams as FixtureMarketParams} from "./utils/peg/PegTypes.sol";
import {MockPegOracle} from "./utils/peg/MockPegOracle.sol";

import {LaunchPool} from "../src/LaunchPool.sol";
import {MarketManager} from "../src/MarketManager.sol";
import {PegHook} from "../src/PegHook.sol";
import {IPegAssetFactory} from "../src/interfaces/IPegAssetFactory.sol";
import {IPegCore as LaunchPegCore, Id, MarketParams} from "../src/interfaces/IPegCore.sol";

contract IntegrationPegJPYAsset is MockERC20 {
    bytes32 internal constant JPY_CURRENCY_ID = keccak256("JPY");

    constructor() MockERC20("Peg Japanese Yen", "pegJPY", 18) {}

    function currency() external pure returns (bytes32) {
        return JPY_CURRENCY_ID;
    }
}

contract IntegrationCreate2PegAssetFactory is IPegAssetFactory {
    bytes32 internal constant JPY_CURRENCY_ID = keccak256("JPY");

    address public immutable expectedAsset;

    constructor(address core, bytes32 initCodeHash) {
        expectedAsset =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), core, JPY_CURRENCY_ID, initCodeHash)))));
    }

    function createPegAsset(string calldata, string calldata) external view returns (address) {
        return expectedAsset;
    }
}

contract LaunchFlowIntegrationTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant SEED_TARGET = 10_000e18;
    uint40 internal constant SEED_DURATION = 7 days;
    uint112 internal constant BORROW_CAP = 1_000_000e18;
    uint256 internal constant JPY_MARKET_PRICE = 0.0076e18;
    uint256 internal constant USD_MARKET_PRICE = 1.14e18;
    uint160 internal constant SQRT_PRICE_1_1 = uint160(1 << 96);

    IntegrationCreate2PegAssetFactory internal factory;
    PegHook internal pegHook;
    MarketManager internal marketManager;
    MockERC20 internal anchorToken;
    MockERC20 internal usdPegAsset;
    MockPegOracle internal jpyOracle;
    MockPegOracle internal usdOracle;
    Id internal usdMarketId;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        deployArtifactsAndLabel();
        deployPegArtifactsAndLabel();

        anchorToken = new MockERC20("USD Coin", "USDC", 18);
        usdPegAsset = new MockERC20("Peg USD", "pegUSD", 18);
        jpyOracle = new MockPegOracle(JPY_MARKET_PRICE);
        usdOracle = new MockPegOracle(USD_MARKET_PRICE);
        anchorToken.mint(alice, 100_000e18);

        pegModel.setCollateralToken(address(anchorToken));

        // The factory deploys the PegAsset at the exact CREATE2 address PegHook derives from real PegCore.
        bytes32 pegAssetInitCodeHash = keccak256(type(IntegrationPegJPYAsset).creationCode);
        factory = new IntegrationCreate2PegAssetFactory(address(pegCore), pegAssetInitCodeHash);
        deployCodeTo("LaunchFlowIntegration.t.sol:IntegrationPegJPYAsset", bytes(""), factory.expectedAsset());

        usdMarketId = _createReferenceUsdMarket();

        // Real PegCore requires the model and LLTV to be configured for the final market id before create().
        pegModel.setLltv(_expectedFixtureMarketId(), 0.8e18);

        // Deploy the real PegHook so activation goes through the actual channel checks.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags ^ (0x6666 << 144));
        deployCodeTo(
            "PegHook.sol:PegHook",
            abi.encode(poolManager, address(pegCore), pegAssetInitCodeHash, usdMarketId),
            hookAddress
        );
        pegHook = PegHook(hookAddress);

        // MarketManager owns the LaunchPool lifecycle and points at the real PegHook.
        marketManager = new MarketManager(
            LaunchPegCore(address(pegCore)),
            IPegAssetFactory(address(factory)),
            poolManager,
            positionManager,
            permit2,
            address(pegHook)
        );

        // Alice only needs Permit2 approval up front; LaunchPool receives explicit allowance in-test.
        vm.startPrank(alice);
        anchorToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function testChannelPoolCanInitializeBeforeRegistrationIsRequired() public {
        (Id marketId, MarketManager.MarketRecord memory record,) = _createPendingActivationMarket();
        PoolKey memory key = _poolKey(record);

        poolManager.initialize(key, SQRT_PRICE_1_1);

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);

        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "pool should initialize at the documented 1:1 peg price");
        assertEq(tick, 0, "pool should initialize at tick 0");

        MarketManager.MarketRecord memory refreshed = marketManager.getMarket(marketId);
        assertEq(refreshed.pegAsset, record.pegAsset, "initialization should not mutate the market record");
    }

    function testDocumentedGraduationFlowRevertsWithoutPegHookRegistration() public {
        (Id marketId, MarketManager.MarketRecord memory record, LaunchPool launchPool) =
            _createPendingActivationMarket();

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(pegHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(PegHook.ChannelNotRegistered.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(bob);
        marketManager.activate(marketId);

        record = marketManager.getMarket(marketId);
        assertFalse(record.active, "market should remain inactive after failed graduation");
        (,,,,,,, uint112 borrowCap) = pegCore.market(_toFixtureId(marketId));
        assertEq(borrowCap, 0, "borrow cap should not be set on failed graduation");
        assertEq(
            uint256(launchPool.stage()),
            uint256(LaunchPool.Stage.PendingActivation),
            "launch pool should remain pending after failed graduation"
        );
    }

    function _createPendingActivationMarket()
        internal
        returns (Id marketId, MarketManager.MarketRecord memory record, LaunchPool launchPool)
    {
        marketId = marketManager.create(_config(), _params(), "Peg Japanese Yen", "pegJPY");
        record = marketManager.getMarket(marketId);
        launchPool = LaunchPool(record.launchPool);

        vm.startPrank(alice);
        anchorToken.approve(address(launchPool), type(uint256).max);
        permit2.approve(address(anchorToken), address(launchPool), type(uint160).max, type(uint48).max);
        launchPool.deposit(SEED_TARGET, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + SEED_DURATION + 1);
        assertEq(uint256(launchPool.stage()), uint256(LaunchPool.Stage.PendingActivation));
    }

    function _poolKey(MarketManager.MarketRecord memory record) internal view returns (PoolKey memory) {
        address pegAsset = record.pegAsset;
        address anchor = address(record.config.anchor);
        bool anchorIsToken0 = anchor < pegAsset;

        return PoolKey({
            currency0: anchorIsToken0 ? Currency.wrap(anchor) : Currency.wrap(pegAsset),
            currency1: anchorIsToken0 ? Currency.wrap(pegAsset) : Currency.wrap(anchor),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(pegHook))
        });
    }

    function _config() internal view returns (MarketManager.MarketConfig memory) {
        address expectedPegAsset = factory.expectedAsset();
        bool anchorIsToken0 = address(anchorToken) < expectedPegAsset;

        return MarketManager.MarketConfig({
            anchor: IERC20(address(anchorToken)),
            launchTarget: SEED_TARGET,
            launchDuration: SEED_DURATION,
            tickLower: anchorIsToken0 ? int24(0) : int24(-240),
            tickUpper: anchorIsToken0 ? int24(240) : int24(0),
            initialBorrowCap: BORROW_CAP
        });
    }

    function _params() internal view returns (MarketParams memory) {
        return MarketParams({
            collateralToken: address(anchorToken),
            loanToken: address(0),
            oracle: address(jpyOracle),
            model: address(pegModel)
        });
    }

    function _expectedFixtureMarketId() internal view returns (FixtureId) {
        address expectedPegAsset = factory.expectedAsset();
        return FixtureId.wrap(
            keccak256(abi.encode(address(anchorToken), expectedPegAsset, address(jpyOracle), address(pegModel)))
        );
    }

    function _createReferenceUsdMarket() internal returns (Id launchId) {
        FixtureMarketParams memory params = FixtureMarketParams({
            collateralToken: address(anchorToken),
            loanToken: address(usdPegAsset),
            oracle: address(usdOracle),
            model: address(pegModel)
        });
        FixtureId fixtureId = FixtureId.wrap(
            keccak256(abi.encode(params.collateralToken, params.loanToken, params.oracle, params.model))
        );

        pegModel.setLltv(fixtureId, 0.8e18);
        pegCore.createMarket(params);

        launchId = _toLaunchId(fixtureId);
    }

    function _toLaunchId(FixtureId marketId) internal pure returns (Id) {
        return Id.wrap(FixtureId.unwrap(marketId));
    }

    function _toFixtureId(Id marketId) internal pure returns (FixtureId) {
        return FixtureId.wrap(Id.unwrap(marketId));
    }
}

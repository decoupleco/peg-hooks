// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IMarketManagerCore, Id, MarketParams} from "./interfaces/IMarketManagerCore.sol";
import {IPegAssetFactory} from "./interfaces/IPegAssetFactory.sol";
import {LaunchPool} from "./LaunchPool.sol";

/// @title  MarketManager — Lifecycle orchestrator for peg.markets channels
///
/// @notice Coordinates the full market lifecycle:
///
///   create()    (owner)         — Deploys a new PegAsset synthetic token and
///                                 a LaunchPool bootstrap vault. Registers the
///                                 market in PegCore with borrowCap = 0 (inactive).
///
///   activate()  (permissionless) — Once the LaunchPool reaches PendingActivation
///                                 (deadline elapsed + target met), anyone may call.
///                                 Initialises the UniV4 channel pool, mints single-
///                                 sided LP from accumulated deposits, then sets
///                                 borrowCap in PegCore to enable live trading.
///
///   disable()   (owner)         — Emergency freeze: sets borrowCap back to 0.
///
/// @dev    MarketManager must be the PegCore admin to call setBorrowCap.
///         All deployed LaunchPool contracts have MarketManager as their owner.
///
/// @dev    TODO: call PegHook.registerChannel(key, marketId, currencyId) inside
///         activate() once PegAssetFactory is upgraded to CREATE2 deployment so
///         that the PEGASSET_INIT_CODE_HASH validation in registerChannel passes.
contract MarketManager {
    using PoolIdLibrary for PoolKey;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev UniV4 dynamic-fee flag — required for PegHook pool keys.
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;

    /// @dev Tick spacing for all peg channel pools.
    int24 internal constant TICK_SPACING = 60;

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice PegCore singleton — market creation and cap management.
    IMarketManagerCore public immutable core;

    /// @notice PegAsset factory — deploys synthetic ERC-20 token contracts.
    IPegAssetFactory public immutable factory;

    /// @notice UniV4 PoolManager singleton.
    IPoolManager public immutable poolManager;

    /// @notice UniV4 PositionManager (passed through to each LaunchPool).
    IPositionManager public immutable positionManager;

    /// @notice Permit2 router (passed through to each LaunchPool).
    IPermit2 public immutable permit2;

    /// @notice PegHook — deployed at a UniV4 flag-encoded address.
    address public immutable pegHook;

    /// @notice Account authorised to call create() and disable().
    address public immutable owner;

    // ═══════════════════════════════════════════════════════════════════════
    //  Types
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Per-market configuration set at create() and consumed at activate().
    /// @dev    Tick bounds must be consistent with the anchor/peg sort order:
    ///           anchor = currency1 → tickUpper ≤ 0 (single-sided token1 range)
    ///           anchor = currency0 → tickLower ≥ 0 (single-sided token0 range)
    struct MarketConfig {
        IERC20  anchor;           // Deposit token for LaunchPool (e.g. USDC, sUSDS)
        uint256 launchTarget;     // Minimum total deposits in anchor units
        uint40  launchDuration;   // Seeding window length in seconds
        int24   tickLower;        // Concentrated LP range — lower tick bound
        int24   tickUpper;        //                         upper tick bound
        uint112 initialBorrowCap; // PegCore borrowCap applied at graduation
    }

    /// @notice On-chain registry entry per market.
    struct MarketRecord {
        address      launchPool;  // LaunchPool address owned by this contract
        address      pegAsset;    // Deployed PegAsset (loanToken in PegCore)
        bool         active;      // true once activate() succeeds
        MarketConfig config;      // Immutable parameters set at create()
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Storage
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Registry: PegCore market Id → MarketRecord.
    mapping(Id => MarketRecord) public markets;

    /// @notice Ordered list of all created market Ids (for enumeration).
    Id[] public marketIds;

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a market and its LaunchPool are created.
    event MarketCreated(
        Id      indexed marketId,
        address indexed launchPool,
        address indexed pegAsset
    );

    /// @notice Emitted when a market is graduated (pool live, borrowCap set).
    event MarketActivated(Id indexed marketId, PoolId indexed channelId);

    /// @notice Emitted when a market's borrowCap is set to 0 (frozen).
    event MarketDisabled(Id indexed marketId);

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error Unauthorized();
    error MarketAlreadyActive();
    /// @param actual  The stage the LaunchPool is currently in.
    error NotReady(LaunchPool.Stage actual);
    error MarketNotFound();

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        IMarketManagerCore _core,
        IPegAssetFactory   _factory,
        IPoolManager       _poolManager,
        IPositionManager   _positionManager,
        IPermit2           _permit2,
        address            _pegHook
    ) {
        core            = _core;
        factory         = _factory;
        poolManager     = _poolManager;
        positionManager = _positionManager;
        permit2         = _permit2;
        pegHook         = _pegHook;
        owner           = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Modifiers
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  create()
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Create a new peg market and deploy its bootstrap LaunchPool.
    ///
    /// @dev    Prerequisites (caller's responsibility before this call):
    ///           • coreParams.model is approved in PegCore (setModel).
    ///           • model accepts coreParams.collateralToken (setCollateralToken).
    ///           • model.lltv(expectedMarketId) > 0 (setLltv).
    ///         The `loanToken` field in coreParams is ignored — it is always
    ///         overwritten with the freshly deployed PegAsset address.
    ///
    /// @param config      Channel and LaunchPool parameters (immutable after creation).
    /// @param coreParams  PegCore MarketParams (loanToken overwritten internally).
    /// @param pegName     ERC-20 name for the PegAsset  (e.g. "Peg Japanese Yen").
    /// @param pegSymbol   ERC-20 symbol for the PegAsset (e.g. "pegJPY").
    /// @return marketId   PegCore market Id (keccak256 of final MarketParams).
    function create(
        MarketConfig calldata config,
        MarketParams calldata coreParams,
        string calldata pegName,
        string calldata pegSymbol
    ) external onlyOwner returns (Id marketId) {
        // 1. Deploy the PegAsset synthetic token via factory.
        address pegAsset = factory.createPegAsset(pegName, pegSymbol);

        // 2. Build final MarketParams, overwriting loanToken with the deployed PegAsset.
        MarketParams memory params = MarketParams({
            collateralToken: coreParams.collateralToken,
            loanToken:       pegAsset,
            oracle:          coreParams.oracle,
            model:           coreParams.model
        });

        // 3. Derive market Id.
        marketId = _marketId(params);

        // 4. Register market in PegCore — borrowCap is 0 until activate() is called.
        core.createMarket(params);

        // 5. Deploy LaunchPool — this contract acts as its owner.
        address launchPool = address(
            new LaunchPool(
                config.anchor,
                config.launchTarget,
                config.launchDuration,
                poolManager,
                positionManager,
                permit2
            )
        );

        // 6. Store registry record.
        markets[marketId] = MarketRecord({
            launchPool: launchPool,
            pegAsset:   pegAsset,
            active:     false,
            config:     config
        });
        marketIds.push(marketId);

        emit MarketCreated(marketId, launchPool, pegAsset);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  activate()
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Graduate a market to live trading.
    ///         Permissionless — callable by anyone once the LaunchPool has
    ///         reached the PendingActivation stage (deadline elapsed + target met).
    ///
    ///         Sequence performed atomically:
    ///           1. Validate LaunchPool.stage() == PendingActivation.
    ///           2. Derive channel PoolKey from sorted (pegAsset, anchor) pair.
    ///           3. Compute single-sided liquidity from totalDeposits + tick bounds.
    ///           4. LaunchPool.activate() → UniV4 pool initialised + LP minted.
    ///           5. core.setBorrowCap() → PegCore market goes live.
    ///
    /// @param marketId  The market to graduate.
    function activate(Id marketId) external {
        MarketRecord storage rec = markets[marketId];
        if (rec.launchPool == address(0)) revert MarketNotFound();
        if (rec.active) revert MarketAlreadyActive();

        LaunchPool lp = LaunchPool(rec.launchPool);
        LaunchPool.Stage s = lp.stage();
        if (s != LaunchPool.Stage.PendingActivation) revert NotReady(s);

        MarketConfig storage cfg = rec.config;

        // Sort pegAsset and anchor into currency0 < currency1 (UniV4 convention).
        address pegAssetAddr = rec.pegAsset;
        address anchorAddr   = address(cfg.anchor);
        bool anchorIsToken0  = anchorAddr < pegAssetAddr;

        PoolKey memory key = PoolKey({
            currency0:   anchorIsToken0
                             ? Currency.wrap(anchorAddr)
                             : Currency.wrap(pegAssetAddr),
            currency1:   anchorIsToken0
                             ? Currency.wrap(pegAssetAddr)
                             : Currency.wrap(anchorAddr),
            fee:         DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(pegHook)
        });

        // Compute single-sided liquidity from the full anchor deposit balance.
        uint128 liquidity = _computeLiquidity(
            lp.totalDeposits(),
            cfg.tickLower,
            cfg.tickUpper,
            anchorIsToken0
        );

        // Initialize the UniV4 pool + mint single-sided LP from all deposits.
        lp.activate(key, cfg.tickLower, cfg.tickUpper, liquidity);

        // Set borrowCap — transitions PegCore market from inactive to live.
        core.setBorrowCap(marketId, cfg.initialBorrowCap);

        rec.active = true;

        emit MarketActivated(marketId, key.toId());

        // TODO: call PegHook.registerChannel(key, marketId, currencyId) once
        //       PegAssetFactory is upgraded to CREATE2 so PEGASSET_INIT_CODE_HASH
        //       validation in registerChannel passes.
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  disable()
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emergency freeze — sets borrowCap to 0, halting new minting.
    ///         Does not affect existing positions.
    function disable(Id marketId) external onlyOwner {
        MarketRecord storage rec = markets[marketId];
        if (rec.launchPool == address(0)) revert MarketNotFound();

        core.setBorrowCap(marketId, 0);

        emit MarketDisabled(marketId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Number of markets created.
    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    /// @notice Return a full MarketRecord struct for a given market Id.
    ///         Returns a zero-value record if the market does not exist.
    function getMarket(Id marketId) external view returns (MarketRecord memory) {
        return markets[marketId];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Compute liquidity for a single-sided concentrated position.
    ///      anchor = token0 → range above current price → getLiquidityForAmount0.
    ///      anchor = token1 → range below current price → getLiquidityForAmount1.
    function _computeLiquidity(
        uint256 amount,
        int24   tickLower,
        int24   tickUpper,
        bool    anchorIsToken0
    ) internal pure returns (uint128 liquidity) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        liquidity = anchorIsToken0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, amount);
    }

    /// @dev Derive PegCore market Id from MarketParams — mirrors PegCore's own derivation.
    function _marketId(MarketParams memory p) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(
            p.collateralToken, p.loanToken, p.oracle, p.model
        )));
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

/// @title LaunchPool — Channel bootstrap vault
///
/// @notice Collects a configurable anchor token (USDC, sUSDS, etc.) during a
///         seeding window.  Once the deposit target is met and the owner calls
///         `activate()`, the full balance is deployed as *single-sided*
///         concentrated liquidity into a PegHook UniV4 pool at 1:1 peg price.
///         Users then redeem pro-rata shares of that pool position (receiving
///         pegToken + anchor).
///
/// Lifecycle
/// ─────────
///   Seeding          — deposits accepted (block.timestamp ≤ deadline)
///     │
///     ├─ deadline passes, target NOT met → Failed (withdrawals unlock)
///     │
///     └─ deadline passes, target met     → PendingActivation
///                                              │
///                                              └─ owner calls activate() ──► Active
///                                                    │
///                                                    └─ users redeem() ──► pegToken + anchor
///
/// Single-sided LP
/// ───────────────
///   At peg (sqrtPrice = 2⁹⁶, tick = 0), the owner supplies tick bounds where
///   the entire range lies below (or above) the current tick so the whole
///   position is anchor-only.  A ±2% single-sided range around peg maps to
///   approximately 200 ticks; with tickSpacing = 60 that is (-240, 0) or
///   (0, 240) depending on which currency is the anchor.
///
/// @dev  Implements minimum ERC-4626 view surface (asset, totalAssets,
///       convertToShares, convertToAssets, maxDeposit) over plain deposit
///       accounting.  Shares are not tokenised — deposits[user] IS the share.
///         userShare = lpLiquidity × deposits[user] / totalDeposits
///       Redeem removes exactly `userShare` units from the V4 position and
///       delivers the output tokens directly to the caller.
contract LaunchPool is IERC721Receiver {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ═══════════════════════════════════════════════════════════════════════
    //  Types
    // ═══════════════════════════════════════════════════════════════════════

    enum Stage {
        Seeding,           // deposits open — deadline not yet reached
        PendingActivation, // deadline passed, target met, awaiting activate()
        Failed,            // deadline passed, target not met — withdrawals open
        Active             // activated — redeem available
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants — pool initialization price 1:1
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev sqrtPrice for 1:1 ratio — floor(sqrt(1) × 2^96) = 2^96.
    uint160 public constant SQRT_PRICE_1_1 = uint160(1 << 96);

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Anchor token deposited during seeding (USDC, sUSDS, etc.)
    IERC20 public immutable anchor;

    /// @notice UniV4 PoolManager singleton.
    IPoolManager public immutable poolManager;

    /// @notice UniV4 PositionManager — issues ERC-721 LP NFTs.
    IPositionManager public immutable positionManager;

    /// @notice Permit2 router — required for PositionManager token pulls.
    IPermit2 public immutable permit2;

    /// @notice Bootstrap deposit target in anchor units.
    uint256 public immutable target;

    /// @notice Seeding window end (Unix timestamp).
    uint40 public immutable deadline;

    /// @notice Account authorized to call activate().
    address public immutable owner;

    // ═══════════════════════════════════════════════════════════════════════
    //  State
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Per-user anchor deposit amount.
    mapping(address => uint256) public deposits;

    /// @notice Total anchor deposited across all users.
    uint256 public totalDeposits;

    /// @notice Set to true once activate() is successfully called.
    bool public activated;

    // ── Position state (written once at activate) ────────────────────────

    /// @notice PositionManager ERC-721 token id for the minted LP position.
    uint256 public lpTokenId;

    /// @notice Total liquidity units minted at activation.
    ///         Used as the denominator for pro-rata redeem math.
    uint128 public lpLiquidity;

    /// @notice PoolKey stored at activation — needed for redeem encoding.
    PoolKey public poolKey;

    /// @notice Tick bounds of the LP position (stored for redeem).
    int24 public tickLower;
    int24 public tickUpper;

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    event Deposited(address indexed receiver, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount);
    event Activated(PoolId indexed poolId, uint256 lpTokenId, uint128 liquidity);
    event Redeemed(address indexed user, uint128 liquidity);

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error Unauthorized();
    error InvalidStage(Stage required, Stage actual);
    error ZeroAmount();
    error TargetNotMet(uint256 total, uint256 target_);
    error TicksNotSingleSided();
    error LiquidityZero();
    error LiquidityMintFailed();
    error NothingToRedeem();

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /// @param _anchor          Deposit token (e.g. USDC).
    /// @param _target          Minimum total deposits to allow activation.
    /// @param _duration        Seeding window length in seconds (e.g. 7 days).
    /// @param _poolManager     UniV4 PoolManager address.
    /// @param _positionManager UniV4 PositionManager address.
    /// @param _permit2         Permit2 address.
    constructor(
        IERC20 _anchor,
        uint256 _target,
        uint40 _duration,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IPermit2 _permit2
    ) {
        anchor = _anchor;
        target = _target;
        deadline = uint40(block.timestamp) + _duration;
        poolManager = _poolManager;
        positionManager = _positionManager;
        permit2 = _permit2;
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Modifiers
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyStage(Stage required) {
        Stage s = stage();
        if (s != required) revert InvalidStage(required, s);
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Stage view
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Derive current lifecycle stage from state.
    function stage() public view returns (Stage) {
        if (activated) return Stage.Active;
        if (block.timestamp > deadline) {
            return totalDeposits >= target ? Stage.PendingActivation : Stage.Failed;
        }
        return Stage.Seeding;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ERC-4626 minimal interface (view + deposit signature)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The underlying token collected during seeding.
    function asset() external view returns (address) {
        return address(anchor);
    }

    /// @notice Total anchor assets held (meaningful during Seeding/PendingActivation).
    function totalAssets() external view returns (uint256) {
        return totalDeposits;
    }

    /// @notice Shares are 1:1 with deposited assets (deposits[user] IS the share).
    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    /// @notice Inverse: 1:1 mapping before activation.
    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    /// @notice Returns max depositable amount for an address (0 if not Seeding).
    function maxDeposit(address) external view returns (uint256) {
        return stage() == Stage.Seeding ? type(uint256).max : 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Seeding — deposit
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deposit anchor tokens during the seeding window.
    /// @dev    ERC-4626-style signature.  `receiver` gets shares credited;
    ///         tokens are pulled from `msg.sender`.  Stage must be Seeding.
    /// @param assets   Anchor amount to deposit (must be pre-approved by caller).
    /// @param receiver Account whose `deposits[]` balance is credited.
    /// @return shares  Always equals `assets` (1:1 accounting).
    function deposit(uint256 assets, address receiver)
        external
        onlyStage(Stage.Seeding)
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        anchor.safeTransferFrom(msg.sender, address(this), assets);
        deposits[receiver] += assets;
        totalDeposits += assets;
        shares = assets;
        emit Deposited(receiver, assets, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Failed — withdraw
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Withdraw deposited anchor after the seeding deadline if the
    ///         target was not met (Failed stage).
    function withdraw() external onlyStage(Stage.Failed) {
        uint256 amount = deposits[msg.sender];
        if (amount == 0) revert NothingToRedeem();
        deposits[msg.sender] = 0;
        totalDeposits -= amount;
        anchor.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Activation — deploy single-sided LP
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initialize a PegHook UniV4 pool and deploy all accumulated
    ///         anchor deposits as single-sided concentrated liquidity.
    ///
    /// @dev    Owner must call *after* computing the appropriate liquidity
    ///         amount offchain via `LiquidityAmounts.getLiquidityForAmount0/1`.
    ///         For a single-sided token1 position at peg (tick=0), pass:
    ///           _tickLower = some negative multiple of tickSpacing
    ///           _tickUpper = 0  (tickUpper == currentTick → all token1)
    ///
    ///         For a single-sided token0 position (anchor is currency0):
    ///           _tickLower = 0  (tickLower == currentTick → all token0)
    ///           _tickUpper = some positive multiple of tickSpacing
    ///
    /// @param key            PoolKey for the PegHook channel pool to initialize.
    /// @param _tickLower     Lower tick of the concentrated LP range.
    /// @param _tickUpper     Upper tick of the concentrated LP range.
    /// @param _liquidity     Exact liquidity units to mint (computed offchain).
    function activate(
        PoolKey calldata key,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity
    ) external onlyOwner {
        // Allow activation from Seeding (early) or PendingActivation (post-deadline).
        Stage s = stage();
        if (s != Stage.Seeding && s != Stage.PendingActivation) {
            revert InvalidStage(Stage.PendingActivation, s);
        }
        if (totalDeposits < target) revert TargetNotMet(totalDeposits, target);
        if (_liquidity == 0) revert LiquidityZero();

        // Validate single-sided constraint.
        // Anchor is token1 → tickUpper must be ≤ 0 (current tick at 1:1 peg).
        // Anchor is token0 → tickLower must be ≥ 0.
        bool anchorIsToken1 = Currency.unwrap(key.currency1) == address(anchor);
        bool anchorIsToken0 = Currency.unwrap(key.currency0) == address(anchor);
        if (anchorIsToken1) {
            // Range must lie below or at current tick (0) so position is all token1.
            if (_tickUpper > 0) revert TicksNotSingleSided();
        } else if (anchorIsToken0) {
            // Range must lie at or above current tick (0) so position is all token0.
            if (_tickLower < 0) revert TicksNotSingleSided();
        } else {
            revert TicksNotSingleSided();
        }

        // Store pool parameters for redeem.
        poolKey = key;
        tickLower = _tickLower;
        tickUpper = _tickUpper;

        // ── Step 1: initialize the PegHook pool at 1:1 ──────────────────
        poolManager.initialize(key, SQRT_PRICE_1_1);

        // ── Step 2: approve anchor through Permit2 → PositionManager ────
        uint256 depositAmount = totalDeposits;
        anchor.forceApprove(address(permit2), depositAmount);
        permit2.approve(
            address(anchor),
            address(positionManager),
            uint160(depositAmount),
            uint48(block.timestamp + 3600)
        );

        // ── Step 3: mint single-sided concentrated LP ────────────────────
        // MINT_POSITION + SETTLE_PAIR + SWEEP (c0 dust to this) + SWEEP (c1 dust to this)
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](4);

        // amount0Max / amount1Max: only anchor side is funded; other side = 0.
        uint256 amount0Max = anchorIsToken0 ? depositAmount : 0;
        uint256 amount1Max = anchorIsToken1 ? depositAmount : 0;

        params[0] = abi.encode(
            key,
            _tickLower,
            _tickUpper,
            _liquidity,
            amount0Max,
            amount1Max,
            address(this),    // recipient of the NFT
            bytes("")         // hookData
        );
        params[1] = abi.encode(key.currency0, key.currency1);  // SETTLE_PAIR
        params[2] = abi.encode(key.currency0, address(this));  // SWEEP c0 dust
        params[3] = abi.encode(key.currency1, address(this));  // SWEEP c1 dust

        // Record the next NFT id before minting (PositionManager increments sequentially).
        uint256 tokenId = positionManager.nextTokenId();

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 3600
        );

        // ── Step 4: verify and record state ─────────────────────────────
        // Read actual minted liquidity from the position — guards against tick
        // rounding and validates the tokenId assumption.
        uint128 actualLiquidity = positionManager.getPositionLiquidity(tokenId);
        if (actualLiquidity == 0) revert LiquidityMintFailed();

        lpTokenId   = tokenId;
        lpLiquidity = actualLiquidity;
        activated   = true;

        emit Activated(key.toId(), tokenId, actualLiquidity);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Redemption — withdraw pro-rata LP share
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Redeem pro-rata share of the LP position.
    ///         Caller receives pegToken + anchor proportional to their deposit.
    ///
    /// @dev    Removes `lpLiquidity × deposits[user] / totalDeposits` from the
    ///         V4 position and delivers tokens directly to `msg.sender`.
    ///         Ratchets deposit tracking but NOT `totalDeposits` — the original
    ///         deposit totals serve as invariant denominators so each user's
    ///         share is independent.
    function redeem() external onlyStage(Stage.Active) {
        uint256 userDeposit = deposits[msg.sender];
        if (userDeposit == 0) revert NothingToRedeem();

        // Pro-rata liquidity share.
        uint128 userLiquidity = uint128(uint256(lpLiquidity) * userDeposit / totalDeposits);
        if (userLiquidity == 0) revert NothingToRedeem();

        deposits[msg.sender] = 0;

        // DECREASE_LIQUIDITY + TAKE_PAIR: delivers tokens directly to msg.sender.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            lpTokenId,
            userLiquidity,
            uint128(0),   // amount0Min — no slippage guard (hackathon)
            uint128(0),   // amount1Min
            bytes("")     // hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, msg.sender);

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 3600
        );

        emit Redeemed(msg.sender, userLiquidity);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ERC-721 receiver — accept PositionManager NFT
    // ═══════════════════════════════════════════════════════════════════════

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}

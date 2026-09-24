// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMiningPower} from "./IMiningPower.sol";

/// @dev Read surface of the immutable `HunterMiningCore` this module is bound
/// to. `challengeState` returns the core's `ChallengeState` ordinal (the enum
/// is ABI-encoded as uint8): 0 WAITING_FOR_SEED, 1 ACTIVE, 2 EXPIRED,
/// 3 ENDED, 4 STOPPED.
interface IPrefundedMiningCoreView {
    function activeChallengeId() external view returns (uint256);
    function nftsMintedEver() external view returns (uint256);
    function acceptedProofs() external view returns (uint256);
    function previousAcceptedDigest() external view returns (bytes32);
    function PROOF_NFT() external view returns (address);
    function challengeState() external view returns (uint8);
}

/// @title Prefunded Mining Power — stake-gated, per-mint-funded Mining Power module
/// @notice Replacement for `MiningPowerCustody`. A mining wallet may only have a
/// proof accepted while (a) at least `MIN_STAKE` HUNTER staked by third-party
/// depositors is assigned to it for the open challenge and (b) it holds at
/// least `LOCK_PER_MINT` HUNTER of prefunded mint funds. Each accepted proof
/// moves `LOCK_PER_MINT` from the wallet's funds into a per-token commitment
/// that is released only to the final beneficiary once that NFT is burned.
/// The optional power bonus reuses the old custody's log curve and is disabled
/// when `CURVE_UNIT == 0` (multiplier fixed at 1.0x).
/// @dev Immutable, no proxy, no owner, no admin withdrawal. Every Mining Core
/// hook (`powerMultiplierWad`, `snapshottedLockedAmount`, `snapshotChallenge`,
/// `onProofAccepted`, `onMiningPowerDetached`) is callable only by
/// `miningCore` and makes NO token calls — hooks only move internal
/// accounting, so a hostile or paused token can never block proof
/// acceptance, detach or shutdown. Tokens move only in user-initiated
/// entry points, each guarded by measured receipts and a solvency check.
///
/// Defaults standing in for open S0 decisions (each flagged "S0 default"):
/// - S0 default 1: power bonus disabled by deploying with `CURVE_UNIT = 0`;
///   the old custody curve is retained for a nonzero unit.
/// - S0 default 2: mint funds are owned by the mining wallet they fund.
/// - S0 default 3: a one-way failsafe is included via the immutable
///   `FAILSAFE_GUARDIAN` (address(0) = no failsafe).
/// - S0 default 4: stake and funds count only from the NEXT challenge
///   snapshot after they arrive (strict), including right after attach.
/// - S0 default 5: token over-receipt (balance delta > requested) reverts.
/// - S0 default 6: the funding/staking depositor must differ from the mining
///   wallet (self-assignment reverts).
/// - S0 default 7: the HUNTER token is a test fixture until the canonical
///   token is bound.
///
/// Slice status (S4): the stake ledger is live — `deposit`, `assign`,
/// `unassign` and `withdraw` port `MiningPowerCustody`'s accounting (pending
/// and removing buckets, per-depositor pending share, per-wallet lazy freeze)
/// with a wall-clock `EXIT_COOLDOWN` in place of the old 12-proof unlock
/// delay. `powerMultiplierWad` freezes the wallet's stake for the challenge
/// and returns the curve at the frozen amount (always 1.0x when
/// `CURVE_UNIT == 0`), but nothing is gated yet (S5) and no mint lock is
/// taken (S6). Challenge bookkeeping (`wired`, `retired`,
/// `latestChallengeId`, `lastAcceptedProofs`) mirrors `MiningPowerCustody`
/// exactly so the module is a drop-in for the core.
contract PrefundedMiningPower is IMiningPower, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error UnauthorizedCaller(address caller);
    error ZeroAddress();
    error ZeroAmount();
    error NotEligible(uint8 reason);
    error NotWired();
    error Retired();
    error GateDisabled();
    error InsufficientUnassigned(uint256 available, uint256 requested);
    error InsufficientAssigned(uint256 available, uint256 requested);
    error InsufficientFunds(uint256 available, uint256 requested);
    error WrongAssignee(address expected, address provided);
    error MustUnassignFirst(address currentAssignee);
    error SelfAssignment();
    error CooldownNotMet(uint256 earliest, uint256 currentTimestamp);
    error AlreadySnapshotted(uint256 challengeId);
    error ChallengeNotOpen(uint256 challengeId);
    error StaleChallengeId(uint256 supplied, uint256 active);
    error RetainedAssignments(uint256 assigned);
    error UnsupportedTokenReceipt();
    error CounterMismatch(uint256 expected, uint256 actual);
    error LockAlreadyExists(uint256 tokenId);
    error NoLock(uint256 tokenId);
    error AlreadyReleased(uint256 tokenId);
    error TokenNotBurned(uint256 tokenId);
    error NotBeneficiary(address caller);
    error Insolvency();
    error DebitMismatch();
    error InvalidConfiguration();

    event Deposited(address indexed depositor, uint256 amount);
    event Assigned(address indexed depositor, address indexed miningWallet, uint256 amount, uint256 timestamp);
    event Unassigned(address indexed depositor, address indexed miningWallet, uint256 amount, uint256 timestamp);
    event Withdrawn(address indexed depositor, uint256 amount);
    event Funded(address indexed funder, address indexed miningWallet, uint256 amount);
    event FundsWithdrawn(address indexed miningWallet, uint256 amount);
    event Committed(
        uint256 indexed tokenId, address indexed miner, uint256 indexed challengeId, bytes32 digest, uint256 amount
    );
    event Released(uint256 indexed tokenId, address indexed beneficiary, address indexed recipient, uint256 amount);
    event ChallengeSnapshotted(uint256 indexed challengeId);
    event ProofProgress(uint256 acceptedProofs);
    event RequirementDisabled(address indexed guardian);

    uint256 private constant _WAD = 1e18;
    uint256 private constant _SLOPE_WAD = 5e17; // 0.5
    uint256 private constant _CAP_BONUS_WAD = 2e18; // bonus cap → max multiplier 3x

    /// @notice The HUNTER token staked, funded and committed here.
    IERC20 public immutable HUNTER;
    /// @notice The only address allowed to call the Mining Power hooks.
    address public immutable miningCore;
    /// @notice E — minimum frozen stake a mining wallet needs for a challenge.
    uint256 public immutable MIN_STAKE;
    /// @notice L — HUNTER committed from the wallet's funds per accepted proof.
    uint256 public immutable LOCK_PER_MINT;
    /// @notice Seconds after the latest assign before a depositor may unassign.
    uint256 public immutable EXIT_COOLDOWN;
    /// @notice 0 disables the power bonus; nonzero = old custody curve unit.
    uint256 public immutable CURVE_UNIT;
    /// @notice One-way failsafe key for `disableRequirement`; zero = none.
    address public immutable FAILSAFE_GUARDIAN;

    /// @notice Sum of all deposited stake held here (unassigned + assigned).
    uint256 public totalStake;
    /// @notice Sum of stake currently assigned to mining wallets.
    uint256 public totalAssigned;
    /// @notice Sum of uncommitted mint funds across mining wallets.
    uint256 public totalFunds;
    /// @notice Sum of per-token commitments not yet released.
    uint256 public totalCommitted;

    /// @notice Latest proof count reported by the core.
    uint256 public lastAcceptedProofs;
    /// @notice Newest challenge opened by `snapshotChallenge`.
    uint256 public latestChallengeId;
    /// @notice True while this module is the one Mining Core reads. Set by the
    /// first `snapshotChallenge` after wiring, cleared by `onMiningPowerDetached`.
    bool public wired;
    /// @notice True only after a terminal detach (mining stopped or minted out).
    bool public retired;
    /// @notice True once the failsafe guardian waived the requirement (one-way).
    bool public gateDisabled;

    /// @notice Deposited stake not assigned to any mining wallet.
    mapping(address => uint256) public unassignedOf;
    /// @notice Total stake assigned to a mining wallet (freeze source).
    mapping(address => uint256) public assignedOf;
    /// @notice Stake this depositor currently has assigned to `assigneeOf[depositor]`.
    mapping(address => uint256) public assignedBy;
    /// @notice The single mining wallet a depositor's assigned stake backs.
    mapping(address => address) public assigneeOf;
    /// @notice `block.timestamp` of this depositor's latest assign (a top-up
    /// resets it). The cooldown clock is per depositor so a shared mining
    /// wallet's other backers can never reset or shorten it.
    mapping(address => uint256) public assignTimestamp;
    /// @notice Assigns made while `pendingEpoch[wallet]` was the open
    /// challenge. They are part of `assignedOf` but excluded from that
    /// challenge's freeze — a digest is derivable once its seed is readable,
    /// so stake that arrives after a challenge opened counts from the next one.
    mapping(address => uint256) public pendingOf;
    /// @notice Challenge the wallet's `pendingOf` / `removingOf` buckets belong to.
    mapping(address => uint256) public pendingEpoch;
    /// @notice This depositor's own share of their wallet's pending bucket,
    /// kept per depositor so one account's unassign cannot launder another's
    /// post-open stake into matured power.
    mapping(address => uint256) public pendingBy;
    /// @notice Challenge the depositor's `pendingBy` share belongs to.
    mapping(address => uint256) public pendingEpochBy;
    /// @notice Matured stake unassigned while `pendingEpoch[wallet]` is the
    /// open challenge. Added back at that challenge's freeze so removals only
    /// take effect from the next one — the bind holds for exits as for entries.
    mapping(address => uint256) public removingOf;

    mapping(uint256 => bool) private _challengeOpen;
    mapping(uint256 => mapping(address => bool)) private _frozen;
    mapping(uint256 => mapping(address => uint256)) private _frozenStake;

    modifier onlyMiningCore() {
        if (msg.sender != miningCore) revert UnauthorizedCaller(msg.sender);
        _;
    }

    constructor(
        address hunterToken,
        address miningCore_,
        uint256 minStake_,
        uint256 lockPerMint_,
        uint256 exitCooldown_,
        uint256 curveUnit_,
        address failsafeGuardian_
    ) {
        if (hunterToken == address(0) || hunterToken.code.length == 0) revert InvalidConfiguration();
        if (miningCore_ == address(0) || miningCore_.code.length == 0) revert InvalidConfiguration();
        if (lockPerMint_ == 0) revert InvalidConfiguration();
        HUNTER = IERC20(hunterToken);
        miningCore = miningCore_;
        MIN_STAKE = minStake_;
        LOCK_PER_MINT = lockPerMint_;
        EXIT_COOLDOWN = exitCooldown_;
        CURVE_UNIT = curveUnit_;
        FAILSAFE_GUARDIAN = failsafeGuardian_;
    }

    // ------------------------------------------------------------------
    // Mining Core hooks — core only, no token calls.
    // ------------------------------------------------------------------

    /// @inheritdoc IMiningPower
    /// @dev Freezes `miner`'s stake for `challengeId` on first read and
    /// returns the curve at the frozen amount (1.0x when `CURVE_UNIT == 0`).
    /// S4: no eligibility gate yet — that lands in S5.
    function powerMultiplierWad(uint256 challengeId, address miner) external onlyMiningCore returns (uint256) {
        return multiplierFromLockedAmount(_freeze(challengeId, miner));
    }

    /// @inheritdoc IMiningPower
    /// @dev Same lazy freeze as `powerMultiplierWad`; returns the frozen stake.
    function snapshottedLockedAmount(uint256 challengeId, address miner) external onlyMiningCore returns (uint256) {
        return _freeze(challengeId, miner);
    }

    /// @inheritdoc IMiningPower
    /// @dev Mirrors `MiningPowerCustody.snapshotChallenge`. A module that still
    /// holds assignments cannot be (re)wired — retained stake carries stale
    /// epochs and could claim power for a challenge whose digest is already
    /// derivable.
    function snapshotChallenge(uint256 challengeId) external onlyMiningCore {
        if (!wired && totalAssigned != 0) revert RetainedAssignments(totalAssigned);
        if (_challengeOpen[challengeId]) {
            if (wired) revert AlreadySnapshotted(challengeId);
            // Re-wired during a challenge it already opened — epoch data intact.
        } else {
            _challengeOpen[challengeId] = true;
            latestChallengeId = challengeId;
            emit ChallengeSnapshotted(challengeId);
        }
        wired = true;
        retired = false;
    }

    /// @inheritdoc IMiningPower
    function onProofAccepted(uint256 acceptedProofs) external onlyMiningCore {
        lastAcceptedProofs = acceptedProofs;
        emit ProofProgress(acceptedProofs);
    }

    /// @inheritdoc IMiningPower
    /// @dev Retirement is sticky until a later rewire (`snapshotChallenge`
    /// clears it); a non-terminal detach never un-retires the module.
    function onMiningPowerDetached(bool terminal) external onlyMiningCore {
        wired = false;
        retired = retired || terminal;
    }

    // ------------------------------------------------------------------
    // Stake ledger (S4) — port of MiningPowerCustody
    // ------------------------------------------------------------------

    /// @notice Deposit HUNTER as unassigned stake. Allowed in every state —
    /// an unassigned deposit carries no power and can always be withdrawn.
    /// @dev Credits the measured balance delta. A zero receipt, a receipt
    /// larger than `amount` (S0 default 5) or a balance that shrinks reverts
    /// `UnsupportedTokenReceipt`. Solvency is checked before and after.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBal = _requireSolvent();
        HUNTER.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBal = HUNTER.balanceOf(address(this));
        if (afterBal <= beforeBal || afterBal - beforeBal > amount) revert UnsupportedTokenReceipt();
        uint256 received = afterBal - beforeBal;
        unassignedOf[msg.sender] += received;
        totalStake += received;
        _requireSolvent();
        emit Deposited(msg.sender, received);
    }

    /// @notice Assign unassigned stake to one mining wallet. The stake is
    /// pending for the open challenge and counts from the next snapshot.
    /// Every assign (including a top-up) restarts the caller's cooldown.
    /// @dev Refused unless this module is the wired, non-retired module and
    /// the failsafe has not fired — no stake is parked on a module that can
    /// never mint. A depositor backs one wallet at a time and can never be
    /// its own mining wallet (S0 default 6).
    function assign(address miningWallet, uint256 amount) external nonReentrant {
        // `retired` is checked first: a terminal detach also clears `wired`,
        // so checking `wired` first would make `Retired` unreachable.
        if (retired) revert Retired();
        if (!wired) revert NotWired();
        if (gateDisabled) revert GateDisabled();
        if (miningWallet == address(0)) revert ZeroAddress();
        if (miningWallet == msg.sender) revert SelfAssignment();
        if (amount == 0) revert ZeroAmount();
        address current = assigneeOf[msg.sender];
        if (current != address(0) && current != miningWallet) revert MustUnassignFirst(current);
        uint256 available = unassignedOf[msg.sender];
        if (amount > available) revert InsufficientUnassigned(available, amount);
        _retagBuckets(miningWallet);
        unassignedOf[msg.sender] = available - amount;
        assignedOf[miningWallet] += amount;
        assignedBy[msg.sender] += amount;
        totalAssigned += amount;
        pendingOf[miningWallet] += amount;
        pendingBy[msg.sender] += amount;
        assigneeOf[msg.sender] = miningWallet;
        assignTimestamp[msg.sender] = block.timestamp;
        emit Assigned(msg.sender, miningWallet, amount, block.timestamp);
    }

    /// @notice Return assigned stake to the caller's unassigned balance.
    /// @dev Requires `EXIT_COOLDOWN` seconds since the caller's latest assign,
    /// waived once the module is retired (terminal detach) or the failsafe
    /// fired. The cooldown is wall-clock only and never reads proof counts,
    /// so a detached module's stake always becomes exitable. The caller's own
    /// still-pending share leaves first; the matured remainder is queued in
    /// `removingOf` so it only narrows the NEXT challenge's freeze.
    /// Fails closed (`Insolvency`) when the books no longer cover the balance.
    function unassign(address miningWallet, uint256 amount) external nonReentrant {
        if (miningWallet == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (assigneeOf[msg.sender] != miningWallet) revert WrongAssignee(assigneeOf[msg.sender], miningWallet);
        if (!retired && !gateDisabled) {
            uint256 earliest = assignTimestamp[msg.sender] + EXIT_COOLDOWN;
            if (block.timestamp < earliest) revert CooldownNotMet(earliest, block.timestamp);
        }
        uint256 available = assignedBy[msg.sender];
        if (amount > available) revert InsufficientAssigned(available, amount);
        _requireSolvent();
        _retagBuckets(miningWallet);
        uint256 pendingPart = pendingBy[msg.sender] < amount ? pendingBy[msg.sender] : amount;
        pendingBy[msg.sender] -= pendingPart;
        pendingOf[miningWallet] -= pendingPart;
        removingOf[miningWallet] += amount - pendingPart;
        assignedBy[msg.sender] = available - amount;
        assignedOf[miningWallet] -= amount;
        totalAssigned -= amount;
        unassignedOf[msg.sender] += amount;
        if (assignedBy[msg.sender] == 0) assigneeOf[msg.sender] = address(0);
        emit Unassigned(msg.sender, miningWallet, amount, block.timestamp);
    }

    /// @notice Withdraw unassigned stake. Allowed in every state.
    /// @dev The module's balance must drop by exactly `amount`
    /// (`DebitMismatch` otherwise) and stay solvent before and after.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 available = unassignedOf[msg.sender];
        if (amount > available) revert InsufficientUnassigned(available, amount);
        uint256 beforeBal = _requireSolvent();
        unassignedOf[msg.sender] = available - amount;
        totalStake -= amount;
        HUNTER.safeTransfer(msg.sender, amount);
        uint256 afterBal = HUNTER.balanceOf(address(this));
        if (afterBal > beforeBal || beforeBal - afterBal != amount) revert DebitMismatch();
        _requireSolvent();
        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The old custody's power curve: 1 + 0.5 * log2(locked / CURVE_UNIT + 1),
    /// bonus capped at 2x (max 3x). Always 1.0x when the bonus is disabled.
    function multiplierFromLockedAmount(uint256 lockedAmount) public view returns (uint256) {
        if (CURVE_UNIT == 0 || lockedAmount == 0) return _WAD;
        uint256 x = lockedAmount / CURVE_UNIT;
        if (x == 0) return _WAD;
        uint256 logTerm = Math.log2(x + 1) * _WAD;
        uint256 bonus = Math.mulDiv(_SLOPE_WAD, logTerm, _WAD);
        if (bonus > _CAP_BONUS_WAD) bonus = _CAP_BONUS_WAD;
        return _WAD + bonus;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev Pending from an older epoch has matured and queued removals have
    /// landed; retag the wallet's buckets and the caller's pending share to
    /// the latest challenge before recording an assign or unassign against it.
    function _retagBuckets(address miningWallet) private {
        uint256 latest = latestChallengeId;
        if (pendingEpoch[miningWallet] < latest) {
            pendingOf[miningWallet] = 0;
            removingOf[miningWallet] = 0;
            pendingEpoch[miningWallet] = latest;
        }
        if (pendingEpochBy[msg.sender] < latest) {
            pendingBy[msg.sender] = 0;
            pendingEpochBy[msg.sender] = latest;
        }
    }

    /// @dev Lazy per-wallet freeze, identical to `MiningPowerCustody._freeze`.
    /// The first read for (challengeId, wallet) records the stake that was
    /// matured when the challenge opened: assigns made after opening are
    /// pending (excluded) and matured removals made after opening are added
    /// back. Later reads return the recorded value unchanged.
    function _freeze(uint256 challengeId, address miningWallet) private returns (uint256 frozen) {
        if (!_challengeOpen[challengeId]) revert ChallengeNotOpen(challengeId);
        if (_frozen[challengeId][miningWallet]) return _frozenStake[challengeId][miningWallet];
        // A never-frozen challenge can only be reconstructed for the latest
        // epoch — older balances are no longer derivable once buckets settle,
        // so refuse rather than permanently record a wrong snapshot.
        if (challengeId != latestChallengeId) revert StaleChallengeId(challengeId, latestChallengeId);
        frozen = assignedOf[miningWallet];
        if (pendingEpoch[miningWallet] == challengeId) {
            frozen = frozen - pendingOf[miningWallet] + removingOf[miningWallet];
        }
        _frozenStake[challengeId][miningWallet] = frozen;
        _frozen[challengeId][miningWallet] = true;
    }

    /// @dev Fails closed when the recorded obligations exceed the balance —
    /// corrupted totals block exits instead of paying out. Returns the
    /// balance read so callers can reuse it as their measurement baseline.
    function _requireSolvent() private view returns (uint256 balance) {
        balance = HUNTER.balanceOf(address(this));
        if (balance < totalStake + totalFunds + totalCommitted) revert Insolvency();
    }
}

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

/// @dev Read surface of the core's immutable `PROOF_NFT` (a `HunterNFT`)
/// used by settlement: its independent lifetime mint counter.
interface IPrefundedProofNftView {
    function mintedEver() external view returns (uint256);
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
/// Slice status (S6): the stake ledger is live — `deposit`, `assign`,
/// `unassign` and `withdraw` port `MiningPowerCustody`'s accounting (pending
/// and removing buckets, per-depositor pending share, per-wallet lazy freeze)
/// with a wall-clock `EXIT_COOLDOWN` in place of the old 12-proof unlock
/// delay. Matured stake unassigned during the open challenge still counts
/// for it and is held in the module until the next snapshot (`heldBy`,
/// `withdrawableOf`), so stake never leaves while it counts.
/// Mint funds are live: `fund` credits a mining wallet (S0 default 2: the
/// funds belong to that wallet) and `withdrawFunds` returns them to it.
/// Funds arriving while a challenge is open are pending for it and count
/// from the next snapshot (`pendingFunds` / `fundsEpoch`).
/// `powerMultiplierWad` is the eligibility gate: it freezes the wallet's
/// stake for the challenge and REVERTS `NotEligible(2)` below `MIN_STAKE`
/// and `NotEligible(3)` when its eligible (non-pending) funds are below
/// `LOCK_PER_MINT` (unless the failsafe fired), then writes a transient
/// eligibility note (challenge id, miner). `onProofAccepted` settles the
/// per-mint lock from that note in the same transaction — `LOCK_PER_MINT`
/// moves from the miner's funds into `_committed[tokenId]` for the token
/// the core is about to mint — and clears it. Release of a lock (S7) and
/// the failsafe entry point (S8) are not implemented yet.
/// Challenge bookkeeping (`wired`, `retired`, `latestChallengeId`,
/// `lastAcceptedProofs`) mirrors `MiningPowerCustody` exactly so the module
/// is a drop-in for the core.
///
/// Why the transient note cannot be replayed or forged:
/// - Only `miningCore` can write it (`powerMultiplierWad`) or consume it
///   (`onProofAccepted`), and the real core calls the two back to back inside
///   one `submitProof` with no external call in between.
/// - Transient storage never survives the transaction, and a revert anywhere
///   in `submitProof` (bad digest, stale id, bad basket, lifecycle hook)
///   rolls the note back with every other write.
/// - `onProofAccepted` clears it after settling, so a later hook call in the
///   same transaction sees no note. A second `submitProof` in the same
///   transaction cannot reach the gate at all: acceptance schedules the next
///   seed `SEED_DELAY_PARENT_BLOCKS` (3) blocks ahead, so the core reports
///   `WAITING_FOR_SEED` for the rest of the block.
/// - Settlement re-reads `activeChallengeId` from the core and fails closed
///   (`StaleChallengeId`) if it differs from the challenge the gate admitted.
///
/// Why the lock's tokenId derivation is safe: `submitProof` increments the
/// core's `nftsMintedEver` BEFORE `onProofAccepted` and mints the NFT AFTER
/// it, so the token about to be minted is `PROOF_NFT.mintedEver() + 1`, and
/// that must equal the core's freshly incremented counter. Settlement checks
/// both independent counters and reverts `CounterMismatch` on any
/// divergence (which also makes the proof unacceptable); the core's
/// permissionless `tripMining` stays available to stop a diverged core
/// because it never calls this module except through the best-effort
/// detach hook. An existing lock for the id is never overwritten
/// (`LockAlreadyExists`).
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
    error StakeHeldUntilNextChallenge(uint256 held, uint256 epoch);

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

    /// @dev Transient slot holding the challenge id of the proof the gate
    /// just admitted (never 0: the gate refuses challenge 0, and the core's
    /// ids start at 1). Nonzero means "a note exists". Written only by an
    /// enforcing gate, consumed and cleared by `onProofAccepted` in the same
    /// transaction; a reverted submission rolls it back with the rest of the
    /// frame.
    uint256 private constant _ELIGIBLE_CHALLENGE_SLOT =
        uint256(keccak256("proof-hunters.PrefundedMiningPower.eligible.challenge.v2"));
    /// @dev Transient slot holding the admitted miner — the lock owner, since
    /// `onProofAccepted` carries no miner argument.
    uint256 private constant _ELIGIBLE_MINER_SLOT =
        uint256(keccak256("proof-hunters.PrefundedMiningPower.eligible.miner.v1"));

    /// @notice A per-token mint commitment, created by `onProofAccepted` for
    /// the token the core is minting and bound to that proof's challenge id
    /// and digest (which equal the NFT's `birthData`).
    struct Lock {
        uint256 amount;
        uint256 challengeId;
        bytes32 digest;
        address miner;
        bool released;
    }

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
    /// @notice Matured stake this depositor unassigned during `heldEpochBy`.
    /// It still counts for that challenge (via the wallet's `removingOf`), so
    /// it may not leave the module until the next snapshot opens: `withdraw`
    /// is limited to `withdrawableOf`. Never reduced by a re-assign — held
    /// stake moved to another wallet (pending there) and unassigned again in
    /// the same epoch must still stay in the module.
    mapping(address => uint256) public heldBy;
    /// @notice Challenge the depositor's `heldBy` amount belongs to.
    mapping(address => uint256) public heldEpochBy;
    /// @notice Latest challenge during which a detach waived the hold (0 =
    /// none). Removals queued in that epoch may already have been withdrawn,
    /// so they no longer count if the module is re-wired into it.
    uint256 public holdWaivedEpoch;

    /// @notice Uncommitted mint funds owned by each mining wallet (S0
    /// default 2). Only the wallet itself can withdraw them.
    mapping(address => uint256) public fundsOf;
    /// @notice Funds that arrived while `fundsEpoch[wallet]` was the latest
    /// challenge. They are part of `fundsOf` but do not count for that
    /// challenge — funds count from the next snapshot, like stake.
    mapping(address => uint256) public pendingFunds;
    /// @notice Challenge the wallet's `pendingFunds` belong to.
    mapping(address => uint256) public fundsEpoch;
    /// @dev Per-token commitments, keyed by the NFT token id.
    mapping(uint256 => Lock) internal _committed;

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
        if (hunterToken == address(0) || hunterToken.code.length == 0) {
            revert InvalidConfiguration();
        }
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
    /// @notice Eligibility gate. The core calls this BEFORE its digest check.
    /// @dev Freezes `miner`'s stake for `challengeId` (stake assigned after the
    /// challenge opened does not count; matured stake unassigned after it
    /// opened still does) and, unless the failsafe fired, reverts
    /// `NotEligible(2)` when the frozen stake is below `MIN_STAKE` and
    /// `NotEligible(3)` when the wallet's eligible funds (`fundsOf` minus
    /// funds still pending for this challenge) are below `LOCK_PER_MINT`.
    /// Funds are not frozen: withdrawing them mid-challenge makes the wallet
    /// ineligible from the next gate call on.
    /// Ineligibility MUST be a revert: in this core a zero or below-base
    /// multiplier is NOT a ban — `_effectiveTarget` treats anything
    /// `<= POWER_BASE_WAD` as the plain base target, so returning 0 would still
    /// let an unqualified wallet mint at the base difficulty.
    /// On success an enforcing gate records a transient note (challenge id,
    /// miner) that `onProofAccepted` consumes and clears in the same
    /// transaction. With `gateDisabled` no check runs and NO note is written,
    /// so no mint lock is taken either (mining is free again).
    /// Returns the curve at the frozen amount (1.0x when `CURVE_UNIT == 0`).
    function powerMultiplierWad(uint256 challengeId, address miner) external onlyMiningCore returns (uint256) {
        uint256 frozen = _freeze(challengeId, miner);
        if (!gateDisabled) {
            if (frozen < MIN_STAKE) revert NotEligible(2);
            if (_eligibleFunds(miner) < LOCK_PER_MINT) revert NotEligible(3);
            // A zero note means "no note"; challenge 0 is never opened by the
            // core, but refuse it rather than admit a proof that settles nothing.
            if (challengeId == 0) revert ChallengeNotOpen(0);
            uint256 challengeSlot = _ELIGIBLE_CHALLENGE_SLOT;
            uint256 minerSlot = _ELIGIBLE_MINER_SLOT;
            assembly ("memory-safe") {
                tstore(challengeSlot, challengeId)
                tstore(minerSlot, miner)
            }
        }
        return multiplierFromLockedAmount(frozen);
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
    /// @notice Settles the per-mint lock for the proof the gate just admitted.
    /// @dev The core fires this after incrementing `acceptedProofs` /
    /// `nftsMintedEver` and setting `previousAcceptedDigest`, but BEFORE it
    /// advances `activeChallengeId` (or retires the module at mint-out) and
    /// BEFORE `PROOF_NFT.mint`. So at this point the core's
    /// `activeChallengeId` is still the accepted proof's challenge,
    /// `previousAcceptedDigest` is its digest, and the token about to be
    /// minted is `PROOF_NFT.mintedEver() + 1 == nftsMintedEver`.
    /// With a note: requires the noted challenge to equal the core's active
    /// challenge (`StaleChallengeId` otherwise), the two independent counters
    /// to agree (`CounterMismatch`), no existing lock for the token
    /// (`LockAlreadyExists`) and `LOCK_PER_MINT` of the miner's funds
    /// (`InsufficientFunds`, unreachable after the gate but checked anyway);
    /// then moves `LOCK_PER_MINT` from `fundsOf[miner]` into the lock.
    /// Without a note — the attach bootstrap (`setMiningPower` /
    /// `attachMiningPowerLate` call this with no submission) or a disabled
    /// gate — no lock is taken. The note is always cleared so it can never
    /// outlive the acceptance it was written for. Reads only core/NFT views;
    /// no token call.
    function onProofAccepted(uint256 acceptedProofs) external onlyMiningCore {
        lastAcceptedProofs = acceptedProofs;
        emit ProofProgress(acceptedProofs);
        uint256 challengeSlot = _ELIGIBLE_CHALLENGE_SLOT;
        uint256 minerSlot = _ELIGIBLE_MINER_SLOT;
        uint256 noteChallenge;
        address miner;
        assembly ("memory-safe") {
            noteChallenge := tload(challengeSlot)
            miner := tload(minerSlot)
        }
        if (noteChallenge != 0) _settleLock(noteChallenge, miner);
        assembly ("memory-safe") {
            tstore(challengeSlot, 0)
            tstore(minerSlot, 0)
        }
    }

    /// @inheritdoc IMiningPower
    /// @dev Retirement is sticky until a later rewire (`snapshotChallenge`
    /// clears it); a non-terminal detach never un-retires the module.
    /// Any detach waives the stake hold (see `withdrawableOf`) — otherwise a
    /// module that is never re-wired would hold that stake forever — so the
    /// removals queued in the open epoch stop counting (`holdWaivedEpoch`).
    function onMiningPowerDetached(bool terminal) external onlyMiningCore {
        wired = false;
        retired = retired || terminal;
        holdWaivedEpoch = latestChallengeId;
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
    /// `removingOf` so it only narrows the NEXT challenge's freeze, and is
    /// held in the module (`heldBy`) until that challenge opens: stake that
    /// still counts can never leave while it counts.
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
        heldBy[msg.sender] += amount - pendingPart;
        assignedBy[msg.sender] = available - amount;
        assignedOf[miningWallet] -= amount;
        totalAssigned -= amount;
        unassignedOf[msg.sender] += amount;
        if (assignedBy[msg.sender] == 0) assigneeOf[msg.sender] = address(0);
        emit Unassigned(msg.sender, miningWallet, amount, block.timestamp);
    }

    /// @notice Withdraw unassigned stake. Allowed in every state, but only
    /// up to `withdrawableOf(msg.sender)`: matured stake unassigned during the
    /// open challenge still counts for it and stays until the next snapshot.
    /// @dev Reverts `InsufficientUnassigned` above the unassigned balance and
    /// `StakeHeldUntilNextChallenge(held, epoch)` when only the hold blocks it.
    /// The module's balance must drop by exactly `amount`
    /// (`DebitMismatch` otherwise) and stay solvent before and after.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 available = unassignedOf[msg.sender];
        if (amount > available) revert InsufficientUnassigned(available, amount);
        uint256 held = heldStakeOf(msg.sender);
        if (amount > available - Math.min(held, available)) {
            revert StakeHeldUntilNextChallenge(held, latestChallengeId);
        }
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
    // Mint funds (S6)
    // ------------------------------------------------------------------

    /// @notice Credit mint funds to `miningWallet`. Anyone may fund any
    /// wallet; the funds then belong to that wallet (S0 default 2) and only
    /// it can withdraw them. Funds that arrive while a challenge is open are
    /// pending for it and count from the next snapshot.
    /// @dev Refused once the module is retired or the failsafe fired — no
    /// further mint can take a lock, so nothing would ever need the funds.
    /// Allowed before attach: at the attach challenge no wallet can have
    /// matured stake (assign requires `wired`, and a re-wire requires zero
    /// assignments), so pre-attach funds can only matter from the next
    /// snapshot whenever `MIN_STAKE > 0`.
    /// Credits the measured balance delta; a zero receipt, an over-receipt
    /// (S0 default 5) or a shrinking balance reverts `UnsupportedTokenReceipt`.
    /// Solvency is checked before and after.
    function fund(address miningWallet, uint256 amount) external nonReentrant {
        if (retired) revert Retired();
        if (gateDisabled) revert GateDisabled();
        if (miningWallet == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBal = _requireSolvent();
        HUNTER.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBal = HUNTER.balanceOf(address(this));
        if (afterBal <= beforeBal || afterBal - beforeBal > amount) revert UnsupportedTokenReceipt();
        uint256 received = afterBal - beforeBal;
        uint256 latest = latestChallengeId;
        if (fundsEpoch[miningWallet] < latest) {
            pendingFunds[miningWallet] = 0;
            fundsEpoch[miningWallet] = latest;
        }
        pendingFunds[miningWallet] += received;
        fundsOf[miningWallet] += received;
        totalFunds += received;
        _requireSolvent();
        emit Funded(msg.sender, miningWallet, received);
    }

    /// @notice Withdraw the caller's own uncommitted mint funds. Allowed in
    /// every state, including mid-challenge: the gate reads funds live, so a
    /// wallet that withdraws below `LOCK_PER_MINT` is simply ineligible from
    /// then on. Committed (locked) funds are never withdrawable here.
    /// @dev Funds still pending for the open challenge leave first, so the
    /// wallet's eligible (matured) funds shrink only by the excess. The
    /// module's balance must drop by exactly `amount` (`DebitMismatch`
    /// otherwise) and stay solvent before and after (`Insolvency`).
    function withdrawFunds(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 available = fundsOf[msg.sender];
        if (amount > available) revert InsufficientFunds(available, amount);
        uint256 beforeBal = _requireSolvent();
        uint256 pending = _livePendingFunds(msg.sender);
        if (pending != 0) pendingFunds[msg.sender] = pending - Math.min(pending, amount);
        fundsOf[msg.sender] = available - amount;
        totalFunds -= amount;
        HUNTER.safeTransfer(msg.sender, amount);
        uint256 afterBal = HUNTER.balanceOf(address(this));
        if (afterBal > beforeBal || beforeBal - afterBal != amount) revert DebitMismatch();
        _requireSolvent();
        emit FundsWithdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice What the gate would decide for `wallet` in the current
    /// (latest snapshotted) challenge, without freezing anything.
    /// @dev `stake` is exactly what `_freeze` would record (or has recorded)
    /// for `latestChallengeId`; `funds` is `eligibleFundsOf(wallet)`, exactly
    /// what the gate compares. Reason codes: 0 ok, 1 this module is not the
    /// live one (not wired, or retired), 2 stake below `MIN_STAKE`, 3 funds
    /// below `LOCK_PER_MINT` (checked after the stake).
    /// Once the failsafe fired a wired module reports eligible (reason 0).
    function eligibilityOf(address wallet)
        external
        view
        returns (bool eligible, uint8 reason, uint256 stake, uint256 funds)
    {
        stake = _frozenPreview(wallet);
        funds = _eligibleFunds(wallet);
        if (!wired || retired) return (false, 1, stake, funds);
        if (gateDisabled) return (true, 0, stake, funds);
        if (stake < MIN_STAKE) return (false, 2, stake, funds);
        if (funds < LOCK_PER_MINT) return (false, 3, stake, funds);
        return (true, 0, stake, funds);
    }

    /// @notice Mint funds that count for the current (latest snapshotted)
    /// challenge: `fundsOf(wallet)` minus funds still pending for it.
    function eligibleFundsOf(address wallet) external view returns (uint256) {
        return _eligibleFunds(wallet);
    }

    /// @notice The commitment recorded for `tokenId` (all zero if none).
    function committedOf(uint256 tokenId)
        external
        view
        returns (uint256 amount, uint256 challengeId, bytes32 digest, address miner, bool released)
    {
        Lock storage lock = _committed[tokenId];
        return (lock.amount, lock.challengeId, lock.digest, lock.miner, lock.released);
    }

    /// @notice The multiplier the gate would return for `wallet` in the
    /// current challenge (it does not say whether the gate would admit it —
    /// use `eligibilityOf`).
    function previewSubmit(address wallet) external view returns (uint256 multiplierWad) {
        return multiplierFromLockedAmount(_frozenPreview(wallet));
    }

    /// @notice Matured stake `depositor` unassigned during the open challenge
    /// that must stay in the module until the next snapshot. Zero once the
    /// module is not wired, is retired, or the failsafe fired (the hold is
    /// waived exactly like the exit cooldown, plus on any detach, and stays
    /// waived for the rest of that epoch after a re-wire into it — its
    /// removals no longer count, see `holdWaivedEpoch`). May exceed
    /// `unassignedOf` while held stake is re-assigned (pending) elsewhere.
    function heldStakeOf(address depositor) public view returns (uint256) {
        uint256 latest = latestChallengeId;
        if (!wired || retired || gateDisabled || latest == holdWaivedEpoch) return 0;
        return heldEpochBy[depositor] == latest ? heldBy[depositor] : 0;
    }

    /// @notice Unassigned stake `depositor` may withdraw right now.
    function withdrawableOf(address depositor) external view returns (uint256) {
        uint256 unassigned = unassignedOf[depositor];
        return unassigned - Math.min(heldStakeOf(depositor), unassigned);
    }

    /// @notice The transient eligibility note of the current transaction:
    /// `note` is the admitted challenge id, `miner` the admitted wallet (both
    /// zero outside a submission). Diagnostic only; it must always read
    /// (0, address(0)) once a proof has been accepted.
    function pendingEligibleNote() external view returns (uint256 note, address miner) {
        uint256 challengeSlot = _ELIGIBLE_CHALLENGE_SLOT;
        uint256 minerSlot = _ELIGIBLE_MINER_SLOT;
        assembly ("memory-safe") {
            note := tload(challengeSlot)
            miner := tload(minerSlot)
        }
    }

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

    /// @dev Moves `LOCK_PER_MINT` of `miner`'s funds into the commitment for
    /// the token the core is about to mint. See `onProofAccepted` for the
    /// call-ordering facts every check below relies on.
    function _settleLock(uint256 noteChallenge, address miner) private {
        IPrefundedMiningCoreView core = IPrefundedMiningCoreView(miningCore);
        uint256 active = core.activeChallengeId();
        if (noteChallenge != active) revert StaleChallengeId(noteChallenge, active);
        uint256 coreCount = core.nftsMintedEver();
        uint256 tokenId = IPrefundedProofNftView(core.PROOF_NFT()).mintedEver() + 1;
        if (tokenId != coreCount) revert CounterMismatch(coreCount, tokenId);
        if (_committed[tokenId].amount != 0) revert LockAlreadyExists(tokenId);
        uint256 lockAmount = LOCK_PER_MINT;
        uint256 available = fundsOf[miner];
        if (available < lockAmount) revert InsufficientFunds(available, lockAmount);
        bytes32 digest = core.previousAcceptedDigest();
        fundsOf[miner] = available - lockAmount;
        totalFunds -= lockAmount;
        totalCommitted += lockAmount;
        _committed[tokenId] =
            Lock({amount: lockAmount, challengeId: noteChallenge, digest: digest, miner: miner, released: false});
        emit Committed(tokenId, miner, noteChallenge, digest, lockAmount);
    }

    /// @dev `pendingFunds` still applies only while it belongs to the latest
    /// challenge; once a newer snapshot opened it has matured.
    function _livePendingFunds(address wallet) private view returns (uint256) {
        return fundsEpoch[wallet] == latestChallengeId ? pendingFunds[wallet] : 0;
    }

    /// @dev Funds that count for `latestChallengeId`. Live pending never
    /// exceeds `fundsOf`: `fund` adds to both, `withdrawFunds` takes pending
    /// first, and a lock only takes funds the gate saw as matured.
    function _eligibleFunds(address wallet) private view returns (uint256) {
        return fundsOf[wallet] - _livePendingFunds(wallet);
    }

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
        if (heldEpochBy[msg.sender] < latest) {
            heldBy[msg.sender] = 0;
            heldEpochBy[msg.sender] = latest;
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
        frozen = _maturedStake(challengeId, miningWallet);
        _frozenStake[challengeId][miningWallet] = frozen;
        _frozen[challengeId][miningWallet] = true;
    }

    /// @dev Read-only twin of `_freeze` for `latestChallengeId`: the recorded
    /// value if the wallet was already frozen, else what `_freeze` would record.
    function _frozenPreview(address miningWallet) private view returns (uint256) {
        uint256 challengeId = latestChallengeId;
        if (_frozen[challengeId][miningWallet]) return _frozenStake[challengeId][miningWallet];
        return _maturedStake(challengeId, miningWallet);
    }

    /// @dev Stake matured for `challengeId` (the latest epoch): assigns made
    /// after it opened are excluded, matured removals made after it opened
    /// are added back — unless a detach waived their hold in this epoch, in
    /// which case they may have left the module and never count again.
    /// Shared by `_freeze` and `_frozenPreview`.
    function _maturedStake(uint256 challengeId, address miningWallet) private view returns (uint256 matured) {
        matured = assignedOf[miningWallet];
        if (pendingEpoch[miningWallet] == challengeId) {
            matured -= pendingOf[miningWallet];
            if (challengeId != holdWaivedEpoch) matured += removingOf[miningWallet];
        }
    }

    /// @dev Fails closed when the recorded obligations exceed the balance —
    /// corrupted totals block exits instead of paying out. Returns the
    /// balance read so callers can reuse it as their measurement baseline.
    function _requireSolvent() private view returns (uint256 balance) {
        balance = HUNTER.balanceOf(address(this));
        if (balance < totalStake + totalFunds + totalCommitted) revert Insolvency();
    }
}

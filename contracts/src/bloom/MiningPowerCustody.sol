// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMiningPower} from "./IMiningPower.sol";

/// @dev Mirrors `HunterMiningCore.ChallengeState`; the core is immutable, so the
/// ordinal mapping is fixed for the lifetime of this custody.
enum CoreChallengeState {
    WAITING_FOR_SEED,
    ACTIVE,
    EXPIRED,
    ENDED,
    STOPPED
}

/// @dev The immutable mining core's live counters — read so a detached (but not
/// retired) custody can keep its unlock delay honest while mining continues on
/// a replacement module, and so it can observe a later terminal transition.
/// Wrapped in try/catch so test doubles without it still work.
interface IHunterMiningCoreView {
    function acceptedProofs() external view returns (uint256);
    function challengeState() external view returns (CoreChallengeState);
}

/// @title Mining Power custody — locked + assigned HUNTER for mining wallets
/// @dev Live wallet balances and gas tokens never count. Snapshots are challenge-bound.
contract MiningPowerCustody is IMiningPower, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error UnauthorizedCaller(address caller);
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientUnassigned(uint256 available, uint256 requested);
    error InsufficientAssigned(uint256 available, uint256 requested);
    error WrongAssignee(address expected, address provided);
    error MustUnassignFirst(address currentAssignee);
    error UnlockDelayNotMet(uint256 earliestProof, uint256 currentProofs);
    error AlreadySnapshotted(uint256 challengeId);
    error ChallengeNotOpen(uint256 challengeId);
    error InvalidCurveConfig();
    error SelfAssignment();
    error NotWired();
    error StaleChallengeId(uint256 supplied, uint256 active);
    error RetainedAssignments(uint256 assigned);

    uint256 public constant WAD = 1e18;
    uint256 public constant SLOPE_WAD = 5e17; // 0.5
    uint256 public constant CAP_BONUS_WAD = 2e18; // bonus cap → max mult 3x
    uint256 public constant UNLOCK_DELAY_PROOFS = 12;

    IERC20 public immutable HUNTER;
    address public immutable miningCore;
    uint256 public immutable curveUnit;

    uint256 public totalLocked;
    uint256 public lastAcceptedProofs;

    mapping(address => uint256) public unassignedOf;
    /// @dev Total HUNTER assigned to a mining wallet (challenge snapshot source).
    mapping(address => uint256) public assignedOf;
    /// @dev HUNTER this depositor currently has assigned to `assigneeOf[depositor]`.
    mapping(address => uint256) public assignedBy;
    mapping(address => address) public assigneeOf;
    /// @dev Unlock-delay clock is per depositor so a shared mining wallet cannot reset it.
    mapping(address => uint256) public assignProofIndex;
    /// @dev Assigns made while `pendingEpoch[wallet]` was the open challenge. They
    /// are part of `assignedOf` but excluded from that challenge's freeze — a
    /// digest is derivable once its seed is readable, so power bought after a
    /// challenge opened must only count from the next one.
    mapping(address => uint256) public pendingOf;
    mapping(address => uint256) public pendingEpoch;
    /// @dev This depositor's own contribution to their wallet's pending bucket,
    /// kept per depositor so one account's unassign cannot launder another's
    /// post-open stake into matured power.
    mapping(address => uint256) public pendingBy;
    mapping(address => uint256) public pendingEpochBy;
    /// @dev Matured stake unassigned while `pendingEpoch[wallet]` is the open
    /// challenge. Added back at that challenge's freeze so removals only take
    /// effect from the next one — the bind holds for exits as well as entries.
    mapping(address => uint256) public removingOf;
    /// @dev Newest challenge opened by `snapshotChallenge`.
    uint256 public latestChallengeId;
    /// @dev True while this custody is the module Mining Core reads. Set by the
    /// first `snapshotChallenge` after wiring, cleared by `onMiningPowerDetached`.
    /// Assignments are refused while false so stake cannot be pre-positioned on
    /// an unwired module or parked on a retired one; exiting stays open either way.
    bool public wired;
    /// @dev True only after a terminal detach (mining stopped or minted out).
    /// The proof clock can never advance again, so the unlock delay is waived;
    /// a non-terminal detach keeps the delay against the live core clock so a
    /// module swap cannot launder stake into a fresh assignment early.
    bool public retired;
    /// @dev Sum of `assignedOf` across all wallets. A custody that still holds
    /// assignments cannot be rewired — retained stake has stale epochs and
    /// could claim power for a challenge whose digest is already derivable.
    uint256 public totalAssigned;

    mapping(uint256 => bool) public challengeOpen;
    mapping(uint256 => mapping(address => bool)) private _frozen;
    mapping(uint256 => mapping(address => uint256)) private _lockedSnap;
    mapping(uint256 => mapping(address => uint256)) private _multSnap;

    event Deposited(address indexed depositor, uint256 amount);
    event Assigned(address indexed depositor, address indexed miningWallet, uint256 amount, uint256 proofIndex);
    event Unassigned(address indexed depositor, address indexed miningWallet, uint256 amount, uint256 proofIndex);
    event Withdrawn(address indexed depositor, uint256 amount);
    event ChallengeSnapshotted(uint256 indexed challengeId);
    event ProofProgress(uint256 acceptedProofs);

    modifier onlyMiningCore() {
        if (msg.sender != miningCore) revert UnauthorizedCaller(msg.sender);
        _;
    }

    constructor(address hunterToken, address miningCore_, uint256 curveUnit_) {
        if (hunterToken == address(0) || miningCore_ == address(0)) revert ZeroAddress();
        if (curveUnit_ == 0) revert InvalidCurveConfig();
        HUNTER = IERC20(hunterToken);
        miningCore = miningCore_;
        curveUnit = curveUnit_;
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBal = HUNTER.balanceOf(address(this));
        HUNTER.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = HUNTER.balanceOf(address(this)) - beforeBal;
        if (received == 0) revert ZeroAmount();
        unassignedOf[msg.sender] += received;
        totalLocked += received;
        emit Deposited(msg.sender, received);
    }

    function assign(address miningWallet, uint256 amount) external nonReentrant {
        if (!wired) revert NotWired();
        if (miningWallet == address(0)) revert ZeroAddress();
        if (miningWallet == msg.sender) revert SelfAssignment();
        if (amount == 0) revert ZeroAmount();
        address current = assigneeOf[msg.sender];
        if (current != address(0) && current != miningWallet) revert MustUnassignFirst(current);
        uint256 available = unassignedOf[msg.sender];
        if (amount > available) revert InsufficientUnassigned(available, amount);
        // Pending from an older epoch has matured and queued removals have
        // landed; retag the bucket to the current challenge before recording
        // this assignment against it.
        if (pendingEpoch[miningWallet] < latestChallengeId) {
            pendingOf[miningWallet] = 0;
            removingOf[miningWallet] = 0;
            pendingEpoch[miningWallet] = latestChallengeId;
        }
        if (pendingEpochBy[msg.sender] < latestChallengeId) {
            pendingBy[msg.sender] = 0;
            pendingEpochBy[msg.sender] = latestChallengeId;
        }
        unassignedOf[msg.sender] = available - amount;
        assignedOf[miningWallet] += amount;
        assignedBy[msg.sender] += amount;
        totalAssigned += amount;
        pendingOf[miningWallet] += amount;
        pendingBy[msg.sender] += amount;
        assigneeOf[msg.sender] = miningWallet;
        assignProofIndex[msg.sender] = lastAcceptedProofs;
        emit Assigned(msg.sender, miningWallet, amount, lastAcceptedProofs);
    }

    function unassign(address miningWallet, uint256 amount) external nonReentrant {
        if (miningWallet == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (assigneeOf[msg.sender] != miningWallet) revert WrongAssignee(assigneeOf[msg.sender], miningWallet);
        // Terminal retirement waives the delay entirely — no proof can ever
        // arrive again. A non-terminal detach keeps it honest: the immutable
        // core's live count still advances on the replacement module, so stake
        // cannot hop custodies to beat the reassignment delay.
        if (!retired) {
            uint256 proofs = lastAcceptedProofs;
            bool terminalNow;
            if (miningCore.code.length > 0) {
                try IHunterMiningCoreView(miningCore).acceptedProofs() returns (uint256 live) {
                    if (live > proofs) proofs = live;
                } catch {}
                // A custody detached before a terminal transition never got the
                // retire notice — the live read is the only way it learns mining
                // can never advance its clock again.
                try IHunterMiningCoreView(miningCore).challengeState() returns (CoreChallengeState state) {
                    terminalNow = state == CoreChallengeState.ENDED || state == CoreChallengeState.STOPPED;
                } catch {}
            }
            if (!terminalNow) {
                uint256 earliest = assignProofIndex[msg.sender] + UNLOCK_DELAY_PROOFS;
                if (proofs < earliest) revert UnlockDelayNotMet(earliest, proofs);
            }
        }
        uint256 available = assignedBy[msg.sender];
        if (amount > available) revert InsufficientAssigned(available, amount);
        // Withdrawals eat the caller's own still-pending part first; the matured
        // balance that the current challenge froze against is always the last to
        // leave. Only the caller's share is debited — an unassign must never
        // launder another depositor's post-open stake into matured power. The
        // matured part is queued as a removal so it only narrows a later
        // challenge, never the one already open.
        if (pendingEpoch[miningWallet] < latestChallengeId) {
            pendingOf[miningWallet] = 0;
            removingOf[miningWallet] = 0;
            pendingEpoch[miningWallet] = latestChallengeId;
        }
        if (pendingEpochBy[msg.sender] < latestChallengeId) {
            pendingBy[msg.sender] = 0;
            pendingEpochBy[msg.sender] = latestChallengeId;
        }
        uint256 pendingPart = pendingBy[msg.sender] < amount ? pendingBy[msg.sender] : amount;
        pendingBy[msg.sender] -= pendingPart;
        pendingOf[miningWallet] -= pendingPart;
        removingOf[miningWallet] += amount - pendingPart;
        assignedBy[msg.sender] = available - amount;
        assignedOf[miningWallet] -= amount;
        totalAssigned -= amount;
        unassignedOf[msg.sender] += amount;
        if (assignedBy[msg.sender] == 0) assigneeOf[msg.sender] = address(0);
        emit Unassigned(msg.sender, miningWallet, amount, lastAcceptedProofs);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 available = unassignedOf[msg.sender];
        if (amount > available) revert InsufficientUnassigned(available, amount);
        unassignedOf[msg.sender] = available - amount;
        totalLocked -= amount;
        HUNTER.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function snapshotChallenge(uint256 challengeId) external onlyMiningCore {
        // A custody that still holds assignments cannot be (re)wired: retained
        // stake carries stale epochs and could claim power for a challenge
        // whose digest is already derivable.
        if (!wired && totalAssigned != 0) revert RetainedAssignments(totalAssigned);
        if (challengeOpen[challengeId]) {
            if (wired) revert AlreadySnapshotted(challengeId);
            // Re-wired during a challenge it already opened — epoch data intact.
        } else {
            challengeOpen[challengeId] = true;
            latestChallengeId = challengeId;
            emit ChallengeSnapshotted(challengeId);
        }
        wired = true;
        retired = false;
    }

    function onMiningPowerDetached(bool terminal) external onlyMiningCore {
        wired = false;
        retired = terminal;
    }

    function onProofAccepted(uint256 acceptedProofs) external onlyMiningCore {
        lastAcceptedProofs = acceptedProofs;
        emit ProofProgress(acceptedProofs);
    }

    function powerMultiplierWad(uint256 challengeId, address miningWallet) external returns (uint256) {
        _freeze(challengeId, miningWallet);
        return _multSnap[challengeId][miningWallet];
    }

    function snapshottedLockedAmount(uint256 challengeId, address miningWallet) external returns (uint256) {
        _freeze(challengeId, miningWallet);
        return _lockedSnap[challengeId][miningWallet];
    }

    function multiplierFromLockedAmount(uint256 lockedAmount) public view returns (uint256) {
        if (lockedAmount == 0) return WAD;
        uint256 x = lockedAmount / curveUnit;
        if (x == 0) return WAD;
        uint256 logTerm = Math.log2(x + 1) * WAD;
        uint256 bonus = Math.mulDiv(SLOPE_WAD, logTerm, WAD);
        if (bonus > CAP_BONUS_WAD) bonus = CAP_BONUS_WAD;
        return WAD + bonus;
    }

    function _freeze(uint256 challengeId, address miningWallet) private {
        if (!challengeOpen[challengeId]) revert ChallengeNotOpen(challengeId);
        if (_frozen[challengeId][miningWallet]) return;
        // A never-frozen challenge can only be reconstructed for the latest
        // epoch — older balances are no longer derivable once buckets settle,
        // so refuse rather than permanently record a wrong snapshot.
        if (challengeId != latestChallengeId) revert StaleChallengeId(challengeId, latestChallengeId);
        uint256 locked = assignedOf[miningWallet];
        // Assignments made after this challenge opened are pending for the next
        // one — they must not widen a window the miner could already evaluate.
        // Symmetrically, matured stake removed after opening is queued and only
        // narrows the next challenge, so it is added back for this freeze.
        if (pendingEpoch[miningWallet] == challengeId) {
            locked = locked - pendingOf[miningWallet] + removingOf[miningWallet];
        }
        _lockedSnap[challengeId][miningWallet] = locked;
        _multSnap[challengeId][miningWallet] = multiplierFromLockedAmount(locked);
        _frozen[challengeId][miningWallet] = true;
    }
}

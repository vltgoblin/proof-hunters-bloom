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
/// Slice status (S3): hooks are pass-through — the multiplier is always
/// 1.0x, nothing is gated and no lock is taken. Challenge bookkeeping
/// (`wired`, `retired`, `latestChallengeId`, `lastAcceptedProofs`) mirrors
/// `MiningPowerCustody` exactly so the module is a drop-in for the core.
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

    mapping(uint256 => bool) private _challengeOpen;

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
    /// @dev S3 pass-through: no stake is frozen yet, so the multiplier is the
    /// curve at zero stake, which is always the 1.0x base.
    function powerMultiplierWad(uint256, address) external view onlyMiningCore returns (uint256) {
        return multiplierFromLockedAmount(0);
    }

    /// @inheritdoc IMiningPower
    /// @dev S3 pass-through: no stake ledger yet.
    function snapshottedLockedAmount(uint256, address) external view onlyMiningCore returns (uint256) {
        return 0;
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
}

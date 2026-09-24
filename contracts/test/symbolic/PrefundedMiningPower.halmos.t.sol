// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PrefundedMiningPower} from "../../src/bloom/PrefundedMiningPower.sol";
import {WeightedHistory} from "../../src/bloom/libraries/WeightedHistory.sol";

/// @dev Halmos cheatcode surface (the `svm` address is
/// `address(bytes20(uint160(uint256(keccak256("svm cheat code")))))`).
/// Declared locally so the suite needs no extra library in `lib/`.
interface IHalmosSvm {
    function enableSymbolicStorage(address account) external;
}

/// @dev TEST-ONLY HUNTER stand-in for symbolic runs: a plain, non-taxing
/// balance ledger. Under `enableSymbolicStorage` every balance starts
/// arbitrary. No allowance model (the module is the only spender).
contract HalmosHunterToken {
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev TEST-ONLY lifecycle model: per-token `known` / `alive` / `eligible` /
/// `finalBeneficiary`, all arbitrary under symbolic storage. An unknown id
/// makes `currentMember` revert, like the real lifecycle.
contract HalmosLifecycle {
    mapping(uint256 => bool) public known;
    mapping(uint256 => bool) public alive;
    mapping(uint256 => bool) public eligible;
    mapping(uint256 => address) public finalBeneficiary;

    function currentMember(uint256 tokenId) external view returns (WeightedHistory.Member memory member) {
        require(known[tokenId], "unknown");
        member.alive = alive[tokenId];
        member.eligible = eligible[tokenId];
    }
}

/// @dev TEST-ONLY PROOF_NFT model: `ownerOf` reverts for a burned id,
/// `mintedEver` is arbitrary. `LIFECYCLE` is immutable so symbolic storage
/// cannot detach it.
contract HalmosProofNft {
    address public immutable LIFECYCLE;
    uint256 public mintedEver;
    mapping(uint256 => bool) public burned;
    mapping(uint256 => address) internal _owners;

    constructor(address lifecycle_) {
        LIFECYCLE = lifecycle_;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(!burned[tokenId], "burned");
        return _owners[tokenId];
    }
}

/// @dev TEST-ONLY Mining Core model: only the views the module reads. Under
/// symbolic storage `activeChallengeId`, `nftsMintedEver` and
/// `previousAcceptedDigest` are arbitrary, i.e. a SUPERSET of what the real
/// `HunterMiningCore` can present at `onProofAccepted` time.
contract HalmosCore {
    address public immutable PROOF_NFT;
    uint256 public activeChallengeId;
    uint256 public nftsMintedEver;
    uint256 public acceptedProofs;
    bytes32 public previousAcceptedDigest;
    uint8 public challengeState;

    constructor(address proofNft) {
        PROOF_NFT = proofNft;
    }
}

/// @title Halmos symbolic suite for PrefundedMiningPower's money paths (S10c, VLT-66)
/// @notice HALMOS ONLY. Every property is a `check_*` function, which
/// `forge test` does not run (it only runs `test*` / `invariant*`), so this
/// file compiles in CI and contributes 0 tests. Run it with Halmos — see
/// `test/symbolic/README.md`.
/// @dev Harness: a minimal symbolic world, NOT the real stack. The module is
/// the real `PrefundedMiningPower` (HEAD source, unmodified) deployed with
/// MIN_STAKE = 1_000e18, LOCK_PER_MINT = 100e18, EXIT_COOLDOWN = 7 days,
/// CURVE_UNIT = 0 and a guardian; token, core, NFT and lifecycle are the
/// mocks above. Each check turns on symbolic storage for all five contracts,
/// so the pre-state is ARBITRARY (any value of every slot), constrained only
/// by the assumptions stated in the check — i.e. the properties are proven
/// inductively ("holds before => holds after") rather than along a bounded
/// history. The core is MODELLED as the caller of the hooks (`vm.prank` of
/// the mock core, with `powerMultiplierWad` and `onProofAccepted` executed
/// atomically in one frame, as `submitProof` does); its views are arbitrary,
/// which over-approximates the real core.
/// Account universe U = 3 depositors (D0..D2) + 2 mining wallets (W0, W1).
/// Depositor-role calls come from D, wallet arguments from W; sums and the
/// structural invariant range over all of U. Summed values are assumed below
/// 2^128 so the property arithmetic itself cannot overflow.
contract PrefundedMiningPowerHalmos is Test {
    IHalmosSvm internal constant SVM = IHalmosSvm(address(uint160(uint256(keccak256("svm cheat code")))));

    uint256 internal constant MIN_STAKE = 1_000e18;
    uint256 internal constant LOCK = 100e18;
    uint256 internal constant COOLDOWN = 7 days;
    uint256 internal constant BOUND = 2 ** 128;
    uint256 internal constant WAD = 1e18;

    /// @dev OpenZeppelin 5.x ReentrancyGuard ERC-7201 slot.
    bytes32 internal constant GUARD_SLOT = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    /// @dev Storage slots of PrefundedMiningPower's private freeze cache
    /// (`forge inspect PrefundedMiningPower storageLayout`).
    uint256 internal constant SLOT_CHALLENGE_OPEN = 22;
    uint256 internal constant SLOT_FROZEN = 23;
    uint256 internal constant SLOT_FROZEN_STAKE = 24;

    address internal constant D0 = address(0x10D0);
    address internal constant D1 = address(0x10D1);
    address internal constant D2 = address(0x10D2);
    address internal constant W0 = address(0x10A0);
    address internal constant W1 = address(0x10A1);
    address internal constant GUARDIAN = address(0x10F5);

    // Operation selectors for the "every state-changing function" checks.
    uint8 internal constant OP_DEPOSIT = 0;
    uint8 internal constant OP_ASSIGN = 1;
    uint8 internal constant OP_UNASSIGN = 2;
    uint8 internal constant OP_WITHDRAW = 3;
    uint8 internal constant OP_EVICT = 4;
    uint8 internal constant OP_SETTLE = 5;
    uint8 internal constant OP_CLAIM = 6;
    uint8 internal constant OP_CLAIM_TO = 7;
    uint8 internal constant OP_SNAPSHOT = 8;
    uint8 internal constant OP_DETACH = 9;
    uint8 internal constant OP_DISABLE = 10;
    uint8 internal constant OP_FREEZE = 11;
    uint8 internal constant OP_GATE = 12;
    uint8 internal constant OP_ACCEPT = 13;
    uint8 internal constant OP_COUNT = 14;

    HalmosHunterToken internal token;
    HalmosLifecycle internal lifecycle;
    HalmosProofNft internal nft;
    HalmosCore internal core;
    PrefundedMiningPower internal pmp;

    struct Snap {
        uint256[5] unassigned;
        uint256[5] assignedOf;
        uint256[5] assignedBy;
        address[5] backerOf;
        address[5] assigneeOf;
        uint256 totalStake;
        uint256 totalAssigned;
        uint256 totalCommitted;
        uint256 balance;
    }

    function setUp() public {
        token = new HalmosHunterToken();
        lifecycle = new HalmosLifecycle();
        nft = new HalmosProofNft(address(lifecycle));
        core = new HalmosCore(address(nft));
        pmp = new PrefundedMiningPower(address(token), address(core), MIN_STAKE, LOCK, COOLDOWN, 0, GUARDIAN);
    }

    // ------------------------------------------------------------------
    // P1 — solvency
    // ------------------------------------------------------------------

    /// @notice P1a: every state-changing entry point (and the core hooks)
    /// preserves `balance >= totalStake + totalCommitted`. No structural
    /// assumption at all — only solvency before.
    function check_P1_solvencyPreserved(
        uint8 op,
        uint8 i,
        uint8 j,
        uint256 amt,
        uint256 aux,
        address who,
        address rcp
    ) public {
        _arbitraryWorld();
        _assumeTotalsBounded();
        vm.assume(_solvent());
        _op(op, i, j, amt, aux, who, rcp);
        assert(_solvent());
    }

    /// @notice P1b: each exit (`withdraw`, `claimCommitted`,
    /// `claimCommittedTo`, and the stake exits `unassign` / `evictBacker`)
    /// reverts when the module is insolvent before the call.
    function check_P1_exitsRevertWhenInsolvent(
        uint8 op,
        uint8 i,
        uint8 j,
        uint256 amt,
        uint256 aux,
        address who,
        address rcp
    ) public {
        vm.assume(op == OP_WITHDRAW || op == OP_CLAIM || op == OP_CLAIM_TO || op == OP_UNASSIGN || op == OP_EVICT);
        _arbitraryWorld();
        _assumeTotalsBounded();
        vm.assume(!_solvent());
        bool ok = _op(op, i, j, amt, aux, who, rcp);
        assert(!ok);
    }

    /// @notice Per-operation splits of P1a / P3+P4 (same properties with `op`
    /// fixed), so each operation is solved in its own Halmos run. P3 and P4
    /// share their pre-state assumptions, so one run asserts both.
    function _p1(uint8 op, uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) internal {
        _arbitraryWorld();
        _assumeTotalsBounded();
        vm.assume(_solvent());
        _op(op, i, j, amt, aux, who, rcp);
        assert(_solvent());
    }

    function _p34(uint8 op, uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) internal {
        _arbitraryWorld();
        _assumeBounded();
        vm.assume(_cons() && _oneBacker());
        _op(op, i, j, amt, aux, who, rcp);
        assert(_cons());
        assert(_oneBacker());
    }

    function check_P1op_Deposit(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(0, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Deposit(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(0, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Assign(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(1, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Assign(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(1, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Unassign(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(2, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Unassign(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(2, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Withdraw(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(3, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Withdraw(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(3, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Evict(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(4, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Evict(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(4, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Settle(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(5, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Settle(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(5, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Claim(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(6, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Claim(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(6, i, j, amt, aux, who, rcp);
    }

    function check_P1op_ClaimTo(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(7, i, j, amt, aux, who, rcp);
    }

    function check_P34op_ClaimTo(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(7, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Snapshot(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(8, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Snapshot(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(8, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Detach(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(9, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Detach(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(9, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Disable(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(10, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Disable(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(10, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Freeze(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(11, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Freeze(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(11, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Gate(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(12, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Gate(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(12, i, j, amt, aux, who, rcp);
    }

    function check_P1op_Accept(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p1(13, i, j, amt, aux, who, rcp);
    }

    function check_P34op_Accept(uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp) public {
        _p34(13, i, j, amt, aux, who, rcp);
    }

    // ------------------------------------------------------------------
    // P2 — withdraw pays exactly and never more than withdrawable
    // ------------------------------------------------------------------

    /// @notice P2: `withdraw(x)` succeeds => `x <= withdrawableOf(sender)`
    /// before; the sender gains exactly x, the module loses exactly x, and
    /// the sender's unassigned stake and `totalStake` drop by exactly x.
    function check_P2_withdrawBoundedAndExact(uint8 i, uint256 x) public {
        vm.assume(i < 3);
        _arbitraryWorld();
        address d = _d(i);
        _assumeTotalsBounded();
        vm.assume(pmp.unassignedOf(d) < BOUND);
        vm.assume(token.balanceOf(d) < BOUND);
        uint256 withdrawable = pmp.withdrawableOf(d);
        uint256 balD = token.balanceOf(d);
        uint256 balM = token.balanceOf(address(pmp));
        uint256 un = pmp.unassignedOf(d);
        uint256 ts = pmp.totalStake();
        uint256 ta = pmp.totalAssigned();
        uint256 tc = pmp.totalCommitted();

        bool ok = _as(d, abi.encodeCall(PrefundedMiningPower.withdraw, (x)));
        if (ok) {
            assert(x <= withdrawable);
            assert(token.balanceOf(d) == balD + x);
            assert(token.balanceOf(address(pmp)) == balM - x);
            assert(pmp.unassignedOf(d) == un - x);
            assert(pmp.totalStake() == ts - x);
            assert(pmp.totalAssigned() == ta);
            assert(pmp.totalCommitted() == tc);
        }
    }

    /// @notice P2 (liveness companion): in a reachable-shaped state
    /// (conservation + one-backer invariant + solvency), any
    /// `0 < x <= withdrawableOf(sender)` withdraw succeeds — exits cannot be
    /// blocked by the module itself.
    function check_P2_withdrawWithinWithdrawableSucceeds(uint8 i, uint256 x) public {
        vm.assume(i < 3);
        _arbitraryWorld();
        address d = _d(i);
        _assumeBounded();
        vm.assume(_cons() && _oneBacker() && _solvent());
        vm.assume(token.balanceOf(d) < BOUND);
        vm.assume(x != 0 && x <= pmp.withdrawableOf(d));
        bool ok = _as(d, abi.encodeCall(PrefundedMiningPower.withdraw, (x)));
        assert(ok);
    }

    // ------------------------------------------------------------------
    // P3 — conservation, P4 — one backer per wallet
    // ------------------------------------------------------------------

    /// @notice P3: `Σ unassignedOf + Σ assignedBy == totalStake` and
    /// `Σ assignedOf == totalAssigned` (over U) are preserved by every
    /// operation, assuming they and the one-backer invariant hold before.
    function check_P3_conservation(uint8 op, uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp)
        public
    {
        _arbitraryWorld();
        _assumeBounded();
        vm.assume(_cons() && _oneBacker());
        _op(op, i, j, amt, aux, who, rcp);
        assert(_cons());
    }

    /// @notice P4: the one-backer / one-wallet bijection (see `_oneBacker`)
    /// is preserved by every operation.
    function check_P4_oneBacker(uint8 op, uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp)
        public
    {
        _arbitraryWorld();
        _assumeBounded();
        vm.assume(_cons() && _oneBacker());
        _op(op, i, j, amt, aux, who, rcp);
        assert(_oneBacker());
    }

    // ------------------------------------------------------------------
    // P5 — settlement
    // ------------------------------------------------------------------

    /// @notice P5: an accepted proof (gate + `onProofAccepted`, atomically,
    /// as the core) takes exactly LOCK from the winner's `assignedOf` and
    /// from its backer's `assignedBy`, and from nobody else; unassigned
    /// balances, the token balance and every other lock are untouched; the
    /// new lock is recorded for the core's `nftsMintedEver` id. No
    /// structural assumption.
    function check_P5_settlementTakesExactLock(uint8 j, uint256 challengeId, uint256 proofs, uint256 otherId)
        public
    {
        vm.assume(j < 2);
        _arbitraryWorld();
        _assumeBounded();
        vm.assume(!pmp.gateDisabled());
        address miner = _w(j);
        address backer = pmp.backerOf(miner);
        uint256 backerPre = pmp.assignedBy(backer);
        uint256 minerPre = pmp.assignedOf(miner);
        Snap memory pre = _snap();
        uint256 tokenId = core.nftsMintedEver();
        vm.assume(otherId != tokenId);
        (uint256 oAmt,,,,, bool oRel) = pmp.committedOf(otherId);

        (bool ok,) = address(this).call(abi.encodeCall(this.settleAsCore, (challengeId, miner, proofs)));
        if (ok) {
            Snap memory post = _snap();
            assert(backer != address(0));
            for (uint256 k; k < 5; ++k) {
                address u = _u(k);
                assert(post.unassigned[k] == pre.unassigned[k]);
                assert(post.assignedOf[k] == (u == miner ? pre.assignedOf[k] - LOCK : pre.assignedOf[k]));
                assert(post.assignedBy[k] == (u == backer ? pre.assignedBy[k] - LOCK : pre.assignedBy[k]));
            }
            assert(pmp.assignedOf(miner) == minerPre - LOCK);
            assert(pmp.assignedBy(backer) == backerPre - LOCK);
            assert(post.totalStake == pre.totalStake - LOCK);
            assert(post.totalAssigned == pre.totalAssigned - LOCK);
            assert(post.totalCommitted == pre.totalCommitted + LOCK);
            assert(post.balance == pre.balance);
            _assertLockRecorded(tokenId, challengeId, miner, backer);
            (uint256 oAmt2,,,,, bool oRel2) = pmp.committedOf(otherId);
            assert(oAmt2 == oAmt && oRel2 == oRel);
        }
    }

    function _assertLockRecorded(uint256 tokenId, uint256 challengeId, address miner, address backer)
        internal
        view
    {
        (uint256 amount, uint256 cId, bytes32 digest, address lMiner, address lBacker, bool released) =
            pmp.committedOf(tokenId);
        assert(amount == LOCK);
        assert(cId == challengeId);
        assert(digest == core.previousAcceptedDigest());
        assert(lMiner == miner);
        assert(lBacker == backer);
        assert(!released);
    }

    /// @notice P5 split, smaller bound: the winner's wallet and backer are
    /// charged exactly LOCK, the totals move by exactly LOCK, the balance is
    /// unchanged and the lock is recorded — without the sweep over the other
    /// accounts of U (that part is only in `check_P5_settlementTakesExactLock`).
    function check_P5_settleExactLockCore(uint8 j, uint256 challengeId, uint256 proofs) public {
        vm.assume(j < 2);
        _arbitraryWorld();
        _assumeTotalsBounded();
        vm.assume(!pmp.gateDisabled());
        address miner = _w(j);
        address backer = pmp.backerOf(miner);
        uint256 backerPre = pmp.assignedBy(backer);
        uint256 minerPre = pmp.assignedOf(miner);
        uint256 ts = pmp.totalStake();
        uint256 ta = pmp.totalAssigned();
        uint256 tc = pmp.totalCommitted();
        uint256 bal = token.balanceOf(address(pmp));
        uint256 tokenId = core.nftsMintedEver();
        (bool ok,) = address(this).call(abi.encodeCall(this.settleAsCore, (challengeId, miner, proofs)));
        if (ok) {
            assert(backer != address(0));
            assert(pmp.assignedOf(miner) == minerPre - LOCK);
            assert(pmp.assignedBy(backer) == backerPre - LOCK);
            assert(pmp.totalStake() == ts - LOCK);
            assert(pmp.totalAssigned() == ta - LOCK);
            assert(pmp.totalCommitted() == tc + LOCK);
            assert(token.balanceOf(address(pmp)) == bal);
            _assertLockRecorded(tokenId, challengeId, miner, backer);
        }
    }

    /// @notice P5 (no note, no lock): `onProofAccepted` without a preceding
    /// enforcing gate — alone, or after a gate with the failsafe fired —
    /// changes no stake, no total, no balance and no lock.
    function check_P5_noNoteNoLock(bool viaDisabledGate, uint8 j, uint256 challengeId, uint256 proofs, uint256 anyId)
        public
    {
        vm.assume(j < 2);
        _arbitraryWorld();
        _assumeBounded();
        Snap memory pre = _snap();
        (uint256 aAmt,,,,, bool aRel) = pmp.committedOf(anyId);
        bool ok;
        if (viaDisabledGate) {
            vm.assume(pmp.gateDisabled());
            (ok,) = address(this).call(abi.encodeCall(this.settleAsCore, (challengeId, _w(j), proofs)));
        } else {
            ok = _as(address(core), abi.encodeCall(PrefundedMiningPower.onProofAccepted, (proofs)));
        }
        if (ok) {
            _assertSnapEq(pre, _snap());
            (uint256 aAmt2,,,,, bool aRel2) = pmp.committedOf(anyId);
            assert(aAmt2 == aAmt && aRel2 == aRel);
        }
    }

    /// @dev The modelled core frame: `submitProof` calls the gate and then
    /// `onProofAccepted` with no external call in between; a revert in either
    /// reverts both. Only callable by this test contract.
    function settleAsCore(uint256 challengeId, address miner, uint256 proofs) external returns (uint256 mult) {
        require(msg.sender == address(this), "self only");
        vm.prank(address(core));
        mult = pmp.powerMultiplierWad(challengeId, miner);
        vm.prank(address(core));
        pmp.onProofAccepted(proofs);
    }

    // ------------------------------------------------------------------
    // P6 — release
    // ------------------------------------------------------------------

    /// @notice P6: a claim succeeds only for the lifecycle's nonzero
    /// `finalBeneficiary`, only after the burn (ownerOf reverts, member known
    /// and neither alive nor eligible), only for an unreleased lock; it pays
    /// exactly the lock to the recipient, lowers `totalCommitted` by exactly
    /// the lock, marks it released, touches no stake — and any second claim
    /// of the same id, by anyone, reverts.
    function check_P6_claimOnceToBeneficiary(
        uint256 tokenId,
        address who,
        address rcp,
        bool useTo,
        address who2,
        address rcp2,
        bool useTo2
    ) public {
        _arbitraryWorld();
        _assumeTotalsBounded();
        address recipient = useTo ? rcp : who;
        vm.assume(recipient != address(pmp));
        vm.assume(token.balanceOf(recipient) < BOUND);
        ClaimPre memory pre = _claimPre(tokenId, recipient);

        bool ok = _claim(tokenId, who, rcp, useTo);
        if (ok) {
            _assertClaimed(tokenId, who, recipient, pre);
            bool again = _claim(tokenId, who2, rcp2, useTo2);
            assert(!again);
        }
    }

    struct ClaimPre {
        uint256 amount;
        bool released;
        uint256 totalCommitted;
        uint256 totalStake;
        uint256 totalAssigned;
        uint256 balModule;
        uint256 balRecipient;
    }

    function _claimPre(uint256 tokenId, address recipient) internal view returns (ClaimPre memory pre) {
        (pre.amount,,,,, pre.released) = pmp.committedOf(tokenId);
        pre.totalCommitted = pmp.totalCommitted();
        pre.totalStake = pmp.totalStake();
        pre.totalAssigned = pmp.totalAssigned();
        pre.balModule = token.balanceOf(address(pmp));
        pre.balRecipient = token.balanceOf(recipient);
    }

    function _assertClaimed(uint256 tokenId, address who, address recipient, ClaimPre memory pre) internal view {
        assert(who == lifecycle.finalBeneficiary(tokenId));
        assert(who != address(0));
        assert(nft.burned(tokenId));
        assert(lifecycle.known(tokenId) && !lifecycle.alive(tokenId) && !lifecycle.eligible(tokenId));
        assert(pre.amount != 0 && !pre.released);
        (uint256 amount2,,,,, bool released2) = pmp.committedOf(tokenId);
        assert(amount2 == pre.amount && released2);
        assert(pmp.totalCommitted() == pre.totalCommitted - pre.amount);
        assert(pmp.totalStake() == pre.totalStake);
        assert(pmp.totalAssigned() == pre.totalAssigned);
        assert(token.balanceOf(address(pmp)) == pre.balModule - pre.amount);
        assert(token.balanceOf(recipient) == pre.balRecipient + pre.amount);
    }

    // ------------------------------------------------------------------
    // P7 — hooks are core-only
    // ------------------------------------------------------------------

    /// @notice P7: every Mining Core hook reverts
    /// `UnauthorizedCaller(caller)` for every caller other than the core.
    function check_P7_hooksCoreOnly(uint8 h, address caller, uint256 a, address w, bool b) public {
        vm.assume(caller != address(core));
        _arbitraryWorld();
        bytes memory data;
        if (h == 0) data = abi.encodeCall(PrefundedMiningPower.powerMultiplierWad, (a, w));
        else if (h == 1) data = abi.encodeCall(PrefundedMiningPower.snapshottedLockedAmount, (a, w));
        else if (h == 2) data = abi.encodeCall(PrefundedMiningPower.snapshotChallenge, (a));
        else if (h == 3) data = abi.encodeCall(PrefundedMiningPower.onProofAccepted, (a));
        else data = abi.encodeCall(PrefundedMiningPower.onMiningPowerDetached, (b));
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(pmp).call(data);
        assert(!ok);
        assert(keccak256(ret) == keccak256(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, caller)));
    }

    /// @notice P7 companion: `disableRequirement` succeeds only for the
    /// guardian, and only sets `gateDisabled` (totals and balance unchanged).
    function check_P7_failsafeGuardianOnly(address caller) public {
        _arbitraryWorld();
        _assumeBounded();
        Snap memory pre = _snap();
        bool ok = _as(caller, abi.encodeCall(PrefundedMiningPower.disableRequirement, ()));
        if (ok) {
            assert(caller == GUARDIAN);
            assert(pmp.gateDisabled());
            _assertSnapEq(pre, _snap());
        }
    }

    // ------------------------------------------------------------------
    // P8 — cooldown and hold
    // ------------------------------------------------------------------

    /// @notice P8a: `unassign` succeeds => the caller's cooldown has elapsed
    /// (`now >= assignTimestamp + EXIT_COOLDOWN`), or it is waived (retired
    /// or failsafe fired).
    function check_P8_unassignRespectsCooldown(uint8 i, uint8 j, uint256 amt, uint256 t) public {
        vm.assume(i < 3 && j < 2);
        _arbitraryWorld();
        vm.warp(t);
        address d = _d(i);
        uint256 assignedAt = pmp.assignTimestamp(d);
        bool waived = pmp.retired() || pmp.gateDisabled();
        bool ok = _as(d, abi.encodeCall(PrefundedMiningPower.unassign, (_w(j), amt)));
        if (ok) assert(waived || (t >= assignedAt && t - assignedAt >= COOLDOWN));
    }

    /// @notice P8b: a withdraw that dips into held stake reverts unless the
    /// hold is over. Spec (written independently of `heldStakeOf`): stake is
    /// held iff the module is wired, not retired, failsafe not fired, the
    /// open epoch's hold was not waived by a detach, and the depositor's hold
    /// belongs to the open (latest) challenge; then `withdraw(x)` succeeds
    /// only if `x <= unassigned - min(heldBy, unassigned)`.
    function check_P8_withdrawRespectsHold(uint8 i, uint256 x) public {
        vm.assume(i < 3);
        _arbitraryWorld();
        address d = _d(i);
        uint256 latest = pmp.latestChallengeId();
        bool holdOver =
            !pmp.wired() || pmp.retired() || pmp.gateDisabled() || latest == pmp.holdWaivedEpoch()
                || pmp.heldEpochBy(d) != latest;
        uint256 held = holdOver ? 0 : pmp.heldBy(d);
        uint256 un = pmp.unassignedOf(d);
        uint256 free = held >= un ? 0 : un - held;
        bool ok = _as(d, abi.encodeCall(PrefundedMiningPower.withdraw, (x)));
        if (ok) assert(x <= free);
    }

    // ------------------------------------------------------------------
    // P9 — gate and curve
    // ------------------------------------------------------------------

    /// @notice P9a: with the failsafe not fired, `powerMultiplierWad`
    /// succeeds only if the wallet's frozen stake is >= MIN_STAKE, for every
    /// wallet and challenge. The frozen stake is recomputed here from the
    /// freeze spec (cached value, lowered to the matured stake in a re-wired
    /// latest epoch; else the matured stake of the latest epoch).
    function check_P9_gateRevertsBelowMinimum(uint256 c, address w) public {
        _arbitraryWorld();
        _p9gate(c, w, 0);
    }

    /// @notice P9a split (bounded): wallet in {W0, W1}; `mode` 1 = the wallet
    /// was never frozen for `c` (fresh freeze), 2 = already frozen (cached,
    /// incl. the re-wired downward re-freeze).
    function check_P9_gateBelowMin_fresh(uint8 j, uint256 c) public {
        vm.assume(j < 2);
        _arbitraryWorld();
        _p9gate(c, _w(j), 1);
    }

    function check_P9_gateBelowMin_cached(uint8 j, uint256 c) public {
        vm.assume(j < 2);
        _arbitraryWorld();
        _p9gate(c, _w(j), 2);
    }

    /// @notice P9a split, smaller bound: cached freeze with the challenge id
    /// pinned to `latestChallengeId` (the only id the real core passes).
    function check_P9_gateBelowMin_cachedLatest(uint8 j) public {
        vm.assume(j < 2);
        _arbitraryWorld();
        _p9gate(pmp.latestChallengeId(), _w(j), 2);
    }

    /// @dev Callers set up the arbitrary world first.
    function _p9gate(uint256 c, address w, uint8 mode) internal {
        vm.assume(!pmp.gateDisabled());
        (bool specOk, uint256 frozen) = _frozenSpec(c, w, mode);
        bool ok = _as(address(core), abi.encodeCall(PrefundedMiningPower.powerMultiplierWad, (c, w)));
        if (ok) {
            assert(specOk);
            assert(frozen >= MIN_STAKE);
        }
    }

    /// @dev Independent restatement of the freeze rule for (c, w): whether a
    /// freeze may succeed at all (`specOk`) and the value it yields.
    function _frozenSpec(uint256 c, address w, uint8 mode) internal view returns (bool specOk, uint256 frozen) {
        bool cached = uint8(uint256(vm.load(address(pmp), _slot2(c, w, SLOT_FROZEN)))) != 0;
        if (mode == 1) vm.assume(!cached);
        if (mode == 2) vm.assume(cached);
        if (uint8(uint256(vm.load(address(pmp), keccak256(abi.encode(c, SLOT_CHALLENGE_OPEN))))) == 0) {
            return (false, 0);
        }
        (bool underflow, uint256 matured) = _maturedSpec(c, w);
        uint256 latest = pmp.latestChallengeId();
        if (cached) {
            frozen = uint256(vm.load(address(pmp), _slot2(c, w, SLOT_FROZEN_STAKE)));
            specOk = true;
            if (c == pmp.rewiredEpoch() && c == latest) {
                if (underflow) specOk = false;
                else if (frozen > matured) frozen = matured;
            }
        } else {
            specOk = c == latest && !underflow;
            frozen = matured;
        }
    }

    function _maturedSpec(uint256 c, address w) internal view returns (bool underflow, uint256 matured) {
        uint256 pending = pmp.pendingOf(w);
        uint256 removing = pmp.removingOf(w);
        matured = pmp.assignedOf(w);
        vm.assume(matured < BOUND && pending < BOUND && removing < BOUND);
        if (pmp.pendingEpoch(w) == c) {
            if (matured < pending) underflow = true;
            else matured -= pending;
            if (c != pmp.holdWaivedEpoch()) matured += removing;
        }
    }

    /// @notice P9b: with CURVE_UNIT == 0 the gate returns exactly 1e18
    /// whenever it succeeds, and `multiplierFromLockedAmount` /
    /// `previewSubmit` never revert and return exactly 1e18 for all inputs.
    function check_P9_curveZeroIsExactlyOne(uint256 c, address w, uint256 x) public {
        _arbitraryWorld();
        (bool ok, bytes memory ret) = _asRet(address(core), abi.encodeCall(PrefundedMiningPower.powerMultiplierWad, (c, w)));
        if (ok) assert(abi.decode(ret, (uint256)) == WAD);
        (bool ok2, bytes memory ret2) =
            address(pmp).call(abi.encodeCall(PrefundedMiningPower.multiplierFromLockedAmount, (x)));
        assert(ok2 && abi.decode(ret2, (uint256)) == WAD);
        (bool ok3, bytes memory ret3) = address(pmp).call(abi.encodeCall(PrefundedMiningPower.previewSubmit, (w)));
        if (ok3) assert(abi.decode(ret3, (uint256)) == WAD);
    }

    /// @notice P9c: for ANY CURVE_UNIT (symbolic constructor argument) and
    /// any locked amount, the curve returns a value in [1e18, 3e18], and so
    /// does the gate hook whenever it succeeds.
    function check_P9_multiplierNeverAboveThree(uint256 curveUnit, uint256 x, uint256 c, address w) public {
        PrefundedMiningPower m =
            new PrefundedMiningPower(address(token), address(core), MIN_STAKE, LOCK, COOLDOWN, curveUnit, GUARDIAN);
        uint256 r = m.multiplierFromLockedAmount(x);
        assert(r >= WAD && r <= 3 * WAD);
        SVM.enableSymbolicStorage(address(m));
        vm.store(address(m), GUARD_SLOT, bytes32(uint256(1)));
        vm.prank(address(core));
        (bool ok, bytes memory ret) = address(m).call(abi.encodeCall(PrefundedMiningPower.powerMultiplierWad, (c, w)));
        if (ok) {
            uint256 g = abi.decode(ret, (uint256));
            assert(g >= WAD && g <= 3 * WAD);
        }
    }

    /// @notice P9c split, smaller bound: the curve alone (no gate hook) for
    /// any CURVE_UNIT and any locked amount stays within [1e18, 3e18].
    function check_P9_curveNeverAboveThree(uint256 curveUnit, uint256 x) public {
        PrefundedMiningPower m =
            new PrefundedMiningPower(address(token), address(core), MIN_STAKE, LOCK, COOLDOWN, curveUnit, GUARDIAN);
        uint256 r = m.multiplierFromLockedAmount(x);
        assert(r >= WAD && r <= 3 * WAD);
    }

    // ------------------------------------------------------------------
    // P10 — evictBacker
    // ------------------------------------------------------------------

    /// @notice P10: `evictBacker(w)` succeeds only for `msg.sender == w` and
    /// `0 < assignedOf[w] < MIN_STAKE`; it moves the backer's whole assigned
    /// stake to the backer's unassigned balance, clears both slots, books the
    /// matured part as removal + hold (pending part first, after epoch
    /// retagging), and changes nothing else (other accounts, totals other
    /// than totalAssigned, token balance, commitments).
    function check_P10_evictBacker(uint8 j, address caller) public {
        vm.assume(j < 2);
        _arbitraryWorld();
        _assumeBounded();
        vm.assume(_cons() && _oneBacker());
        address w = _w(j);
        address backer = pmp.backerOf(w);
        uint256 latest = pmp.latestChallengeId();
        // Retag bases (what `_retagBuckets` leaves before the move).
        uint256 pendOfBase = pmp.pendingEpoch(w) < latest ? 0 : pmp.pendingOf(w);
        uint256 remBase = pmp.pendingEpoch(w) < latest ? 0 : pmp.removingOf(w);
        uint256 pendByBase = pmp.pendingEpochBy(backer) < latest ? 0 : pmp.pendingBy(backer);
        uint256 heldBase = pmp.heldEpochBy(backer) < latest ? 0 : pmp.heldBy(backer);
        vm.assume(pendOfBase < BOUND && remBase < BOUND && pendByBase < BOUND && heldBase < BOUND);
        Snap memory pre = _snap();
        uint256 amount = pmp.assignedOf(w);

        bool ok = _as(caller, abi.encodeCall(PrefundedMiningPower.evictBacker, (w)));
        if (ok) {
            assert(caller == w);
            assert(amount != 0 && amount < MIN_STAKE);
            assert(backer != address(0));
            Snap memory post = _snap();
            for (uint256 k; k < 5; ++k) {
                address u = _u(k);
                assert(post.unassigned[k] == (u == backer ? pre.unassigned[k] + amount : pre.unassigned[k]));
                assert(post.assignedBy[k] == (u == backer ? 0 : pre.assignedBy[k]));
                assert(post.assignedOf[k] == (u == w ? 0 : pre.assignedOf[k]));
                assert(post.backerOf[k] == (u == w ? address(0) : pre.backerOf[k]));
                assert(post.assigneeOf[k] == (u == backer ? address(0) : pre.assigneeOf[k]));
            }
            assert(post.totalStake == pre.totalStake);
            assert(post.totalAssigned == pre.totalAssigned - amount);
            assert(post.totalCommitted == pre.totalCommitted);
            assert(post.balance == pre.balance);
            uint256 pendingPart = pendByBase < amount ? pendByBase : amount;
            uint256 matured = amount - pendingPart;
            assert(pmp.pendingBy(backer) == pendByBase - pendingPart);
            assert(pmp.pendingOf(w) == pendOfBase - pendingPart);
            assert(pmp.removingOf(w) == remBase + matured);
            assert(pmp.heldBy(backer) == heldBase + matured);
            assert(pmp.pendingEpoch(w) >= latest && pmp.heldEpochBy(backer) >= latest);
        }
    }

    // ------------------------------------------------------------------
    // Harness
    // ------------------------------------------------------------------

    /// @dev Arbitrary pre-state: every slot of the module, token, core, NFT
    /// and lifecycle is symbolic. The reentrancy guard is pinned to
    /// NOT_ENTERED (an "entered" guard only adds revert paths and cannot
    /// occur between transactions).
    function _arbitraryWorld() internal {
        SVM.enableSymbolicStorage(address(pmp));
        SVM.enableSymbolicStorage(address(token));
        SVM.enableSymbolicStorage(address(core));
        SVM.enableSymbolicStorage(address(nft));
        SVM.enableSymbolicStorage(address(lifecycle));
        vm.store(address(pmp), GUARD_SLOT, bytes32(uint256(1)));
    }

    function _op(uint8 op, uint8 i, uint8 j, uint256 amt, uint256 aux, address who, address rcp)
        internal
        returns (bool ok)
    {
        vm.assume(op < OP_COUNT && i < 3 && j < 2);
        address d = _d(i);
        address w = _w(j);
        if (op == OP_DEPOSIT) {
            vm.assume(token.balanceOf(d) < BOUND);
            return _as(d, abi.encodeCall(PrefundedMiningPower.deposit, (amt)));
        }
        if (op == OP_ASSIGN) return _as(d, abi.encodeCall(PrefundedMiningPower.assign, (w, amt)));
        if (op == OP_UNASSIGN) return _as(d, abi.encodeCall(PrefundedMiningPower.unassign, (w, amt)));
        if (op == OP_WITHDRAW) {
            vm.assume(token.balanceOf(d) < BOUND);
            return _as(d, abi.encodeCall(PrefundedMiningPower.withdraw, (amt)));
        }
        if (op == OP_EVICT) return _as(w, abi.encodeCall(PrefundedMiningPower.evictBacker, (w)));
        if (op == OP_SETTLE) {
            (ok,) = address(this).call(abi.encodeCall(this.settleAsCore, (aux, w, amt)));
            return ok;
        }
        if (op == OP_CLAIM || op == OP_CLAIM_TO) {
            address recipient = op == OP_CLAIM_TO ? rcp : who;
            vm.assume(token.balanceOf(recipient) < BOUND);
            return _claim(aux, who, rcp, op == OP_CLAIM_TO);
        }
        if (op == OP_SNAPSHOT) return _as(address(core), abi.encodeCall(PrefundedMiningPower.snapshotChallenge, (aux)));
        if (op == OP_DETACH) {
            return _as(address(core), abi.encodeCall(PrefundedMiningPower.onMiningPowerDetached, (amt & 1 == 1)));
        }
        if (op == OP_DISABLE) return _as(GUARDIAN, abi.encodeCall(PrefundedMiningPower.disableRequirement, ()));
        if (op == OP_FREEZE) {
            return _as(address(core), abi.encodeCall(PrefundedMiningPower.snapshottedLockedAmount, (aux, w)));
        }
        if (op == OP_GATE) return _as(address(core), abi.encodeCall(PrefundedMiningPower.powerMultiplierWad, (aux, w)));
        return _as(address(core), abi.encodeCall(PrefundedMiningPower.onProofAccepted, (amt)));
    }

    function _claim(uint256 tokenId, address who, address rcp, bool useTo) internal returns (bool) {
        if (useTo) return _as(who, abi.encodeCall(PrefundedMiningPower.claimCommittedTo, (tokenId, rcp)));
        return _as(who, abi.encodeCall(PrefundedMiningPower.claimCommitted, (tokenId)));
    }

    function _as(address from, bytes memory data) internal returns (bool ok) {
        vm.prank(from);
        (ok,) = address(pmp).call(data);
    }

    function _asRet(address from, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(from);
        (ok, ret) = address(pmp).call(data);
    }

    function _d(uint8 i) internal pure returns (address) {
        if (i == 0) return D0;
        if (i == 1) return D1;
        return D2;
    }

    function _w(uint8 j) internal pure returns (address) {
        if (j == 0) return W0;
        return W1;
    }

    function _u(uint256 k) internal pure returns (address) {
        if (k == 0) return D0;
        if (k == 1) return D1;
        if (k == 2) return D2;
        if (k == 3) return W0;
        return W1;
    }

    function _inU(address a) internal pure returns (bool) {
        return a == D0 || a == D1 || a == D2 || a == W0 || a == W1;
    }

    function _slot2(uint256 c, address w, uint256 base) internal pure returns (bytes32) {
        return keccak256(abi.encode(w, keccak256(abi.encode(c, base))));
    }

    function _solvent() internal view returns (bool) {
        return token.balanceOf(address(pmp)) >= pmp.totalStake() + pmp.totalCommitted();
    }

    function _assumeTotalsBounded() internal view {
        vm.assume(pmp.totalStake() < BOUND);
        vm.assume(pmp.totalAssigned() < BOUND);
        vm.assume(pmp.totalCommitted() < BOUND);
        vm.assume(token.balanceOf(address(pmp)) < BOUND);
    }

    function _assumeBounded() internal view {
        _assumeTotalsBounded();
        for (uint256 k; k < 5; ++k) {
            address u = _u(k);
            vm.assume(pmp.unassignedOf(u) < BOUND);
            vm.assume(pmp.assignedOf(u) < BOUND);
            vm.assume(pmp.assignedBy(u) < BOUND);
        }
    }

    /// @dev Conservation over U: Σ unassignedOf + Σ assignedBy == totalStake
    /// and Σ assignedOf == totalAssigned.
    function _cons() internal view returns (bool) {
        uint256 stake;
        uint256 assigned;
        for (uint256 k; k < 5; ++k) {
            address u = _u(k);
            stake += pmp.unassignedOf(u) + pmp.assignedBy(u);
            assigned += pmp.assignedOf(u);
        }
        return stake == pmp.totalStake() && assigned == pmp.totalAssigned();
    }

    /// @dev One backer per wallet, one wallet per backer, over U:
    /// - wallet side: `assignedOf[u] == 0 <=> backerOf[u] == 0`; a backer is
    ///   in U, is not the wallet itself, points back (`assigneeOf`) and holds
    ///   exactly the wallet's stake (`assignedBy[backer] == assignedOf[u]`);
    /// - depositor side: `assignedBy[u] == 0 <=> assigneeOf[u] == 0`; an
    ///   assignee is in U and names `u` as its backer.
    function _oneBacker() internal view returns (bool) {
        for (uint256 k; k < 5; ++k) {
            address u = _u(k);
            uint256 a = pmp.assignedOf(u);
            address b = pmp.backerOf(u);
            if ((a == 0) != (b == address(0))) return false;
            if (b != address(0)) {
                if (!_inU(b) || b == u) return false;
                if (pmp.assigneeOf(b) != u || pmp.assignedBy(b) != a) return false;
            }
            uint256 ab = pmp.assignedBy(u);
            address e = pmp.assigneeOf(u);
            if ((ab == 0) != (e == address(0))) return false;
            if (e != address(0)) {
                if (!_inU(e) || pmp.backerOf(e) != u) return false;
            }
        }
        return true;
    }

    function _snap() internal view returns (Snap memory s) {
        for (uint256 k; k < 5; ++k) {
            address u = _u(k);
            s.unassigned[k] = pmp.unassignedOf(u);
            s.assignedOf[k] = pmp.assignedOf(u);
            s.assignedBy[k] = pmp.assignedBy(u);
            s.backerOf[k] = pmp.backerOf(u);
            s.assigneeOf[k] = pmp.assigneeOf(u);
        }
        s.totalStake = pmp.totalStake();
        s.totalAssigned = pmp.totalAssigned();
        s.totalCommitted = pmp.totalCommitted();
        s.balance = token.balanceOf(address(pmp));
    }

    function _assertSnapEq(Snap memory a, Snap memory b) internal pure {
        for (uint256 k; k < 5; ++k) {
            assert(a.unassigned[k] == b.unassigned[k]);
            assert(a.assignedOf[k] == b.assignedOf[k]);
            assert(a.assignedBy[k] == b.assignedBy[k]);
            assert(a.backerOf[k] == b.backerOf[k]);
            assert(a.assigneeOf[k] == b.assigneeOf[k]);
        }
        assert(a.totalStake == b.totalStake);
        assert(a.totalAssigned == b.totalAssigned);
        assert(a.totalCommitted == b.totalCommitted);
        assert(a.balance == b.balance);
    }
}

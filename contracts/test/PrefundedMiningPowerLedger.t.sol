// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {PrefundedMiningPower} from "../src/bloom/PrefundedMiningPower.sol";
import {PrefundedMiningStack} from "./helpers/PrefundedMiningStack.sol";
import {PrefundedBonusHunter} from "./PrefundedMiningPowerHostile.t.sol";

/// @notice S4 (VLT-55) stake ledger of PrefundedMiningPower on the REAL stack.
/// Every hook call comes from the real `HunterMiningCore` (attach, submitProof,
/// stopMining); frozen stake is observed through the effective target the
/// core applies to a real proof. All amounts are TEST-ONLY fixture values.
contract PrefundedMiningPowerLedgerTest is PrefundedMiningStack {
    using stdStorage for StdStorage;

    address internal constant CAROL = address(0xCA201);
    address internal constant MINER2 = address(0x222E);
    address internal constant OUTSIDER = address(0x0B5E);

    uint256 private constant LOCK = 100e18;
    uint256 private constant COOLDOWN = 1 hours;
    uint256 private constant GATED_MIN = 1_000e18;

    function setUp() public override {
        super.setUp();
        _deployModule(0, LOCK, COOLDOWN, 0, address(0));
        _attach(module);
        assertTrue(module.wired());
    }

    // ------------------------------------------------------------------
    // Round trip
    // ------------------------------------------------------------------

    function testStakeRoundTripConserves() public {
        uint256 t0 = block.timestamp;
        uint256 open = core.activeChallengeId();
        token.mint(ALICE, 5_000e18);
        vm.prank(ALICE);
        token.approve(address(module), type(uint256).max);
        _trackDepositor(ALICE);

        vm.expectEmit(true, false, false, true, address(module));
        emit PrefundedMiningPower.Deposited(ALICE, 5_000e18);
        vm.prank(ALICE);
        module.deposit(5_000e18);
        assertEq(module.totalStake(), 5_000e18);
        assertEq(module.unassignedOf(ALICE), 5_000e18);
        assertEq(token.balanceOf(address(module)), 5_000e18);
        _assertBooks();

        vm.expectEmit(true, true, false, true, address(module));
        emit PrefundedMiningPower.Assigned(ALICE, MINER, 2_000e18, t0);
        _assign(ALICE, MINER, 2_000e18);
        assertEq(module.assignedOf(MINER), 2_000e18);
        assertEq(module.assignedBy(ALICE), 2_000e18);
        assertEq(module.assigneeOf(ALICE), MINER);
        assertEq(module.unassignedOf(ALICE), 3_000e18);
        assertEq(module.totalAssigned(), 2_000e18);
        assertEq(module.totalStake(), 5_000e18);
        assertEq(module.assignTimestamp(ALICE), t0);
        assertEq(module.pendingOf(MINER), 2_000e18);
        assertEq(module.pendingEpoch(MINER), open);
        assertEq(module.pendingBy(ALICE), 2_000e18);
        assertEq(module.pendingEpochBy(ALICE), open);
        _assertBooks();

        // Cooldown blocks the exit until EXIT_COOLDOWN has elapsed.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, t0 + COOLDOWN, t0));
        module.unassign(MINER, 1_000e18);
        vm.warp(t0 + COOLDOWN - 1);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, t0 + COOLDOWN, t0 + COOLDOWN - 1)
        );
        module.unassign(MINER, 1_000e18);

        vm.warp(t0 + COOLDOWN);
        vm.expectEmit(true, true, false, true, address(module));
        emit PrefundedMiningPower.Unassigned(ALICE, MINER, 1_000e18, t0 + COOLDOWN);
        _unassign(ALICE, MINER, 1_000e18);
        // Still pending (same challenge): leaves the pending bucket first.
        assertEq(module.pendingOf(MINER), 1_000e18);
        assertEq(module.removingOf(MINER), 0);
        _assertBooks();

        vm.expectEmit(true, false, false, true, address(module));
        emit PrefundedMiningPower.Withdrawn(ALICE, 4_000e18);
        _withdraw(ALICE, 4_000e18);
        assertEq(module.totalStake(), 1_000e18);
        assertEq(token.balanceOf(ALICE), 4_000e18);
        assertEq(token.balanceOf(address(module)), 1_000e18);
        _assertBooks();

        _unassign(ALICE, MINER, 1_000e18);
        assertEq(module.assigneeOf(ALICE), address(0));
        _withdraw(ALICE, 1_000e18);
        assertEq(module.totalStake(), 0);
        assertEq(module.totalAssigned(), 0);
        assertEq(module.assignedOf(MINER), 0);
        assertEq(module.pendingOf(MINER), 0);
        assertEq(token.balanceOf(ALICE), 5_000e18);
        assertEq(token.balanceOf(address(module)), 0);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Challenge bind (curve enabled, observed through the real core)
    // ------------------------------------------------------------------

    /// @dev Stake assigned during challenge c1 is pending (1.0x in c1). It
    /// matures into c2; unassigned mid-c2 it is queued in `removingOf`, so the
    /// real core still applies MINER's 2.0x multiplier in c2 (3,000 frozen;
    /// the widened target saturates at MAX_TARGET). From
    /// c3 on it is gone and the same band is rejected at the base target.
    function testUnassignRemovalAppliesNextChallenge() public {
        _useCurvedModule();
        _activate();
        uint256 c1 = cid;
        _deposit(ALICE, 3_000e18);
        _assign(ALICE, MINER, 3_000e18);
        assertEq(module.pendingOf(MINER), 3_000e18);
        assertEq(module.pendingEpoch(MINER), c1);

        // c1: pending stake does not count — a 2x-band digest is rejected.
        uint256 base = core.currentTarget();
        (uint256 n, bytes32 d) = _bandNonce(MINER, base, _widen(base, 2e18));
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, d, base));
        core.submitProof(cid, seed, n, basket);

        // c2 opens; ALICE's 3,000 matured, then exits mid-challenge.
        _win(OUTSIDER);
        _activate();
        uint256 c2 = cid;
        assertEq(c2, c1 + 1);
        assertEq(module.latestChallengeId(), c2);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, 3_000e18);
        assertEq(module.assignedOf(MINER), 0);
        assertEq(module.pendingOf(MINER), 0);
        assertEq(module.removingOf(MINER), 3_000e18);
        assertEq(module.pendingEpoch(MINER), c2);
        assertEq(module.totalAssigned(), 0);
        _assertBooks();

        // c2: the removal has not landed yet — 3,000 frozen → 2.0x (saturated).
        assertEq(module.multiplierFromLockedAmount(3_000e18), 2e18);
        base = core.currentTarget();
        uint256 widened = _widen(base, 2e18);
        (n, d) = _bandNonce(MINER, base, widened);
        uint256 before = nft.mintedEver();
        _send(MINER, n);
        assertEq(nft.mintedEver(), before + 1);
        assertEq(nft.ownerOf(before + 1), MINER);
        (,,, uint8 tier) = nft.birthData(before + 1);
        assertEq(tier, 1); // bonus-band proof mints one common NFT

        // c3: the removal landed — the same band is rejected at the base target.
        _activate();
        assertEq(cid, c2 + 1);
        base = core.currentTarget();
        (n, d) = _bandNonce(MINER, base, _widen(base, 2e18));
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, d, base));
        core.submitProof(cid, seed, n, basket);
        // The stale c2 bucket no longer applies (epoch is behind).
        assertLt(module.pendingEpoch(MINER), module.latestChallengeId());

        _withdraw(ALICE, 3_000e18);
        assertEq(token.balanceOf(ALICE), 3_000e18);
        _assertBooks();
    }

    /// @dev Port of the old custody regression: a matured depositor exiting a
    /// shared wallet debits only their own share — BOB's post-open (pending)
    /// assignment stays pending and never passes as matured power. ALICE's
    /// matured 600 (< CURVE_UNIT, 1.0x) exits during c2 while BOB's 1,000
    /// (1.5x on its own) is pending: through the real core c2 freezes exactly
    /// ALICE's opening 600, so a bonus-band digest is rejected at the base
    /// target; from c3 BOB's matured 1,000 widens the same band.
    function testMaturedUnassignDoesNotLaunderPendingAssignment() public {
        _useCurvedModule();
        _activate();
        uint256 c1 = cid;
        _deposit(ALICE, 600e18);
        _assign(ALICE, MINER, 600e18); // pending for c1

        _win(OUTSIDER); // c2 opens: ALICE's 600 matured
        _activate();
        uint256 c2 = cid;
        assertEq(c2, c1 + 1);
        _deposit(BOB, 1_000e18);
        _assign(BOB, MINER, 1_000e18); // pending for c2
        assertEq(module.pendingOf(MINER), 1_000e18);
        assertEq(module.pendingEpoch(MINER), c2);
        assertEq(module.pendingBy(BOB), 1_000e18);
        // ALICE's c1 share is stale (retagged lazily on her next action).
        assertEq(module.pendingBy(ALICE), 600e18);
        assertEq(module.pendingEpochBy(ALICE), c1);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, 600e18);

        // ALICE's exit is queued as a matured removal; BOB's pending untouched.
        assertEq(module.assignedOf(MINER), 1_000e18);
        assertEq(module.pendingOf(MINER), 1_000e18);
        assertEq(module.pendingBy(BOB), 1_000e18);
        assertEq(module.pendingBy(ALICE), 0);
        assertEq(module.pendingEpochBy(ALICE), c2);
        assertEq(module.removingOf(MINER), 600e18);
        _assertBooks();

        // c2 through the real core: frozen = 1,000 - 1,000 + 600 = 600 → 1.0x.
        assertEq(module.multiplierFromLockedAmount(600e18), 1e18);
        uint256 base = core.currentTarget();
        uint256 band = _widen(base, 15e17);
        assertGt(band, base);
        (uint256 n, bytes32 d) = _bandNonce(MINER, base, band);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, d, base));
        core.submitProof(cid, seed, n, basket);

        // c3: BOB's 1,000 has matured (1.5x) — the same band now mints.
        _win(OUTSIDER);
        _activate();
        assertEq(cid, c2 + 1);
        assertEq(module.multiplierFromLockedAmount(1_000e18), 15e17);
        base = core.currentTarget();
        (n, d) = _bandNonce(MINER, base, _widen(base, 15e17));
        uint256 before = nft.mintedEver();
        _send(MINER, n);
        assertEq(nft.ownerOf(before + 1), MINER);

        // BOB's later exit never underflows the shared buckets.
        _unassign(BOB, MINER, 1_000e18);
        assertEq(module.assignedOf(MINER), 0);
        assertEq(module.totalAssigned(), 0);
        _assertBooks();
    }

    function testTwoDepositorsCannotStealSharedAssignment() public {
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, 1_000e18);
        _deposit(BOB, 2_000e18);
        _assign(BOB, MINER, 2_000e18);

        assertEq(module.assignedOf(MINER), 3_000e18);
        assertEq(module.assignedBy(ALICE), 1_000e18);
        assertEq(module.assignedBy(BOB), 2_000e18);
        _assertBooks();

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientAssigned.selector, 1_000e18, 3_000e18));
        module.unassign(MINER, 3_000e18);
        // Nor can ALICE pull BOB's stake out as her own unassigned balance.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientUnassigned.selector, 0, 1));
        module.withdraw(1);

        _unassign(ALICE, MINER, 1_000e18);
        assertEq(module.assignedOf(MINER), 2_000e18);
        assertEq(module.assignedBy(ALICE), 0);
        assertEq(module.assignedBy(BOB), 2_000e18);
        assertEq(module.assigneeOf(ALICE), address(0));
        assertEq(module.assigneeOf(BOB), MINER);
        assertEq(module.unassignedOf(ALICE), 1_000e18);
        assertEq(module.unassignedOf(BOB), 0);
        assertEq(module.totalStake(), 3_000e18);
        assertEq(module.totalAssigned(), 2_000e18);
        _assertBooks();

        // The mining wallet itself owns nothing and can move nothing.
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.WrongAssignee.selector, address(0), MINER));
        module.unassign(MINER, 1);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientUnassigned.selector, 0, 1));
        module.withdraw(1);
    }

    /// @dev Port: a top-up assign restarts only the caller's cooldown clock.
    /// BOB's untouched clock (control) unlocks while ALICE's reset one still
    /// reverts, then unlocks one full cooldown after the top-up.
    function testTopUpAssignResetsThisDepositorsUnlockClockOnly() public {
        uint256 t0 = block.timestamp;
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, 500e18); // ALICE earliest t0 + 1h
        _deposit(BOB, 1_000e18);
        _assign(BOB, MINER, 500e18); // BOB earliest t0 + 1h (control)

        vm.warp(t0 + COOLDOWN);
        _assign(ALICE, MINER, 500e18); // top-up: ALICE earliest t0 + 2h
        assertEq(module.assignTimestamp(ALICE), t0 + COOLDOWN);
        assertEq(module.assignTimestamp(BOB), t0);

        vm.warp(t0 + COOLDOWN + COOLDOWN / 2);
        _unassign(BOB, MINER, 100e18); // control unlocks
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrefundedMiningPower.CooldownNotMet.selector, t0 + 2 * COOLDOWN, t0 + COOLDOWN + COOLDOWN / 2
            )
        );
        module.unassign(MINER, 1);

        vm.warp(t0 + 2 * COOLDOWN);
        _unassign(ALICE, MINER, 1_000e18);
        assertEq(module.assigneeOf(ALICE), address(0));
        assertEq(module.assignedOf(MINER), 400e18);
        assertEq(module.assignedBy(BOB), 400e18);
        _assertBooks();
    }

    /// @dev The cooldown is wall-clock only: with zero proofs accepted it
    /// unlocks on time, and a burst of real proofs never shortens it.
    function testCooldownIsPerDepositorAndProofIndependent() public {
        // S6: OUTSIDER's 13 wins each lock LOCK of mint funds; fund it and
        // let the funds mature (refresh opens a challenge, no proof, no warp).
        _fund(OUTSIDER, 13 * LOCK);
        _nextChallenge();
        assertEq(core.acceptedProofs(), 0);
        assertEq(module.lastAcceptedProofs(), 0);
        uint256 t0 = block.timestamp;
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, 1_000e18);
        vm.warp(t0 + COOLDOWN / 2);
        _deposit(BOB, 1_000e18);
        _assign(BOB, MINER2, 1_000e18);

        vm.warp(t0 + COOLDOWN - 1);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, t0 + COOLDOWN, t0 + COOLDOWN - 1)
        );
        module.unassign(MINER, 1_000e18);

        vm.warp(t0 + COOLDOWN);
        assertEq(core.acceptedProofs(), 0); // still no proof at all
        _unassign(ALICE, MINER, 1_000e18);
        assertEq(module.assignedBy(ALICE), 0);

        // BOB's clock is his own — and 13 real proofs (more than the old
        // 12-proof delay) at the same timestamp do not move it.
        for (uint256 i = 0; i < 13; i++) {
            _win(OUTSIDER);
        }
        assertEq(core.acceptedProofs(), 13);
        assertEq(module.lastAcceptedProofs(), 13);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrefundedMiningPower.CooldownNotMet.selector, t0 + COOLDOWN + COOLDOWN / 2, t0 + COOLDOWN
            )
        );
        module.unassign(MINER2, 1_000e18);

        vm.warp(t0 + COOLDOWN + COOLDOWN / 2);
        _unassign(BOB, MINER2, 1_000e18);
        assertEq(module.totalAssigned(), 0);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Assignment rules
    // ------------------------------------------------------------------

    function testSelfAssignmentRule() public {
        _deposit(ALICE, 1_000e18);
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.SelfAssignment.selector);
        module.assign(ALICE, 1_000e18);

        // A mining wallet may stake for someone else, never for itself.
        _deposit(MINER, 500e18);
        vm.prank(MINER);
        vm.expectRevert(PrefundedMiningPower.SelfAssignment.selector);
        module.assign(MINER, 500e18);
        _assign(MINER, ALICE, 500e18);
        _assign(ALICE, MINER, 1_000e18);
        assertEq(module.assignedOf(MINER), 1_000e18);
        assertEq(module.assignedOf(ALICE), 500e18);
        _assertBooks();
    }

    /// @dev S0 default 5: a token that credits more than requested is refused.
    function testOverReceiptPolicy() public {
        PrefundedBonusHunter bonus = new PrefundedBonusHunter();
        PrefundedMiningPower m =
            new PrefundedMiningPower(address(bonus), address(core), 0, LOCK, COOLDOWN, 0, address(0));
        bonus.setModule(address(m));
        bonus.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        bonus.approve(address(m), type(uint256).max);
        vm.expectRevert(PrefundedMiningPower.UnsupportedTokenReceipt.selector);
        m.deposit(1_000e18);
        vm.stopPrank();
        assertEq(m.totalStake(), 0);
        assertEq(m.unassignedOf(ALICE), 0);
        assertEq(bonus.balanceOf(address(m)), 0);
        assertEq(bonus.balanceOf(ALICE), 1_000e18);
    }

    function testAssignRefusedUnwiredDetachedRetiredAndAllowedWhenWired() public {
        // Fresh, never-attached module: deposits land, assigns do not.
        _detach();
        _deployModule(0, LOCK, COOLDOWN, 0, address(0));
        assertFalse(module.wired());
        _deposit(ALICE, 1_000e18);
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.NotWired.selector);
        module.assign(MINER, 100e18);

        // Wired: allowed, pending for the open challenge.
        _attach(module);
        _assign(ALICE, MINER, 100e18);
        assertEq(module.pendingEpoch(MINER), core.activeChallengeId());

        // Non-terminal detach: new assigns refused; the cooldown still holds.
        uint256 t = module.assignTimestamp(ALICE);
        _detach();
        assertFalse(module.wired());
        assertFalse(module.retired());
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.NotWired.selector);
        module.assign(MINER, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, t + COOLDOWN, t));
        module.unassign(MINER, 100e18);
        _deposit(ALICE, 1e18); // deposit and withdraw stay open while detached
        _withdraw(ALICE, 1e18);
        vm.warp(t + COOLDOWN);
        _unassign(ALICE, MINER, 100e18);

        // Re-wired (clean) → allowed again; then a keyed stop retires it.
        _attach(module);
        _assign(ALICE, MINER, 200e18);
        vm.prank(STOP);
        core.stopMining();
        assertFalse(module.wired());
        assertTrue(module.retired());
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.Retired.selector);
        module.assign(MINER, 1);
        _deposit(ALICE, 5e18);
        _withdraw(ALICE, 805e18);
        assertEq(module.unassignedOf(ALICE), 0);
        assertEq(module.assignedBy(ALICE), 200e18);
        _assertBooks();
    }

    function testCooldownWaivedAfterTerminalDetach() public {
        uint256 t0 = block.timestamp;
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, 1_000e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, t0 + COOLDOWN, t0));
        module.unassign(MINER, 1_000e18);

        vm.prank(STOP);
        core.stopMining();
        assertTrue(module.retired());
        assertEq(block.timestamp, t0);

        // Same timestamp: the waiver releases the stake immediately.
        _unassign(ALICE, MINER, 1_000e18);
        _withdraw(ALICE, 1_000e18);
        assertEq(token.balanceOf(ALICE), 1_000e18);
        assertEq(module.totalStake(), 0);
        assertEq(module.totalAssigned(), 0);
        _assertBooks();
    }

    /// @dev S8's `disableRequirement` does not exist yet; the flag is injected
    /// with stdstore to prove the S4 ledger already honours it: new assigns
    /// are refused and the exit cooldown is waived.
    function testGateDisabledRefusesAssignAndWaivesCooldown() public {
        uint256 t0 = block.timestamp;
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, 600e18);
        stdstore.enable_packed_slots().target(address(module)).sig("gateDisabled()").checked_write(true);
        assertTrue(module.gateDisabled());
        assertTrue(module.wired());

        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.GateDisabled.selector);
        module.assign(MINER, 1);
        assertEq(block.timestamp, t0);
        _unassign(ALICE, MINER, 600e18);
        _withdraw(ALICE, 1_000e18);
        assertEq(token.balanceOf(ALICE), 1_000e18);
        _assertBooks();
    }

    /// @dev Input validation on every ledger entry point.
    function testLedgerInputValidation() public {
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.ZeroAmount.selector);
        module.deposit(0);
        _deposit(ALICE, 1_000e18);

        vm.startPrank(ALICE);
        vm.expectRevert(PrefundedMiningPower.ZeroAddress.selector);
        module.assign(address(0), 1);
        vm.expectRevert(PrefundedMiningPower.ZeroAmount.selector);
        module.assign(MINER, 0);
        vm.expectRevert(
            abi.encodeWithSelector(PrefundedMiningPower.InsufficientUnassigned.selector, 1_000e18, 1_001e18)
        );
        module.assign(MINER, 1_001e18);
        vm.stopPrank();

        _assign(ALICE, MINER, 400e18);
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.MustUnassignFirst.selector, MINER));
        module.assign(MINER2, 1);
        vm.expectRevert(PrefundedMiningPower.ZeroAddress.selector);
        module.unassign(address(0), 1);
        vm.expectRevert(PrefundedMiningPower.ZeroAmount.selector);
        module.unassign(MINER, 0);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.WrongAssignee.selector, MINER, MINER2));
        module.unassign(MINER2, 1);
        vm.expectRevert(PrefundedMiningPower.ZeroAmount.selector);
        module.withdraw(0);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientUnassigned.selector, 600e18, 601e18));
        module.withdraw(601e18);
        vm.stopPrank();

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientAssigned.selector, 400e18, 401e18));
        module.unassign(MINER, 401e18);

        // Partial exit keeps the assignee; a full exit frees ALICE to switch.
        _unassign(ALICE, MINER, 100e18);
        assertEq(module.assigneeOf(ALICE), MINER);
        _unassign(ALICE, MINER, 300e18);
        assertEq(module.assigneeOf(ALICE), address(0));
        _assign(ALICE, MINER2, 1_000e18);
        assertEq(module.assignedOf(MINER2), 1_000e18);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Stake hold: matured stake unassigned mid-challenge stays until the
    // next snapshot (it still counts for the open challenge).
    // ------------------------------------------------------------------

    /// @dev The cooldown has elapsed, yet the stake that still backs MINER
    /// in the open challenge cannot leave; MINER mines a real proof with it,
    /// and only once the next challenge opens is it withdrawable — and MINER
    /// is then no longer eligible.
    function testMaturedUnassignHeldUntilNextSnapshot() public {
        _useGatedModule();
        _qualifyAndFund(ALICE, MINER, GATED_MIN, LOCK);
        uint256 c = cid;
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, GATED_MIN);
        assertEq(module.unassignedOf(ALICE), GATED_MIN);
        assertEq(module.heldBy(ALICE), GATED_MIN);
        assertEq(module.heldEpochBy(ALICE), c);
        assertEq(module.heldStakeOf(ALICE), GATED_MIN);
        assertEq(module.withdrawableOf(ALICE), 0);
        assertEq(module.removingOf(MINER), GATED_MIN);
        _assertBooks();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.StakeHeldUntilNextChallenge.selector, GATED_MIN, c));
        module.withdraw(1);
        // Over the unassigned balance it is still the plain balance error.
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(PrefundedMiningPower.InsufficientUnassigned.selector, GATED_MIN, GATED_MIN + 1)
        );
        module.withdraw(GATED_MIN + 1);

        // The held stake still backs MINER this challenge: a real proof mints.
        (bool eligible,, uint256 stake,) = module.eligibilityOf(MINER);
        assertTrue(eligible);
        assertEq(stake, GATED_MIN);
        uint256 tokenId = _win(MINER);
        assertEq(nft.ownerOf(tokenId), MINER);

        // Next challenge: the hold is gone and so is MINER's eligibility.
        _activate();
        assertEq(cid, c + 1);
        assertEq(module.heldStakeOf(ALICE), 0);
        assertEq(module.withdrawableOf(ALICE), GATED_MIN);
        uint8 reason;
        (eligible, reason, stake,) = module.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 2);
        assertEq(stake, 0);
        (uint256 n,) = _nonce(MINER);
        _expectNotEligible(2);
        _send(MINER, n);
        _withdraw(ALICE, GATED_MIN);
        assertEq(token.balanceOf(ALICE), GATED_MIN);
        _assertBooks();
    }

    /// @dev Stake assigned in the open challenge never counted, so it is not
    /// held; in a mixed exit only the matured part is held.
    function testPendingUnassignIsImmediatelyWithdrawable() public {
        uint256 c = core.activeChallengeId();
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, 1_000e18);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, 1_000e18);
        assertEq(module.heldBy(ALICE), 0);
        assertEq(module.withdrawableOf(ALICE), 1_000e18);
        _withdraw(ALICE, 1_000e18);
        assertEq(core.activeChallengeId(), c);
        _assertBooks();

        // Mixed: 600 matured + 400 pending top-up, all unassigned.
        _qualify(BOB, MINER2, 600e18);
        _deposit(BOB, 400e18);
        _assign(BOB, MINER2, 400e18);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(BOB, MINER2, 1_000e18);
        assertEq(module.heldStakeOf(BOB), 600e18);
        assertEq(module.withdrawableOf(BOB), 400e18);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.StakeHeldUntilNextChallenge.selector, 600e18, cid));
        module.withdraw(400e18 + 1);
        _withdraw(BOB, 400e18);
        assertEq(module.unassignedOf(BOB), 600e18);
        _assertBooks();

        // The refresh path (no proof) releases it as well.
        _nextChallenge();
        assertEq(module.withdrawableOf(BOB), 600e18);
        _withdraw(BOB, 600e18);
        assertEq(token.balanceOf(BOB), 1_000e18);
        _assertBooks();
    }

    /// @dev Waived exactly like the cooldown: failsafe, then retirement.
    function testHoldWaivedAfterRetirementAndFailsafe() public {
        // Failsafe (S8 lands `disableRequirement`; injected with stdstore).
        _useGatedModule();
        _qualify(ALICE, MINER, GATED_MIN);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, GATED_MIN);
        assertEq(module.withdrawableOf(ALICE), 0);
        stdstore.enable_packed_slots().target(address(module)).sig("gateDisabled()").checked_write(true);
        assertEq(module.heldStakeOf(ALICE), 0);
        assertEq(module.withdrawableOf(ALICE), GATED_MIN);
        _withdraw(ALICE, GATED_MIN);
        _assertBooks();

        // Retirement (terminal stop) on a fresh gated module.
        _useGatedModule();
        _qualify(BOB, MINER2, GATED_MIN);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(BOB, MINER2, GATED_MIN);
        assertEq(module.withdrawableOf(BOB), 0);
        vm.prank(STOP);
        core.stopMining();
        assertTrue(module.retired());
        assertEq(module.heldStakeOf(BOB), 0);
        _withdraw(BOB, GATED_MIN);
        assertEq(token.balanceOf(BOB), GATED_MIN);
        _assertBooks();
    }

    /// @dev A non-terminal detach also waives the hold (a module that is
    /// never re-wired would otherwise keep the stake forever). The released
    /// removal then no longer counts if the module is re-wired into the same
    /// challenge, so it can never back a wallet with nothing in the module.
    function testDetachWaivesHoldAndRewiredEpochIgnoresReleasedRemoval() public {
        _useGatedModule();
        _qualify(ALICE, MINER, GATED_MIN);
        uint256 c = cid;
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, GATED_MIN);
        assertEq(module.withdrawableOf(ALICE), 0);

        _detach();
        assertEq(module.holdWaivedEpoch(), c);
        assertEq(module.heldStakeOf(ALICE), 0);
        _withdraw(ALICE, GATED_MIN);
        assertEq(token.balanceOf(address(module)), 0);

        // Re-wired into the SAME challenge: MINER's queued removal is void.
        _attach(module);
        assertEq(module.latestChallengeId(), c);
        assertEq(module.removingOf(MINER), GATED_MIN);
        (bool eligible, uint8 reason, uint256 stake,) = module.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 2);
        assertEq(stake, 0);
        _activate();
        (uint256 n,) = _nonce(MINER);
        _expectNotEligible(2);
        _send(MINER, n);
        _assertBooks();
    }

    /// @dev Held stake re-assigned to W2 mid-challenge is pending there: W2
    /// is frozen at 0 and W1 keeps its frozen stake — one challenge, one
    /// wallet. Bouncing it back out of W2 (a pending-part unassign) does not
    /// release the hold. Next challenge W2 counts and W1 does not.
    function testHeldStakeCannotCountTwiceInOneChallenge() public {
        _useGatedModule();
        _fund(MINER2, LOCK);
        _qualifyAndFund(ALICE, MINER, GATED_MIN, LOCK);
        uint256 c = cid;
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, GATED_MIN);
        _assign(ALICE, MINER2, GATED_MIN);
        assertEq(module.unassignedOf(ALICE), 0);
        assertEq(module.heldStakeOf(ALICE), GATED_MIN);
        assertEq(module.withdrawableOf(ALICE), 0);
        _assertStake(MINER, true, GATED_MIN);
        _assertStake(MINER2, false, 0);
        _assertBooks();

        // Laundering attempt: pull it back out of W2 (pending part) — still held.
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER2, GATED_MIN);
        assertEq(module.removingOf(MINER2), 0);
        assertEq(module.unassignedOf(ALICE), GATED_MIN);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.StakeHeldUntilNextChallenge.selector, GATED_MIN, c));
        module.withdraw(1);
        _assign(ALICE, MINER2, GATED_MIN);
        _assertStake(MINER, true, GATED_MIN);
        _assertStake(MINER2, false, 0);
        _assertBooks();

        // Real core: W2 rejected, W1 mines.
        (uint256 n,) = _nonce(MINER2);
        _expectNotEligible(2);
        _send(MINER2, n);
        _win(MINER);

        // Next challenge: W2 counts, W1 does not.
        _activate();
        assertEq(cid, c + 1);
        _assertStake(MINER, false, 0);
        _assertStake(MINER2, true, GATED_MIN);
        (n,) = _nonce(MINER);
        _expectNotEligible(2);
        _send(MINER, n);
        _win(MINER2);
        assertEq(module.heldStakeOf(ALICE), 0);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Fuzz: random sequences conserve every unit
    // ------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 64
    /// forge-config: release.fuzz.runs = 64
    function testFuzz_RandomSequencesConserve(uint256 fuzzSeed) public {
        _useCurvedModule();
        address[3] memory ds = [ALICE, BOB, CAROL];
        address[2] memory ws = [MINER, MINER2];
        uint256[3] memory inflow;
        uint256[3] memory outflow;

        for (uint256 i = 0; i < 48; i++) {
            uint256 r = uint256(keccak256(abi.encode(fuzzSeed, i)));
            uint256 di = (r >> 8) % 3;
            address d = ds[di];
            uint256 amt = ((r >> 16) % 5_000e18) + 1;
            uint256 op = r % 6;
            if (op == 0) {
                _deposit(d, amt);
                inflow[di] += amt;
            } else if (op == 1) {
                uint256 avail = module.unassignedOf(d);
                if (avail != 0) {
                    address w = module.assigneeOf(d);
                    if (w == address(0)) w = ws[(r >> 128) % 2];
                    _assign(d, w, (amt % avail) + 1);
                }
            } else if (op == 2) {
                uint256 assigned = module.assignedBy(d);
                if (assigned != 0) {
                    address w = module.assigneeOf(d);
                    uint256 a = (amt % assigned) + 1;
                    uint256 earliest = module.assignTimestamp(d) + COOLDOWN;
                    if (block.timestamp < earliest) {
                        vm.prank(d);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                PrefundedMiningPower.CooldownNotMet.selector, earliest, block.timestamp
                            )
                        );
                        module.unassign(w, a);
                    } else {
                        _unassign(d, w, a);
                    }
                }
            } else if (op == 3) {
                // Withdraw within `withdrawableOf`; any excess over it that
                // is still unassigned must be held stake and revert.
                uint256 avail = module.unassignedOf(d);
                uint256 free = module.withdrawableOf(d);
                if (free != 0) {
                    uint256 a = (amt % free) + 1;
                    _withdraw(d, a);
                    outflow[di] += a;
                }
                free = module.withdrawableOf(d);
                avail = module.unassignedOf(d);
                if (avail > free) {
                    bytes memory heldErr = abi.encodeWithSelector(
                        PrefundedMiningPower.StakeHeldUntilNextChallenge.selector,
                        module.heldStakeOf(d),
                        module.latestChallengeId()
                    );
                    vm.prank(d);
                    vm.expectRevert(heldErr);
                    module.withdraw(free + 1);
                }
            } else if (op == 4) {
                vm.warp(block.timestamp + ((r >> 128) % (2 * COOLDOWN)));
            } else {
                // Real proof: the winner's stake is frozen for the open
                // challenge and a new challenge opens.
                address winner = (r >> 128) % 3 == 0 ? OUTSIDER : ws[(r >> 130) % 2];
                _win(winner);
                assertEq(module.latestChallengeId(), core.activeChallengeId());
            }
            _assertBooks();
        }

        // Terminal stop: every depositor exits in full, cooldown waived.
        vm.prank(STOP);
        core.stopMining();
        assertTrue(module.retired());
        for (uint256 k = 0; k < 3; k++) {
            address d = ds[k];
            uint256 assigned = module.assignedBy(d);
            if (assigned != 0) _unassign(d, module.assigneeOf(d), assigned);
            uint256 avail = module.unassignedOf(d);
            assertEq(module.withdrawableOf(d), avail, "hold not waived after retirement");
            if (avail != 0) {
                _withdraw(d, avail);
                outflow[k] += avail;
            }
            assertEq(outflow[k], inflow[k], "depositor not made whole");
            assertEq(token.balanceOf(d), inflow[k], "depositor balance");
            _assertBooks();
        }
        assertEq(module.totalStake(), 0);
        assertEq(module.totalAssigned(), 0);
        // S6: every accepted proof committed LOCK of its winner's mint funds
        // (released only in S7). The winners take back their unused funds;
        // what remains in the module is exactly the commitments.
        address[3] memory winners = [OUTSIDER, MINER, MINER2];
        for (uint256 k = 0; k < 3; k++) {
            uint256 left = module.fundsOf(winners[k]);
            if (left != 0) {
                vm.prank(winners[k]);
                module.withdrawFunds(left);
            }
        }
        assertEq(module.totalFunds(), 0);
        assertEq(module.totalCommitted(), LOCK * nft.mintedEver());
        assertEq(token.balanceOf(address(module)), module.totalCommitted());
        _assertBooks();
        assertEq(module.assignedOf(MINER), 0);
        assertEq(module.assignedOf(MINER2), 0);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Swap the attached module for one that enforces `GATED_MIN`.
    function _useGatedModule() private {
        _detach();
        _deployModule(GATED_MIN, LOCK, COOLDOWN, 0, address(0));
        _attach(module);
    }

    function _assertStake(address wallet, bool eligible, uint256 stake) private view {
        (bool e,, uint256 s,) = module.eligibilityOf(wallet);
        assertEq(e, eligible, "eligible");
        assertEq(s, stake, "frozen stake");
    }

    /// @dev Swap the attached base module for a curve-enabled one. S6: the
    /// wallets these tests mine with are funded BEFORE attach (enough for
    /// every possible win), so their funds count from the attach challenge.
    function _useCurvedModule() private {
        _detach();
        _deployModule(0, LOCK, COOLDOWN, CURVE_UNIT, address(0));
        _fund(OUTSIDER, 48 * LOCK);
        _fund(MINER, 48 * LOCK);
        _fund(MINER2, 48 * LOCK);
        _attach(module);
        assertEq(module.CURVE_UNIT(), CURVE_UNIT);
    }

    /// @dev Mirrors `HunterMiningCore._effectiveTarget`: widen by the
    /// multiplier and saturate at MAX_TARGET (the harness genesis target is
    /// MAX/2 of uint256, so any multiplier >= 1.5x saturates).
    function _widen(uint256 base, uint256 multWad) private view returns (uint256) {
        uint256 cap = core.MAX_TARGET();
        uint256 maxSafe = Math.mulDiv(cap, 1e18, multWad);
        return base >= maxSafe ? cap : Math.mulDiv(base, multWad, 1e18);
    }

    /// @dev A nonce whose digest for `miner` lies in (lo, hi] for the synced
    /// challenge.
    function _bandNonce(address miner, uint256 lo, uint256 hi) private view returns (uint256 nonce, bytes32 digest) {
        bytes32 challenge = core.currentChallenge();
        for (; nonce < 4_096; nonce++) {
            digest = core.deriveProofDigest(cid, challenge, miner, nonce);
            if (uint256(digest) > lo && uint256(digest) <= hi) return (nonce, digest);
        }
        revert("band nonce not found");
    }
}

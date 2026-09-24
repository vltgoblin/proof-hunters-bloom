// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";

/// @dev External wrapper around the internal-only WeightedHistory seam so
///      tests can use expectRevert across a real call boundary and read raw
///      member/global/basket trace lengths for overwrite assertions. Mutating
///      through this harness is a test-only entry point; it proves nothing
///      about the future controller's NFT or reserve authentication.
contract HistoryHarness {
    WeightedHistory.Store internal store;

    function mint(uint256 id, address basket, uint64 rarity) external {
        WeightedHistory.mint(store, id, basket, rarity);
    }

    function setHunter(uint256 id, uint256 credited) external {
        WeightedHistory.setHunter(store, id, credited);
    }

    function pause(uint256 id) external {
        WeightedHistory.pause(store, id);
    }

    function resume(uint256 id, address basket) external {
        WeightedHistory.resume(store, id, basket);
    }

    function burn(uint256 id) external {
        WeightedHistory.burn(store, id);
    }

    function memberBefore(uint256 id, uint256 cutoff) external view returns (WeightedHistory.Member memory) {
        return WeightedHistory.memberBefore(store, id, cutoff);
    }

    function globalBefore(uint256 cutoff) external view returns (WeightedHistory.Totals memory) {
        return WeightedHistory.globalBefore(store, cutoff);
    }

    function basketBefore(address basket, uint256 cutoff) external view returns (WeightedHistory.Totals memory) {
        return WeightedHistory.basketBefore(store, basket, cutoff);
    }

    function currentMember(uint256 id) external view returns (WeightedHistory.Member memory) {
        return WeightedHistory.currentMember(store, id);
    }

    function currentGlobal() external view returns (WeightedHistory.Totals memory) {
        return WeightedHistory.currentGlobal(store);
    }

    function currentBasket(address basket) external view returns (WeightedHistory.Totals memory) {
        return WeightedHistory.currentBasket(store, basket);
    }

    function memberTraceLength(uint256 id) external view returns (uint256) {
        return store.members[id].length;
    }

    function globalTraceLength() external view returns (uint256) {
        return store.globalHistory.length;
    }

    function basketTraceLength(address basket) external view returns (uint256) {
        return store.basketHistory[basket].length;
    }
}

contract WeightedHistoryTest is Test {
    address internal constant BASKET_A = address(0xA11CE);
    address internal constant BASKET_B = address(0xB0B);

    HistoryHarness internal h;

    function setUp() public {
        h = new HistoryHarness();
    }

    function _assertMember(
        WeightedHistory.Member memory m,
        address basket,
        uint64 rarity,
        uint256 hunter,
        bool alive,
        bool eligible
    ) internal {
        assertEq(m.basket, basket);
        assertEq(uint256(m.rarity), uint256(rarity));
        assertEq(m.hunter, hunter);
        assertTrue(m.alive == alive);
        assertTrue(m.eligible == eligible);
    }

    function _assertTotals(WeightedHistory.Totals memory t, uint256 rarity, uint256 hunter, uint256 count) internal {
        assertEq(uint256(t.rarity), rarity);
        assertEq(t.hunter, hunter);
        assertEq(uint256(t.count), count);
    }

    /// Two members in different baskets: mints at t=100, top-ups at t=101,
    /// another credit at t=102. Expected totals are independent literals — a
    /// memory-aliased transition must not leave the totals traces stale.
    function testTwoBasketAggregation() public {
        vm.warp(100);
        h.mint(1, BASKET_A, 100);
        h.mint(2, BASKET_B, 150);
        _assertTotals(h.currentGlobal(), 250, 0, 2);
        _assertTotals(h.currentBasket(BASKET_A), 100, 0, 1);
        _assertTotals(h.currentBasket(BASKET_B), 150, 0, 1);

        vm.warp(101);
        h.setHunter(1, 1000);
        h.setHunter(2, 3000);
        _assertTotals(h.currentGlobal(), 250, 4000, 2);
        _assertTotals(h.currentBasket(BASKET_A), 100, 1000, 1);
        _assertTotals(h.currentBasket(BASKET_B), 150, 3000, 1);
        _assertMember(h.currentMember(1), BASKET_A, 100, 1000, true, true);
        _assertMember(h.currentMember(2), BASKET_B, 150, 3000, true, true);

        vm.warp(102);
        h.setHunter(1, 1200);
        _assertTotals(h.currentGlobal(), 250, 4200, 2);
        _assertTotals(h.currentBasket(BASKET_A), 100, 1200, 1);
        _assertTotals(h.currentBasket(BASKET_B), 150, 3000, 1);
        _assertMember(h.currentMember(1), BASKET_A, 100, 1200, true, true);

        // Crediting the same amount is a no-op: no member checkpoint and no
        // totals movement on either aggregate trace.
        uint256 memberLen = h.memberTraceLength(1);
        uint256 globalLen = h.globalTraceLength();
        uint256 basketLen = h.basketTraceLength(BASKET_A);
        h.setHunter(1, 1200);
        assertEq(h.memberTraceLength(1), memberLen);
        assertEq(h.globalTraceLength(), globalLen);
        assertEq(h.basketTraceLength(BASKET_A), basketLen);
        _assertTotals(h.currentGlobal(), 250, 4200, 2);
    }

    /// Lookups are strictly-before: a checkpoint at exactly the cutoff is
    /// excluded. Mint at t=100, top-up at t=101, then burn at t=103 — earlier
    /// snapshots must survive the later burn.
    function testStrictlyBeforeCutoffs() public {
        vm.warp(100);
        h.mint(1, BASKET_A, 100);
        vm.warp(101);
        h.setHunter(1, 1000);
        vm.warp(102);

        // Cutoff 0 and cutoff at the mint timestamp both see nothing.
        _assertMember(h.memberBefore(1, 0), address(0), 0, 0, false, false);
        _assertMember(h.memberBefore(1, 100), address(0), 0, 0, false, false);
        _assertTotals(h.globalBefore(0), 0, 0, 0);
        _assertTotals(h.globalBefore(100), 0, 0, 0);
        _assertTotals(h.basketBefore(BASKET_A, 0), 0, 0, 0);
        _assertTotals(h.basketBefore(BASKET_A, 100), 0, 0, 0);

        // Cutoff 101 sees the minted member with hunter 0.
        _assertMember(h.memberBefore(1, 101), BASKET_A, 100, 0, true, true);
        _assertTotals(h.globalBefore(101), 100, 0, 1);
        _assertTotals(h.basketBefore(BASKET_A, 101), 100, 0, 1);

        // Cutoff 102 sees the topped-up member.
        _assertMember(h.memberBefore(1, 102), BASKET_A, 100, 1000, true, true);
        _assertTotals(h.globalBefore(102), 100, 1000, 1);
        _assertTotals(h.basketBefore(BASKET_A, 102), 100, 1000, 1);

        // An unknown basket reads zero; an unknown NFT reverts.
        _assertTotals(h.basketBefore(BASKET_B, 102), 0, 0, 0);
        _assertTotals(h.currentBasket(BASKET_B), 0, 0, 0);
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        h.memberBefore(9, 102);
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        h.currentMember(9);

        // Cutoffs beyond block.timestamp revert on all three lookups.
        vm.expectRevert(WeightedHistory.FutureCutoff.selector);
        h.memberBefore(1, 103);
        vm.expectRevert(WeightedHistory.FutureCutoff.selector);
        h.globalBefore(103);
        vm.expectRevert(WeightedHistory.FutureCutoff.selector);
        h.basketBefore(BASKET_A, 103);

        // A later burn never rewrites earlier snapshots: at cutoff 103 the
        // burn checkpoint itself is still excluded.
        vm.warp(103);
        h.burn(1);
        _assertMember(h.memberBefore(1, 102), BASKET_A, 100, 1000, true, true);
        _assertMember(h.memberBefore(1, 103), BASKET_A, 100, 1000, true, true);
        _assertTotals(h.globalBefore(102), 100, 1000, 1);
        _assertTotals(h.globalBefore(103), 100, 1000, 1);
        _assertTotals(h.basketBefore(BASKET_A, 102), 100, 1000, 1);
        _assertMember(h.currentMember(1), BASKET_A, 100, 0, false, false);
        _assertTotals(h.currentGlobal(), 0, 0, 0);
        _assertTotals(h.currentBasket(BASKET_A), 0, 0, 0);
    }

    /// Pending-switch pause/resume: pausing removes the contribution while
    /// keeping the member fields; a paused top-up updates the member trace
    /// only; resume into another basket re-adds the share there; a
    /// same-basket pause+resume cancels cleanly without double counting.
    function testPauseResumePendingSwitch() public {
        vm.warp(200);
        h.mint(1, BASKET_A, 100);
        h.mint(2, BASKET_A, 150);
        vm.warp(201);
        h.setHunter(1, 1000);
        h.setHunter(2, 3000);
        _assertTotals(h.currentGlobal(), 250, 4000, 2);
        _assertTotals(h.currentBasket(BASKET_A), 250, 4000, 2);

        // Pause id1: contribution leaves the totals, member fields retained.
        vm.warp(202);
        h.pause(1);
        _assertMember(h.currentMember(1), BASKET_A, 100, 1000, true, false);
        _assertTotals(h.currentGlobal(), 150, 3000, 1);
        _assertTotals(h.currentBasket(BASKET_A), 150, 3000, 1);

        // A top-up while paused moves the member trace but not the totals.
        vm.warp(203);
        h.setHunter(1, 1200);
        _assertMember(h.currentMember(1), BASKET_A, 100, 1200, true, false);
        _assertTotals(h.currentGlobal(), 150, 3000, 1);
        _assertTotals(h.currentBasket(BASKET_A), 150, 3000, 1);

        // Resume into basket B: the share re-enters the totals on B.
        vm.warp(204);
        h.resume(1, BASKET_B);
        _assertMember(h.currentMember(1), BASKET_B, 100, 1200, true, true);
        _assertTotals(h.currentGlobal(), 250, 4200, 2);
        _assertTotals(h.currentBasket(BASKET_A), 150, 3000, 1);
        _assertTotals(h.currentBasket(BASKET_B), 100, 1200, 1);

        // Pause + resume into the same basket cancels the pending switch and
        // restores the totals without duplicating the contribution.
        vm.warp(205);
        h.pause(1);
        _assertTotals(h.currentGlobal(), 150, 3000, 1);
        _assertTotals(h.currentBasket(BASKET_B), 0, 0, 0);
        vm.warp(206);
        h.resume(1, BASKET_B);
        _assertMember(h.currentMember(1), BASKET_B, 100, 1200, true, true);
        _assertTotals(h.currentGlobal(), 250, 4200, 2);
        _assertTotals(h.currentBasket(BASKET_A), 150, 3000, 1);
        _assertTotals(h.currentBasket(BASKET_B), 100, 1200, 1);

        // Snapshots taken before each transition stay intact.
        vm.warp(207);
        _assertTotals(h.globalBefore(202), 250, 4000, 2);
        _assertTotals(h.basketBefore(BASKET_A, 202), 250, 4000, 2);
        _assertTotals(h.globalBefore(203), 150, 3000, 1);
        _assertTotals(h.globalBefore(204), 150, 3000, 1);
        _assertTotals(h.globalBefore(205), 250, 4200, 2);
        _assertTotals(h.basketBefore(BASKET_A, 205), 150, 3000, 1);
        _assertTotals(h.basketBefore(BASKET_B, 205), 100, 1200, 1);
        _assertTotals(h.globalBefore(206), 150, 3000, 1);
        _assertTotals(h.basketBefore(BASKET_B, 206), 0, 0, 0);
        _assertMember(h.memberBefore(1, 202), BASKET_A, 100, 1000, true, true);
        _assertMember(h.memberBefore(1, 203), BASKET_A, 100, 1000, true, false);
        _assertMember(h.memberBefore(1, 204), BASKET_A, 100, 1200, true, false);
        _assertMember(h.memberBefore(1, 205), BASKET_B, 100, 1200, true, true);
        _assertMember(h.memberBefore(1, 206), BASKET_B, 100, 1200, true, false);
        _assertMember(h.memberBefore(1, 207), BASKET_B, 100, 1200, true, true);
    }

    /// Mint, top-up and burn at one timestamp collapse into a single member
    /// checkpoint ending dead; the member contributes nothing at any cutoff
    /// while a live member touched in the same block keeps its share.
    function testSameTimestampLifecycle() public {
        vm.warp(98);
        h.mint(2, BASKET_A, 150);
        vm.warp(99);
        h.setHunter(2, 3000);

        vm.warp(100);
        h.mint(1, BASKET_A, 100);
        h.setHunter(1, 1000);
        h.burn(1);

        // One overwritten member checkpoint, ending dead with fields kept.
        assertEq(h.memberTraceLength(1), 1);
        _assertMember(h.currentMember(1), BASKET_A, 100, 0, false, false);
        _assertMember(h.currentMember(2), BASKET_A, 150, 3000, true, true);
        _assertTotals(h.currentGlobal(), 150, 3000, 1);
        _assertTotals(h.currentBasket(BASKET_A), 150, 3000, 1);

        vm.warp(101);
        // Cutoff 100 excludes the whole same-block lifecycle; cutoff 101 sees
        // the dead member and totals that only count id2.
        _assertMember(h.memberBefore(1, 100), address(0), 0, 0, false, false);
        _assertMember(h.memberBefore(1, 101), BASKET_A, 100, 0, false, false);
        _assertTotals(h.globalBefore(100), 150, 3000, 1);
        _assertTotals(h.globalBefore(101), 150, 3000, 1);
        _assertTotals(h.basketBefore(BASKET_A, 100), 150, 3000, 1);
        _assertTotals(h.basketBefore(BASKET_A, 101), 150, 3000, 1);
        _assertMember(h.memberBefore(2, 100), BASKET_A, 150, 3000, true, true);
        _assertMember(h.memberBefore(2, 101), BASKET_A, 150, 3000, true, true);

        // Burned ids stay known: no remint, no further lifecycle calls.
        vm.expectRevert(WeightedHistory.IdAlreadyKnown.selector);
        h.mint(1, BASKET_A, 7);
        vm.expectRevert(WeightedHistory.NotLive.selector);
        h.setHunter(1, 2000);
        vm.expectRevert(WeightedHistory.NotLive.selector);
        h.pause(1);
        vm.expectRevert(WeightedHistory.NotLive.selector);
        h.resume(1, BASKET_A);
        vm.expectRevert(WeightedHistory.NotLive.selector);
        h.burn(1);
    }

    /// Active and paused burns each remove an eligible contribution exactly
    /// once. A paused burn must not subtract twice nor re-enter eligibility;
    /// burned members end dead with hunter 0 and rarity/basket retained, and
    /// earlier snapshots keep the historical hunter.
    function testActiveAndPausedBurn() public {
        vm.warp(110);
        h.mint(1, BASKET_A, 100);
        h.mint(2, BASKET_B, 150);
        h.mint(3, BASKET_B, 200);
        vm.warp(111);
        h.setHunter(1, 1000);
        h.setHunter(2, 3000);
        h.setHunter(3, 9000);
        _assertTotals(h.currentGlobal(), 450, 13000, 3);
        _assertTotals(h.currentBasket(BASKET_A), 100, 1000, 1);
        _assertTotals(h.currentBasket(BASKET_B), 350, 12000, 2);

        // Pause id2: its share leaves, id3's remains behind in B.
        vm.warp(112);
        h.pause(2);
        _assertMember(h.currentMember(2), BASKET_B, 150, 3000, true, false);
        _assertTotals(h.currentGlobal(), 300, 10000, 2);
        _assertTotals(h.currentBasket(BASKET_B), 200, 9000, 1);

        // Paused burn: nothing left to subtract, and no re-entry. The exact
        // totals prove no double subtraction against id3's surviving share.
        vm.warp(113);
        h.burn(2);
        _assertMember(h.currentMember(2), BASKET_B, 150, 0, false, false);
        _assertTotals(h.currentGlobal(), 300, 10000, 2);
        _assertTotals(h.currentBasket(BASKET_A), 100, 1000, 1);
        _assertTotals(h.currentBasket(BASKET_B), 200, 9000, 1);

        // Active burn removes the contribution exactly once.
        vm.warp(114);
        h.burn(1);
        _assertMember(h.currentMember(1), BASKET_A, 100, 0, false, false);
        _assertTotals(h.currentGlobal(), 200, 9000, 1);
        _assertTotals(h.currentBasket(BASKET_A), 0, 0, 0);
        _assertTotals(h.currentBasket(BASKET_B), 200, 9000, 1);
        _assertMember(h.currentMember(3), BASKET_B, 200, 9000, true, true);

        // Historical member states and totals keep the pre-burn hunter.
        vm.warp(115);
        _assertMember(h.memberBefore(2, 112), BASKET_B, 150, 3000, true, true);
        _assertMember(h.memberBefore(2, 113), BASKET_B, 150, 3000, true, false);
        _assertMember(h.memberBefore(2, 114), BASKET_B, 150, 0, false, false);
        _assertMember(h.memberBefore(1, 114), BASKET_A, 100, 1000, true, true);
        _assertTotals(h.globalBefore(112), 450, 13000, 3);
        _assertTotals(h.globalBefore(113), 300, 10000, 2);
        _assertTotals(h.globalBefore(114), 300, 10000, 2);
        _assertTotals(h.basketBefore(BASKET_B, 112), 350, 12000, 2);
        _assertTotals(h.basketBefore(BASKET_B, 113), 200, 9000, 1);
        _assertTotals(h.basketBefore(BASKET_B, 114), 200, 9000, 1);
    }

    /// Argument validation, monotone-hunter rules, pause/resume guards,
    /// backward-timestamp rejection and checked-arithmetic rollback. Fresh
    /// harnesses isolate each overflow so the rolled-back appends are
    /// observable through trace lengths.
    function testValidationAndAtomicReverts() public {
        HistoryHarness f = new HistoryHarness();

        vm.expectRevert(WeightedHistory.InvalidId.selector);
        f.mint(0, BASKET_A, 1);
        vm.expectRevert(WeightedHistory.InvalidBasket.selector);
        f.mint(1, address(0), 1);
        vm.expectRevert(WeightedHistory.InvalidRarity.selector);
        f.mint(1, BASKET_A, 0);

        vm.warp(300);
        f.mint(1, BASKET_A, 100);
        vm.expectRevert(WeightedHistory.IdAlreadyKnown.selector);
        f.mint(1, BASKET_A, 100);

        // Unknown ids revert on every member-scoped call.
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        f.setHunter(9, 1);
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        f.pause(9);
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        f.resume(9, BASKET_A);
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        f.burn(9);
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        f.currentMember(9);
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        f.memberBefore(9, 300);

        // The zero basket never owns a trace.
        vm.expectRevert(WeightedHistory.InvalidBasket.selector);
        f.currentBasket(address(0));
        vm.expectRevert(WeightedHistory.InvalidBasket.selector);
        f.basketBefore(address(0), 300);

        // Monotone hunter: lower reverts, equal is a checkpoint-free no-op.
        vm.warp(301);
        f.setHunter(1, 500);
        vm.expectRevert(WeightedHistory.HunterDecrease.selector);
        f.setHunter(1, 499);
        uint256 memberLen = f.memberTraceLength(1);
        f.setHunter(1, 500);
        assertEq(f.memberTraceLength(1), memberLen);

        // Resume needs a paused member; pause needs an eligible one.
        vm.expectRevert(WeightedHistory.StillEligible.selector);
        f.resume(1, BASKET_B);
        vm.warp(302);
        f.pause(1);
        vm.expectRevert(WeightedHistory.NotEligible.selector);
        f.pause(1);
        vm.expectRevert(WeightedHistory.InvalidBasket.selector);
        f.resume(1, address(0));
        f.resume(1, BASKET_B);
        vm.expectRevert(WeightedHistory.StillEligible.selector);
        f.resume(1, BASKET_B);
        _assertMember(f.currentMember(1), BASKET_B, 100, 500, true, true);
        _assertTotals(f.currentGlobal(), 100, 500, 1);
        _assertTotals(f.currentBasket(BASKET_A), 0, 0, 0);
        _assertTotals(f.currentBasket(BASKET_B), 100, 500, 1);

        // A backward timestamp is rejected only when a checkpoint is
        // actually written: an unchanged setHunter returns before appending.
        vm.warp(299);
        f.setHunter(1, 500);
        vm.expectRevert(WeightedHistory.BackwardTimestamp.selector);
        f.setHunter(1, 600);
        vm.expectRevert(WeightedHistory.BackwardTimestamp.selector);
        f.mint(2, BASKET_A, 5);
        vm.expectRevert(WeightedHistory.BackwardTimestamp.selector);
        f.pause(1);
        vm.expectRevert(WeightedHistory.BackwardTimestamp.selector);
        f.burn(1);

        // Forward again: ordinary updates resume normally.
        vm.warp(303);
        f.setHunter(1, 700);
        _assertMember(f.currentMember(1), BASKET_B, 100, 700, true, true);
        _assertTotals(f.currentGlobal(), 100, 700, 1);
        _assertTotals(f.currentBasket(BASKET_B), 100, 700, 1);

        bytes memory arithmeticPanic = abi.encodeWithSignature("Panic(uint256)", 0x11);

        // Checked uint64 global-rarity overflow on the second mint: the
        // member append rolls back with the call, leaving id2 unknown.
        HistoryHarness g = new HistoryHarness();
        vm.warp(400);
        g.mint(1, BASKET_A, type(uint64).max);
        vm.expectRevert(arithmeticPanic);
        g.mint(2, BASKET_A, 1);
        assertEq(g.memberTraceLength(2), 0);
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        g.currentMember(2);
        _assertMember(g.currentMember(1), BASKET_A, type(uint64).max, 0, true, true);
        _assertTotals(g.currentGlobal(), type(uint64).max, 0, 1);
        _assertTotals(g.currentBasket(BASKET_A), type(uint64).max, 0, 1);

        // Checked uint256 global-hunter overflow on the second member's
        // top-up: member checkpoint and totals appends roll back atomically.
        HistoryHarness g2 = new HistoryHarness();
        vm.warp(400);
        g2.mint(1, BASKET_A, 10);
        g2.mint(2, BASKET_A, 20);
        g2.setHunter(1, type(uint256).max);
        uint256 memberLen2 = g2.memberTraceLength(2);
        uint256 globalLen2 = g2.globalTraceLength();
        uint256 basketLen2 = g2.basketTraceLength(BASKET_A);
        vm.expectRevert(arithmeticPanic);
        g2.setHunter(2, 1);
        _assertMember(g2.currentMember(2), BASKET_A, 20, 0, true, true);
        assertEq(g2.memberTraceLength(2), memberLen2);
        assertEq(g2.globalTraceLength(), globalLen2);
        assertEq(g2.basketTraceLength(BASKET_A), basketLen2);
        _assertTotals(g2.currentGlobal(), 30, type(uint256).max, 2);
        _assertTotals(g2.currentBasket(BASKET_A), 30, type(uint256).max, 2);
    }

    /// 256 forward-timestamped top-ups build a 257-entry trace; binary
    /// lookups still return the exact checkpoint strictly before each cutoff
    /// on all three traces. Gas samples are warmed call-region measurements
    /// only — logged, with no fabricated cap or price claim. This fixed
    /// workload is a test of trace depth, not a production history limit.
    function testLongHistoryLookups() public {
        vm.warp(1000);
        h.mint(1, BASKET_A, 7);
        for (uint256 i = 1; i <= 256; i++) {
            vm.warp(1000 + i);
            h.setHunter(1, i * 10);
        }

        assertEq(h.memberTraceLength(1), 257);
        assertEq(h.globalTraceLength(), 257);
        assertEq(h.basketTraceLength(BASKET_A), 257);
        _assertMember(h.currentMember(1), BASKET_A, 7, 2560, true, true);
        _assertTotals(h.currentGlobal(), 7, 2560, 1);
        _assertTotals(h.currentBasket(BASKET_A), 7, 2560, 1);

        // Strict cutoffs return exact midpoints on all three traces.
        _assertMember(h.memberBefore(1, 1000), address(0), 0, 0, false, false);
        _assertMember(h.memberBefore(1, 1001), BASKET_A, 7, 0, true, true);
        _assertMember(h.memberBefore(1, 1065), BASKET_A, 7, 640, true, true);
        _assertMember(h.memberBefore(1, 1129), BASKET_A, 7, 1280, true, true);
        _assertMember(h.memberBefore(1, 1256), BASKET_A, 7, 2550, true, true);
        _assertTotals(h.globalBefore(1000), 0, 0, 0);
        _assertTotals(h.globalBefore(1001), 7, 0, 1);
        _assertTotals(h.globalBefore(1065), 7, 640, 1);
        _assertTotals(h.globalBefore(1129), 7, 1280, 1);
        _assertTotals(h.globalBefore(1256), 7, 2550, 1);
        _assertTotals(h.basketBefore(BASKET_A, 1001), 7, 0, 1);
        _assertTotals(h.basketBefore(BASKET_A, 1065), 7, 640, 1);
        _assertTotals(h.basketBefore(BASKET_A, 1129), 7, 1280, 1);
        _assertTotals(h.basketBefore(BASKET_A, 1256), 7, 2550, 1);

        // Warmed external lookup gas samples — log only, no bound asserted.
        h.memberBefore(1, 1129);
        h.globalBefore(1129);
        h.basketBefore(BASKET_A, 1129);
        uint256 gasBefore = gasleft();
        h.memberBefore(1, 1129);
        emit log_named_uint("memberBefore 257-entry lookup gas", gasBefore - gasleft());
        gasBefore = gasleft();
        h.globalBefore(1129);
        emit log_named_uint("globalBefore 257-entry lookup gas", gasBefore - gasleft());
        gasBefore = gasleft();
        h.basketBefore(BASKET_A, 1129);
        emit log_named_uint("basketBefore 257-entry lookup gas", gasBefore - gasleft());
    }
}

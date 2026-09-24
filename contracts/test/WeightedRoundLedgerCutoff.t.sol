// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";

/// @notice Exact-boundary behaviour of the real WeightedRoundLedger: the
/// strictly-before cutoff at `day * 86_400` freezes the cohort as of the
/// previous timestamp, so a deposit, a burn and a mint landing exactly on
/// the boundary all belong to day 2 — never to the day-1 round recorded in
/// the very same block.
contract WeightedRoundLedgerCutoffTest is LifecycleTestBase {
    /// @notice The day-1 cutoff 86_400 sees A/B/C exactly as of 86_399 and
    /// excludes the same-timestamp extra deposit, B's burn and D's mint;
    /// the day-2 cutoff 172_800 then picks up all three boundary writes.
    function testExactCutoffIsolatesBoundaryWrites() public {
        // Pre-boundary cohort: three ALICE members in basketA, A and B funded.
        vm.warp(86_399);
        uint256[4] memory ids;
        ids[0] = _mint(ALICE, 1, basketA);
        ids[1] = _mint(ALICE, 4, basketA);
        ids[2] = _mint(ALICE, 1, basketA);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(ids[2], 3);
        vm.prank(ALICE);
        assertEq(vault.deposit(ids[0], 100), 100);
        vm.prank(ALICE);
        assertEq(vault.deposit(ids[1], 100), 100);

        WeightedRoundLedger ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);

        // Exactly on the day-1 boundary: A gains 100 more, B burns, D is
        // born into basketB — all invisible to a strictly-before-86_400 read.
        vm.warp(86_400);
        vm.prank(ALICE);
        assertEq(vault.deposit(ids[0], 100), 100);
        vm.prank(ALICE);
        nft.redeemAndDestroy(ids[1]);
        ids[3] = _mint(ALICE, 1, basketB);
        assertEq(ids[3], 4);

        // Recorded in the same block, the round still freezes pre-boundary:
        // 100 + 150 + 100 rarity, A100 + B100 HUNTER, three eligible members.
        bytes32 receipt1 = keccak256("receipt-day-1");
        ledger.recordRound(1, receipt1, 1_000);
        _assertDay1Round(ledger, receipt1, ids);

        // A second ledger recording day 1 one second later freezes the exact
        // same cohort — the cutoff, not the recording time, decides.
        vm.warp(86_401);
        WeightedRoundLedger ledger2 = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        ledger2.recordRound(1, receipt1, 1_000);
        _assertRound(ledger2, 1, 86_400, 350, 200, 3);
        assertEq(ledger2.round(1).receipt, receipt1);
        assertEq(ledger2.round(1).nominalBackingBudget, 500);

        // Day 2 picks up every boundary write: A at H200, B burned out of
        // the eligible cohort, D eligible under basketB.
        vm.warp(172_800);
        bytes32 receipt2 = keccak256("receipt-day-2");
        ledger.recordRound(2, receipt2, 600);
        _assertDay2Round(ledger, receipt2, ids);

        // The live lifecycle history replays the boundary exactly: strictly
        // before 86_400 the pre-write cohort stands, one second later every
        // write is visible, and 172_800 matches the day-2 record.
        _assertLiveHistory(ids);

        // Reserve history is exact too: A's boundary deposit sits in day 2's
        // window, and B's reserve vanishes strictly after the burn.
        _assertReserveHistory(ids);

        // Independent of every frozen record, live state shows B burned: a
        // dead member, a fixed beneficiary and a settled reserve.
        _assertBurnedLiveState(ids);
    }

    function _assertDay1Round(WeightedRoundLedger ledger_, bytes32 receipt_, uint256[4] memory ids_) internal {
        _assertRound(ledger_, 1, 86_400, 350, 200, 3);
        assertEq(ledger_.round(1).rarityNum, 7);
        assertEq(ledger_.round(1).rarityDen, 10);
        assertEq(ledger_.round(1).assertedIncome, 1_000);
        assertEq(ledger_.round(1).nominalBackingBudget, 500);
        assertEq(ledger_.round(1).allocatedBudget, 0);
        assertEq(ledger_.round(1).receipt, receipt_);
        assertEq(ledger_.receiptDay(receipt_), 1);

        _assertMemberEq(ledger_.memberSnapshot(1, ids_[0]), basketA, 100, 100, true, true);
        _assertMemberEq(ledger_.memberSnapshot(1, ids_[1]), basketA, 150, 100, true, true); // alive at the cutoff
        _assertMemberEq(ledger_.memberSnapshot(1, ids_[2]), basketA, 100, 0, true, true);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.MemberNotEligible.selector, uint32(1), ids_[3]));
        ledger_.memberSnapshot(1, ids_[3]);

        ledger_.freezeGroup(1, basketA);
        WeightedRoundLedger.Group memory g1A = _assertGroup(ledger_, 1, basketA, 350, 200, 3);
        assertEq(ledger_.round(1).allocatedBudget, g1A.budget);
        assertEq(ledger_.unallocated(1), 500 - g1A.budget);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.EmptyGroup.selector, uint32(1), basketB));
        ledger_.freezeGroup(1, basketB);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.GroupNotFrozen.selector, uint32(1), basketB));
        ledger_.group(1, basketB);
    }

    function _assertDay2Round(WeightedRoundLedger ledger_, bytes32 receipt_, uint256[4] memory ids_) internal {
        _assertRound(ledger_, 2, 172_800, 300, 200, 3);
        assertEq(ledger_.round(2).assertedIncome, 600);
        assertEq(ledger_.round(2).nominalBackingBudget, 300);
        assertEq(ledger_.receiptDay(receipt_), 2);

        _assertMemberEq(ledger_.memberSnapshot(2, ids_[0]), basketA, 100, 200, true, true);
        _assertMemberEq(ledger_.memberSnapshot(2, ids_[2]), basketA, 100, 0, true, true);
        _assertMemberEq(ledger_.memberSnapshot(2, ids_[3]), basketB, 100, 0, true, true);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.MemberNotEligible.selector, uint32(2), ids_[1]));
        ledger_.memberSnapshot(2, ids_[1]);

        ledger_.freezeGroup(2, basketA);
        WeightedRoundLedger.Group memory g2A = _assertGroup(ledger_, 2, basketA, 200, 200, 2);
        ledger_.freezeGroup(2, basketB);
        WeightedRoundLedger.Group memory g2B = _assertGroup(ledger_, 2, basketB, 100, 0, 1);
        assertEq(ledger_.round(2).allocatedBudget, g2A.budget + g2B.budget);
        assertEq(ledger_.unallocated(2), 300 - g2A.budget - g2B.budget);
    }

    function _assertLiveHistory(uint256[4] memory ids_) internal {
        _assertMemberEq(lc.memberBefore(ids_[0], 86_400), basketA, 100, 100, true, true);
        _assertMemberEq(lc.memberBefore(ids_[1], 86_400), basketA, 150, 100, true, true);
        _assertMemberEq(lc.memberBefore(ids_[2], 86_400), basketA, 100, 0, true, true);
        _assertMemberEq(lc.memberBefore(ids_[3], 86_400), address(0), 0, 0, false, false);
        _assertTotalsEq(lc.globalBefore(86_400), 350, 200, 3);
        _assertTotalsEq(lc.basketBefore(basketB, 86_400), 0, 0, 0);
        _assertMemberEq(lc.memberBefore(ids_[0], 86_401), basketA, 100, 200, true, true);
        _assertMemberEq(lc.memberBefore(ids_[1], 86_401), basketA, 150, 0, false, false);
        _assertMemberEq(lc.memberBefore(ids_[3], 86_401), basketB, 100, 0, true, true);
        _assertTotalsEq(lc.basketBefore(basketB, 86_401), 100, 0, 1);
        _assertMemberEq(lc.memberBefore(ids_[0], 172_800), basketA, 100, 200, true, true);
        _assertMemberEq(lc.memberBefore(ids_[1], 172_800), basketA, 150, 0, false, false);
        _assertMemberEq(lc.memberBefore(ids_[2], 172_800), basketA, 100, 0, true, true);
        _assertMemberEq(lc.memberBefore(ids_[3], 172_800), basketB, 100, 0, true, true);
        _assertTotalsEq(lc.globalBefore(172_800), 300, 200, 3);
        _assertTotalsEq(lc.basketBefore(basketA, 172_800), 200, 200, 2);
        _assertTotalsEq(lc.basketBefore(basketB, 172_800), 100, 0, 1);
    }

    function _assertReserveHistory(uint256[4] memory ids_) internal {
        assertEq(vault.historyLength(ids_[0]), 2);
        (uint256 tsA0, uint256 amtA0) = vault.history(ids_[0], 0);
        assertEq(tsA0, 86_399);
        assertEq(amtA0, 100);
        (uint256 tsA1, uint256 amtA1) = vault.history(ids_[0], 1);
        assertEq(tsA1, 86_400);
        assertEq(amtA1, 200); // checkpoints store the cumulative reserve, not the deposit delta
        assertEq(vault.reserveBefore(ids_[0], 86_400), 100);
        assertEq(vault.reserveBefore(ids_[0], 86_401), 200);
        assertEq(vault.reserveBefore(ids_[1], 86_400), 100);
        assertEq(vault.reserveBefore(ids_[1], 86_401), 0);
    }

    function _assertBurnedLiveState(uint256[4] memory ids_) internal {
        _assertMemberEq(lc.currentMember(ids_[1]), basketA, 150, 0, false, false);
        assertEq(lc.finalBeneficiary(ids_[1]), ALICE);
        assertEq(lc.finalBeneficiary(ids_[0]), address(0));
        assertTrue(vault.settled(ids_[1]));
        assertEq(vault.reserveOf(ids_[1]), 0);
        assertEq(vault.totalReserved(), 200);
        assertEq(token.balanceOf(ALICE), 800); // 1000 - 300 deposited + 100 paid out
    }

    function _assertRound(
        WeightedRoundLedger ledger_,
        uint32 day,
        uint64 cutoff,
        uint64 rarity,
        uint256 hunter,
        uint32 count
    ) internal {
        WeightedRoundLedger.Round memory r = ledger_.round(day);
        assertEq(r.cutoff, cutoff);
        assertEq(r.globalRarity, rarity);
        assertEq(r.globalHunter, hunter);
        assertEq(r.globalCount, count);
    }

    function _assertGroup(
        WeightedRoundLedger ledger_,
        uint32 day,
        address basket,
        uint64 rarity,
        uint256 hunter,
        uint32 count
    ) internal returns (WeightedRoundLedger.Group memory g) {
        g = ledger_.group(day, basket);
        assertEq(g.rarity, rarity);
        assertEq(g.hunter, hunter);
        assertEq(g.count, count);
    }
}

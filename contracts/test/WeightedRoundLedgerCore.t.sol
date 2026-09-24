// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";

/// @notice Core round-recording behavior of WeightedRoundLedger over the REAL
/// lifecycle history wired by LifecycleTestBase: strictly-before-cutoff
/// cohorts, one-shot group freezes and nominal budgets that never track live
/// state. No fake history — every cohort fact comes from actual mints,
/// deposits, sales and burns on the canonical HunterLifecycle triple.
contract WeightedRoundLedgerCoreTest is LifecycleTestBase {
    bytes32 internal constant RECEIPT1 = bytes32(uint256(1));
    bytes32 internal constant RECEIPT2 = bytes32(uint256(2));
    bytes32 internal constant RECEIPT3 = bytes32(uint256(3));

    /// @notice Two ALICE members minted before the day-1 cutoff (tier-1 in
    /// basketA funded 100, tier-4 in basketB funded 300) freeze into round 1.
    /// A later top-up, sale and real burn by the new owner move live state
    /// but leave every recorded field, frozen group and nominal member budget
    /// at the ALICE-era snapshot. Two identical ledgers freeze in opposite
    /// basket orders to the same result — the cutoff, not the freeze order or
    /// late history, decides.
    function testMixedCohortRoundIgnoresLateHistory() public {
        vm.warp(86_400 - 2);
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(ALICE, 4, basketB);
        vm.prank(ALICE);
        assertEq(vault.deposit(idA, 100), 100);
        vm.prank(ALICE);
        assertEq(vault.deposit(idB, 300), 300);

        WeightedRoundLedger ledger1 = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        WeightedRoundLedger ledger2 = new WeightedRoundLedger(address(lc), address(this), 7, 10);

        vm.warp(86_400);
        ledger1.recordRound(1, RECEIPT1, 2_002);
        ledger2.recordRound(1, RECEIPT1, 2_002);
        _assertRound(ledger1.round(1), 86_400, 250, 2, 400, 2_002, 1_001, 0, RECEIPT1);
        _assertRound(ledger2.round(1), 86_400, 250, 2, 400, 2_002, 1_001, 0, RECEIPT1);
        assertEq(ledger1.unallocated(1), 1_001);
        assertEq(ledger2.unallocated(1), 1_001);

        // Late history one second past the cutoff: top-up A, sell B to BOB,
        // then the actual new owner burns B through the real NFT path.
        vm.warp(86_400 + 1);
        vm.prank(ALICE);
        assertEq(vault.deposit(idA, 100), 100);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, idB);
        assertEq(nft.ownerOf(idB), BOB);
        vm.prank(BOB);
        nft.redeemAndDestroy(idB);

        // Live state moved on; the burn's actual reserve payout to BOB is
        // separate existing behavior the ledger never duplicates or assumes.
        assertEq(lc.finalBeneficiary(idB), BOB);
        assertEq(token.balanceOf(BOB), 300);
        assertTrue(vault.settled(idB));
        assertEq(vault.reserveOf(idB), 0);
        assertEq(vault.reserveOf(idA), 200);
        _assertMemberEq(lc.currentMember(idB), basketB, 150, 0, false, false);
        _assertTotalsEq(lc.currentGlobal(), 100, 200, 1);
        vm.expectRevert();
        nft.ownerOf(idB);

        // Permissionless freezes by OP in opposite orders across ledgers.
        vm.startPrank(OP);
        ledger1.freezeGroup(1, basketA);
        ledger1.freezeGroup(1, basketB);
        ledger2.freezeGroup(1, basketB);
        ledger2.freezeGroup(1, basketA);
        vm.stopPrank();

        _assertMixedDay1(ledger1, idA, idB);
        _assertMixedDay1(ledger2, idA, idB);
    }

    /// @notice A recorded round on a fresh lifecycle has a zero cohort: the
    /// full nominal budget stays unallocated and every group freeze reverts
    /// EmptyGroup. An all-rarity (H == 0) cohort on day 2 falls back to
    /// rarity-only shares, and a zero-income day 3 still freezes each group
    /// once with count as the existence flag — past records never move.
    function testEmptyCohortAndRarityOnlyRounds() public {
        WeightedRoundLedger ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);

        // Day 1 before any mint: an empty round is legal and records the
        // whole nominal budget as unallocated.
        vm.warp(86_400);
        ledger.recordRound(1, RECEIPT1, 2_003);
        _assertRound(ledger.round(1), 86_400, 0, 0, 0, 2_003, 1_001, 0, RECEIPT1);
        assertEq(ledger.unallocated(1), 1_001);
        assertEq(ledger.receiptDay(RECEIPT1), 1);

        bytes memory emptyGroup = abi.encodeWithSelector(WeightedRoundLedger.EmptyGroup.selector, uint32(1), basketA);
        vm.expectRevert(emptyGroup);
        ledger.freezeGroup(1, basketA);

        // Day-2 cohort mints after the day-1 cutoff and holds no HUNTER.
        vm.warp(86_400 + 1);
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(ALICE, 4, basketB);

        // The later-minted members were never eligible for recorded day 1.
        bytes memory notEligible =
            abi.encodeWithSelector(WeightedRoundLedger.MemberNotEligible.selector, uint32(1), idA);
        vm.expectRevert(notEligible);
        ledger.memberSnapshot(1, idA);

        // Day 2 at H == 0: the rarity-only fallback splits 1000 as 400/600
        // even though the configured rarity fraction is 7/10.
        vm.warp(172_800);
        ledger.recordRound(2, RECEIPT2, 2_000);
        _assertRound(ledger.round(2), 172_800, 250, 2, 0, 2_000, 1_000, 0, RECEIPT2);
        ledger.freezeGroup(2, basketA);
        ledger.freezeGroup(2, basketB);
        _assertRound(ledger.round(2), 172_800, 250, 2, 0, 2_000, 1_000, 1_000, RECEIPT2);
        _assertGroup(ledger.group(2, basketA), 100, 1, 0, 400);
        _assertGroup(ledger.group(2, basketB), 150, 1, 0, 600);
        assertEq(ledger.unallocated(2), 0);
        _assertMemberEq(ledger.memberSnapshot(2, idA), basketA, 100, 0, true, true);
        _assertMemberEq(ledger.memberSnapshot(2, idB), basketB, 150, 0, true, true);
        assertEq(ledger.memberBudget(2, idA), 400);
        assertEq(ledger.memberBudget(2, idB), 600);

        // Day 3 records zero asserted income: both groups still freeze once
        // each, count stays the existence flag behind a nominal zero budget.
        vm.warp(259_200);
        ledger.recordRound(3, RECEIPT3, 0);
        _assertRound(ledger.round(3), 259_200, 250, 2, 0, 0, 0, 0, RECEIPT3);
        ledger.freezeGroup(3, basketA);
        ledger.freezeGroup(3, basketB);
        _assertGroup(ledger.group(3, basketA), 100, 1, 0, 0);
        _assertGroup(ledger.group(3, basketB), 150, 1, 0, 0);
        assertEq(ledger.unallocated(3), 0);
        assertEq(ledger.memberBudget(3, idA), 0);
        assertEq(ledger.memberBudget(3, idB), 0);

        bytes memory alreadyFrozenA =
            abi.encodeWithSelector(WeightedRoundLedger.GroupAlreadyFrozen.selector, uint32(3), basketA);
        vm.expectRevert(alreadyFrozenA);
        ledger.freezeGroup(3, basketA);
        bytes memory alreadyFrozenB =
            abi.encodeWithSelector(WeightedRoundLedger.GroupAlreadyFrozen.selector, uint32(3), basketB);
        vm.expectRevert(alreadyFrozenB);
        ledger.freezeGroup(3, basketB);

        // Past rounds and groups are untouched by the later days.
        _assertRound(ledger.round(1), 86_400, 0, 0, 0, 2_003, 1_001, 0, RECEIPT1);
        assertEq(ledger.unallocated(1), 1_001);
        _assertRound(ledger.round(2), 172_800, 250, 2, 0, 2_000, 1_000, 1_000, RECEIPT2);
        _assertGroup(ledger.group(2, basketA), 100, 1, 0, 400);
        _assertGroup(ledger.group(2, basketB), 150, 1, 0, 600);
        assertEq(ledger.receiptDay(RECEIPT1), 1);
        assertEq(ledger.receiptDay(RECEIPT2), 2);
        assertEq(ledger.receiptDay(RECEIPT3), 3);
    }

    /// @dev The fully frozen day-1 mixed-cohort record: groups, nominal
    /// member budgets and member snapshots still carry the ALICE-era
    /// pre-cutoff weights, with B alive at the cutoff despite the later burn.
    function _assertMixedDay1(WeightedRoundLedger ledger, uint256 idA, uint256 idB) internal {
        _assertRound(ledger.round(1), 86_400, 250, 2, 400, 2_002, 1_001, 1_000, RECEIPT1);
        _assertGroup(ledger.group(1, basketA), 100, 1, 100, 355);
        _assertGroup(ledger.group(1, basketB), 150, 1, 300, 645);
        assertEq(ledger.unallocated(1), 1);
        assertEq(ledger.receiptDay(RECEIPT1), 1);

        WeightedHistory.Member memory snapA = ledger.memberSnapshot(1, idA);
        WeightedHistory.Member memory snapB = ledger.memberSnapshot(1, idB);
        _assertMemberEq(snapA, basketA, 100, 100, true, true);
        _assertMemberEq(snapB, basketB, 150, 300, true, true);
        assertEq(ledger.memberBudget(1, idA), 355);
        assertEq(ledger.memberBudget(1, idB), 645);
    }

    /// @dev Exact recorded-round fields; the fraction copies are always the
    /// 7/10 deployment configuration used throughout this file.
    function _assertRound(
        WeightedRoundLedger.Round memory r,
        uint64 cutoff,
        uint64 globalRarity,
        uint32 globalCount,
        uint256 globalHunter,
        uint256 assertedIncome,
        uint256 nominalBackingBudget,
        uint256 allocatedBudget,
        bytes32 receipt
    ) internal {
        assertEq(r.cutoff, cutoff);
        assertEq(r.globalRarity, globalRarity);
        assertEq(r.rarityNum, 7);
        assertEq(r.rarityDen, 10);
        assertEq(r.globalCount, globalCount);
        assertEq(r.globalHunter, globalHunter);
        assertEq(r.assertedIncome, assertedIncome);
        assertEq(r.nominalBackingBudget, nominalBackingBudget);
        assertEq(r.allocatedBudget, allocatedBudget);
        assertEq(r.receipt, receipt);
    }

    /// @dev Exact frozen-group fields: rarity/count/hunter are the basket's
    /// eligible totals at the cutoff, budget its nominal share.
    function _assertGroup(
        WeightedRoundLedger.Group memory g,
        uint64 rarity,
        uint32 count,
        uint256 hunter,
        uint256 budget
    ) internal {
        assertEq(g.rarity, rarity);
        assertEq(g.count, count);
        assertEq(g.hunter, hunter);
        assertEq(g.budget, budget);
    }
}

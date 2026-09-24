// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";

/// @notice Malformed-snapshot guards of the real WeightedRoundLedger wired to
/// the canonical lifecycle of LifecycleTestBase. vm.mockCall is used here
/// ONLY to forge corrupted strictly-before responses on the real lifecycle
/// address — a test-harness artifact, never a real exploit path or provider
/// claim. No such snapshot can arise from the canonical writer: WeightedHistory
/// checkpoints are appended solely through authenticated lifecycle hooks,
/// which keep a basket's contribution inside the global totals and a nonzero
/// aggregate behind a nonzero count by construction. These cases therefore
/// exercise defensive validation only: each injected response reverts with the
/// exact guard error before any state write, the failed call leaves no trace,
/// and the cleared-mock retry then records the real, independently known
/// budgets.
contract WeightedRoundLedgerSnapshotsTest is LifecycleTestBase {
    /// @notice Day-1 cohort: ALICE's tier-1 in basketA funded 100 and tier-4
    /// in basketB funded 300, both minted at 86_399 — real cutoff totals
    /// R250 / H400 / count 2 with baskets A 100/100/1 and B 150/300/1. Three
    /// injected snapshots trip the three consistency guards in turn: a
    /// zero-count global behind nonzero HUNTER (InconsistentSnapshot on
    /// record), a subgroup count above the frozen global count
    /// (InconsistentSnapshot on freeze) and a basket equal to the entire
    /// frozen cohort whose 1000 budget would push the 355 already allocated
    /// past the recorded 1000 (AccountingInvariant). Every revert precedes
    /// the writes, so each honest retry lands: receipt1/day1 records budget
    /// 1000 of asserted income 2000, basketA freezes at 355, basketB at 645.
    function testMalformedSnapshotsRollbackAndRetry() public {
        bytes32 receipt1 = bytes32(uint256(1));

        // Real pre-cutoff cohort written at 86_399 by the canonical hooks.
        vm.warp(86_399);
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(ALICE, 4, basketB);
        assertEq(idA, 1);
        assertEq(idB, 2);
        vm.prank(ALICE);
        assertEq(vault.deposit(idA, 100), 100);
        vm.prank(ALICE);
        assertEq(vault.deposit(idB, 300), 300);

        WeightedRoundLedger ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);

        vm.warp(86_400);
        // The independently known real snapshots the mocks below corrupt.
        _assertTotalsEq(lc.globalBefore(86_400), 250, 400, 2);
        _assertTotalsEq(lc.basketBefore(basketA, 86_400), 100, 100, 1);
        _assertTotalsEq(lc.basketBefore(basketB, 86_400), 150, 300, 1);

        // Guard 1: a zero global count behind nonzero HUNTER is malformed —
        // the record reverts before writing the round or binding the receipt.
        _mockGlobalBefore(WeightedHistory.Totals({rarity: 0, hunter: 1, count: 0}));
        vm.expectRevert(WeightedRoundLedger.InconsistentSnapshot.selector);
        ledger.recordRound(1, receipt1, 2_000);
        vm.clearMockedCalls();

        // Nothing was written: day 1 stays unrecorded and receipt1 unused.
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.RoundNotRecorded.selector, uint32(1)));
        ledger.round(1);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.UnknownReceipt.selector, receipt1));
        ledger.receiptDay(receipt1);

        // The same day/receipt retry against the real snapshot records fully.
        ledger.recordRound(1, receipt1, 2_000);
        WeightedRoundLedger.Round memory r = ledger.round(1);
        assertEq(r.cutoff, 86_400);
        assertEq(r.globalRarity, 250);
        assertEq(r.rarityNum, 7);
        assertEq(r.rarityDen, 10);
        assertEq(r.globalCount, 2);
        assertEq(r.globalHunter, 400);
        assertEq(r.assertedIncome, 2_000);
        assertEq(r.nominalBackingBudget, 1_000);
        assertEq(r.allocatedBudget, 0);
        assertEq(r.receipt, receipt1);
        assertEq(ledger.receiptDay(receipt1), 1);
        assertEq(ledger.unallocated(1), 1_000);

        // Guard 2: the basket's real rarity/HUNTER behind a count above the
        // frozen global count is malformed — the freeze reverts before writing
        // the group or touching allocatedBudget.
        _mockBasketBefore(basketA, WeightedHistory.Totals({rarity: 100, hunter: 100, count: 3}));
        vm.expectRevert(WeightedRoundLedger.InconsistentSnapshot.selector);
        ledger.freezeGroup(1, basketA);
        vm.clearMockedCalls();

        // No group record, no allocation: the failed freeze left no trace.
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.GroupNotFrozen.selector, uint32(1), basketA));
        ledger.group(1, basketA);
        assertEq(ledger.round(1).allocatedBudget, 0);

        ledger.freezeGroup(1, basketA);
        WeightedRoundLedger.Group memory gA = ledger.group(1, basketA);
        assertEq(gA.rarity, 100);
        assertEq(gA.count, 1);
        assertEq(gA.hunter, 100);
        assertEq(gA.budget, 355);
        assertEq(ledger.round(1).allocatedBudget, 355);

        // Guard 3: a basket snapshot equal to the entire frozen cohort claims
        // the full 1000 budget, which on top of the 355 already allocated
        // would overrun the recorded budget — AccountingInvariant before any
        // write.
        _mockBasketBefore(basketB, WeightedHistory.Totals({rarity: 250, hunter: 400, count: 2}));
        vm.expectRevert(WeightedRoundLedger.AccountingInvariant.selector);
        ledger.freezeGroup(1, basketB);
        vm.clearMockedCalls();

        assertEq(ledger.round(1).allocatedBudget, 355);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.GroupNotFrozen.selector, uint32(1), basketB));
        ledger.group(1, basketB);

        ledger.freezeGroup(1, basketB);
        WeightedRoundLedger.Group memory gB = ledger.group(1, basketB);
        assertEq(gB.rarity, 150);
        assertEq(gB.count, 1);
        assertEq(gB.hunter, 300);
        assertEq(gB.budget, 645);
        assertEq(ledger.round(1).allocatedBudget, 1_000);
        assertEq(ledger.unallocated(1), 0);
    }

    /// @dev TEST-ONLY corrupted `globalBefore(86_400)` response on the real
    /// lifecycle address: `abi.encode` of the exact WeightedHistory.Totals
    /// struct, matching the canonical return encoding. Such a response cannot
    /// be produced by the real history writer; it exists only to reach the
    /// ledger's defensive guard.
    function _mockGlobalBefore(WeightedHistory.Totals memory t) internal {
        vm.mockCall(
            address(lc),
            abi.encodeWithSelector(bytes4(keccak256("globalBefore(uint256)")), uint256(86_400)),
            abi.encode(t)
        );
    }

    /// @dev TEST-ONLY corrupted `basketBefore(basket, 86_400)` response; same
    /// real-struct encoding the canonical lifecycle would return.
    function _mockBasketBefore(address basket, WeightedHistory.Totals memory t) internal {
        vm.mockCall(
            address(lc),
            abi.encodeWithSelector(bytes4(keccak256("basketBefore(address,uint256)")), basket, uint256(86_400)),
            abi.encode(t)
        );
    }
}

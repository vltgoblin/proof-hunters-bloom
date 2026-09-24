// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";

/// @notice Wide-integer end-to-end nominal-budget round on the REAL lifecycle
/// wiring: ~2^240 HUNTER reserves and a `type(uint256).max` recorder-asserted
/// income. The expected budgets below are independent exact constants
/// (computed offline with Python integers/Fractions), never outputs of the
/// implementation's own math.
contract WeightedRoundLedgerWideTest is LifecycleTestBase {
    bytes32 internal constant RECEIPT = bytes32(uint256(1));
    uint256 internal constant H_A = uint256(1) << 240;
    uint256 internal constant H_B = uint256(2) << 240;
    uint256 internal constant BUDGET_A = 22000496955090077130478487151650702492121297086471707167496940961503494631587;
    uint256 internal constant BUDGET_B = 35895547663568020581307005352693251434513695246348574852231851042453070188379;

    /// @notice Two one-NFT baskets frozen one second before the day-1 cutoff
    /// share the nominal `max/2` budget floor-wise at 19/50 : 31/50 (total
    /// rarity 250, total HUNTER 3 << 240), leaving a residual of exactly 1.
    /// Recording and freezing move no value: reserves, deposit history and
    /// member state are untouched by the ledger.
    function testWideNominalBudgetRecordedExactly() public {
        vm.warp(86_399);
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(ALICE, 4, basketB);
        token.mint(ALICE, 3 * (uint256(1) << 240)); // on top of the 1_000 setUp mint; fits uint256

        vm.prank(ALICE);
        assertEq(vault.deposit(idA, H_A), H_A);
        vm.prank(ALICE);
        assertEq(vault.deposit(idB, H_B), H_B);
        assertEq(token.balanceOf(ALICE), 1_000);

        WeightedRoundLedger ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        vm.warp(86_400);
        ledger.recordRound(1, RECEIPT, type(uint256).max);
        ledger.freezeGroup(1, basketA);
        ledger.freezeGroup(1, basketB);

        _assertWideRound(ledger);
        _assertWideGroup(ledger, basketA, 100, H_A, BUDGET_A);
        _assertWideGroup(ledger, basketB, 150, H_B, BUDGET_B);
        _assertWideMembers(ledger, idA, idB);
        _assertWideStateUntouched(idA, idB);
    }

    function _assertWideRound(WeightedRoundLedger ledger) internal {
        WeightedRoundLedger.Round memory r = ledger.round(1);
        assertEq(uint256(r.cutoff), 86_400);
        assertEq(uint256(r.globalRarity), 250);
        assertEq(uint256(r.rarityNum), 7);
        assertEq(uint256(r.rarityDen), 10);
        assertEq(uint256(r.globalCount), 2);
        assertEq(r.globalHunter, H_A + H_B); // 3 << 240, exact
        assertEq(r.assertedIncome, type(uint256).max);
        assertEq(r.nominalBackingBudget, type(uint256).max / 2);
        assertEq(r.allocatedBudget, BUDGET_A + BUDGET_B);
        assertEq(r.receipt, RECEIPT);
        assertEq(uint256(ledger.receiptDay(RECEIPT)), 1);
        assertEq(ledger.unallocated(1), 1); // independent residual constant
        assertEq(r.allocatedBudget + ledger.unallocated(1), r.nominalBackingBudget);
    }

    function _assertWideGroup(
        WeightedRoundLedger ledger,
        address basket,
        uint256 rarity,
        uint256 hunter,
        uint256 budget
    ) internal {
        WeightedRoundLedger.Group memory g = ledger.group(1, basket);
        assertEq(uint256(g.rarity), rarity);
        assertEq(uint256(g.count), 1);
        assertEq(g.hunter, hunter); // stored H exact, never narrowed
        assertEq(g.budget, budget);
    }

    function _assertWideMembers(WeightedRoundLedger ledger, uint256 idA, uint256 idB) internal {
        // One NFT per group: the member's nominal budget equals the frozen
        // basket budget exactly.
        assertEq(ledger.memberBudget(1, idA), BUDGET_A);
        assertEq(ledger.memberBudget(1, idB), BUDGET_B);
        _assertMemberEq(ledger.memberSnapshot(1, idA), basketA, 100, H_A, true, true);
        _assertMemberEq(ledger.memberSnapshot(1, idB), basketB, 150, H_B, true, true);
    }

    function _assertWideStateUntouched(uint256 idA, uint256 idB) internal {
        _assertMemberEq(lc.currentMember(idA), basketA, 100, H_A, true, true);
        _assertMemberEq(lc.currentMember(idB), basketB, 150, H_B, true, true);
        _assertTotalsEq(lc.currentGlobal(), 250, H_A + H_B, 2);
        _assertTotalsEq(lc.currentBasket(basketA), 100, H_A, 1);
        _assertTotalsEq(lc.currentBasket(basketB), 150, H_B, 1);
        assertEq(vault.reserveOf(idA), H_A);
        assertEq(vault.reserveOf(idB), H_B);
        assertEq(vault.totalReserved(), H_A + H_B);
        assertEq(vault.historyLength(idA), 1);
        assertEq(vault.historyLength(idB), 1);
        (uint256 tsA, uint256 amountA) = vault.history(idA, 0);
        assertEq(tsA, 86_399);
        assertEq(amountA, H_A);
        (uint256 tsB, uint256 amountB) = vault.history(idB, 0);
        assertEq(tsB, 86_399);
        assertEq(amountB, H_B);
    }
}

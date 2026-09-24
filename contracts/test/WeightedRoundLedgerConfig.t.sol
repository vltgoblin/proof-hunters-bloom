// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {WeightedRewardMath} from "../specs/hunter-bloom/src/WeightedRewardMath.sol";

/// @notice Constructor validation plus the two rarity-fraction endpoint
/// configurations (0/den all-HUNTER, den/den all-rarity) recorded over one
/// shared real cohort on the actual lifecycle wiring.
contract WeightedRoundLedgerConfigTest is LifecycleTestBase {
    /// @notice The constructor rejects a zero lifecycle, a zero recorder, an
    /// identical lifecycle/recorder pair and a codeless lifecycle with
    /// InvalidConfiguration, and a zero denominator or a numerator above the
    /// denominator with the shared WeightedRewardMath.InvalidFraction.
    function testConstructorRejectsBadConfigAndFraction() public {
        _ctorRevert(address(0), address(this), 5, 10, WeightedRoundLedger.InvalidConfiguration.selector);
        _ctorRevert(address(lc), address(0), 5, 10, WeightedRoundLedger.InvalidConfiguration.selector);
        _ctorRevert(address(lc), address(lc), 5, 10, WeightedRoundLedger.InvalidConfiguration.selector);
        _ctorRevert(ALICE, address(this), 5, 10, WeightedRoundLedger.InvalidConfiguration.selector); // EOA lifecycle
        _ctorRevert(address(lc), address(this), 0, 0, WeightedRewardMath.InvalidFraction.selector);
        _ctorRevert(address(lc), address(this), 11, 10, WeightedRewardMath.InvalidFraction.selector);
    }

    /// @notice The two fraction endpoints freeze the same real cohort
    /// differently: all-HUNTER pays only B's reserve (A still records a
    /// zero-budget freeze that cannot repeat), all-rarity splits 400/600 on
    /// rarity alone despite B holding every HUNTER. Both ledgers keep the
    /// same frozen globals, fully allocate, and expose their constructor
    /// configuration through the immutable getters.
    function testFractionEndpointsOverSharedCohort() public {
        // Cohort completes strictly before the day-1 cutoff: A tier1 and B
        // tier4, both ALICE; only B carries 100 HUNTER.
        vm.warp(86_399);
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(ALICE, 4, basketB);
        vm.prank(ALICE);
        vault.deposit(idB, 100);

        WeightedRoundLedger hunterL = new WeightedRoundLedger(address(lc), address(this), 0, 10);
        WeightedRoundLedger rarityL = new WeightedRoundLedger(address(lc), address(this), 10, 10);

        vm.warp(86_400);
        hunterL.recordRound(1, bytes32(uint256(1)), 2_000); // budget 1_000
        rarityL.recordRound(1, bytes32(uint256(2)), 2_000);
        _freezeBoth(hunterL);
        _freezeBoth(rarityL);

        // All-HUNTER endpoint: only B's reserve counts. A's zero-budget freeze
        // is still recorded — the count sentinel — and cannot repeat.
        _assertGroup(hunterL, basketA, 100, 0, 0);
        _assertGroup(hunterL, basketB, 150, 100, 1_000);
        assertEq(hunterL.memberBudget(1, idA), 0);
        assertEq(hunterL.memberBudget(1, idB), 1_000);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.GroupAlreadyFrozen.selector, uint32(1), basketA));
        hunterL.freezeGroup(1, basketA);

        // All-rarity endpoint: rarity alone splits 400/600 even though B holds
        // every HUNTER.
        _assertGroup(rarityL, basketA, 100, 0, 400);
        _assertGroup(rarityL, basketB, 150, 100, 600);
        assertEq(rarityL.memberBudget(1, idA), 400);
        assertEq(rarityL.memberBudget(1, idB), 600);

        // Both ledgers froze identical globals, fully allocated the budget,
        // and kept their constructor configuration.
        _assertRound(hunterL, 0, 10);
        _assertRound(rarityL, 10, 10);
    }

    function _ctorRevert(address lifecycle_, address recorder_, uint32 num, uint32 den, bytes4 err) internal {
        vm.expectRevert(err);
        new WeightedRoundLedger(lifecycle_, recorder_, num, den);
    }

    function _freezeBoth(WeightedRoundLedger l) internal {
        l.freezeGroup(1, basketA);
        l.freezeGroup(1, basketB);
    }

    function _assertGroup(WeightedRoundLedger l, address basket, uint64 rarity, uint256 hunter, uint256 budget)
        internal
        view
    {
        WeightedRoundLedger.Group memory g = l.group(1, basket);
        assertEq(g.rarity, rarity);
        assertEq(g.hunter, hunter);
        assertEq(g.count, 1);
        assertEq(g.budget, budget);
    }

    function _assertRound(WeightedRoundLedger l, uint32 num, uint32 den) internal view {
        WeightedRoundLedger.Round memory r = l.round(1);
        assertEq(r.cutoff, 86_400);
        assertEq(r.assertedIncome, 2_000);
        assertEq(r.nominalBackingBudget, 1_000);
        assertEq(r.allocatedBudget, 1_000);
        assertEq(r.globalRarity, 250);
        assertEq(r.globalHunter, 100);
        assertEq(r.globalCount, 2);
        assertEq(r.rarityNum, num);
        assertEq(r.rarityDen, den);
        assertEq(l.unallocated(1), 0);
        assertEq(address(l.lifecycle()), address(lc));
        assertEq(l.recorder(), address(this));
        assertEq(l.rarityNum(), num);
        assertEq(l.rarityDen(), den);
    }
}

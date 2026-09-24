// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {MaterialisationHarness} from "./WeightedRoundMaterialisationCore.t.sol";
import {WeightedRoundMaterialisation} from "../src/bloom/WeightedRoundMaterialisation.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

contract WeightedRoundMaterialisationBurnTest is LifecycleTestBase {
    WeightedRoundLedger internal ledger;
    MaterialisationHarness internal harness;

    /// @notice A zero-income round still consumes its `(day, tokenId)` share
    /// exactly once — replay reverts `AlreadyConsumed` despite 0 units. A
    /// real NFT burn afterwards fixes the beneficiary but moves NO basket
    /// asset: materialised backing stays stored on the burned id, an
    /// unconsumed share of a burned id is NOT consumed or released (it stays
    /// reserved for the future fixed-beneficiary claim leg), and a
    /// materialise attempt on the burned id reverts `NotLive`. Conservation
    /// still holds: materialised-burned backing + unconsumed-burned share +
    /// floor dust == totalReceived, with `totalReleased` unmoved — this
    /// slice claims no burn-time basket release.
    function testZeroShareConsumptionAndBurnAccounting() public {
        // H0: both members mint alive+eligible into basketA with hunter == 0.
        vm.warp(86_399);
        uint256 idA = _mint(ALICE, 1, basketA); // rarity 100
        uint256 idB = _mint(ALICE, 4, basketA); // rarity 150

        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        harness = new MaterialisationHarness(address(ledger), address(this));

        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(harness)); // custody is the taxed inbound sink
        asset.mint(address(this), 1_000);
        asset.approve(address(harness), type(uint256).max);
        asset.transfer(address(harness), 50); // direct donation, credited nowhere

        // Day 1: freeze the real basketA cohort at cutoff 86400, fund 101
        // units, then materialise A's share into stored backing.
        vm.warp(86_400);
        _recordFreezeFund(1, keccak256("receipt-day-1"), 2_000, 101);
        harness.materialise(1, idA);
        assertEq(harness.backingOf(idA), 40); // floor(101 * 100/250)
        assertTrue(harness.consumed(1, idA));

        // Day 2: zero-income round finalises received == 0; A's zero-unit
        // share still consumes the one-shot flag while backing is unchanged.
        vm.warp(172_800);
        _recordFreezeFund(2, keccak256("receipt-day-2"), 0, 0);
        harness.materialise(2, idA);
        assertEq(harness.backingOf(idA), 40); // zero share credits nothing
        assertTrue(harness.consumed(2, idA));

        vm.expectRevert(abi.encodeWithSelector(WeightedRoundMaterialisation.AlreadyConsumed.selector, uint32(2), idA));
        harness.materialise(2, idA); // consumed is a fact, not an amount

        // Sale then real burn via the NFT: BOB becomes the fixed
        // beneficiary, yet no basket leg exists — A's 40 materialised units
        // remain reserved backing and both consumed flags stay set.
        vm.warp(172_801);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, idA);
        vm.prank(BOB);
        nft.redeemAndDestroy(idA);
        assertEq(lc.finalBeneficiary(idA), BOB);
        assertEq(harness.backingOf(idA), 40);
        assertTrue(harness.consumed(1, idA));
        assertTrue(harness.consumed(2, idA));

        // ALICE burns B while its day-1 share is still unconsumed: the burn
        // neither consumes nor releases that share, and materialise now
        // reverts `NotLive` on the destroyed token.
        vm.prank(ALICE);
        nft.redeemAndDestroy(idB);
        assertEq(lc.finalBeneficiary(idB), ALICE);

        vm.expectRevert(abi.encodeWithSelector(WeightedRoundMaterialisation.NotLive.selector, idB));
        harness.materialise(1, idB);
        assertFalse(harness.consumed(1, idB));
        assertEq(harness.backingOf(idB), 0);
        {
            (address basket, uint256 shareB) = harness.memberReceivedShare(1, idB);
            assertEq(basket, basketA);
            assertEq(shareB, 60); // frozen share survives the burn untouched
            uint256 dust = 101 - 40 - shareB;
            assertEq(dust, 1); // floor residue stays reserved in custody
            // Conservation over the burned cohort: A's materialised backing
            // + B's reserved unconsumed share + dust == received.
            assertEq(harness.backingOf(idA) + shareB + dust, 101);
        }

        // The burns moved NO basket asset: no release leg ran, the fixed
        // beneficiaries received nothing, and custody still holds the funded
        // units plus the uncredited donation.
        assertEq(harness.totalReceived(basketA), 101);
        assertEq(harness.totalReleased(basketA), 0);
        assertEq(asset.balanceOf(address(harness)), 151);
        assertEq(asset.balanceOf(BOB), 0);
        assertEq(asset.balanceOf(ALICE), 0);
        assertEq(harness.unaccountedBalance(basketA), 50);
    }

    /// @dev Record the round, freeze the basketA cohort and finalise funding
    /// for one day in one shot; `requested == 0` is the zero-budget path.
    function _recordFreezeFund(uint32 day, bytes32 receipt, uint256 assertedIncome, uint256 requested) private {
        ledger.recordRound(day, receipt, assertedIncome);
        ledger.freezeGroup(day, basketA);
        harness.fund(day, basketA, requested);
    }
}

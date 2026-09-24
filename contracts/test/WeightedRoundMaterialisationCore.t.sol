// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {WeightedRoundMaterialisation} from "../src/bloom/WeightedRoundMaterialisation.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @notice TEST-ONLY concrete instance of the abstract
/// `WeightedRoundMaterialisation` base so the suite can exercise the
/// candidate. Constructor forwarding only: adds NO release, withdrawal,
/// mutation or admin surface beyond the base — a codegen/test fixture for
/// the abstract contract, not a launch artifact.
contract MaterialisationHarness is WeightedRoundMaterialisation {
    constructor(address ledger_, address funder_) WeightedRoundMaterialisation(ledger_, funder_) {}
}

contract WeightedRoundMaterialisationCoreTest is LifecycleTestBase {
    WeightedRoundLedger internal ledger;
    MaterialisationHarness internal harness;

    /// @notice A permissionless materialise consumes the funded
    /// `(day, tokenId)` share exactly once and relabels its frozen received
    /// units as stored backing — effects only, no token leg. The duplicate
    /// call reverts `AlreadyConsumed`, and the outstanding liability stays
    /// conserved: unconsumed share + backing + floor residue == received.
    /// No release leg exists, so `totalReleased` never moves.
    function testMaterialiseCreditsBackingOnceAndConserves() public {
        // H0: both members mint alive+eligible into basketA with hunter == 0.
        vm.warp(86_399);
        uint256 idA = _mint(ALICE, 1, basketA); // rarity 100
        uint256 idB = _mint(ALICE, 4, basketA); // rarity 150

        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        harness = new MaterialisationHarness(address(ledger), address(this));
        assertEq(address(harness.lifecycle()), address(lc));
        assertEq(address(harness.nft()), address(nft));

        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(harness)); // custody is the taxed inbound sink
        asset.mint(address(this), 1_000);
        asset.approve(address(harness), type(uint256).max);
        asset.transfer(address(harness), 50); // direct donation, credited nowhere

        // Day 1: freeze the real basketA cohort at cutoff 86400 (mints at
        // 86399 are strictly before), then fund 101 untaxed units.
        vm.warp(86_400);
        ledger.recordRound(1, keccak256("receipt-day-1"), 2_000);
        ledger.freezeGroup(1, basketA);
        harness.fund(1, basketA, 101);

        vm.prank(OP); // permissionless caller; credit accrues to tokenId only
        harness.materialise(1, idA);
        assertEq(harness.backingOf(idA), 40); // floor(101 * 100/250)
        assertTrue(harness.consumed(1, idA));
        assertFalse(harness.consumed(1, idB));

        vm.prank(OP);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundMaterialisation.AlreadyConsumed.selector, uint32(1), idA));
        harness.materialise(1, idA);

        assertEq(harness.totalReceived(basketA), 101); // materialise moves no tokens
        assertEq(harness.totalReleased(basketA), 0); // no release leg exists
        assertEq(asset.balanceOf(address(harness)), 151);
        assertEq(harness.unaccountedBalance(basketA), 50);
        {
            (address basket, uint256 shareB) = harness.memberReceivedShare(1, idB);
            assertEq(basket, basketA);
            assertEq(shareB, 60); // floor(101 * 150/250), still unconsumed
            uint256 dust = 101 - 40 - shareB;
            assertEq(dust, 1); // floor residue stays reserved in custody
            // Conservation: funded unconsumed share + backing + dust == received.
            assertEq(shareB + harness.backingOf(idA) + dust, 101);
        }
    }
}

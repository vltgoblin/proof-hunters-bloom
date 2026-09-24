// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @notice TEST-ONLY concrete instance of the abstract `WeightedRoundFunding`
/// base so the suite can exercise the candidate. Constructor forwarding only:
/// adds NO release, withdrawal, mutation or admin surface beyond the base —
/// a codegen/test fixture for the abstract contract, not a launch artifact.
contract FundingHarness is WeightedRoundFunding {
    constructor(address ledger_, address funder_) WeightedRoundFunding(ledger_, funder_) {}
}

contract WeightedRoundFundingCoreTest is LifecycleTestBase {
    WeightedRoundLedger internal ledger;
    FundingHarness internal funding;

    /// @notice One-shot pull funding over two real frozen rounds of the same
    /// basket asset: the measured delta (including an inbound tax) is the
    /// credited custody, per-member shares are pure functions of the frozen
    /// snapshots and stay immutable across a later sale + burn, and a direct
    /// donation never overcredits. Expected constants are computed
    /// independently from the frozen H0 cohort — rarity-only weights
    /// 100/250 = 2/5 and 150/250 = 3/5 — no fake history source.
    function testFundAcrossDaysKeepsFrozenSharesAndCustody() public {
        // H0: both members mint alive+eligible into basketA with hunter == 0.
        vm.warp(86_399);
        uint256 idA = _mint(ALICE, 1, basketA); // rarity 100
        uint256 idB = _mint(ALICE, 4, basketA); // rarity 150

        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        funding = new FundingHarness(address(ledger), address(this));

        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(funding)); // funding is the taxed inbound sink
        asset.mint(address(this), 1_000);
        asset.approve(address(funding), type(uint256).max);
        asset.transfer(address(funding), 50); // direct donation, taxBps still 0
        _assertCustody(0, 50, 50);

        // Day 1: freeze the real basketA cohort at cutoff 86400 (mints at
        // 86399 are strictly before), then fund 101 untaxed units.
        vm.warp(86_400);
        ledger.recordRound(1, keccak256("receipt-day-1"), 2_000);
        ledger.freezeGroup(1, basketA);
        {
            WeightedRoundLedger.Round memory r = ledger.round(1);
            assertEq(r.nominalBackingBudget, 1_000);
            WeightedRoundLedger.Group memory g = ledger.group(1, basketA);
            assertEq(g.count, 2);
            assertEq(g.rarity, 250);
            assertEq(g.hunter, 0);
            assertEq(g.budget, 1_000); // sole membered basket takes the full budget
        }
        funding.fund(1, basketA, 101);
        {
            WeightedRoundFunding.Funding memory f = funding.funding(1, basketA);
            assertTrue(f.finalised);
            assertEq(f.received, 101);
        }
        _assertCustody(101, 151, 50);
        {
            uint256 shareA1 = _shareUnits(1, idA);
            uint256 shareB1 = _shareUnits(1, idB);
            assertEq(shareA1, 40); // floor(101 * 2/5)
            assertEq(shareB1, 60); // floor(101 * 3/5)
            assertEq(101 - shareA1 - shareB1, 1); // floor residue stays in custody
        }

        // Day 2: same basket, same frozen cohort (no history between the
        // cutoffs). A 10% inbound tax measures 90 received of 100 requested.
        vm.warp(172_800);
        ledger.recordRound(2, keccak256("receipt-day-2"), 2_000);
        ledger.freezeGroup(2, basketA);
        asset.setBehavior(1_000, false, false, false);
        funding.fund(2, basketA, 100);
        {
            WeightedRoundFunding.Funding memory f = funding.funding(2, basketA);
            assertTrue(f.finalised);
            assertEq(f.received, 90);
        }
        _assertCustody(191, 241, 50); // cumulative per asset, counted once per day
        assertEq(asset.balanceOf(address(this)), 749);
        {
            uint256 shareA2 = _shareUnits(2, idA);
            uint256 shareB2 = _shareUnits(2, idB);
            assertEq(shareA2, 36); // floor(90 * 2/5)
            assertEq(shareB2, 54); // floor(90 * 3/5)
            assertEq(shareA2 + shareB2, 90);
        }
        assertEq(_shareUnits(1, idA), 40); // day-1 shares immutable
        assertEq(_shareUnits(1, idB), 60);
        assertEq(funding.totalReceived(basketB), 0); // other basket untouched

        // A later sale plus real burn of idB cannot move frozen shares: the
        // snapshots are strictly-before-cutoff and this base records custody
        // only — the funder's position and the fixed beneficiary part ways.
        vm.warp(172_801);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, idB);
        vm.prank(BOB);
        nft.redeemAndDestroy(idB);
        assertEq(lc.finalBeneficiary(idB), BOB);
        assertEq(_shareUnits(1, idB), 60);
        assertEq(_shareUnits(2, idB), 54);
        assertEq(_shareUnits(1, idA), 40);
        _assertCustody(191, 241, 50); // custody unchanged, still no payout leg

        assertTrue(funding.isFunded(1, basketA));
        assertTrue(funding.isFunded(2, basketA));
        assertEq(funding.funding(1, basketA).received, 101);
        assertEq(funding.funding(2, basketA).received, 90);
        assertEq(funding.totalReleased(basketA), 0);
    }

    /// @dev Resolved frozen-share units of `tokenId` in round `day`, also
    /// asserting the returned basket is basketA.
    function _shareUnits(uint32 day, uint256 tokenId) internal view returns (uint256 units) {
        address basket;
        (basket, units) = funding.memberReceivedShare(day, tokenId);
        assertEq(basket, basketA);
    }

    /// @dev Per-asset custody triple for basketA: cumulative measured
    /// receipts, live balance and the never-credited donation excess, with
    /// the always-zero released counter.
    function _assertCustody(uint256 received, uint256 balance, uint256 unaccounted) internal view {
        assertEq(funding.totalReceived(basketA), received);
        assertEq(ReserveTokenFixture(basketA).balanceOf(address(funding)), balance);
        assertEq(funding.unaccountedBalance(basketA), unaccounted);
        assertEq(funding.totalReleased(basketA), 0);
    }
}

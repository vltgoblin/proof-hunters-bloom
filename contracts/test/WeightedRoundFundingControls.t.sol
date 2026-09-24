// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {FundingHarness} from "./WeightedRoundFundingCore.t.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @notice Guard-ordering and one-shot semantics of `WeightedRoundFunding.fund`
/// over a single-member basketA cohort on the REAL lifecycle history. Every
/// failed call — wrong funder, bad amount for the frozen budget, a fully
/// fee-eaten receipt, a reverting inbound transfer — aborts atomically with
/// the precise error and leaves the group unfunded, retryable and with token
/// balances untouched; the zero-budget path finalises with no token call at
/// all. Callback, false-return and fresh-fixture receipts are exercised in a
/// separate file, not here.
contract WeightedRoundFundingControlsTest is LifecycleTestBase {
    WeightedRoundLedger internal ledger;
    FundingHarness internal funding;

    /// @notice Day 1 (positive income, budget 1000): `UnauthorizedFunder`
    /// precedes every other check, `InvalidAmount` guards both directions of
    /// the requested-vs-budget contract, `UnsupportedTokenReceipt` and the
    /// token's own `InboundBlocked` roll back the whole pull, and the one-shot
    /// `GroupAlreadyFunded` seal keeps the frozen share at 100. Day 2 (zero
    /// income, budget 0): `requested == 0` finalises `received == 0` while the
    /// token is configured to revert on ANY transfer — inbound-blocked and
    /// zero-value-forbidden — proving the path never touches the token.
    function testFundGuardsPreserveStateAndOneShotSeal() public {
        // H0: a single ALICE tier-1 mint into basketA before the day-1 cutoff.
        vm.warp(86_399);
        uint256 idA = _mint(ALICE, 1, basketA); // rarity 100

        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        funding = new FundingHarness(address(ledger), address(this));

        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(funding)); // funding is the gated inbound sink
        asset.mint(address(this), 1_000);
        asset.approve(address(funding), type(uint256).max);

        // Day 1: sole-member basket takes the full nominal budget of 1000.
        vm.warp(86_400);
        ledger.recordRound(1, keccak256("receipt-day-1"), 2_000);
        ledger.freezeGroup(1, basketA);
        assertEq(ledger.group(1, basketA).budget, 1_000);

        // An otherwise-valid call from a non-funder never reaches the checks.
        vm.prank(OP);
        vm.expectRevert(WeightedRoundFunding.UnauthorizedFunder.selector);
        funding.fund(1, basketA, 100);
        _assertUnfunded(1, 0, 0, 1_000);

        // A positive-budget group can never finalise to zero.
        vm.expectRevert(WeightedRoundFunding.InvalidAmount.selector);
        funding.fund(1, basketA, 0);
        _assertUnfunded(1, 0, 0, 1_000);

        // A 100% inbound tax measures received == 0: the explicit
        // unsupported-receipt check fires and the pull rolls back atomically.
        asset.setBehavior(10_000, false, false, false);
        vm.expectRevert(WeightedRoundFunding.UnsupportedTokenReceipt.selector);
        funding.fund(1, basketA, 100);
        _assertUnfunded(1, 0, 0, 1_000);

        // A reverting inbound transfer surfaces the token's own error
        // unchanged and leaves the group retryable.
        asset.setBehavior(0, true, false, false);
        vm.expectRevert(ReserveTokenFixture.InboundBlocked.selector);
        funding.fund(1, basketA, 100);
        _assertUnfunded(1, 0, 0, 1_000);

        // Behaviour reset: the identical call funds the group once.
        asset.setBehavior(0, false, false, false);
        funding.fund(1, basketA, 100);
        {
            WeightedRoundFunding.Funding memory f = funding.funding(1, basketA);
            assertTrue(f.finalised);
            assertEq(f.received, 100);
        }
        _assertCustody(100, 100, 900);

        // One-shot seal: a second fund of the same (day, basket) reverts
        // before any token call and the frozen share stays 100.
        bytes memory alreadyFunded1 =
            abi.encodeWithSelector(WeightedRoundFunding.GroupAlreadyFunded.selector, uint32(1), basketA);
        vm.expectRevert(alreadyFunded1);
        funding.fund(1, basketA, 100);
        _assertCustody(100, 100, 900);
        assertEq(_shareUnits(1, idA), 100); // sole member, rarity-only weights

        // Day 2: zero asserted income freezes a zero-budget group.
        vm.warp(172_800);
        ledger.recordRound(2, keccak256("receipt-day-2"), 0);
        ledger.freezeGroup(2, basketA);
        assertEq(ledger.group(2, basketA).budget, 0);

        // A zero-budget group accepts requested == 0 only.
        vm.expectRevert(WeightedRoundFunding.InvalidAmount.selector);
        funding.fund(2, basketA, 1);
        _assertUnfunded(2, 100, 100, 900);

        // With inbound transfers blocked AND zero-value transfers forbidden,
        // any token call would revert — the transferless zero-budget path is
        // the only way this can finalise.
        asset.setBehavior(0, true, false, true);
        funding.fund(2, basketA, 0);
        {
            WeightedRoundFunding.Funding memory f = funding.funding(2, basketA);
            assertTrue(f.finalised);
            assertEq(f.received, 0);
        }
        bytes memory alreadyFunded2 =
            abi.encodeWithSelector(WeightedRoundFunding.GroupAlreadyFunded.selector, uint32(2), basketA);
        vm.expectRevert(alreadyFunded2);
        funding.fund(2, basketA, 0);

        // Cumulative custody is untouched by the zero path and every revert.
        _assertCustody(100, 100, 900);
        assertEq(_shareUnits(2, idA), 0);
    }

    /// @dev The `(day, basketA)` record is unfinalised and cumulative custody
    /// sits at the expected state: `received`/`fundingBal`/`funderBal` triple.
    function _assertUnfunded(uint32 day, uint256 received, uint256 fundingBal, uint256 funderBal) internal view {
        assertFalse(funding.isFunded(day, basketA));
        _assertCustody(received, fundingBal, funderBal);
    }

    /// @dev Per-asset custody triple for basketA: cumulative measured
    /// receipts, live funding-contract balance and this funder's balance,
    /// with the always-zero released counter.
    function _assertCustody(uint256 received, uint256 fundingBal, uint256 funderBal) internal view {
        assertEq(funding.totalReceived(basketA), received);
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        assertEq(asset.balanceOf(address(funding)), fundingBal);
        assertEq(asset.balanceOf(address(this)), funderBal);
        assertEq(funding.totalReleased(basketA), 0);
    }

    /// @dev Resolved frozen-share units of `tokenId` in round `day`, also
    /// asserting the returned basket is basketA.
    function _shareUnits(uint32 day, uint256 tokenId) internal view returns (uint256 units) {
        address basket;
        (basket, units) = funding.memberReceivedShare(day, tokenId);
        assertEq(basket, basketA);
    }
}

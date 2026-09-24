// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {MaterialisationHarness} from "./WeightedRoundMaterialisationCore.t.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";
import {WeightedRoundMaterialisation} from "../src/bloom/WeightedRoundMaterialisation.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @notice Operational wiring proof of `materialise` on the REAL canonical
/// triple of LifecycleTestBase. vm.mockCall and vm.etch are used here ONLY
/// to forge corrupted or absent responses on the real NFT address — a
/// test-harness artifact that reaches the defensive `_custodyWired` and
/// `basketOf` tripwires, never a real exploit path, a fake NFT source, or a
/// basket-switch implementation. The canonical binding itself is produced
/// by the ledger's own getters, exactly as in production.
contract WeightedRoundMaterialisationWiringTest is LifecycleTestBase {
    WeightedRoundLedger internal ledger;
    MaterialisationHarness internal harness;

    /// @notice One real mint (ALICE tier-1 into basketA at 86_399) drives the
    /// whole gate chain at the 86_400 day-1 cutoff. Recorded and frozen but
    /// UNFUNDED, materialise reverts the exact FundingNotFinalized(1,
    /// basketA); funded 100, each TEST-ONLY corrupted NFT view in turn — a
    /// wrong LIFECYCLE backpointer, a basketB basketOf answer, and the NFT's
    /// runtime code stripped outright — reverts WiringMismatch or
    /// BasketMismatch(id) BEFORE any state write, leaving consumed false and
    /// backing 0. The exact saved code is restored before the closing leg,
    /// where the permissionless call credits the full 100 exactly once.
    function testMaterialiseRevertsOnUnfundedAndCorruptedWiring() public {
        // H0: real mint strictly before the day-1 cutoff — rarity 100,
        // hunter 0, sole member of the basketA cohort.
        vm.warp(86_399);
        uint256 id = _mint(ALICE, 1, basketA);
        assertEq(id, 1);

        // Canonical binding only: the harness derives lifecycle/nft back out
        // of the deployed ledger — there is no caller-supplied NFT argument.
        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        harness = new MaterialisationHarness(address(ledger), address(this));
        assertEq(address(harness.lifecycle()), address(lc));
        assertEq(address(harness.nft()), address(nft));

        // Day 1: round recorded and the real basketA cohort frozen at the
        // 86_400 cutoff, but the group left UNFUNDED — materialise reverts
        // the exact FundingNotFinalized(1, basketA) and writes nothing.
        vm.warp(86_400);
        ledger.recordRound(1, keccak256("receipt-day-1"), 2_000);
        ledger.freezeGroup(1, basketA);
        bytes memory notFunded =
            abi.encodeWithSelector(WeightedRoundFunding.FundingNotFinalized.selector, uint32(1), basketA);
        vm.expectRevert(notFunded);
        harness.materialise(1, id);
        assertFalse(harness.consumed(1, id));
        assertEq(harness.backingOf(id), 0);

        // Fund for real: 100 basketA units pulled from this contract (the
        // immutable funder); the measured received is exactly 100.
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(harness)); // custody is the taxed inbound sink
        asset.mint(address(this), 100);
        asset.approve(address(harness), 100);
        harness.fund(1, basketA, 100);
        assertEq(harness.totalReceived(basketA), 100);

        bytes memory wiringBad = abi.encodeWithSelector(WeightedRoundMaterialisation.WiringMismatch.selector);

        // TEST-ONLY corrupted view: a LIFECYCLE() answer pointing at a
        // non-canonical lifecycle trips WiringMismatch inside _custodyWired,
        // before the share or liveness reads. Cleared before the next case.
        vm.mockCall(address(nft), abi.encodeWithSelector(bytes4(keccak256("LIFECYCLE()"))), abi.encode(address(0xDEAD)));
        vm.expectRevert(wiringBad);
        harness.materialise(1, id);
        vm.clearMockedCalls();
        assertFalse(harness.consumed(1, id));
        assertEq(harness.backingOf(id), 0);

        // TEST-ONLY corrupted view: basketOf answering basketB against the
        // frozen basketA share trips BasketMismatch(id) after the real
        // liveness read — the live-vs-historical tripwire a switch seam
        // would need, exercised here as a forged read only.
        bytes memory basketBad = abi.encodeWithSelector(WeightedRoundMaterialisation.BasketMismatch.selector, id);
        vm.mockCall(
            address(nft), abi.encodeWithSelector(bytes4(keccak256("basketOf(uint256)")), id), abi.encode(basketB)
        );
        vm.expectRevert(basketBad);
        harness.materialise(1, id);
        vm.clearMockedCalls();
        assertFalse(harness.consumed(1, id));
        assertEq(harness.backingOf(id), 0);

        // TEST-ONLY codeless case: with the real NFT's runtime code stripped,
        // the code-presence half of _custodyWired reverts WiringMismatch
        // before ANY NFT call — no NFT mutation runs while its code is
        // absent — then the EXACT saved code is restored before the success.
        {
            bytes memory nftCode = address(nft).code;
            vm.etch(address(nft), "");
            vm.expectRevert(wiringBad);
            harness.materialise(1, id);
            vm.etch(address(nft), nftCode);
        }
        assertFalse(harness.consumed(1, id));
        assertEq(harness.backingOf(id), 0);

        // Real wiring, funded group, live NFT: the permissionless call
        // materialises the share exactly once — consumed set, backing 100,
        // no token leg.
        vm.prank(OP);
        harness.materialise(1, id);
        assertTrue(harness.consumed(1, id));
        assertEq(harness.backingOf(id), 100);
        assertEq(asset.balanceOf(address(harness)), 100); // effects only
        assertEq(harness.totalReleased(basketA), 0);

        bytes memory consumed =
            abi.encodeWithSelector(WeightedRoundMaterialisation.AlreadyConsumed.selector, uint32(1), id);
        vm.expectRevert(consumed);
        harness.materialise(1, id);
        assertEq(harness.backingOf(id), 100);
    }
}

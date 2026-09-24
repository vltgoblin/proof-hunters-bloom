// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

/// @notice VLT-38 Stage 2: `HunterLifecycle` guard legs not reachable through
/// the happy-path switch suites — burn beneficiary pre-set, missing-request
/// cancel/prepare/complete, the composed `switchNow` path including its
/// unready revert, the funding-gap preparation break, and the completion
/// guard rail. `StaleSwitchState` is dead by construction: the backing
/// vault's `_requireUnchanged` inside `convertForSwitch` revalidates the same
/// owner/nonce/encumbrance predicates and reverts first — recorded residual.
contract HunterLifecycleEdgesTest is LifecycleTestBase {
    using stdStorage for StdStorage;

    function testOnBurnRejectsPresetBeneficiary() public {
        uint256 id = _mint(ALICE, 1, basketA);
        stdstore.target(address(lc)).sig("finalBeneficiary(uint256)").with_key(id).checked_write(BOB);
        vm.prank(address(nft));
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.BeneficiaryAlreadySet.selector, id));
        lc.onBurn(id, BOB);
    }

    function testCancelAndPrepareRejectMissingRequest() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NoSwitchRequest.selector, id));
        lc.cancelSwitch(id);

        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NoSwitchRequest.selector, id));
        lc.prepareSwitch(id, 1);
    }

    function testRequestSwitchGuards() public {
        uint256 id = _mint(ALICE, 1, basketA);

        // Zero and same-basket targets are invalid.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.InvalidSwitchTarget.selector, address(0)));
        lc.requestSwitch(id, address(0));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.InvalidSwitchTarget.selector, basketA));
        lc.requestSwitch(id, basketA);

        // A disabled destination is not an entry.
        registry.setEntryEnabled(basketB, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.BasketNotEnabled.selector, basketB));
        lc.requestSwitch(id, basketB);
        registry.setEntryEnabled(basketB, true);

        // Escrow custody is not owner-held; the escrow contract is the owner.
        vm.prank(ALICE);
        nft.escrowTo(id, address(escrow), "");
        vm.prank(address(escrow));
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.TokenNotOwnerHeld.selector, id));
        lc.requestSwitch(id, basketB);

        // Unencumber via release back to ALICE, then request twice.
        vm.prank(address(escrow));
        escrow.release(nft, id, ALICE);
        vm.prank(ALICE);
        lc.requestSwitch(id, basketB);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.SwitchRequestActive.selector, id));
        lc.requestSwitch(id, basketB);
    }

    function testSwitchNowZeroBackingCompletesInOneTransaction() public {
        uint256 id = _mint(ALICE, 1, basketA);
        // Same-day mint: the request barrier is already below the cursor, so
        // the composed call completes with the zero-backing path — no
        // converter interaction at all.
        vm.prank(ALICE);
        uint256 totalOut = lc.switchNow(id, basketB, address(0), 0, 0, block.timestamp, 1, 1);
        assertEq(totalOut, 0);
        assertEq(nft.basketOf(id), basketB);
        assertEq(lc.switchRequestOf(id).target, address(0));
    }

    function testSwitchNowRevertsWhenPreparationCannotReachReadiness() public {
        uint256 id = _mint(ALICE, 1, basketA);
        // Day 2 request with an unfunded eligible day between the cursor and
        // the barrier: preparation stops at the funding gap, so the composed
        // call reverts SwitchNotReady and leaves no request behind.
        vm.warp(2 days);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.SwitchNotReady.selector, id));
        lc.switchNow(id, basketB, address(0), 0, 0, block.timestamp, 1, 30);
        assertEq(lc.switchRequestOf(id).target, address(0));
    }

    function testCompleteSwitchGuardRail() public {
        uint256 id = _mint(ALICE, 1, basketA);

        // Expired deadline wins the guard order.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.SwitchDeadlineExpired.selector, block.timestamp - 1));
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp - 1, 1);

        // Non-owner caller.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NotTokenOwner.selector, id));
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 1);

        // Escrow custody: the escrow holder is owner but the token is not owner-held.
        vm.prank(ALICE);
        nft.escrowTo(id, address(escrow), "");
        vm.prank(address(escrow));
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.TokenNotOwnerHeld.selector, id));
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 1);
        vm.prank(address(escrow));
        escrow.release(nft, id, ALICE);

        // No pending request.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NoSwitchRequest.selector, id));
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 1);

        // A wrong switch nonce is stale.
        vm.prank(ALICE);
        lc.requestSwitch(id, basketB);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.StaleSwitchNonce.selector, id));
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 2);

        // Destination entry disabled after the request.
        registry.setEntryEnabled(basketB, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.BasketNotEnabled.selector, basketB));
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 1);
        registry.setEntryEnabled(basketB, true);
    }

    function testDayOverflowRevertsWhenDayExceedsUint32() public {
        uint256 id = _mint(ALICE, 1, basketA);
        // Day numbering is uint32; the first timestamp past the range must
        // revert rather than wrap the day counter.
        vm.warp(uint256(type(uint32).max) * 86_400 + 1);
        vm.prank(ALICE);
        vm.expectRevert(HunterLifecycle.DayOverflow.selector);
        lc.requestSwitch(id, basketB);
    }

    function testRequestSwitchRejectsLedgerBasketDrift() public {
        uint256 id = _mint(ALICE, 1, basketA);
        // A member basket inconsistent with the NFT's recorded basket is
        // malformed state: refuse rather than carry the drift forward.
        stdstore.target(address(nft)).sig("basketOf(uint256)").with_key(id).checked_write(basketB);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.BasketMismatch.selector, id));
        lc.requestSwitch(id, basketB);
    }

    function testPrepareSwitchRejectsDayBounds() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.expectRevert(HunterLifecycle.InvalidDayBound.selector);
        lc.prepareSwitch(id, 0);
        vm.expectRevert(HunterLifecycle.InvalidDayBound.selector);
        lc.prepareSwitch(id, 33); // MAX_PREPARE_DAYS is 32
    }

    function testCompleteSwitchRejectsStaleAuthorization() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        lc.requestSwitch(id, basketB);
        // The stored request nonce must match the NFT's authorization nonce.
        // A real transfer cannot seed the mismatch — onTransfer deletes the
        // request first — so the drift is seeded directly.
        stdstore.target(address(nft)).sig("authorizationNonce(uint256)").with_key(id).checked_write(9);
        vm.prank(ALICE);
        vm.expectRevert(HunterLifecycle.StaleAuthorization.selector);
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 1);
    }

    function testCompleteSwitchRejectsLedgerBasketDrift() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        lc.requestSwitch(id, basketB);
        stdstore.target(address(nft)).sig("basketOf(uint256)").with_key(id).checked_write(basketB);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.BasketMismatch.selector, id));
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 1);
    }

    function testCompleteSwitchRejectsNonzeroQuoteWithoutBacking() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        lc.requestSwitch(id, basketB);
        // Zero combined backing admits only the zero quote.
        vm.prank(ALICE);
        vm.expectRevert(HunterLifecycle.InvalidSwitchQuote.selector);
        lc.completeSwitch(id, address(0), 5, 1, block.timestamp, 1);
    }

    function testPrepareSwitchSkipsIneligibleDay() public {
        // Day-0 member with a funded day-1 group.
        vm.warp(86_399);
        uint256 id = _mint(ALICE, 1, basketA);
        vm.warp(86_400);
        canonicalLedger.recordRound(1, keccak256("receipt-ineligible-skip"), 2_000);
        canonicalLedger.freezeGroup(1, basketA);
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.mint(address(this), 100);
        asset.approve(address(canonicalBacking), 100);
        canonicalBacking.fund(1, basketA, 100);

        // First request pauses eligibility on day 1; cancelling on day 3
        // leaves a historical ineligible record covering day 2's cutoff.
        vm.prank(ALICE);
        lc.requestSwitch(id, basketB);
        vm.warp(3 days);
        vm.prank(ALICE);
        lc.cancelSwitch(id);

        // Second request (barrier day 3): preparation settles day 1 through
        // materialise, then reads the member as ineligible at the day-2 and
        // day-3 cutoffs — the cursor skips both without touching the vault.
        vm.prank(ALICE);
        lc.requestSwitch(id, basketB);
        (uint256 examined, bool ready) = lc.prepareSwitch(id, 30);
        assertEq(examined, 3);
        assertTrue(ready);
        assertEq(lc.nextUncheckedDay(id), 4);
    }

    function testCompleteSwitchRejectsUnreadyCursor() public {
        // Mint on day 0, request on day 2: cursor (day 1) is at or below the
        // barrier (day 2) so completion refuses until preparation advances.
        uint256 id = _mint(ALICE, 1, basketA);
        vm.warp(2 days);
        vm.prank(ALICE);
        lc.requestSwitch(id, basketB);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.SwitchNotReady.selector, id));
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 1);
    }
}

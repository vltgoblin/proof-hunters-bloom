// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {FundingHarness} from "./WeightedRoundFundingCore.t.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

/// @notice VLT-38 Stage 2: `WeightedRoundFunding` constructor configuration
/// guards plus the solvency legs that only fire when custody storage or the
/// token's balance read is corrupted — measured balance below the recorded
/// outstanding liability, or a released counter ahead of received.
contract WeightedRoundFundingEdgesTest is LifecycleTestBase {
    using stdStorage for StdStorage;

    function testConstructorRejectsBadAddresses() public {
        address funder = address(0xF00D);
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new FundingHarness(address(0), funder);
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new FundingHarness(address(canonicalLedger), address(0));
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new FundingHarness(address(canonicalLedger), address(canonicalLedger));
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new FundingHarness(address(0xCAFE), funder); // ledger with no code

        // ledger or funder equal to the funding contract's own address.
        // Predict the current CREATE nonce before each deployment — a
        // failed constructor still consumes the nonce.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new FundingHarness(predicted, funder); // ledger_ == address(this)
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new FundingHarness(address(canonicalLedger), predicted); // funder_ == address(this)
    }

    function _fundedRound() internal returns (WeightedRoundLedger led, FundingHarness f, address assetAddr) {
        vm.warp(86_399);
        _mint(ALICE, 1, basketA);
        _mint(ALICE, 4, basketA);
        led = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        f = new FundingHarness(address(led), address(this));
        assetAddr = basketA;
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.mint(address(this), 1_000);
        asset.approve(address(f), type(uint256).max);
        vm.warp(86_400);
        led.recordRound(1, keccak256("receipt-edge-1"), 2_000);
        led.freezeGroup(1, basketA);
        f.fund(1, basketA, 100);
    }

    function testFundRevertsWhenBalanceDropsBelowOutstanding() public {
        (WeightedRoundLedger led, FundingHarness f, address assetAddr) = _fundedRound();

        // Corrupt the custody balance read below the recorded liability.
        stdstore.target(assetAddr).sig("balanceOf(address)").with_key(address(f)).checked_write(50);

        // The next pull measures solvency against the recorded liability first.
        vm.warp(172_800);
        led.recordRound(2, keccak256("receipt-edge-2"), 2_000);
        led.freezeGroup(2, basketA);
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        f.fund(2, basketA, 10);

        // The donation read reverts rather than narrowing the deficit.
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        f.unaccountedBalance(assetAddr);
    }

    function testReleasedAheadOfReceivedIsAnAccountingBreak() public {
        (, FundingHarness f, address assetAddr) = _fundedRound();

        // A released counter ahead of received is impossible by construction;
        // corrupt it to prove the guard reverts rather than underflowing.
        stdstore.target(address(f)).sig("totalReleased(address)").with_key(assetAddr).checked_write(200);
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        f.unaccountedBalance(assetAddr);
    }
}

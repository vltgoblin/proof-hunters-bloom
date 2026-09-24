// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {FundingHarness} from "./WeightedRoundFundingCore.t.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice TEST-ONLY basket asset whose `transferFrom` can misreport or
/// mutate the pull result: move-then-report-false, move-then-overdeliver,
/// shrink the recipient, or take an inbound tax. A mock for exercising the
/// measured-receipt guards — no claim of untrusted-asset support is made or
/// implied by it.
contract HostileReceiptFixture is ERC20 {
    /// @dev TEST-ONLY pull outcome selector; `Normal` is the default.
    enum Mode {
        Normal,
        FalseReturn,
        BonusReceipt,
        DecreaseRecipient,
        TaxHalf
    }

    Mode public mode;

    constructor() ERC20("Fixture HOSTILE", "fHOST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(Mode newMode) external {
        mode = newMode;
    }

    /// @dev TEST-ONLY: `FalseReturn` moves the units honestly then lies about
    /// success; the other non-normal modes report success while the real
    /// recipient delta differs from `value`.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (mode == Mode.FalseReturn) {
            super.transferFrom(from, to, value);
            return false;
        }
        if (mode == Mode.BonusReceipt) {
            super.transferFrom(from, to, value);
            _mint(to, 1);
            return true;
        }
        if (mode == Mode.DecreaseRecipient) {
            _burn(to, 1);
            return true;
        }
        if (mode == Mode.TaxHalf) {
            super.transferFrom(from, to, value);
            _burn(to, value / 2);
            return true;
        }
        return super.transferFrom(from, to, value);
    }
}

/// @notice Measured-delta receipt handling of `WeightedRoundFunding.fund`
/// against a hostile-mode basket asset on REAL lifecycle history. Every
/// misreporting pull — a false success flag, a bonus mint, a recipient
/// balance decrease — reverts with the exact error and rolls back atomically,
/// leaving the group unfunded, retryable and the pre-seeded donation
/// uncredited. A plain inbound tax is supported: the measured delta alone is
/// credited, so a raw post-pull balance read would wrongfully fold the
/// donation into `received` — the balance already satisfies `<= requested`,
/// meaning no other guard masks that mutation.
contract WeightedRoundFundingHostileTest is LifecycleTestBase {
    WeightedRoundLedger internal ledger;
    FundingHarness internal funding;
    HostileReceiptFixture internal asset;

    /// @notice Day 1, sole ALICE member, frozen budget 1000. Funder (this
    /// contract) holds 1000 with full approval; a 50-unit donation sits in
    /// the funding contract uncredited. Three hostile pulls revert exactly,
    /// then the 50%-tax pull finalises `received == 50` of `requested == 100`
    /// with the sole-member share at 50 and the donation still unaccounted.
    function testMeasuredReceiptRejectsMisreportingPulls() public {
        // The fixture token is admitted for real: the same contract is the
        // basket asset and the misreporting transferFrom source.
        asset = new HostileReceiptFixture();
        registry.admitBasket(address(asset), keccak256("reviewH"));

        // H0: single ALICE tier-1 mint into the fixture basket at 86399.
        vm.warp(86_399);
        uint256 idA = _mint(ALICE, 1, address(asset)); // rarity 100

        // Day 1 at the 86400 cutoff: sole-member group takes the full
        // nominal backing budget of 1000.
        vm.warp(86_400);
        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        ledger.recordRound(1, keccak256("receipt-hostile-1"), 2_000);
        ledger.freezeGroup(1, address(asset));
        assertEq(ledger.group(1, address(asset)).budget, 1_000);

        // This contract is the authorized funder: 1000 units and full
        // approval, plus a direct 50-unit donation that is never credited.
        funding = new FundingHarness(address(ledger), address(this));
        asset.mint(address(this), 1_000);
        asset.approve(address(funding), type(uint256).max);
        asset.transfer(address(funding), 50);
        _assertUnfunded();

        // The pull moves 100 units then reports `false`: SafeERC20 rejects
        // the receipt with the token address and the moved units roll back
        // with the whole call.
        asset.setMode(HostileReceiptFixture.Mode.FalseReturn);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("SafeERC20FailedOperation(address)")), address(asset)));
        funding.fund(1, address(asset), 100);
        _assertUnfunded();

        // The pull moves 100 then mints 1 to the funding contract: the
        // measured 101 exceeds the requested 100.
        asset.setMode(HostileReceiptFixture.Mode.BonusReceipt);
        vm.expectRevert(WeightedRoundFunding.UnsupportedTokenReceipt.selector);
        funding.fund(1, address(asset), 100);
        _assertUnfunded();

        // The pull moves nothing and burns 1 from the funding contract: the
        // post-pull balance 49 reads below the pre-pull 50.
        asset.setMode(HostileReceiptFixture.Mode.DecreaseRecipient);
        vm.expectRevert(WeightedRoundFunding.UnsupportedTokenReceipt.selector);
        funding.fund(1, address(asset), 100);
        _assertUnfunded();

        // A plain 50% inbound tax: the pull moves 100 then burns 50, so the
        // measured delta 50 is credited. The raw post-pull balance is 100 <=
        // requested 100 — crediting it would fold the donation into received
        // unmasked by any other guard; the asserts pin the measured 50.
        asset.setMode(HostileReceiptFixture.Mode.TaxHalf);
        funding.fund(1, address(asset), 100);
        {
            WeightedRoundFunding.Funding memory f = funding.funding(1, address(asset));
            assertTrue(f.finalised);
            assertEq(f.received, 50);
        }
        assertTrue(funding.isFunded(1, address(asset)));
        assertEq(funding.totalReceived(address(asset)), 50);
        assertEq(asset.balanceOf(address(funding)), 100);
        assertEq(asset.balanceOf(address(this)), 850);
        assertEq(funding.unaccountedBalance(address(asset)), 50);
        assertEq(funding.totalReleased(address(asset)), 0);
        {
            (address basket, uint256 units) = funding.memberReceivedShare(1, idA);
            assertEq(basket, address(asset));
            assertEq(units, 50);
        }
    }

    /// @dev After the donation and every reverted pull: the (day 1, asset)
    /// record is unfinalised, cumulative custody is zero, the funding
    /// contract holds exactly the 50-unit donation (all unaccounted), the
    /// funder keeps 950 and the released counter stays 0.
    function _assertUnfunded() internal view {
        assertFalse(funding.isFunded(1, address(asset)));
        assertEq(funding.totalReceived(address(asset)), 0);
        assertEq(asset.balanceOf(address(funding)), 50);
        assertEq(asset.balanceOf(address(this)), 950);
        assertEq(funding.unaccountedBalance(address(asset)), 50);
        assertEq(funding.totalReleased(address(asset)), 0);
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {FundingHarness} from "./WeightedRoundFundingCore.t.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice TEST-ONLY ERC20 that is simultaneously a basket asset (basket
/// identity IS the token address) and the immutable `funder` of a
/// `WeightedRoundFunding` instance: it holds its own minted supply and, while
/// the one-shot callback switch is armed, attempts a nested `fund` of the
/// same (day, basket) from inside `transferFrom`. Not production: no hooks,
/// no release or withdrawal surface of any kind.
contract FundingTokenFixture is ERC20 {
    /// @dev The funding instance this token is the immutable funder of.
    WeightedRoundFunding public funding;
    /// @dev The recorded day the armed callback re-enters on.
    uint32 public fundDay;
    /// @dev One-shot reentrancy switch; disarmed before the nested call.
    bool public callbackEnabled;

    constructor() ERC20("Fixture FUND", "fFUND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev TEST-ONLY wiring: the funding instance and the recorded day the
    /// callback re-enters on. The basket is always this token itself.
    function setFunding(WeightedRoundFunding funding_, uint32 day_) external {
        funding = funding_;
        fundDay = day_;
    }

    function setCallback(bool enabled) external {
        callbackEnabled = enabled;
    }

    /// @dev TEST-ONLY: this contract is the authorized funder; approves the
    /// pull then calls `fund` exactly as an EOA funder would.
    function beginFund(uint256 requested) external {
        _approve(address(this), address(funding), requested);
        funding.fund(fundDay, address(this), requested);
    }

    /// @dev TEST-ONLY: while armed, the funding pull's own `transferFrom`
    /// first disarms the one-shot flag — so a hypothetically missing guard
    /// would produce a real nested credit/error, never infinite recursion —
    /// then attempts a nested `fund` on the same valid (day, basket) as the
    /// authorized funder. The nested call is direct: its error propagates.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (callbackEnabled) {
            callbackEnabled = false;
            funding.fund(fundDay, address(this), value);
        }
        return super.transferFrom(from, to, value);
    }
}

contract WeightedRoundFundingCallbackTest is LifecycleTestBase {
    WeightedRoundLedger internal ledger;
    FundingHarness internal funding;
    FundingTokenFixture internal asset;

    /// @notice A real reentrant `fund` from inside the basket token's own
    /// `transferFrom` reaches the pull as the AUTHORIZED funder (the token
    /// contract itself), so the `nonReentrant` guard — not
    /// `UnauthorizedFunder` — rejects it, and the whole pull rolls back
    /// atomically: the fixture keeps its 200 units, no funding record exists,
    /// and cumulative custody stays zero. With the callback disarmed the same
    /// call funds the group once: sole-member rarity-only shares are the full
    /// received 100.
    function testFundCallbackReentrancyGuardRollsBackAtomically() public {
        // The fixture token is admitted for real: the same contract is the
        // basket asset, the funder and the reentrancy source.
        asset = new FundingTokenFixture();
        registry.admitBasket(address(asset), keccak256("reviewC"));

        // H0: single ALICE tier-1 mint into the fixture basket at 86399.
        vm.warp(86_399);
        uint256 idA = _mint(ALICE, 1, address(asset)); // rarity 100

        // Day 1 at the 86400 cutoff: sole-member group takes the full
        // nominal backing budget of 1000.
        vm.warp(86_400);
        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        ledger.recordRound(1, keccak256("receipt-day-1"), 2_000);
        ledger.freezeGroup(1, address(asset));
        assertEq(ledger.group(1, address(asset)).budget, 1_000);

        asset.mint(address(asset), 200); // the funder holds its own supply
        funding = new FundingHarness(address(ledger), address(asset));
        asset.setFunding(funding, 1);

        // Armed: the pull's transferFrom re-enters fund as funder and the
        // reentrancy guard's error propagates out through SafeERC20.
        asset.setCallback(true);
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        asset.beginFund(100);
        _assertRolledBack();

        // Disarmed: the identical call funds the group once, measured 100.
        asset.setCallback(false);
        asset.beginFund(100);
        _assertFundedOnce(idA);
    }

    /// @dev After the reverted pull: fixture 200 / funding 0, no record, and
    /// both cumulative counters zero.
    function _assertRolledBack() internal view {
        assertEq(asset.balanceOf(address(asset)), 200);
        assertEq(asset.balanceOf(address(funding)), 0);
        assertEq(funding.totalReceived(address(asset)), 0);
        assertFalse(funding.isFunded(1, address(asset)));
        assertEq(funding.totalReleased(address(asset)), 0);
    }

    /// @dev After the successful retry: finalised received 100, sole-member
    /// share 100, balances 100/100, released still 0.
    function _assertFundedOnce(uint256 tokenId) internal view {
        WeightedRoundFunding.Funding memory f = funding.funding(1, address(asset));
        assertTrue(f.finalised);
        assertEq(f.received, 100);
        assertEq(asset.balanceOf(address(asset)), 100);
        assertEq(asset.balanceOf(address(funding)), 100);
        assertEq(funding.totalReceived(address(asset)), 100);
        assertEq(funding.totalReleased(address(asset)), 0);
        (address basket, uint256 units) = funding.memberReceivedShare(1, tokenId);
        assertEq(basket, address(asset));
        assertEq(units, 100);
    }
}

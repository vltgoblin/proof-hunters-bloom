// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {PrefundedMiningPower} from "../src/bloom/PrefundedMiningPower.sol";
import {DirectLoan} from "../src/bloom/DirectLoan.sol";
import {LiveHunt} from "../src/LiveHunt.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {PrefundedMiningStack} from "./helpers/PrefundedMiningStack.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @dev TEST-ONLY HUNTER stand-in with an OUTBOUND tax: a transfer out of
/// `module` debits the full amount from it but burns `taxBps` of it, so the
/// recipient receives the net. Inbound transfers are untaxed.
contract CompanionOutboundTaxHunter is ERC20 {
    address public module;
    uint256 public taxBps;

    constructor() ERC20("Outbound-tax HUNTER", "oHUNT") {}

    function configure(address module_, uint256 taxBps_) external {
        module = module_;
        taxBps = taxBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == module && from != address(0) && to != address(0) && taxBps != 0) {
            uint256 tax = (value * taxBps) / 10_000;
            super._update(from, address(0), tax);
            super._update(from, to, value - tax);
            return;
        }
        super._update(from, to, value);
    }
}

/// @notice S7 (VLT-58): the per-mint lock is released only when its NFT is
/// burned, and only to the lifecycle's final beneficiary — the companion
/// right follows the NFT (transfer, LiveHunt sale, DirectLoan repay and
/// default) and never stays with the original miner or goes back to the
/// backer whose stake paid it. Single bucket (owner decision 2026-09-25):
/// the lock comes out of the stake assigned to the winner, and the release
/// is paid from the module balance, which holds only stake and locks. Everything runs on the
/// FULL real stack: every lock comes from a real `submitProof`, every burn
/// from a real `redeemAndDestroy`. All amounts are TEST-ONLY fixture values.
contract PrefundedMiningPowerCompanionTest is PrefundedMiningStack {
    address internal constant CAROL = address(0xCA201);

    uint256 private constant MIN_STAKE = 1_000e18;
    uint256 private constant LOCK = 100e18;

    function setUp() public override {
        super.setUp();
        _deployModule(MIN_STAKE, LOCK, 0, 0, address(0));
        _attach(module);
    }

    // ------------------------------------------------------------------
    // The right follows the NFT
    // ------------------------------------------------------------------

    /// @dev S0 default 6: ALICE (a separate depositor) stakes for MINER, and
    /// the win moves L of that stake into the lock. MINER keeps the NFT,
    /// burns it and claims L.
    function testMinerBurnsAndClaims() public {
        uint256 id = _mineLocked(ALICE, MINER);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(module.assignedOf(MINER), MIN_STAKE - LOCK);
        assertEq(module.totalStake(), MIN_STAKE - LOCK);
        uint256 moduleBal = token.balanceOf(address(module));
        assertEq(moduleBal, MIN_STAKE);

        _burn(id);
        assertEq(lifecycle.finalBeneficiary(id), MINER);
        // The burn itself moves nothing out of the module.
        assertEq(token.balanceOf(address(module)), moduleBal);
        _assertClaimable(id, true, MINER, LOCK);

        vm.expectEmit(true, true, true, true, address(module));
        emit PrefundedMiningPower.Released(id, MINER, MINER, LOCK);
        _claim(id, MINER);

        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(token.balanceOf(address(module)), MIN_STAKE - LOCK);
        assertEq(module.totalCommitted(), 0);
        (uint256 amount,,, address miner, address backer, bool released) = module.committedOf(id);
        assertEq(amount, LOCK);
        assertEq(miner, MINER);
        assertEq(backer, ALICE);
        assertTrue(released);
        _assertClaimable(id, false, MINER, 0);
        // The remaining stake is untouched by the release; the backer never
        // gets the lock back.
        assertEq(module.assignedOf(MINER), MIN_STAKE - LOCK);
        assertEq(module.assignedBy(ALICE), MIN_STAKE - LOCK);
        assertEq(module.totalStake(), MIN_STAKE - LOCK);
        assertEq(token.balanceOf(ALICE), 0);
        _assertBooks();
    }

    function testTransferMovesRightsToBurner() public {
        uint256 id = _mineLocked(ALICE, MINER);
        vm.prank(MINER);
        nft.transferFrom(MINER, BOB, id);
        _burn(id);
        assertEq(lifecycle.finalBeneficiary(id), BOB);

        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotBeneficiary.selector, MINER));
        module.claimCommitted(id);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotBeneficiary.selector, MINER));
        module.claimCommittedTo(id, MINER);

        _claim(id, BOB);
        assertEq(token.balanceOf(BOB), LOCK);
        assertEq(token.balanceOf(MINER), 0);
        _assertBooks();
    }

    function testLiveHuntSaleMovesRightsToCollector() public {
        uint256 id = _mineLocked(ALICE, MINER);

        LiveHunt.Criteria memory criteria;
        criteria.artVersion = 1;
        vm.deal(COLLECTOR, HUNT_OFFER);
        vm.prank(COLLECTOR);
        uint256 huntId = hunt.createHunt{value: HUNT_OFFER}(criteria, HUNT_MIN_DURATION);
        assertTrue(hunt.matches(id, huntId));
        vm.prank(MINER);
        nft.safeTransferFrom(MINER, address(hunt), id, abi.encode(huntId));
        assertEq(nft.ownerOf(id), COLLECTOR);
        uint256 huntFee = HUNT_OFFER * HUNT_FEE_BPS / hunt.FEE_DENOMINATOR();
        assertEq(hunt.credit(MINER), HUNT_OFFER - huntFee);

        // The seller's lock did not follow the seller.
        _assertClaimable(id, false, address(0), LOCK);
        _burn(id);
        assertEq(lifecycle.finalBeneficiary(id), COLLECTOR);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotBeneficiary.selector, MINER));
        module.claimCommitted(id);

        _claim(id, COLLECTOR);
        assertEq(token.balanceOf(COLLECTOR), LOCK);
        assertEq(token.balanceOf(MINER), 0);
        _assertBooks();
    }

    function testEscrowedLoanNftCannotBeBurnedOrClaimed() public {
        uint256 id = _mineLocked(ALICE, MINER);
        uint256 loanId = _escrowIntoLoan(id, MINER);
        assertEq(nft.ownerOf(id), address(loan));
        assertTrue(nft.isEncumbered(id));

        // The borrower no longer owns it; the loan owns it but it is escrowed.
        vm.prank(MINER);
        vm.expectRevert(HunterNFT.NotTokenOwner.selector);
        nft.redeemAndDestroy(id);
        vm.prank(address(loan));
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        nft.redeemAndDestroy(id);

        // Nobody can claim the lock of a live (escrowed) NFT — nor after funding.
        address[3] memory claimants = [MINER, address(loan), LENDER];
        for (uint256 i = 0; i < claimants.length; i++) {
            vm.prank(claimants[i]);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.TokenNotBurned.selector, id));
            module.claimCommitted(id);
        }
        _fundLoan(loanId);
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.TokenNotBurned.selector, id));
        module.claimCommittedTo(id, LENDER);
        _assertClaimable(id, false, address(0), LOCK);
        assertEq(module.totalCommitted(), LOCK);
        _assertBooks();
    }

    function testRepaidLoanReturnsRightsToBorrower() public {
        uint256 id = _mineLocked(ALICE, MINER);
        uint256 loanId = _escrowIntoLoan(id, MINER);
        _fundLoan(loanId);
        loanAsset.mint(MINER, LOAN_REPAYMENT);
        vm.startPrank(MINER);
        loanAsset.approve(address(loan), LOAN_REPAYMENT);
        loan.depositRepayment(loanId, LOAN_REPAYMENT);
        vm.stopPrank();
        assertEq(uint8(loan.getLoan(loanId).status), uint8(DirectLoan.Status.Repaid));
        loan.claimNft(loanId);
        assertEq(nft.ownerOf(id), MINER);
        assertFalse(nft.isEncumbered(id));

        _burn(id);
        assertEq(lifecycle.finalBeneficiary(id), MINER);
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotBeneficiary.selector, LENDER));
        module.claimCommitted(id);
        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(token.balanceOf(LENDER), 0);
        _assertBooks();
    }

    function testDefaultedLoanMovesRightsToLender() public {
        uint256 id = _mineLocked(ALICE, MINER);
        uint256 loanId = _escrowIntoLoan(id, MINER);
        _fundLoan(loanId);
        vm.warp(loan.getLoan(loanId).deadline + 1);
        vm.prank(LENDER);
        loan.resolveDefault(loanId);
        assertEq(uint8(loan.getLoan(loanId).status), uint8(DirectLoan.Status.Defaulted));
        loan.claimNft(loanId);
        assertEq(nft.ownerOf(id), LENDER);

        _burn(id);
        assertEq(lifecycle.finalBeneficiary(id), LENDER);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotBeneficiary.selector, MINER));
        module.claimCommitted(id);

        vm.expectEmit(true, true, true, true, address(module));
        emit PrefundedMiningPower.Released(id, LENDER, LENDER, LOCK);
        _claim(id, LENDER);
        assertEq(token.balanceOf(LENDER), LOCK);
        assertEq(token.balanceOf(MINER), 0);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Claim preconditions
    // ------------------------------------------------------------------

    function testClaimBeforeBurnReverts() public {
        uint256 id = _mineLocked(ALICE, MINER);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.TokenNotBurned.selector, id));
        module.claimCommitted(id);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.TokenNotBurned.selector, id));
        module.claimCommittedTo(id, BOB);
        _assertClaimable(id, false, address(0), LOCK);
        (,,,,, bool released) = module.committedOf(id);
        assertFalse(released);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(token.balanceOf(MINER), 0);
        _assertBooks();
    }

    function testNonBeneficiaryClaimReverts() public {
        uint256 id = _mineLocked(ALICE, MINER);
        _burn(id);
        uint256 bal = token.balanceOf(address(module));
        // Neither the backer (ALICE), strangers (FUNDER, BOB) nor the core may claim.
        address[4] memory others = [ALICE, FUNDER, BOB, address(core)];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotBeneficiary.selector, others[i]));
            module.claimCommitted(id);
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotBeneficiary.selector, others[i]));
            module.claimCommittedTo(id, others[i]);
        }
        assertEq(token.balanceOf(address(module)), bal);
        assertEq(module.totalCommitted(), LOCK);
        _assertClaimable(id, true, MINER, LOCK);
        _claim(id, MINER);
        _assertBooks();
    }

    function testDuplicateClaimReverts() public {
        uint256 id = _mineLocked(ALICE, MINER);
        _burn(id);
        _claim(id, MINER);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.AlreadyReleased.selector, id));
        module.claimCommitted(id);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.AlreadyReleased.selector, id));
        module.claimCommittedTo(id, BOB);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(module.totalCommitted(), 0);
        _assertBooks();
    }

    function testClaimUnknownTokenReverts() public {
        uint256 id = _mineLocked(ALICE, MINER);
        uint256[3] memory unknown = [uint256(0), id + 1, 999];
        for (uint256 i = 0; i < unknown.length; i++) {
            vm.prank(MINER);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NoLock.selector, unknown[i]));
            module.claimCommitted(unknown[i]);
            vm.prank(MINER);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NoLock.selector, unknown[i]));
            module.claimCommittedTo(unknown[i], MINER);
            _assertClaimable(unknown[i], false, address(0), 0);
        }
        vm.prank(MINER);
        vm.expectRevert(PrefundedMiningPower.ZeroAddress.selector);
        module.claimCommittedTo(id, address(0));
    }

    // ------------------------------------------------------------------
    // Durability
    // ------------------------------------------------------------------

    /// @dev Burned three years later, after the module was detached: still pays.
    function testClaimYearsLaterStillPays() public {
        uint256 id = _mineLocked(ALICE, MINER);
        _detach();
        assertFalse(module.wired());
        vm.warp(block.timestamp + 3 * 365 days);
        _burn(id);
        vm.warp(block.timestamp + 30 days);
        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(module.totalCommitted(), 0);
        _assertBooks();
    }

    /// @dev Mining stopped for good (terminal detach, module retired), then the
    /// NFT is burned and claimed years later.
    function testClaimAfterMiningStoppedStillPays() public {
        uint256 id = _mineLocked(ALICE, MINER);
        vm.prank(STOP);
        core.stopMining();
        assertTrue(module.retired());
        assertFalse(module.wired());
        vm.warp(block.timestamp + 3 * 365 days);
        _burn(id);
        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        // The rest of the stake exits too (cooldown waived after retirement).
        _unassign(ALICE, MINER, MIN_STAKE - LOCK);
        _withdraw(ALICE, MIN_STAKE - LOCK);
        assertEq(token.balanceOf(ALICE), MIN_STAKE - LOCK);
        assertEq(token.balanceOf(address(module)), 0);
        _assertBooks();
    }

    /// @dev A token that refuses the payout reverts the whole claim: the lock
    /// stays unreleased, the totals are unchanged and a later retry pays.
    function testBlockedPayoutIsRetryableWithoutStateChange() public {
        uint256 id = _mineLocked(ALICE, MINER);
        _burn(id);
        uint256 bal = token.balanceOf(address(module));
        // Point the fixture's outbound switch at the module (TEST-ONLY).
        token.setVault(address(module));
        token.setBehavior(0, false, true, false);

        vm.prank(MINER);
        vm.expectRevert(ReserveTokenFixture.OutboundBlocked.selector);
        module.claimCommitted(id);
        vm.prank(MINER);
        vm.expectRevert(ReserveTokenFixture.OutboundBlocked.selector);
        module.claimCommittedTo(id, BOB);

        (,,,,, bool released) = module.committedOf(id);
        assertFalse(released);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(token.balanceOf(address(module)), bal);
        assertEq(token.balanceOf(MINER), 0);
        _assertClaimable(id, true, MINER, LOCK);

        token.setBehavior(0, false, false, false);
        token.setVault(address(vault));
        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(module.totalCommitted(), 0);
        _assertBooks();
    }

    function testClaimToRecipient() public {
        uint256 id = _mineLocked(ALICE, MINER);
        _burn(id);

        // Paying the module itself would not debit it: refused, nothing changes.
        vm.prank(MINER);
        vm.expectRevert(PrefundedMiningPower.DebitMismatch.selector);
        module.claimCommittedTo(id, address(module));
        _assertClaimable(id, true, MINER, LOCK);

        vm.expectEmit(true, true, true, true, address(module));
        emit PrefundedMiningPower.Released(id, MINER, CAROL, LOCK);
        vm.prank(MINER);
        module.claimCommittedTo(id, CAROL);
        assertEq(token.balanceOf(CAROL), LOCK);
        assertEq(token.balanceOf(MINER), 0);
        assertEq(module.totalCommitted(), 0);
        _assertClaimable(id, false, MINER, 0);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Independence from reserve and backing
    // ------------------------------------------------------------------

    /// @dev Reserve credit, owner backing and the module lock are three
    /// separate rights: the burn pays the first two, the lock stays in the
    /// module until its own claim.
    function testBurnSettlesReserveAndBackingIndependently() public {
        uint256 id = _mineLocked(ALICE, MINER);
        uint256 reserveAmt = 500e18;
        token.mint(MINER, reserveAmt);
        vm.startPrank(MINER);
        token.approve(address(vault), reserveAmt);
        vault.deposit(id, reserveAmt);
        vm.stopPrank();
        uint256 backingAmt = 50e18;
        _depositOwnerBacking(id, MINER, backingAmt);
        assertEq(vault.reserveOf(id), reserveAmt);
        assertEq(backing.totalBackingOf(id), backingAmt);
        assertEq(lifecycle.currentMember(id).hunter, reserveAmt);

        uint256 moduleBal = token.balanceOf(address(module));
        _burn(id);
        assertTrue(vault.settled(id));
        assertTrue(backing.burnSettled(id));
        assertEq(token.balanceOf(MINER), reserveAmt);
        assertEq(IERC20(basket).balanceOf(MINER), backingAmt);
        // The module lock is untouched by the burn.
        assertEq(token.balanceOf(address(module)), moduleBal);
        assertEq(module.totalCommitted(), LOCK);
        _assertClaimable(id, true, MINER, LOCK);

        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), reserveAmt + LOCK);
        assertEq(token.balanceOf(address(vault)), 0);
        _assertBooks();
    }

    /// @dev An NFT minted before the module was attached has no lock: nothing
    /// to claim, before or after burn, and the next locked mint is unaffected.
    function testPreCutoverNftHasNothingCommitted() public {
        _detach();
        PrefundedMiningPower first = module;
        uint256 legacy = _win(BOB);
        _deployModule(MIN_STAKE, LOCK, 0, 0, address(0));
        assertTrue(address(module) != address(first));
        _attach(module);

        _assertClaimable(legacy, false, address(0), 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NoLock.selector, legacy));
        module.claimCommitted(legacy);
        _burn(legacy);
        _assertClaimable(legacy, false, BOB, 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NoLock.selector, legacy));
        module.claimCommitted(legacy);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NoLock.selector, legacy));
        first.claimCommitted(legacy);

        uint256 id = _mineLocked(ALICE, MINER);
        assertEq(id, legacy + 1);
        _burn(id);
        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(token.balanceOf(BOB), 0);
        _assertBooks();
    }

    /// @dev An outbound tax is borne by the recipient: the module is debited
    /// exactly L, the recipient receives the net, and the remaining
    /// obligations stay fully covered.
    function testOutboundTaxStillDebitsExactly() public {
        CompanionOutboundTaxHunter tax = new CompanionOutboundTaxHunter();
        PrefundedMiningPower m = new PrefundedMiningPower(address(tax), address(core), MIN_STAKE, LOCK, 0, 0, address(0));
        _detach();
        _attach(m);
        vm.prank(MINER);
        m.approveBacker(ALICE);
        tax.mint(ALICE, MIN_STAKE);
        vm.startPrank(ALICE);
        tax.approve(address(m), MIN_STAKE);
        m.deposit(MIN_STAKE);
        m.assign(MINER, MIN_STAKE);
        vm.stopPrank();
        _nextChallenge();
        uint256 id = _win(MINER);
        (uint256 locked,,,,,) = m.committedOf(id);
        assertEq(locked, LOCK);
        _burn(id);

        tax.configure(address(m), 1_000); // 10% outbound
        uint256 before = tax.balanceOf(address(m));
        vm.expectEmit(true, true, true, true, address(m));
        emit PrefundedMiningPower.Released(id, MINER, MINER, LOCK);
        vm.prank(MINER);
        m.claimCommitted(id);
        assertEq(before - tax.balanceOf(address(m)), LOCK);
        assertEq(tax.balanceOf(MINER), LOCK - LOCK / 10);
        assertEq(m.totalCommitted(), 0);
        assertEq(tax.balanceOf(address(m)), m.totalStake() + m.totalCommitted());
        assertEq(tax.balanceOf(address(m)), MIN_STAKE - LOCK);
    }

    // ------------------------------------------------------------------
    // Burn-signal defence in depth (lifecycle reads mocked to be inconsistent)
    // ------------------------------------------------------------------

    /// @dev On the real stack the three burn signals always agree; here each
    /// one is made to lie on its own (vm.mockCall on the LIFECYCLE views only
    /// — no core hook is faked) and the claim must still refuse.
    function testBurnCheckNeedsEverySignal() public {
        uint256 id = _mineLocked(ALICE, MINER);
        bytes memory memberCall = abi.encodeWithSelector(lifecycle.currentMember.selector, id);
        bytes memory beneficiaryCall = abi.encodeWithSelector(lifecycle.finalBeneficiary.selector, id);
        bytes memory notBurned = abi.encodeWithSelector(PrefundedMiningPower.TokenNotBurned.selector, id);
        WeightedHistory.Member memory live = lifecycle.currentMember(id);
        assertTrue(live.alive);

        // (1) Live member, but ownerOf reverts and a beneficiary is reported:
        // the alive member alone refuses.
        vm.mockCall(address(lifecycle), beneficiaryCall, abi.encode(MINER));
        vm.mockCallRevert(address(nft), abi.encodeWithSelector(nft.ownerOf.selector, id), hex"deadbeef");
        vm.prank(MINER);
        vm.expectRevert(notBurned);
        module.claimCommitted(id);
        _assertClaimable(id, false, address(0), LOCK);
        vm.clearMockedCalls();
        vm.mockCall(address(lifecycle), beneficiaryCall, abi.encode(MINER));

        // (2) Member reported ended but eligible: refused.
        WeightedHistory.Member memory fake = live;
        fake.alive = false;
        fake.eligible = true;
        vm.mockCall(address(lifecycle), memberCall, abi.encode(fake));
        vm.prank(MINER);
        vm.expectRevert(notBurned);
        module.claimCommitted(id);

        // (3) Member reported ended and ineligible, but ownerOf still answers:
        // the NFT is live, refused.
        fake.eligible = false;
        vm.mockCall(address(lifecycle), memberCall, abi.encode(fake));
        vm.prank(MINER);
        vm.expectRevert(notBurned);
        module.claimCommitted(id);
        _assertClaimable(id, false, address(0), LOCK);

        // (4) A reverting member read counts as "not burned".
        vm.mockCallRevert(address(lifecycle), memberCall, hex"deadbeef");
        vm.prank(MINER);
        vm.expectRevert(notBurned);
        module.claimCommitted(id);
        _assertClaimable(id, false, address(0), LOCK);
        vm.clearMockedCalls();

        // (5) Really burned, but the lifecycle reports no beneficiary: even
        // address(0) as caller cannot match it.
        _burn(id);
        vm.mockCall(address(lifecycle), beneficiaryCall, abi.encode(address(0)));
        _assertClaimable(id, false, address(0), LOCK);
        vm.prank(address(0));
        vm.expectRevert(notBurned);
        module.claimCommittedTo(id, BOB);
        vm.clearMockedCalls();

        (,,,,, bool released) = module.committedOf(id);
        assertFalse(released);
        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Documented limitations
    // ------------------------------------------------------------------

    /// @notice LIMITATION: release is gated on a completed burn, and the burn
    /// is atomic with the reserve and backing payouts. If either payout leg
    /// fails (paused/blocking HUNTER or basket token), the NFT cannot be
    /// burned, so the lock cannot be claimed either. Nothing is lost: once the
    /// failing leg recovers the burn and then the claim succeed.
    function testLimitation_BackingPayoutFailureBlocksBurnAndClaim() public {
        uint256 id = _mineLocked(ALICE, MINER);
        _depositOwnerBacking(id, MINER, 50e18);

        // Backing leg: the basket token refuses outbound transfers.
        vm.mockCallRevert(basket, abi.encodeWithSelector(IERC20.transfer.selector), hex"deadbeef");
        vm.prank(MINER);
        vm.expectRevert(bytes(hex"deadbeef"));
        nft.redeemAndDestroy(id);
        assertEq(nft.ownerOf(id), MINER);
        assertEq(lifecycle.finalBeneficiary(id), address(0));
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.TokenNotBurned.selector, id));
        module.claimCommitted(id);
        vm.clearMockedCalls();

        // Reserve leg: the HUNTER token refuses the reserve's outbound payout.
        token.mint(MINER, 10e18);
        vm.startPrank(MINER);
        token.approve(address(vault), 10e18);
        vault.deposit(id, 10e18);
        vm.stopPrank();
        token.setBehavior(0, false, true, false);
        vm.prank(MINER);
        vm.expectRevert(ReserveTokenFixture.OutboundBlocked.selector);
        nft.redeemAndDestroy(id);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.TokenNotBurned.selector, id));
        module.claimCommitted(id);
        assertEq(module.totalCommitted(), LOCK);
        _assertClaimable(id, false, address(0), LOCK);

        // Both legs recover: burn, then claim.
        token.setBehavior(0, false, false, false);
        _burn(id);
        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), 10e18 + LOCK);
        assertEq(IERC20(basket).balanceOf(MINER), 50e18);
        _assertBooks();
    }

    /// @notice LIMITATION: the committed lock is NOT reserve credit — the
    /// lifecycle member's HUNTER weight (daily-round weight) ignores it.
    function testLimitation_CommittedValueNotInDailyRoundWeight() public {
        uint256 id = _mineLocked(ALICE, MINER);
        (uint256 locked,,,,,) = module.committedOf(id);
        assertEq(locked, LOCK);
        WeightedHistory.Member memory m = lifecycle.currentMember(id);
        assertTrue(m.alive);
        assertEq(m.hunter, 0);
        assertEq(vault.reserveOf(id), 0);

        token.mint(MINER, 7e18);
        vm.startPrank(MINER);
        token.approve(address(vault), 7e18);
        vault.deposit(id, 7e18);
        vm.stopPrank();
        assertEq(lifecycle.currentMember(id).hunter, 7e18); // not 7e18 + LOCK
        assertEq(module.totalCommitted(), LOCK);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev `depositor` stakes exactly one win's worth (MIN_STAKE) for
    /// `wallet`, which wins one NFT through the real core; L of that stake
    /// is now the lock.
    function _mineLocked(address depositor, address wallet) private returns (uint256 id) {
        _qualifyFor(depositor, wallet, 1);
        id = _win(wallet);
        (uint256 amount, uint256 challengeId, bytes32 digest, address miner, address backer, bool released) =
            module.committedOf(id);
        (, bytes32 birthDigest, uint256 birthChallenge,) = nft.birthData(id);
        assertEq(amount, LOCK);
        assertEq(challengeId, birthChallenge);
        assertEq(digest, birthDigest);
        assertEq(miner, wallet);
        assertEq(backer, depositor);
        assertFalse(released);
        assertEq(module.assignedOf(wallet), MIN_STAKE - LOCK);
    }

    function _assertClaimable(uint256 id, bool claimable, address beneficiary, uint256 amount) private view {
        (bool c, address b, uint256 a) = module.claimableOf(id);
        assertEq(c, claimable, "claimable");
        assertEq(b, beneficiary, "beneficiary");
        assertEq(a, amount, "amount");
    }

    function _escrowIntoLoan(uint256 id, address borrower) private returns (uint256 loanId) {
        vm.prank(borrower);
        nft.escrowTo(
            id,
            address(loan),
            abi.encode(
                DirectLoan.Terms({
                    version: 1, principal: LOAN_PRINCIPAL, repayment: LOAN_REPAYMENT, duration: LOAN_DURATION
                })
            )
        );
        loanId = loan.loanIdByToken(id);
    }

    function _fundLoan(uint256 loanId) private {
        loanAsset.mint(LENDER, LOAN_PRINCIPAL);
        vm.startPrank(LENDER);
        loanAsset.approve(address(loan), LOAN_PRINCIPAL);
        loan.fund(loanId);
        vm.stopPrank();
        assertEq(uint8(loan.getLoan(loanId).status), uint8(DirectLoan.Status.Funded));
    }

    /// @dev Owner-deposited basket backing (the harness basket has no mint,
    /// so the owner's basket balance is dealt).
    function _depositOwnerBacking(uint256 id, address owner, uint256 amount) private {
        deal(basket, owner, amount);
        vm.startPrank(owner);
        IERC20(basket).approve(address(backing), amount);
        backing.depositOwnerBacking(id, amount);
        vm.stopPrank();
    }
}

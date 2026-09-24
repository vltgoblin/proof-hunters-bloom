// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PrefundedMiningStack} from "./helpers/PrefundedMiningStack.sol";
import {MiningPowerCustody} from "../src/bloom/MiningPowerCustody.sol";
import {IMiningPower} from "../src/bloom/IMiningPower.sol";
import {DirectLoan} from "../src/bloom/DirectLoan.sol";
import {LiveHunt} from "../src/LiveHunt.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";

/// @notice S2 (VLT-53) harness self-test: the shared real stack mines, trades,
/// lends and burns with no Mining Power module attached, and the old custody
/// attaches, gates nothing it should not, and detaches cleanly. All amounts
/// are TEST-ONLY fixture values.
contract PrefundedMiningStackTest is PrefundedMiningStack {
    /// @notice Module-free lifecycle on the real stack: mine -> transfer ->
    /// LiveHunt fill -> DirectLoan fund/repay/claim -> burn with a recorded
    /// final beneficiary.
    function testHarnessMinesAndBurnsWithoutModule() public {
        assertEq(address(core.miningPower()), address(0));

        // 1. Mine a real NFT to ALICE and hand it to BOB.
        uint256 sold = _win(ALICE);
        assertEq(sold, 1);
        (uint32 artVersion,, uint256 bornIn,) = nft.birthData(sold);
        assertEq(artVersion, 1);
        assertEq(bornIn, 1);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, sold);
        assertEq(nft.ownerOf(sold), BOB);

        // 2. COLLECTOR posts a LiveHunt offer; BOB fills it with the NFT.
        LiveHunt.Criteria memory criteria;
        criteria.artVersion = 1;
        vm.deal(COLLECTOR, HUNT_OFFER);
        vm.prank(COLLECTOR);
        uint256 huntId = hunt.createHunt{value: HUNT_OFFER}(criteria, HUNT_MIN_DURATION);
        assertTrue(hunt.matches(sold, huntId));
        vm.prank(BOB);
        nft.safeTransferFrom(BOB, address(hunt), sold, abi.encode(huntId));
        assertEq(nft.ownerOf(sold), COLLECTOR);
        uint256 huntFee = HUNT_OFFER * HUNT_FEE_BPS / hunt.FEE_DENOMINATOR();
        assertEq(hunt.credit(BOB), HUNT_OFFER - huntFee);
        assertEq(hunt.credit(FEE_SINK), huntFee);
        assertEq(hunt.totalEscrowed(), 0);

        // 3. The new owner mines a fresh NFT and escrows it into DirectLoan.
        uint256 pledged = _win(COLLECTOR);
        assertEq(pledged, 2);
        loanAsset.mint(LENDER, 1_000 ether);
        loanAsset.mint(COLLECTOR, 1_000 ether);
        vm.prank(LENDER);
        loanAsset.approve(address(loan), type(uint256).max);
        vm.prank(COLLECTOR);
        loanAsset.approve(address(loan), type(uint256).max);

        vm.prank(COLLECTOR);
        nft.escrowTo(
            pledged,
            address(loan),
            abi.encode(
                DirectLoan.Terms({
                    version: 1, principal: LOAN_PRINCIPAL, repayment: LOAN_REPAYMENT, duration: LOAN_DURATION
                })
            )
        );
        uint256 loanId = loan.loanIdByToken(pledged);
        assertEq(nft.ownerOf(pledged), address(loan));
        assertTrue(nft.isEncumbered(pledged));

        vm.prank(LENDER);
        loan.fund(loanId);
        assertEq(uint8(loan.getLoan(loanId).status), uint8(DirectLoan.Status.Funded));
        vm.prank(COLLECTOR);
        loan.depositRepayment(loanId, LOAN_REPAYMENT);
        assertEq(uint8(loan.getLoan(loanId).status), uint8(DirectLoan.Status.Repaid));
        loan.claimNft(loanId);
        assertEq(nft.ownerOf(pledged), COLLECTOR);
        assertFalse(nft.isEncumbered(pledged));
        uint256 lenderBefore = loanAsset.balanceOf(LENDER);
        loan.claimLender(LENDER);
        assertEq(loanAsset.balanceOf(LENDER), lenderBefore + LOAN_REPAYMENT);

        // 4. Burn: the lifecycle ends the member and records the beneficiary.
        _burn(pledged);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, pledged));
        nft.ownerOf(pledged);
        assertEq(lifecycle.finalBeneficiary(pledged), COLLECTOR);
        WeightedHistory.Member memory m = lifecycle.currentMember(pledged);
        assertFalse(m.alive);
        assertTrue(vault.settled(pledged));
        assertEq(lifecycle.finalBeneficiary(sold), address(0)); // the sold NFT is still live
        assertEq(nft.mintedEver(), 2);
        assertEq(core.acceptedProofs(), 2);
        assertEq(core.nftsMintedEver(), 2);
        _assertBooks();
    }

    /// @notice The old custody attaches through the real setter, sees a real
    /// proof, detaches non-terminally, and its unassigned stake stays
    /// withdrawable while assigned stake keeps its unlock delay.
    function testHarnessOldCustodyAttachesAndDetaches() public {
        assertFalse(oldCustody.wired());
        _attach(IMiningPower(address(oldCustody)));
        assertTrue(oldCustody.wired());
        assertFalse(oldCustody.retired());
        assertEq(oldCustody.latestChallengeId(), core.activeChallengeId());
        assertEq(oldCustody.lastAcceptedProofs(), 0);

        token.mint(ALICE, 10_000e18);
        vm.startPrank(ALICE);
        token.approve(address(oldCustody), type(uint256).max);
        oldCustody.deposit(10_000e18);
        oldCustody.assign(MINER, 3_000e18);
        vm.stopPrank();
        assertEq(oldCustody.assignedOf(MINER), 3_000e18);
        _assertBooks();

        // One real proof through the wired module (pending stake -> 1x).
        uint256 id = _win(MINER);
        assertEq(id, 1);
        assertEq(oldCustody.lastAcceptedProofs(), 1);
        assertEq(oldCustody.latestChallengeId(), 2);
        assertEq(oldCustody.snapshottedLockedAmount(1, MINER), 0);

        _detach();
        assertFalse(oldCustody.wired());
        assertFalse(oldCustody.retired()); // non-terminal detach

        // Assigned stake keeps its proof-count delay after a non-terminal detach.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, 12, 1));
        oldCustody.unassign(MINER, 3_000e18);
        // No new assignments on an unwired custody.
        vm.prank(ALICE);
        vm.expectRevert(MiningPowerCustody.NotWired.selector);
        oldCustody.assign(MINER, 1);

        // Unassigned stake is always withdrawable.
        vm.prank(ALICE);
        oldCustody.withdraw(7_000e18);
        assertEq(token.balanceOf(ALICE), 7_000e18);
        assertEq(oldCustody.totalLocked(), 3_000e18);
        assertEq(oldCustody.assignedOf(MINER), 3_000e18);
        _assertBooks();

        // Mining continues module-free after the detach.
        assertEq(_win(BOB), 2);
        assertEq(oldCustody.lastAcceptedProofs(), 1); // detached module sees no hooks

        // Re-attach toggles `wired` back on (old custody allows a rewire only
        // while it retains no assignments — ALICE's stake blocks it).
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.RetainedAssignments.selector, 3_000e18));
        core.setMiningPower(IMiningPower(address(oldCustody)));
        assertFalse(oldCustody.wired());
    }
}

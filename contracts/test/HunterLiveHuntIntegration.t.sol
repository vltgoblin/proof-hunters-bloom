// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

// TEST-ONLY regression file. Not production code.
//
// M2.4 actual-assembly integration: the REAL Hunter composition assembled by
// LifecycleTestBase (HunterNFT + HunterLifecycle + HunterReserveVault +
// WeightedRoundLedger + HunterBackingVault + BasketRegistry) wired to a REAL
// LiveHunt through the narrow ILiveHuntNFT boundary. Every offer, duration,
// reserve, backing and fee figure below is a constructor-valid TEST-ONLY
// fixture value — this file chooses no launch parameter. B1 scope only: the
// fully funded sale carrying every attached right, exact truncated-fee and
// seller-proceeds pull credits, and the collector-only cancellation refund.
// B2 extends this same file with the failed-collector and custody-restriction
// cases.

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {LiveHunt} from "../src/LiveHunt.sol";
import {ILiveHuntNFT} from "../src/ILiveHuntNFT.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterBackingVault} from "../src/bloom/HunterBackingVault.sol";
import {WeightedRoundMaterialisation} from "../src/bloom/WeightedRoundMaterialisation.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @dev TEST-ONLY collector fixture: escrows a real offer like any collector
/// wallet, but its ERC721 receiver hook refuses the token until acceptance is
/// switched on — exercising the fill's atomic rollback and exact retry.
contract ToggleCollector is IERC721Receiver {
    error ReceiptRejected();

    LiveHunt public immutable hunt;
    bool public accepting;

    constructor(LiveHunt hunt_) {
        hunt = hunt_;
    }

    function post(uint256 offer) external returns (uint256 huntId) {
        LiveHunt.Criteria memory criteria;
        criteria.artVersion = 1;
        huntId = hunt.createHunt{value: offer}(criteria, hunt.MIN_HUNT_DURATION());
    }

    function setAccepting(bool accepting_) external {
        accepting = accepting_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (!accepting) revert ReceiptRejected();
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract HunterLiveHuntIntegrationTest is LifecycleTestBase {
    // Every constant below is a TEST-ONLY fixture inside the contract's own
    // constructor/domain ranges; none of them is a launch decision.
    uint256 private constant TEST_ONLY_MIN_OFFER = 0.005 ether;
    uint256 private constant TEST_ONLY_MIN_DURATION = 1 days;
    uint256 private constant TEST_ONLY_MAX_DURATION = 90 days;
    uint256 private constant TEST_ONLY_FEE_BPS = 250; // TEST-ONLY rate, not a launch fee choice
    uint256 private constant TEST_ONLY_MAX_FEE_BPS = 500;
    address private constant TEST_ONLY_FEE_RECIPIENT = address(0xFEE5);
    address private constant TEST_ONLY_STOP_MULTISIG = address(0x5709);

    uint256 private constant TEST_ONLY_HUNTER_RESERVE = 50;
    uint256 private constant TEST_ONLY_OWNER_BACKING = 30;
    uint256 private constant TEST_ONLY_ROUND_UNITS = 100;
    uint256 private constant TEST_ONLY_ASSERTED_INCOME = 2_000;
    // The offer times the fee is not a clean multiple of the denominator, so
    // the truncated remainder is real and observable.
    uint256 private constant TEST_ONLY_OFFER = 0.01 ether + 3;
    uint256 private constant TEST_ONLY_OFFER_B = 0.02 ether + 11;

    uint32 private constant DAY_ONE = 1;
    uint256 private constant DAY_ONE_CUTOFF = 86_400;

    address private constant CAROL = address(0xCA401);

    ReserveTokenFixture private basketToken;

    /// @notice A fully funded sale settles the NFT, every attached right and
    /// both pull credits exactly, then the buyer materialises the pre-sale
    /// frozen day and burns once for the exact combined payout.
    function testFundedSaleCarriesAttachedValueAndSettlesByPullCredit() public {
        uint256 id = _seedAttachedPosition();
        LiveHunt hunt = _deployHunt();
        uint256 huntId = _postOffer(hunt, BOB, TEST_ONLY_OFFER);
        assertTrue(hunt.matches(id, huntId));

        _fillAndAssertCarry(hunt, huntId, id);
        _assertCreditsAndIndependentClaims(hunt);
        _materialiseAndBurnAsBuyer(id);
    }

    /// @notice An open offer is cancellable only by its recorded collector;
    /// cancellation moves the WHOLE offer into pull credit and each claim
    /// rail refunds the exact ETH amount exactly once.
    function testCollectorOnlyCancellationRefundsWholeOfferByPullCredit() public {
        LiveHunt hunt = _deployHunt();
        uint256 huntIdA = _postOffer(hunt, CAROL, TEST_ONLY_OFFER);
        uint256 huntIdB = _postOffer(hunt, CAROL, TEST_ONLY_OFFER_B);

        // Only the recorded collector can cancel — no other wallet.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiveHunt.NotHuntCollector.selector, ALICE, huntIdA, CAROL));
        hunt.withdrawOffer(huntIdA);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LiveHunt.NotHuntCollector.selector, BOB, huntIdA, CAROL));
        hunt.withdrawOffer(huntIdA);
        assertEq(hunt.totalEscrowed(), TEST_ONLY_OFFER + TEST_ONLY_OFFER_B);
        assertEq(hunt.totalCredited(), 0);
        assertEq(hunt.credit(CAROL), 0);

        // Rail 1: withdrawOffer records the WHOLE offer as collector credit.
        vm.prank(CAROL);
        hunt.withdrawOffer(huntIdA);
        LiveHunt.Hunt memory cancelled = _readHunt(hunt, huntIdA);
        assertEq(uint256(cancelled.status), uint256(LiveHunt.HuntStatus.Cancelled));
        assertEq(cancelled.collector, CAROL);
        assertEq(cancelled.offer, TEST_ONLY_OFFER);
        assertEq(hunt.credit(CAROL), TEST_ONLY_OFFER);
        assertEq(hunt.totalEscrowed(), TEST_ONLY_OFFER_B);
        assertEq(hunt.totalCredited(), TEST_ONLY_OFFER);

        // claim() then refunds the exact ETH amount and cannot repeat.
        uint256 carolBefore = CAROL.balance;
        vm.prank(CAROL);
        hunt.claim();
        assertEq(CAROL.balance - carolBefore, TEST_ONLY_OFFER);
        assertEq(hunt.credit(CAROL), 0);
        assertEq(hunt.totalCredited(), 0);
        assertEq(hunt.totalEscrowed(), TEST_ONLY_OFFER_B);
        assertEq(address(hunt).balance, TEST_ONLY_OFFER_B);

        // Rail 2: the combined withdrawOfferAndClaim wrapper refunds the
        // exact amount through the same caller-only pull path.
        carolBefore = CAROL.balance;
        vm.prank(CAROL);
        hunt.withdrawOfferAndClaim(huntIdB);
        assertEq(CAROL.balance - carolBefore, TEST_ONLY_OFFER_B);
        assertEq(uint256(_readHunt(hunt, huntIdB).status), uint256(LiveHunt.HuntStatus.Cancelled));
        assertEq(hunt.credit(CAROL), 0);
        assertEq(hunt.totalEscrowed(), 0);
        assertEq(hunt.totalCredited(), 0);
        assertEq(address(hunt).balance, 0);

        // Every liability is closed: repeat withdrawal and claim both fail.
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(LiveHunt.HuntNotOpen.selector, huntIdA, LiveHunt.HuntStatus.Cancelled));
        hunt.withdrawOffer(huntIdA);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(LiveHunt.HuntNotOpen.selector, huntIdB, LiveHunt.HuntStatus.Cancelled));
        hunt.withdrawOfferAndClaim(huntIdB);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(LiveHunt.NoCredit.selector, CAROL));
        hunt.claim();
    }

    /// @notice A collector whose receiver hook rejects the token aborts the
    /// fill atomically — the token and every attached right stay exactly with
    /// the seller and the whole offer stays escrowed — and the identical fill
    /// settles exactly once the collector accepts the receipt.
    function testRejectedReceiptRollsBackFillThenRetrySettlesExactly() public {
        uint256 id = _seedAttachedPosition();
        LiveHunt hunt = _deployHunt();
        ToggleCollector collector = new ToggleCollector(hunt);
        vm.deal(address(collector), TEST_ONLY_OFFER);
        uint256 huntId = collector.post(TEST_ONLY_OFFER);

        // Open hunt, whole offer escrowed, nothing credited yet.
        LiveHunt.Hunt memory open = _readHunt(hunt, huntId);
        assertEq(uint256(open.status), uint256(LiveHunt.HuntStatus.Open));
        assertEq(open.collector, address(collector));
        assertEq(open.offer, TEST_ONLY_OFFER);
        assertEq(hunt.totalEscrowed(), TEST_ONLY_OFFER);
        assertEq(hunt.totalCredited(), 0);
        assertEq(hunt.credit(ALICE), 0);
        assertEq(hunt.credit(TEST_ONLY_FEE_RECIPIENT), 0);
        assertEq(address(hunt).balance, TEST_ONLY_OFFER);

        // Pre-fill baseline: minted at ALICE, never transferred, the funded
        // day-1 right unconsumed and every attached value in place.
        assertEq(nft.authorizationNonce(id), 1);
        assertFalse(canonicalBacking.consumed(DAY_ONE, id));
        _assertAttachedState(id, ALICE);

        // The collector rejects the receipt: the whole fill reverts raw.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ToggleCollector.ReceiptRejected.selector));
        nft.safeTransferFrom(ALICE, address(hunt), id, abi.encode(huntId));

        // Full rollback — owner, nonce, birth data and every attached right
        // are exactly as before the attempt; the hunt is still Open holding
        // the full offer with zero credits anywhere.
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.authorizationNonce(id), 1);
        (uint32 artVersion, bytes32 proofDigest, uint256 challengeId, uint8 proofTier) = nft.birthData(id);
        assertEq(artVersion, 1);
        assertEq(proofDigest, bytes32(0));
        assertEq(challengeId, 0);
        assertEq(proofTier, 1);
        _assertAttachedState(id, ALICE);
        LiveHunt.Hunt memory stillOpen = _readHunt(hunt, huntId);
        assertEq(uint256(stillOpen.status), uint256(LiveHunt.HuntStatus.Open));
        assertEq(stillOpen.collector, address(collector));
        assertEq(stillOpen.offer, TEST_ONLY_OFFER);
        assertEq(hunt.totalEscrowed(), TEST_ONLY_OFFER);
        assertEq(hunt.totalCredited(), 0);
        assertEq(hunt.credit(ALICE), 0);
        assertEq(hunt.credit(TEST_ONLY_FEE_RECIPIENT), 0);
        assertEq(hunt.credit(address(collector)), 0);
        assertEq(address(hunt).balance, TEST_ONLY_OFFER);

        // Acceptance enabled: the identical fill settles exactly as in B1.
        collector.setAccepting(true);
        vm.prank(ALICE);
        nft.safeTransferFrom(ALICE, address(hunt), id, abi.encode(huntId));
        assertEq(nft.ownerOf(id), address(collector));
        assertEq(nft.authorizationNonce(id), 3);
        LiveHunt.Hunt memory filled = _readHunt(hunt, huntId);
        assertEq(uint256(filled.status), uint256(LiveHunt.HuntStatus.Filled));
        assertEq(filled.collector, address(collector));
        assertEq(filled.offer, TEST_ONLY_OFFER);
        _assertAttachedState(id, address(collector));
        uint256 fee = TEST_ONLY_OFFER * TEST_ONLY_FEE_BPS / hunt.FEE_DENOMINATOR();
        assertEq(hunt.totalEscrowed(), 0);
        assertEq(hunt.totalCredited(), TEST_ONLY_OFFER);
        assertEq(hunt.credit(ALICE), TEST_ONLY_OFFER - fee);
        assertEq(hunt.credit(TEST_ONLY_FEE_RECIPIENT), fee);
        assertEq(hunt.credit(address(collector)), 0);
        assertEq(address(hunt).balance, TEST_ONLY_OFFER);
    }

    /// @notice A credit-locked token cannot be sold into a hunt: the owner's
    /// own transfer reverts CreditLocked, the lock pins every attached value
    /// in place, the real lifecycle unlock restores owner-held custody with
    /// the exact nonce, and the untouched open offer refunds in full.
    function testCreditLockedTokenCannotFillAndOfferRefundsExactly() public {
        uint256 id = _seedAttachedPosition();
        LiveHunt hunt = _deployHunt();
        uint256 huntId = _postOffer(hunt, BOB, TEST_ONLY_OFFER);
        _assertHuntOpenEscrowed(hunt, huntId, BOB, TEST_ONLY_OFFER);

        // The real module entry point locks the token's credit against the
        // TEST-ONLY escrow fixture position, consuming authorization nonce 1.
        uint256 nonce = nft.authorizationNonce(id);
        assertEq(nonce, 1);
        vm.prank(address(lc));
        nft.lockCredit(id, address(escrow), ALICE, nonce);

        // Locked: the owner is unchanged but the position is recorded, the
        // count rises and custody flips — yet no attached value moves.
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.creditPositionOf(id), address(escrow));
        assertEq(nft.authorizationNonce(id), 2);
        assertEq(uint256(nft.custody(id)), uint256(HunterNFT.Custody.CreditLocked));
        assertTrue(nft.isEncumbered(id));
        assertEq(nft.activeCreditCount(ALICE), 1);
        _assertAttachedValues(id);

        // The sale cannot even start: the transfer hook reverts CreditLocked
        // and the whole attempt rolls back — token, lock and hunt unchanged.
        uint256 aliceHunter = token.balanceOf(ALICE);
        uint256 aliceBasket = basketToken.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.CreditLocked.selector, id));
        nft.safeTransferFrom(ALICE, address(hunt), id, abi.encode(huntId));

        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.creditPositionOf(id), address(escrow));
        assertEq(nft.authorizationNonce(id), 2);
        assertEq(uint256(nft.custody(id)), uint256(HunterNFT.Custody.CreditLocked));
        assertTrue(nft.isEncumbered(id));
        assertEq(nft.activeCreditCount(ALICE), 1);
        _assertAttachedValues(id);
        assertEq(token.balanceOf(ALICE), aliceHunter);
        assertEq(basketToken.balanceOf(ALICE), aliceBasket);
        assertEq(token.balanceOf(address(hunt)), 0);
        assertEq(basketToken.balanceOf(address(hunt)), 0);
        _assertHuntOpenEscrowed(hunt, huntId, BOB, TEST_ONLY_OFFER);

        // The module lifts the lock with the exact current nonce: position
        // and count clear, custody returns to owner-held, values untouched.
        assertEq(nft.authorizationNonce(id), 2);
        vm.prank(address(lc));
        nft.unlockCredit(id, address(escrow), 2);
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.creditPositionOf(id), address(0));
        assertEq(nft.authorizationNonce(id), 3);
        assertEq(nft.activeCreditCount(ALICE), 0);
        _assertAttachedState(id, ALICE);

        // The never-touched offer still refunds the whole amount exactly once.
        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        hunt.withdrawOfferAndClaim(huntId);
        assertEq(BOB.balance - bobBefore, TEST_ONLY_OFFER);
        assertEq(uint256(_readHunt(hunt, huntId).status), uint256(LiveHunt.HuntStatus.Cancelled));
        assertEq(hunt.credit(BOB), 0);
        assertEq(hunt.credit(ALICE), 0);
        assertEq(hunt.credit(TEST_ONLY_FEE_RECIPIENT), 0);
        assertEq(hunt.totalEscrowed(), 0);
        assertEq(hunt.totalCredited(), 0);
        assertEq(address(hunt).balance, 0);
    }

    /// @notice A token released from escrow inside this same transaction
    /// cannot fill a hunt: the receiver guard reverts
    /// TokenReleasedThisTransaction, the release returns the token to
    /// owner-held custody with every attached value exact, and the open
    /// offer still refunds the collector in full.
    function testSameTransactionEscrowReleaseCannotFillAndOfferRefundsExactly() public {
        uint256 id = _seedAttachedPosition();
        LiveHunt hunt = _deployHunt();
        uint256 huntId = _postOffer(hunt, BOB, TEST_ONLY_OFFER);
        _assertHuntOpenEscrowed(hunt, huntId, BOB, TEST_ONLY_OFFER);

        // Owner-directed escrow entry: the fixture takes custody of the
        // token, the nonce steps to 2 and no attached value moves.
        vm.prank(ALICE);
        nft.escrowTo(id, address(escrow), "");
        assertEq(nft.ownerOf(id), address(escrow));
        assertEq(nft.escrowedTo(id), address(escrow));
        assertEq(nft.authorizationNonce(id), 2);
        assertEq(uint256(nft.custody(id)), uint256(HunterNFT.Custody.Escrowed));
        assertTrue(nft.isEncumbered(id));
        _assertAttachedValues(id);

        // The escrow releases back to ALICE inside this same transaction: the
        // transient release flag is raised as custody returns to owner-held.
        escrow.release(IERC721(address(nft)), id, ALICE);
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.escrowedTo(id), address(0));
        assertEq(nft.authorizationNonce(id), 3);
        assertEq(uint256(nft.custody(id)), uint256(HunterNFT.Custody.OwnerHeld));
        assertFalse(nft.isEncumbered(id));
        assertTrue(nft.wasReleasedThisTransaction(id));
        _assertAttachedState(id, ALICE);

        // The immediate fill is refused by the same-transaction guard: the
        // whole transfer rolls back, so the nonce stays 3, ALICE stays
        // owner-held with every attached value, and the hunt is untouched.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiveHunt.TokenReleasedThisTransaction.selector, id));
        nft.safeTransferFrom(ALICE, address(hunt), id, abi.encode(huntId));

        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.escrowedTo(id), address(0));
        assertEq(nft.authorizationNonce(id), 3);
        assertTrue(nft.wasReleasedThisTransaction(id));
        _assertAttachedState(id, ALICE);
        _assertHuntOpenEscrowed(hunt, huntId, BOB, TEST_ONLY_OFFER);

        // The still-open offer refunds the whole escrowed amount exactly once.
        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        hunt.withdrawOfferAndClaim(huntId);
        assertEq(BOB.balance - bobBefore, TEST_ONLY_OFFER);
        assertEq(uint256(_readHunt(hunt, huntId).status), uint256(LiveHunt.HuntStatus.Cancelled));
        assertEq(hunt.credit(BOB), 0);
        assertEq(hunt.credit(ALICE), 0);
        assertEq(hunt.credit(TEST_ONLY_FEE_RECIPIENT), 0);
        assertEq(hunt.totalEscrowed(), 0);
        assertEq(hunt.totalCredited(), 0);
        assertEq(address(hunt).balance, 0);
    }

    /// @dev Mint, TEST-ONLY reserve deposit and owner backing all land strictly
    /// before the real 00:00 UTC day-1 cutoff, then the day-1 round is
    /// recorded, frozen and funded with 100 basketA units through the actual
    /// fixture ERC20 pull — the member right stays funded but UNMATERIALISED.
    function _seedAttachedPosition() private returns (uint256 id) {
        basketToken = ReserveTokenFixture(basketA);
        basketToken.setVault(address(canonicalBacking));

        vm.warp(DAY_ONE_CUTOFF - 1);
        id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, TEST_ONLY_HUNTER_RESERVE), TEST_ONLY_HUNTER_RESERVE);

        basketToken.mint(ALICE, TEST_ONLY_OWNER_BACKING);
        vm.prank(ALICE);
        basketToken.approve(address(canonicalBacking), type(uint256).max);
        vm.prank(ALICE);
        assertEq(canonicalBacking.depositOwnerBacking(id, TEST_ONLY_OWNER_BACKING), TEST_ONLY_OWNER_BACKING);

        basketToken.mint(address(this), TEST_ONLY_ROUND_UNITS);
        basketToken.approve(address(canonicalBacking), type(uint256).max);
        vm.warp(DAY_ONE_CUTOFF);
        canonicalLedger.recordRound(DAY_ONE, bytes32(uint256(DAY_ONE)), TEST_ONLY_ASSERTED_INCOME);
        canonicalLedger.freezeGroup(DAY_ONE, basketA);
        canonicalBacking.fund(DAY_ONE, basketA, TEST_ONLY_ROUND_UNITS);

        _assertAttachedState(id, ALICE);
    }

    /// @dev The REAL LiveHunt bound to the narrow NFT interface; all values
    /// are TEST-ONLY fixtures inside the constructor's accepted ranges.
    function _deployHunt() private returns (LiveHunt hunt) {
        hunt = new LiveHunt(
            ILiveHuntNFT(address(nft)),
            TEST_ONLY_MIN_OFFER,
            TEST_ONLY_MIN_DURATION,
            TEST_ONLY_MAX_DURATION,
            TEST_ONLY_FEE_BPS,
            TEST_ONLY_MAX_FEE_BPS,
            TEST_ONLY_FEE_RECIPIENT,
            TEST_ONLY_STOP_MULTISIG,
            block.timestamp + 360 days
        );
        assertEq(address(hunt.PROOF_NFT()), address(nft));
        assertEq(hunt.FEE_BPS(), TEST_ONLY_FEE_BPS);
        assertEq(hunt.MAX_FEE_BPS(), TEST_ONLY_MAX_FEE_BPS);
        assertEq(hunt.FEE_RECIPIENT(), TEST_ONLY_FEE_RECIPIENT);
        assertEq(hunt.MIN_OFFER(), TEST_ONLY_MIN_OFFER);
    }

    /// @dev A matching fully funded offer: criteria artVersion 1 with every
    /// mask zero accepts this token; the whole offer escrows at creation.
    function _postOffer(LiveHunt hunt, address collector, uint256 offer) private returns (uint256 huntId) {
        LiveHunt.Criteria memory criteria;
        criteria.artVersion = 1;
        uint256 escrowedBefore = hunt.totalEscrowed();
        uint256 balanceBefore = address(hunt).balance;
        vm.deal(collector, offer);
        vm.prank(collector);
        huntId = hunt.createHunt{value: offer}(criteria, TEST_ONLY_MIN_DURATION);
        assertEq(hunt.totalEscrowed(), escrowedBefore + offer);
        assertEq(address(hunt).balance, balanceBefore + offer);
    }

    /// @dev Snapshot of the exact attached-value state shared by the pre-sale
    /// and post-fill checks: reserve, owner backing, funded unconsumed right,
    /// lifecycle membership and the strictly-before cutoff history.
    function _assertAttachedState(uint256 id, address owner) private {
        assertEq(nft.ownerOf(id), owner);
        assertEq(nft.basketOf(id), basketA);
        assertFalse(nft.isEncumbered(id));
        assertEq(uint256(nft.custody(id)), uint256(HunterNFT.Custody.OwnerHeld));
        _assertMemberEq(lc.currentMember(id), basketA, 100, TEST_ONLY_HUNTER_RESERVE, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, TEST_ONLY_HUNTER_RESERVE, 1);
        _assertTotalsEq(lc.currentBasket(basketA), 100, TEST_ONLY_HUNTER_RESERVE, 1);
        _assertMemberEq(lc.memberBefore(id, DAY_ONE_CUTOFF), basketA, 100, TEST_ONLY_HUNTER_RESERVE, true, true);
        assertEq(lc.firstEligibleDay(id), DAY_ONE);
        assertEq(lc.finalBeneficiary(id), address(0));

        assertEq(vault.reserveOf(id), TEST_ONLY_HUNTER_RESERVE);
        assertEq(vault.totalReserved(), TEST_ONLY_HUNTER_RESERVE);
        assertFalse(vault.settled(id));
        assertEq(token.balanceOf(address(vault)), TEST_ONLY_HUNTER_RESERVE);

        assertEq(canonicalBacking.ownerBackingOf(id), TEST_ONLY_OWNER_BACKING);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), TEST_ONLY_OWNER_BACKING);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertFalse(canonicalBacking.consumed(DAY_ONE, id));
        assertEq(canonicalBacking.totalReceived(basketA), TEST_ONLY_ROUND_UNITS);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalBackingOf(id), TEST_ONLY_OWNER_BACKING);
    }

    /// @dev The custody-independent half of _assertAttachedState: every
    /// attached value — reserve, owner backing, the funded unconsumed day-1
    /// right, lifecycle membership and pre-cutoff history — asserted without
    /// the owner or encumbrance lines so it holds verbatim while the token is
    /// escrowed or credit-locked.
    function _assertAttachedValues(uint256 id) private {
        assertEq(nft.basketOf(id), basketA);
        _assertMemberEq(lc.currentMember(id), basketA, 100, TEST_ONLY_HUNTER_RESERVE, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, TEST_ONLY_HUNTER_RESERVE, 1);
        _assertTotalsEq(lc.currentBasket(basketA), 100, TEST_ONLY_HUNTER_RESERVE, 1);
        _assertMemberEq(lc.memberBefore(id, DAY_ONE_CUTOFF), basketA, 100, TEST_ONLY_HUNTER_RESERVE, true, true);
        assertEq(lc.firstEligibleDay(id), DAY_ONE);
        assertEq(lc.finalBeneficiary(id), address(0));

        assertEq(vault.reserveOf(id), TEST_ONLY_HUNTER_RESERVE);
        assertEq(vault.totalReserved(), TEST_ONLY_HUNTER_RESERVE);
        assertFalse(vault.settled(id));
        assertEq(token.balanceOf(address(vault)), TEST_ONLY_HUNTER_RESERVE);

        assertEq(canonicalBacking.ownerBackingOf(id), TEST_ONLY_OWNER_BACKING);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), TEST_ONLY_OWNER_BACKING);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertFalse(canonicalBacking.consumed(DAY_ONE, id));
        assertEq(canonicalBacking.totalReceived(basketA), TEST_ONLY_ROUND_UNITS);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalBackingOf(id), TEST_ONLY_OWNER_BACKING);
    }

    /// @dev The open-hunt invariant a blocked fill must leave behind: status
    /// Open, the WHOLE offer still escrowed, zero credit on every rail and
    /// the full balance retained by the hunt contract.
    function _assertHuntOpenEscrowed(LiveHunt hunt, uint256 huntId, address collector, uint256 offer) private view {
        LiveHunt.Hunt memory record = _readHunt(hunt, huntId);
        assertEq(uint256(record.status), uint256(LiveHunt.HuntStatus.Open));
        assertEq(record.collector, collector);
        assertEq(record.offer, offer);
        assertEq(hunt.totalEscrowed(), offer);
        assertEq(hunt.totalCredited(), 0);
        assertEq(hunt.credit(ALICE), 0);
        assertEq(hunt.credit(collector), 0);
        assertEq(hunt.credit(TEST_ONLY_FEE_RECIPIENT), 0);
        assertEq(address(hunt).balance, offer);
    }

    /// @dev The owner fills through the real safe-transfer receiver path and
    /// the SAME tokenId lands on the collector with every attached right
    /// exact; no HUNTER or basket token moves during the sale.
    function _fillAndAssertCarry(LiveHunt hunt, uint256 huntId, uint256 id) private {
        uint256 aliceHunter = token.balanceOf(ALICE);
        uint256 aliceBasket = basketToken.balanceOf(ALICE);
        uint256 vaultHunter = token.balanceOf(address(vault));
        uint256 custodyBasket = basketToken.balanceOf(address(canonicalBacking));

        vm.prank(ALICE);
        nft.safeTransferFrom(ALICE, address(hunt), id, abi.encode(huntId));

        // The collector receives the same tokenId with untouched identity.
        assertEq(nft.ownerOf(id), BOB);
        (uint32 artVersion, bytes32 proofDigest, uint256 challengeId, uint8 proofTier) = nft.birthData(id);
        assertEq(artVersion, 1);
        assertEq(proofDigest, bytes32(0));
        assertEq(challengeId, 0);
        assertEq(proofTier, 1);
        // Mint plus two real sale hops: 1 -> 2 (owner -> module) -> 3 (module -> buyer).
        assertEq(nft.authorizationNonce(id), 3);
        LiveHunt.Hunt memory filled = _readHunt(hunt, huntId);
        assertEq(uint256(filled.status), uint256(LiveHunt.HuntStatus.Filled));
        assertEq(filled.collector, BOB);
        assertEq(filled.offer, TEST_ONLY_OFFER);

        // Every attached right rides along on the tokenId, unchanged.
        _assertAttachedState(id, BOB);

        // No HUNTER or basket token moved during the sale — not to the seller,
        // the buyer or the module.
        assertEq(token.balanceOf(ALICE), aliceHunter);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(basketToken.balanceOf(ALICE), aliceBasket);
        assertEq(basketToken.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(vault)), vaultHunter);
        assertEq(basketToken.balanceOf(address(canonicalBacking)), custodyBasket);
        assertEq(token.balanceOf(address(hunt)), 0);
        assertEq(basketToken.balanceOf(address(hunt)), 0);
    }

    /// @dev Exact truncated fee, seller proceeds credit, full-offer credit
    /// conservation and two independent pull claims with no repeat credit.
    function _assertCreditsAndIndependentClaims(LiveHunt hunt) private {
        uint256 fee = TEST_ONLY_OFFER * TEST_ONLY_FEE_BPS / hunt.FEE_DENOMINATOR();
        // The fixture really truncates: the raw product has a nonzero remainder.
        assertTrue(TEST_ONLY_OFFER * TEST_ONLY_FEE_BPS % hunt.FEE_DENOMINATOR() != 0);
        uint256 proceeds = TEST_ONLY_OFFER - fee;

        assertEq(hunt.credit(ALICE), proceeds);
        assertEq(hunt.credit(TEST_ONLY_FEE_RECIPIENT), fee);
        assertEq(hunt.credit(BOB), 0);
        assertEq(hunt.totalEscrowed(), 0);
        assertEq(hunt.totalCredited(), TEST_ONLY_OFFER);
        assertEq(address(hunt).balance, TEST_ONLY_OFFER);
        assertEq(proceeds + fee, TEST_ONLY_OFFER);

        // The seller claims independently: exact wallet delta, counters move.
        uint256 aliceBefore = ALICE.balance;
        vm.prank(ALICE);
        hunt.claim();
        assertEq(ALICE.balance - aliceBefore, proceeds);
        assertEq(hunt.credit(ALICE), 0);
        assertEq(hunt.totalCredited(), fee);
        assertEq(address(hunt).balance, fee);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiveHunt.NoCredit.selector, ALICE));
        hunt.claim();

        // The fee recipient claims independently with the same exactness.
        uint256 feeBefore = TEST_ONLY_FEE_RECIPIENT.balance;
        vm.prank(TEST_ONLY_FEE_RECIPIENT);
        hunt.claim();
        assertEq(TEST_ONLY_FEE_RECIPIENT.balance - feeBefore, fee);
        assertEq(hunt.credit(TEST_ONLY_FEE_RECIPIENT), 0);
        assertEq(hunt.totalCredited(), 0);
        assertEq(hunt.totalEscrowed(), 0);
        assertEq(address(hunt).balance, 0);
        vm.prank(TEST_ONLY_FEE_RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(LiveHunt.NoCredit.selector, TEST_ONLY_FEE_RECIPIENT));
        hunt.claim();
    }

    /// @dev Post-sale the buyer materialises the pre-sale frozen day into the
    /// same tokenId — the full 100 round units join the 30 owner units — then
    /// burns once for exactly 50 HUNTER + 130 basketA. The former owner can
    /// neither burn nor claim any attached asset; the right is consumed once.
    function _materialiseAndBurnAsBuyer(uint256 id) private {
        vm.prank(BOB);
        canonicalBacking.materialise(DAY_ONE, id);
        assertTrue(canonicalBacking.consumed(DAY_ONE, id));
        assertEq(canonicalBacking.backingOf(id), TEST_ONLY_ROUND_UNITS);
        assertEq(canonicalBacking.totalBackingOf(id), TEST_ONLY_ROUND_UNITS + TEST_ONLY_OWNER_BACKING);

        // The former owner holds no burn authority over the sold tokenId.
        vm.prank(ALICE);
        vm.expectRevert(HunterNFT.NotTokenOwner.selector);
        nft.redeemAndDestroy(id);

        vm.prank(BOB);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(BOB), TEST_ONLY_HUNTER_RESERVE);
        assertEq(basketToken.balanceOf(BOB), TEST_ONLY_ROUND_UNITS + TEST_ONLY_OWNER_BACKING);
        assertEq(lc.finalBeneficiary(id), BOB);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, false, false);
        _assertTotalsEq(lc.currentGlobal(), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);

        // Source ledgers and counters settle exactly.
        assertTrue(vault.settled(id));
        assertEq(vault.reserveOf(id), 0);
        assertEq(vault.totalReserved(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertTrue(canonicalBacking.burnSettled(id));
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 0);
        assertEq(canonicalBacking.totalBackingOf(id), 0);
        assertEq(canonicalBacking.totalReleased(basketA), TEST_ONLY_ROUND_UNITS);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), TEST_ONLY_OWNER_BACKING);
        assertEq(basketToken.balanceOf(address(canonicalBacking)), 0);

        // The frozen right was consumed exactly once — as a materialisation
        // for the buyer and as a late claim alike — and the burned id cannot
        // be materialised again.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundMaterialisation.AlreadyConsumed.selector, DAY_ONE, id));
        canonicalBacking.claimBurned(DAY_ONE, id);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.UnauthorizedBeneficiary.selector, id));
        canonicalBacking.claimBurned(DAY_ONE, id);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundMaterialisation.NotLive.selector, id));
        canonicalBacking.materialise(DAY_ONE, id);
        vm.prank(BOB);
        vm.expectRevert();
        nft.redeemAndDestroy(id);

        // No attached asset ever reached the seller through sale or burn.
        assertEq(token.balanceOf(ALICE), 950);
        assertEq(basketToken.balanceOf(ALICE), 0);
    }

    function _readHunt(LiveHunt hunt, uint256 huntId) private view returns (LiveHunt.Hunt memory record) {
        (record.id, record.collector, record.offer, record.createdAt, record.deadline, record.status, record.criteria) =
            hunt.hunts(huntId);
    }
}

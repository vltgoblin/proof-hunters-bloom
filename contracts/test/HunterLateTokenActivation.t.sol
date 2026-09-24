// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {HunterBackingVault} from "../src/bloom/HunterBackingVault.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {SwitchConverterFixture} from "./HunterBasketSwitch.t.sol";
import {ReserveTokenFixture, ReserveEscrowFixture} from "./helpers/HunterReserveFixtures.sol";

/// @dev TEST-ONLY non-ERC20 contract: has bytecode but no token surface, so the
/// `activateToken` ERC-20 probes must reject it.
contract NotATokenContract {
    function notToken() external pure returns (bool) {
        return true;
    }
}

/// @notice Mine-first / token-later acceptance on the REAL assembled stack:
/// canonical HunterNFT <-> HunterLifecycle <-> HunterReserveVault plus
/// WeightedRoundLedger and HunterBackingVault, deployed with NO HUNTER token.
/// The reserve's token is activated exactly once mid-life and every amount
/// below (income 1000, deposits 300, funding 500) is a TEST-ONLY value, never
/// a production figure.
contract HunterLateTokenActivationTest is Test {
    using stdStorage for StdStorage;

    HunterLifecycle internal lc;
    WeightedRoundLedger internal ledger;
    HunterBackingVault internal backing;
    HunterReserveVault internal vault;
    HunterNFT internal nft;
    BasketRegistry internal registry;
    ReserveEscrowFixture internal escrow;
    address internal basketA;
    address internal basketB;

    /// @dev The HUNTER token is created LATE inside each test — the whole point
    /// is that the stack exists and operates before it.
    ReserveTokenFixture internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant LAUNCH = address(0x1A04C);
    address internal constant ROYALTIES = address(0x2017);

    uint256 internal constant DAY = 86_400;

    function setUp() public virtual {
        vm.warp(100);
        registry = new BasketRegistry(address(this));
        basketA = address(new ReserveTokenFixture());
        basketB = address(new ReserveTokenFixture());
        registry.admitBasket(basketA, keccak256("reviewA"));
        registry.admitBasket(basketB, keccak256("reviewB"));

        uint64 n = vm.getNonce(address(this));
        address wantNft = vm.computeCreateAddress(address(this), n + 4);
        address wantReserve = vm.computeCreateAddress(address(this), n + 3);
        address wantBacking = vm.computeCreateAddress(address(this), n + 2);
        lc = new HunterLifecycle(
            wantNft, wantReserve, wantBacking, [uint64(100), uint64(110), uint64(125), uint64(150)]
        );
        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        backing = new HunterBackingVault(address(ledger), address(this));
        vault = new HunterReserveVault(wantNft, address(lc), LAUNCH);
        nft = new HunterNFT(address(registry), address(lc), 1, ROYALTIES, "");
        assertEq(address(backing), wantBacking);
        assertEq(address(vault), wantReserve);
        assertEq(address(nft), wantNft);
        escrow = new ReserveEscrowFixture();
    }

    function _mint(address to, uint8 tier, address basket_) internal returns (uint256) {
        return nft.mint(to, bytes32(0), nft.mintedEver(), tier, basket_);
    }

    /// @dev Deploys a fresh fixture token and records it through the launch
    /// authority — the only path that may ever set `HUNTER()`.
    function _launchToken() internal returns (ReserveTokenFixture t) {
        t = new ReserveTokenFixture();
        t.setVault(address(vault));
        vm.prank(LAUNCH);
        vault.activateToken(address(t));
    }

    /// @notice Pre-token full journey on the real stack: mine (mint), daily
    /// round + actual backing, escrow, trade, basket switch and burn — every
    /// token-dependent path stays safe and no ERC-20 call to address zero can
    /// ever happen because the vault holds no token reference at all.
    function testPreTokenStackMintsBacksTradesSwitchesEscrowsAndBurns() public {
        assertEq(address(vault.HUNTER()), address(0));
        assertFalse(vault.tokenActivated());
        assertEq(vault.unreservedBalance(), 0);
        assertEq(vault.totalReserved(), 0);

        uint256 idA = _mint(ALICE, 1, basketA); // rarity 100
        uint256 idB = _mint(BOB, 4, basketA); // rarity 150
        assertEq(nft.mintedEver(), 2);

        // Pre-token deposits refuse clearly before any owner/amount handling.
        vm.prank(ALICE);
        vm.expectRevert(HunterReserveVault.TokenNotActivated.selector);
        vault.deposit(idA, 100);
        assertEq(vault.reserveOf(idA), 0);
        assertEq(vault.historyLength(idA), 0);

        // Day-1 round: the cohort's H is zero so rarity gets the full budget.
        vm.warp(DAY + 50);
        ledger.recordRound(1, keccak256("receipt-day1"), 1_000);
        WeightedRoundLedger.Round memory r1 = ledger.round(1);
        assertEq(r1.globalRarity, 250);
        assertEq(r1.globalHunter, 0);
        assertEq(r1.nominalBackingBudget, 500);
        ledger.freezeGroup(1, basketA);
        WeightedRoundLedger.Group memory gA = ledger.group(1, basketA);
        assertEq(gA.rarity, 250);
        assertEq(gA.hunter, 0);
        assertEq(gA.budget, 500);
        assertEq(ledger.unallocated(1), 0);
        assertEq(ledger.memberBudget(1, idA), 200); // floor(500 * 100/250)
        assertEq(ledger.memberBudget(1, idB), 300);

        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assetA.mint(address(this), 500);
        assetA.approve(address(backing), 500);
        backing.fund(1, basketA, 500);
        backing.materialise(1, idA);
        backing.materialise(1, idB);
        assertEq(backing.backingOf(idA), 200);
        assertEq(backing.backingOf(idB), 300);

        // Escrow ("Live Hunt" holder) entry/exit works with no token at all.
        uint256 idC = _mint(ALICE, 1, basketB); // eligible from day 2
        vm.prank(ALICE);
        nft.escrowTo(idC, address(escrow), "");
        assertTrue(nft.isEncumbered(idC));
        assertEq(nft.ownerOf(idC), address(escrow));
        escrow.release(IERC721(address(nft)), idC, ALICE);
        assertEq(nft.ownerOf(idC), ALICE);
        assertFalse(nft.isEncumbered(idC));

        // Trade: the NFT changes wallet mid-life, still pre-token.
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, idA);
        assertEq(nft.ownerOf(idA), BOB);

        // Basket switch with materialised backing through an admitted
        // TEST-ONLY 2:1 converter: 300 basketA -> 600 basketB.
        SwitchConverterFixture converter = new SwitchConverterFixture(2, 1);
        registry.admitConverter(address(converter), keccak256("review-converter"));
        ReserveTokenFixture(basketB).mint(address(converter), 600);

        vm.prank(BOB);
        assertEq(lc.requestSwitch(idB, basketB), 1);
        (uint256 examined, bool ready) = lc.prepareSwitch(idB, 1);
        assertEq(examined, 1);
        assertTrue(ready);
        vm.prank(BOB);
        assertEq(lc.completeSwitch(idB, address(converter), 300, 600, block.timestamp, 1), 600);
        assertEq(nft.basketOf(idB), basketB);
        assertEq(backing.backingOf(idB), 600);
        WeightedHistory.Member memory cur = lc.currentMember(idB);
        assertEq(cur.basket, basketB);
        assertEq(cur.hunter, 0);

        // Burn pays basket backing and settles a zero reserve WITHOUT any
        // token call — the vault has no token to call.
        vm.prank(BOB);
        vm.expectEmit(true, true, false, true, address(vault));
        emit HunterReserveVault.BurnSettled(idA, BOB, 0);
        nft.redeemAndDestroy(idA);
        assertEq(assetA.balanceOf(BOB), 200);
        assertTrue(vault.settled(idA));
        assertEq(vault.totalReserved(), 0);
        assertEq(lc.finalBeneficiary(idA), BOB);

        vm.prank(BOB);
        nft.redeemAndDestroy(idB);
        assertEq(ReserveTokenFixture(basketB).balanceOf(BOB), 600);
        assertTrue(vault.settled(idB));

        // Post-burn historical reads stay valid with no token recorded.
        assertEq(vault.reserveBefore(idA, DAY), 0);
        assertEq(vault.unreservedBalance(), 0);
        assertEq(assetA.balanceOf(address(backing)), 0);
        assertEq(assetA.balanceOf(address(vault)), 0);
    }

    /// @notice The authorized launch account records the canonical token once;
    /// every wrong caller/address fails and nothing can replace or clear it.
    function testActivateTokenBoundariesAndImmutability() public {
        token = new ReserveTokenFixture();

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.UnauthorizedTokenAuthority.selector, BOB));
        vault.activateToken(address(token));

        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.InvalidToken.selector);
        vault.activateToken(address(0));

        address eoa = address(0xBEEF);
        assertEq(eoa.code.length, 0);
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.InvalidToken.selector);
        vault.activateToken(eoa);

        NotATokenContract notToken = new NotATokenContract();
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.InvalidToken.selector);
        vault.activateToken(address(notToken));

        // The wired contracts and the authority itself are never valid tokens.
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.InvalidToken.selector);
        vault.activateToken(address(vault));
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.InvalidToken.selector);
        vault.activateToken(address(nft));
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.InvalidToken.selector);
        vault.activateToken(address(lc));
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.InvalidToken.selector);
        vault.activateToken(LAUNCH);

        vm.prank(LAUNCH);
        vm.expectEmit(true, true, false, true, address(vault));
        emit HunterReserveVault.TokenActivated(address(token), LAUNCH);
        vault.activateToken(address(token));
        assertEq(address(vault.HUNTER()), address(token));
        assertTrue(vault.tokenActivated());

        // Immutable after set: no repeat, no replacement, no clearing — and a
        // non-authority caller can never even reach the token checks.
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.TokenAlreadyActivated.selector);
        vault.activateToken(address(token));
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.TokenAlreadyActivated.selector);
        vault.activateToken(address(0));
        ReserveTokenFixture other = new ReserveTokenFixture();
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.TokenAlreadyActivated.selector);
        vault.activateToken(address(other));
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.UnauthorizedTokenAuthority.selector, BOB));
        vault.activateToken(address(other));
    }

    /// @notice Deposit into an NFT minted BEFORE the token existed: the
    /// recorded day-1 round (H=0) stays rarity-only forever, the deposit only
    /// counts from the first cutoff strictly after credit, and the exact 7/10
    /// split conserves the day-2 budget with zero dust for these values.
    function testDepositIntoPreTokenNftAndExactSeventyThirty() public {
        uint256 idA = _mint(ALICE, 1, basketA); // rarity 100
        uint256 idB = _mint(BOB, 4, basketA); // rarity 150

        // Day-1 is recorded with no token: the rarity-only fallback is frozen.
        vm.warp(DAY + 50);
        ledger.recordRound(1, keccak256("receipt-day1"), 1_000);
        ledger.freezeGroup(1, basketA);
        assertEq(ledger.round(1).globalHunter, 0);
        assertEq(ledger.memberBudget(1, idA), 200);
        assertEq(ledger.memberBudget(1, idB), 300);

        // The token is created later; the SAME NFT ids receive deposits.
        token = _launchToken();
        token.mint(ALICE, 1_000);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);

        uint256 depositTime = block.timestamp; // day 1, strictly after cutoff
        vm.prank(ALICE);
        assertEq(vault.deposit(idA, 300), 300);
        assertEq(vault.reserveOf(idA), 300);
        assertEq(vault.totalReserved(), 300);
        assertEq(vault.historyLength(idA), 1);
        (uint256 ts, uint256 amount) = vault.history(idA, 0);
        assertEq(ts, depositTime);
        assertEq(amount, 300);

        // Strictly-before reads: the deposit is invisible at the day-1 cutoff
        // and at its own timestamp; visible one second later.
        assertEq(vault.reserveBefore(idA, DAY), 0);
        assertEq(vault.reserveBefore(idA, depositTime), 0);

        // Late funding of the recorded pre-token round: the frozen H=0 cohort
        // still pays rarity-only — later deposits can never rewrite history.
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assetA.mint(address(this), 1_000);
        assetA.approve(address(backing), type(uint256).max);
        backing.fund(1, basketA, 500);
        backing.materialise(1, idA);
        backing.materialise(1, idB);
        assertEq(backing.backingOf(idA), 200);
        assertEq(backing.backingOf(idB), 300);

        // Day-2: the deposit matured at the day-2 cutoff — the combined
        // numerator gives the EXACT 70/30 split: N(A)=7*100*300+3*300*250
        // =435000, N(B)=7*150*300=315000, N(global)=750000.
        vm.warp(2 * DAY + 50);
        assertEq(vault.reserveBefore(idA, depositTime + 1), 300);
        ledger.recordRound(2, keccak256("receipt-day2"), 1_000);
        WeightedRoundLedger.Round memory r2 = ledger.round(2);
        assertEq(r2.globalRarity, 250);
        assertEq(r2.globalHunter, 300);
        ledger.freezeGroup(2, basketA);
        WeightedRoundLedger.Group memory g2 = ledger.group(2, basketA);
        assertEq(g2.rarity, 250);
        assertEq(g2.hunter, 300);
        assertEq(g2.budget, 500);
        assertEq(ledger.memberBudget(2, idA), 290); // floor(500*435000/750000)
        assertEq(ledger.memberBudget(2, idB), 210); // floor(500*315000/750000)
        assertEq(ledger.unallocated(2), 0);

        backing.fund(2, basketA, 500);
        backing.materialise(2, idA);
        backing.materialise(2, idB);
        assertEq(backing.backingOf(idA), 490); // 200 + 290
        assertEq(backing.backingOf(idB), 510); // 300 + 210
        // Conservation: received units equal allocated member shares exactly.
        assertEq(backing.totalReceived(basketA), 1_000);
        assertEq(backing.backingOf(idA) + backing.backingOf(idB), 1_000);
    }

    /// @notice The first eligible depositor can take the ENTIRE 30% HUNTER
    /// tranche of a round under concentrated ownership — an expected property
    /// of the allocation model, not a bug. Here A's 290 = rarity share 140
    /// (500*7/10*100/250) + the full hunter tranche 150 (500*3/10*300/300).
    function testSoleDepositorConcentrationTakesFullHunterTranche() public {
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(BOB, 4, basketA);
        token = _launchToken();
        token.mint(ALICE, 300);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        vault.deposit(idA, 300); // A is the ONLY depositor

        vm.warp(DAY + 50);
        ledger.recordRound(1, keccak256("receipt-day1"), 1_000);
        ledger.freezeGroup(1, basketA);
        // rarity part of A's nominal budget: floor via the combined numerator
        // already yields 290; cross-check the decomposition explicitly.
        assertEq(ledger.memberBudget(1, idA), 290);
        assertEq(ledger.memberBudget(1, idB), 210);
        // 290 = 140 (70% rarity share) + 150 (100% of the 30% hunter tranche).
        assertEq(ledger.memberSnapshot(1, idB).hunter, 0);
    }

    /// @notice A deposit at EXACTLY the cutoff belongs to the next round:
    /// strictly-before history excludes same-timestamp writes even when the
    /// record happens in the same block.
    function testDepositAtExactCutoffCountsFromNextDay() public {
        uint256 idA = _mint(ALICE, 1, basketA);
        _mint(BOB, 4, basketA);
        token = _launchToken();
        token.mint(ALICE, 300);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);

        vm.warp(DAY); // exactly the day-1 cutoff
        vm.prank(ALICE);
        vault.deposit(idA, 300);
        ledger.recordRound(1, keccak256("receipt-day1"), 1_000); // same block
        assertEq(ledger.round(1).globalHunter, 0); // deposit not visible at cutoff
        assertEq(ledger.memberSnapshot(1, idA).hunter, 0);
        assertEq(vault.reserveBefore(idA, DAY), 0);

        vm.warp(2 * DAY);
        ledger.recordRound(2, keccak256("receipt-day2"), 1_000);
        assertEq(ledger.round(2).globalHunter, 300);
        assertEq(ledger.memberSnapshot(2, idA).hunter, 300);
    }

    /// @notice Deposit-before-cutoff then immediate burn ("recycling"): the
    /// frozen right survives the burn and pays the recorded beneficiary late.
    /// The HUNTER principal returns at burn and can legitimately re-enter the
    /// NEXT round through another NFT — historical rounds are unaffected.
    function testBurnAfterCutoffKeepsFrozenRightForBeneficiary() public {
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(BOB, 4, basketA);
        token = _launchToken();
        token.mint(ALICE, 600);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        vault.deposit(idA, 300);

        vm.warp(DAY + 10);
        ledger.recordRound(1, keccak256("receipt-day1"), 1_000);
        ledger.freezeGroup(1, basketA);
        assertEq(ledger.round(1).globalHunter, 300);

        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assetA.mint(address(this), 500);
        assetA.approve(address(backing), 500);
        backing.fund(1, basketA, 500);

        // Burn before materialisation: reserve pays out, backing right is
        // frozen to ALICE as final beneficiary, nothing materialised yet.
        uint256 aliceBefore = token.balanceOf(ALICE);
        vm.prank(ALICE);
        nft.redeemAndDestroy(idA);
        assertEq(token.balanceOf(ALICE), aliceBefore + 300);
        assertTrue(vault.settled(idA));
        assertEq(vault.totalReserved(), 0);
        assertEq(lc.finalBeneficiary(idA), ALICE);

        // The burned member's frozen day-1 share (290) still claims late.
        vm.prank(ALICE);
        backing.claimBurned(1, idA);
        assertEq(assetA.balanceOf(ALICE), 290);

        // The recycled tokens legitimately re-enter through idB's NEXT round —
        // they never rewrite the frozen day-1 record.
        vm.prank(ALICE);
        token.transfer(BOB, 300);
        vm.prank(BOB);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        vault.deposit(idB, 300);
        vm.warp(2 * DAY + 10);
        ledger.recordRound(2, keccak256("receipt-day2"), 1_000);
        assertEq(ledger.round(1).globalHunter, 300); // day-1 record immutable
        assertEq(ledger.round(2).globalHunter, 300); // recycled into day 2
    }

    /// @notice When the sole depositor burns, the eligible HUNTER total returns
    /// to zero and later rounds fall back to 100% rarity allocation.
    function testHunterReturnsToZeroAfterDepositorBurns() public {
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(BOB, 4, basketA);
        token = _launchToken();
        token.mint(ALICE, 300);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        vault.deposit(idA, 300);

        vm.warp(DAY + 50);
        ledger.recordRound(1, keccak256("receipt-day1"), 1_000);
        ledger.freezeGroup(1, basketA);
        assertEq(ledger.round(1).globalHunter, 300);
        assertEq(ledger.memberBudget(1, idA), 290);

        vm.prank(ALICE);
        nft.redeemAndDestroy(idA); // sole depositor leaves the cohort

        vm.warp(2 * DAY + 50);
        ledger.recordRound(2, keccak256("receipt-day2"), 1_000);
        WeightedRoundLedger.Round memory r2 = ledger.round(2);
        assertEq(r2.globalHunter, 0); // H returned to zero
        assertEq(r2.globalRarity, 150);
        assertEq(r2.globalCount, 1);
        ledger.freezeGroup(2, basketA);
        assertEq(ledger.group(2, basketA).hunter, 0);
        assertEq(ledger.memberBudget(2, idB), 500); // sole member: full budget, rarity-only
    }

    /// @notice Two baskets, one depositor: each frozen group keeps its own
    /// measured receipt and the member shares follow the combined numerator —
    /// partial funding scales shares proportionally without touching the other
    /// basket's group.
    function testTwoBasketsAndPartialFunding() public {
        uint256 idA = _mint(ALICE, 1, basketA); // N(A) = 435000
        uint256 idB = _mint(BOB, 4, basketB); // N(B) = 315000, N(global) 750000
        token = _launchToken();
        token.mint(ALICE, 300);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        vault.deposit(idA, 300);

        vm.warp(DAY + 50);
        ledger.recordRound(1, keccak256("receipt-day1"), 1_000);
        ledger.freezeGroup(1, basketA);
        ledger.freezeGroup(1, basketB);
        assertEq(ledger.group(1, basketA).budget, 290); // floor(500*435000/750000)
        assertEq(ledger.group(1, basketB).budget, 210); // floor(500*315000/750000)
        assertEq(ledger.round(1).allocatedBudget, 500);
        assertEq(ledger.memberBudget(1, idA), 290);
        assertEq(ledger.memberBudget(1, idB), 210);

        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        ReserveTokenFixture assetB = ReserveTokenFixture(basketB);
        assetA.mint(address(this), 290);
        assetA.approve(address(backing), 290);
        assetB.mint(address(this), 100); // deliberately PARTIAL vs budget 210
        assetB.approve(address(backing), 100);
        backing.fund(1, basketA, 290);
        backing.fund(1, basketB, 100);

        backing.materialise(1, idA);
        assertEq(backing.backingOf(idA), 290); // sole member of its group
        backing.materialise(1, idB);
        assertEq(backing.backingOf(idB), 100); // scaled by measured receipt only
        assertEq(assetA.balanceOf(address(backing)), 290);
        assertEq(assetB.balanceOf(address(backing)), 100);
    }

    /// @notice Direct token transfers to the vault (donations) are never
    /// credited to any NFT and stay readable as unreserved excess after
    /// activation; taxed deposits credit only the measured receipt, and the
    /// deposit-path callback defense is unchanged by late activation.
    function testDonationTaxAndCallbackAfterActivation() public {
        uint256 idA = _mint(ALICE, 1, basketA);
        token = _launchToken();

        token.mint(address(vault), 50); // unsolicited excess — never credited
        assertEq(vault.unreservedBalance(), 50);
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.reserveOf(idA), 0);

        token.mint(ALICE, 1_000);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);

        token.setBehavior(3_000, false, false, false); // 30% inbound tax
        vm.prank(ALICE);
        assertEq(vault.deposit(idA, 100), 70); // actual receipt only
        assertEq(vault.reserveOf(idA), 70);
        token.setBehavior(0, false, false, false);

        // Callback defense: a deposit whose token leg self-transfers the NFT
        // must still trip the stale-authorization guard and roll back.
        uint256 idT = _mint(address(token), 1, basketA);
        token.mint(address(token), 100);
        token.setCallback(address(nft), idT, true);
        vm.expectRevert(HunterReserveVault.StaleAuthorization.selector);
        token.beginDeposit(idT, 100);
        assertEq(vault.reserveOf(idT), 0);
        token.setCallback(address(nft), idT, false);
        token.beginDeposit(idT, 100);
        assertEq(vault.reserveOf(idT), 100);
        assertEq(vault.unreservedBalance(), 50);
    }

    /// @notice Mint-out does not touch the reserve lifecycle: with the
    /// lifetime cap forced (TEST-ONLY storage write on the real NFT), a token
    /// activation afterwards still accepts deposits into already-mined NFTs
    /// and burn settlement keeps paying them out.
    function testMintedOutReserveDepositsAndBurnsStillWork() public {
        uint256 idA = _mint(ALICE, 1, basketA);
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(5_000);
        vm.expectRevert(HunterNFT.LifetimeCapReached.selector);
        nft.mint(BOB, bytes32(0), 4_999, 1, basketA);

        token = _launchToken();
        token.mint(ALICE, 300);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        assertEq(vault.deposit(idA, 300), 300);
        assertEq(vault.reserveOf(idA), 300);

        vm.warp(DAY + 50);
        vm.prank(ALICE);
        nft.redeemAndDestroy(idA);
        assertEq(token.balanceOf(ALICE), 300);
        assertTrue(vault.settled(idA));
    }

    /// @notice A round recorded with no eligible NFTs stays recorded with its
    /// full nominal budget unallocated: no user entitlement, no group can ever
    /// freeze, and nothing can be funded — funds remain separately accounted.
    function testZeroCohortRoundKeepsBudgetUnallocated() public {
        vm.warp(DAY + 50);
        ledger.recordRound(1, keccak256("receipt-empty"), 1_000);
        WeightedRoundLedger.Round memory r = ledger.round(1);
        assertEq(r.globalCount, 0);
        assertEq(r.globalRarity, 0);
        assertEq(r.globalHunter, 0);
        assertEq(r.nominalBackingBudget, 500);
        assertEq(r.allocatedBudget, 0);
        assertEq(ledger.unallocated(1), 500);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.EmptyGroup.selector, 1, basketA));
        ledger.freezeGroup(1, basketA);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.GroupNotFrozen.selector, 1, basketA));
        backing.fund(1, basketA, 500);
    }

    /// @notice An ERC20 may have supply but reject balance queries (for example
    /// a paused/permissioned token). Probe failure must leave activation reusable.
    function testBalanceProbeFailureDoesNotConsumeActivation() public {
        token = new ReserveTokenFixture();
        vm.mockCallRevert(address(token), abi.encodeWithSignature("balanceOf(address)", address(vault)), "blocked");
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.InvalidToken.selector);
        vault.activateToken(address(token));
        assertEq(address(vault.HUNTER()), address(0));
        assertFalse(vault.tokenActivated());
        vm.clearMockedCalls();
        vm.prank(LAUNCH);
        vault.activateToken(address(token));
        assertEq(address(vault.HUNTER()), address(token));
    }

    /// @notice Explicit fault injection, NOT a reachable pre-token state:
    /// if accounting is corrupted, activation/read/burn must fail closed.
    /// This test does not claim a user can create a pre-token liability.
    function testPreTokenCorruptLiabilityCannotBeActivatedHiddenOrBurned() public {
        uint256 id = _mint(ALICE, 1, basketA);
        stdstore.target(address(vault)).sig("totalReserved()").checked_write(1);
        token = new ReserveTokenFixture();
        vm.prank(LAUNCH);
        vm.expectRevert(HunterReserveVault.Insolvency.selector);
        vault.activateToken(address(token));
        assertEq(address(vault.HUNTER()), address(0));
        vm.expectRevert(HunterReserveVault.Insolvency.selector);
        vault.unreservedBalance();
        vm.prank(ALICE);
        vm.expectRevert(HunterReserveVault.Insolvency.selector);
        nft.redeemAndDestroy(id);
        assertEq(nft.ownerOf(id), ALICE);
        assertFalse(vault.settled(id));
        assertEq(vault.totalReserved(), 1);
        assertEq(vault.historyLength(id), 0);
    }
}

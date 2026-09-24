// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {HunterBackingVault} from "../src/bloom/HunterBackingVault.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {ReserveEscrowFixture, ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @notice Shared wiring for the REAL HunterLifecycle <-> HunterNFT <->
/// HunterReserveVault five-module composition. The test contract is registry admin, NFT minter
/// and deployer. Basket assets are token stand-ins admitted for real in the
/// registry; only the token and escrow fixtures are reused, never the fixture
/// lifecycle. Everything stays internal so later suites can subclass this.
abstract contract LifecycleTestBase is Test {
    HunterLifecycle internal lc;
    WeightedRoundLedger internal canonicalLedger;
    HunterBackingVault internal canonicalBacking;
    HunterNFT internal nft;
    HunterReserveVault internal vault;
    ReserveTokenFixture internal token;
    BasketRegistry internal registry;
    address internal basketA;
    address internal basketB;
    ReserveEscrowFixture internal escrow;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant OP = address(0x0B);
    address internal constant ROYALTIES = address(0x2017);

    function setUp() public virtual {
        token = new ReserveTokenFixture();
        basketA = address(new ReserveTokenFixture());
        basketB = address(new ReserveTokenFixture());
        registry = new BasketRegistry(address(this));
        registry.admitBasket(basketA, keccak256("reviewA"));
        registry.admitBasket(basketB, keccak256("reviewB"));

        // Deploy order consumes nonces: lifecycle (n), reserve (n + 3), NFT (n + 4).
        uint64 n = vm.getNonce(address(this));
        address wantNft = vm.computeCreateAddress(address(this), n + 4);
        address wantReserve = vm.computeCreateAddress(address(this), n + 3);
        address wantBacking = vm.computeCreateAddress(address(this), n + 2);
        lc = new HunterLifecycle(
            wantNft, wantReserve, wantBacking, [uint64(100), uint64(110), uint64(125), uint64(150)]
        );
        canonicalLedger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        canonicalBacking = new HunterBackingVault(address(canonicalLedger), address(this));
        vault = new HunterReserveVault(wantNft, address(lc), address(this));
        nft = new HunterNFT(address(registry), address(lc), 1, ROYALTIES, "");
        vault.activateToken(address(token)); // this test contract is the launch authority
        assertEq(address(canonicalBacking), wantBacking);
        assertEq(lc.backing(), wantBacking);
        assertEq(address(vault), wantReserve);
        assertEq(address(nft), wantNft);

        escrow = new ReserveEscrowFixture();
        token.setVault(address(vault));
        token.mint(ALICE, 1_000);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
    }

    /// @dev Real mint by this contract (the NFT's fixed MINER); the lifecycle
    /// hook authenticates the actual minted owner/basket/birth proof tier.
    function _mint(address owner, uint8 tier, address basket) internal returns (uint256 tokenId) {
        tokenId = nft.mint(owner, bytes32(0), nft.mintedEver(), tier, basket);
    }

    function _assertMemberEq(
        WeightedHistory.Member memory m,
        address expectedBasket,
        uint64 expectedRarity,
        uint256 expectedHunter,
        bool expectedAlive,
        bool expectedEligible
    ) internal {
        assertEq(m.basket, expectedBasket);
        assertEq(m.rarity, expectedRarity);
        assertEq(m.hunter, expectedHunter);
        assertEq(m.alive, expectedAlive);
        assertEq(m.eligible, expectedEligible);
    }

    function _assertTotalsEq(
        WeightedHistory.Totals memory t,
        uint64 expectedRarity,
        uint256 expectedHunter,
        uint32 expectedCount
    ) internal {
        assertEq(t.rarity, expectedRarity);
        assertEq(t.hunter, expectedHunter);
        assertEq(t.count, expectedCount);
    }
}

contract HunterLifecycleCoreTest is LifecycleTestBase {
    /// @notice Real mints record the NFT's own birth proof tier as the fixed
    /// rarity weight; global and per-basket totals stay separate and
    /// strictly-before cutoffs exclude same-timestamp writes.
    function testMintProofTierDrivesRarityAndTotals() public {
        assertEq(lc.rarityWeight(1), 100);
        assertEq(lc.rarityWeight(2), 110);
        assertEq(lc.rarityWeight(3), 125);
        assertEq(lc.rarityWeight(4), 150);

        vm.warp(100);
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(BOB, 4, basketB);
        assertEq(idA, 1);
        assertEq(idB, 2);
        assertEq(nft.mintedEver(), 2);

        (,,, uint8 tierA) = nft.birthData(idA);
        (,,, uint8 tierB) = nft.birthData(idB);
        assertEq(tierA, 1);
        assertEq(tierB, 4);
        assertEq(nft.basketOf(idA), basketA);
        assertEq(nft.basketOf(idB), basketB);

        _assertMemberEq(lc.currentMember(idA), basketA, 100, 0, true, true);
        _assertMemberEq(lc.currentMember(idB), basketB, 150, 0, true, true);
        _assertTotalsEq(lc.currentGlobal(), 250, 0, 2);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 0, 1);
        _assertTotalsEq(lc.currentBasket(basketB), 150, 0, 1);
        assertEq(lc.finalBeneficiary(idA), address(0));
        assertEq(lc.finalBeneficiary(idB), address(0));

        // The strictly-before cutoff at the mint timestamp sees nothing.
        _assertMemberEq(lc.memberBefore(idA, 100), address(0), 0, 0, false, false);
        _assertMemberEq(lc.memberBefore(idB, 100), address(0), 0, 0, false, false);
        _assertTotalsEq(lc.globalBefore(100), 0, 0, 0);
        _assertTotalsEq(lc.basketBefore(basketA, 100), 0, 0, 0);
        _assertTotalsEq(lc.basketBefore(basketB, 100), 0, 0, 0);

        vm.warp(101);
        _assertMemberEq(lc.memberBefore(idA, 101), basketA, 100, 0, true, true);
        _assertMemberEq(lc.memberBefore(idB, 101), basketB, 150, 0, true, true);
        _assertTotalsEq(lc.globalBefore(101), 250, 0, 2);
        _assertTotalsEq(lc.basketBefore(basketA, 101), 100, 0, 1);
        _assertTotalsEq(lc.basketBefore(basketB, 101), 150, 0, 1);
    }

    /// @notice Deposits credit the measured received amount only: a direct
    /// vault donation never enters reserve/history and the lifecycle totals
    /// track credited reserve, never the live token balance.
    function testDepositCreditsReceivedAmountNotBalance() public {
        vm.warp(100);
        uint256 id = _mint(ALICE, 1, basketA);

        token.mint(address(vault), 50); // unsolicited donation, credited nowhere
        assertEq(vault.reserveOf(id), 0);
        assertEq(vault.historyLength(id), 0);
        assertEq(vault.unreservedBalance(), 50);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, true);

        token.setBehavior(1_000, false, false, false); // 10% receipt tax
        vm.warp(101);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 100), 90);
        assertEq(vault.reserveOf(id), 90);
        assertEq(vault.totalReserved(), 90);
        assertEq(token.balanceOf(address(vault)), 140);
        assertEq(vault.unreservedBalance(), 50);
        assertEq(vault.historyLength(id), 1);
        (uint256 ts, uint256 amount) = vault.history(id, 0);
        assertEq(ts, 101);
        assertEq(amount, 90); // credited amount, never the 140 live balance
        _assertMemberEq(lc.currentMember(id), basketA, 100, 90, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, 90, 1);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 90, 1);
        _assertTotalsEq(lc.currentBasket(basketB), 0, 0, 0); // baskets never mix

        token.setBehavior(0, false, false, false);
        vm.warp(102);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 20), 20);
        assertEq(vault.reserveOf(id), 110);
        assertEq(vault.totalReserved(), 110);
        assertEq(token.balanceOf(address(vault)), 160);
        assertEq(vault.unreservedBalance(), 50);
        assertEq(vault.historyLength(id), 2);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 110, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, 110, 1);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 110, 1);
        _assertTotalsEq(lc.currentBasket(basketB), 0, 0, 0);

        // Strict cutoffs replay mint (H0) -> first deposit (H90) -> second (H110).
        assertEq(vault.reserveBefore(id, 101), 0);
        _assertMemberEq(lc.memberBefore(id, 101), basketA, 100, 0, true, true);
        _assertTotalsEq(lc.globalBefore(101), 100, 0, 1);
        assertEq(vault.reserveBefore(id, 102), 90);
        _assertMemberEq(lc.memberBefore(id, 102), basketA, 100, 90, true, true);
        _assertTotalsEq(lc.globalBefore(102), 100, 90, 1);
        vm.warp(103);
        assertEq(vault.reserveBefore(id, 103), 110);
        _assertMemberEq(lc.memberBefore(id, 103), basketA, 100, 110, true, true);
        _assertTotalsEq(lc.globalBefore(103), 100, 110, 1);
        _assertTotalsEq(lc.basketBefore(basketB, 103), 0, 0, 0);
    }

    /// @notice A sale plus escrow entry/release never pauses eligibility even
    /// after basket entry is disabled: rights stay on the tokenId. The escrow
    /// fixture only holds and releases the NFT; no loan is claimed or proven.
    function testDisabledEntryKeepsSaleEscrowAndDepositRights() public {
        vm.warp(100);
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 100), 100);

        registry.setEntryEnabled(basketA, false); // new-entry policy only

        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        assertEq(nft.ownerOf(id), BOB);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, 100, 1);

        vm.prank(BOB);
        nft.escrowTo(id, address(escrow), "");
        assertEq(nft.ownerOf(id), address(escrow));
        assertEq(nft.escrowedTo(id), address(escrow));
        assertTrue(nft.isEncumbered(id));
        assertTrue(nft.custody(id) == HunterNFT.Custody.Escrowed);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, 100, 1);

        // While escrowed the real owner guards still fire; history does not move.
        vm.prank(BOB);
        vm.expectRevert(HunterReserveVault.NotTokenOwner.selector);
        vault.deposit(id, 10);
        vm.prank(BOB);
        vm.expectRevert(HunterNFT.NotTokenOwner.selector);
        nft.redeemAndDestroy(id);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, 100, 1);
        assertEq(vault.reserveOf(id), 100);

        escrow.release(IERC721(address(nft)), id, BOB);
        assertEq(nft.ownerOf(id), BOB);
        assertEq(nft.escrowedTo(id), address(0));
        assertFalse(nft.isEncumbered(id));
        assertTrue(nft.custody(id) == HunterNFT.Custody.OwnerHeld);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);

        // The current owner can still fund the reserve: disabling basket entry
        // never froze existing rights or paused eligibility.
        token.mint(BOB, 25);
        vm.prank(BOB);
        token.approve(address(vault), 25);
        vm.prank(BOB);
        assertEq(vault.deposit(id, 25), 25);
        assertEq(vault.reserveOf(id), 125);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 125, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 125, 1);
        _assertTotalsEq(lc.currentBasket(basketB), 0, 0, 0);
        _assertTotalsEq(lc.currentGlobal(), 100, 125, 1);
    }

    /// @notice Burn-after-sale pays the reserve to the actual new owner once:
    /// a blocked outbound transfer rolls back the NFT burn, history and
    /// beneficiary together, then the retry settles the record for good.
    function testBurnAfterFailedPayoutRetriesAndSettlesOnce() public {
        vm.warp(100);
        uint256 id = _mint(ALICE, 1, basketA);
        vm.warp(101);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 100), 100);
        vm.warp(102);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        assertEq(nft.ownerOf(id), BOB);

        vm.warp(103);
        token.setBehavior(0, false, true, false); // block the payout leg
        vm.prank(BOB);
        vm.expectRevert(ReserveTokenFixture.OutboundBlocked.selector);
        nft.redeemAndDestroy(id);

        // Full atomic rollback: token live, no beneficiary, reserve/history kept.
        assertEq(nft.ownerOf(id), BOB);
        assertEq(lc.finalBeneficiary(id), address(0));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, 100, 1);
        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.totalReserved(), 100);
        assertFalse(vault.settled(id));

        // Pre-burn strict cutoff still shows the funded live member.
        assertEq(vault.reserveBefore(id, 103), 100);
        _assertMemberEq(lc.memberBefore(id, 103), basketA, 100, 100, true, true);
        _assertTotalsEq(lc.globalBefore(103), 100, 100, 1);

        token.setBehavior(0, false, false, false);
        vm.prank(BOB);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(token.balanceOf(ALICE), 900); // original owner keeps no beneficiary right
        assertEq(lc.finalBeneficiary(id), BOB);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, false, false);
        _assertTotalsEq(lc.currentGlobal(), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        assertTrue(vault.settled(id));
        assertEq(vault.reserveOf(id), 0);
        assertEq(vault.totalReserved(), 0);

        vm.warp(104);
        _assertMemberEq(lc.memberBefore(id, 104), basketA, 100, 0, false, false);
        _assertTotalsEq(lc.globalBefore(104), 0, 0, 0);
        _assertTotalsEq(lc.basketBefore(basketA, 104), 0, 0, 0);
        assertEq(vault.reserveBefore(id, 104), 0);

        // The NFT remains sole authority: no replay mint, no second payout.
        assertEq(nft.mintedEver(), 1);
        vm.prank(BOB);
        vm.expectRevert();
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(vault.totalReserved(), 0);
    }
}

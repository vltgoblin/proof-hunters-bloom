// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {ReserveEscrowFixture, ReserveLifecycleFixture, ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @notice Shared reserve wiring; the test contract is the NFT minter and mints nothing here.
abstract contract ReserveVaultTestBase is Test {
    ReserveTokenFixture internal token;
    HunterReserveVault internal vault;
    HunterNFT internal nft;
    ReserveLifecycleFixture internal lifecycle;
    BasketRegistry internal registry;
    address internal basket;
    ReserveEscrowFixture internal escrow;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant OP = address(0x0B);
    address internal constant ROYALTIES = address(0x2017);

    function setUp() public virtual {
        token = new ReserveTokenFixture();
        basket = address(new ReserveTokenFixture());
        registry = new BasketRegistry(address(this));
        registry.admitBasket(basket, keccak256("review"));

        uint64 n = vm.getNonce(address(this));
        address wantNft = vm.computeCreateAddress(address(this), n + 2);
        address wantVault = vm.computeCreateAddress(address(this), n + 1);
        lifecycle = new ReserveLifecycleFixture(wantNft, wantVault);
        vault = new HunterReserveVault(wantNft, address(lifecycle), address(this));
        nft = new HunterNFT(address(registry), address(lifecycle), 1, ROYALTIES, "");
        assertEq(address(vault), wantVault);
        assertEq(address(nft), wantNft);
        vault.activateToken(address(token)); // this test contract is the launch authority

        escrow = new ReserveEscrowFixture();
        token.setVault(address(vault));
        token.mint(ALICE, 1_000);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
    }

    function _mintTo(address to) internal returns (uint256) {
        return nft.mint(to, bytes32(0), nft.mintedEver(), 1, basket);
    }
}

contract ReserveVaultCoreTest is ReserveVaultTestBase {
    function testDepositCreditsReserveAndHistory() public {
        uint256 id = _mintTo(ALICE);
        vm.warp(1_000);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 100), 100);
        assertEq(token.balanceOf(address(vault)), 100);
        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.totalReserved(), 100);
        assertEq(vault.historyLength(id), 1);
        assertEq(vault.reserveBefore(id, 1_000), 0); // strictly-before excludes same-time
        vm.warp(2_000);
        assertEq(vault.reserveBefore(id, 2_000), 100);
        vm.expectRevert(HunterReserveVault.FutureCutoff.selector);
        vault.reserveBefore(id, 2_001);
    }

    function testDepositRejectsOperatorAndZeroAmount() public {
        uint256 id = _mintTo(ALICE);
        vm.prank(ALICE);
        nft.setApprovalForAll(OP, true);
        uint256 nonce = nft.authorizationNonce(id);
        vm.prank(OP);
        vm.expectRevert(HunterReserveVault.NotTokenOwner.selector);
        vault.deposit(id, 100);
        vm.prank(ALICE);
        vm.expectRevert(HunterReserveVault.InvalidAmount.selector);
        vault.deposit(id, 0);
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.authorizationNonce(id), nonce);
        assertEq(vault.reserveOf(id), 0);
        assertEq(token.balanceOf(ALICE), 1_000);
    }

    function testDonationExcessAndBurnAfterSale() public {
        uint256 id = _mintTo(ALICE);
        token.mint(address(vault), 50); // unsolicited excess, never credited
        vm.prank(ALICE);
        vault.deposit(id, 100);
        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.unreservedBalance(), 50);

        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        vm.prank(ALICE);
        vm.expectRevert(HunterNFT.NotTokenOwner.selector);
        nft.redeemAndDestroy(id);

        uint256 ever = nft.mintedEver();
        vm.prank(BOB);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(vault.reserveOf(id), 0);
        assertEq(vault.totalReserved(), 0);
        assertTrue(vault.settled(id));
        assertEq(vault.unreservedBalance(), 50);
        assertEq(nft.mintedEver(), ever);
    }

    function testDepositTaxAndInboundFailure() public {
        uint256 id = _mintTo(ALICE);
        token.setBehavior(3_000, false, false, false); // 30% of 100 -> 70 credited
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 100), 70);
        assertEq(vault.reserveOf(id), 70);
        assertEq(token.balanceOf(ALICE), 900);

        token.setBehavior(10_000, false, false, false); // 100% tax: nothing received
        vm.prank(ALICE);
        vm.expectRevert(HunterReserveVault.UnsupportedTokenReceipt.selector);
        vault.deposit(id, 100);
        assertEq(token.balanceOf(ALICE), 900);
        assertEq(vault.reserveOf(id), 70);

        token.setBehavior(0, true, false, false);
        vm.prank(ALICE);
        vm.expectRevert(ReserveTokenFixture.InboundBlocked.selector);
        vault.deposit(id, 100);
        assertEq(vault.reserveOf(id), 70);
    }

    function testOutboundFailureRollsBackBurn() public {
        uint256 id = _mintTo(ALICE);
        vm.prank(ALICE);
        vault.deposit(id, 100);
        token.setBehavior(0, false, true, false);
        uint256 nonce = nft.authorizationNonce(id);
        vm.prank(ALICE);
        vm.expectRevert(ReserveTokenFixture.OutboundBlocked.selector);
        nft.redeemAndDestroy(id);
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.authorizationNonce(id), nonce);
        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.totalReserved(), 100);
        assertEq(vault.historyLength(id), 1);
        assertEq(token.balanceOf(ALICE), 900);
        assertEq(token.balanceOf(address(vault)), 100);

        token.setBehavior(0, false, false, false);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(ALICE), 1_000);
        assertEq(vault.totalReserved(), 0);
        assertTrue(vault.settled(id));
    }

    function testZeroReserveBurnAndSettleGuards() public {
        uint256 id = _mintTo(BOB);
        token.setBehavior(0, false, false, true); // reverts on value == 0 calls
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.TokenNotBurned.selector, id));
        lifecycle.forceSettle(id, BOB);
        vm.prank(BOB);
        vm.expectRevert(HunterReserveVault.UnauthorizedLifecycle.selector);
        vault.settleBurn(id, BOB);
        vm.prank(BOB);
        nft.redeemAndDestroy(id); // gross == 0: no token call is made
        assertTrue(vault.settled(id));
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.AlreadySettled.selector, id));
        lifecycle.forceSettle(id, BOB);
    }

    function testLifecycleCallbackFailuresRollBack() public {
        uint256 id = _mintTo(ALICE);
        lifecycle.setFailures(true, false);
        vm.prank(ALICE);
        vm.expectRevert(ReserveLifecycleFixture.CheckpointFailed.selector);
        vault.deposit(id, 100);
        assertEq(token.balanceOf(ALICE), 1_000);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.allowance(ALICE, address(vault)), type(uint256).max);
        assertEq(vault.reserveOf(id), 0);
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.historyLength(id), 0);

        lifecycle.setFailures(false, false);
        vm.prank(ALICE);
        vault.deposit(id, 100);
        assertEq(vault.reserveOf(id), 100);

        lifecycle.setFailures(false, true);
        vm.prank(ALICE);
        vm.expectRevert(ReserveLifecycleFixture.BurnFailed.selector);
        nft.redeemAndDestroy(id);
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(vault.reserveOf(id), 100);
    }

    function testCrossContractCallbackStaleNonce() public {
        uint256 id = _mintTo(address(token));
        token.mint(address(token), 100);
        vm.prank(address(token));
        nft.transferFrom(address(token), address(token), id); // authorized self-transfer
        uint256 nonce = nft.authorizationNonce(id);

        token.setCallback(address(nft), id, true);
        vm.expectRevert(HunterReserveVault.StaleAuthorization.selector);
        token.beginDeposit(id, 100);
        assertEq(nft.ownerOf(id), address(token));
        assertEq(nft.authorizationNonce(id), nonce);
        assertEq(vault.reserveOf(id), 0);
        assertEq(token.balanceOf(address(token)), 100);

        token.setCallback(address(nft), id, false);
        token.beginDeposit(id, 100);
        assertEq(vault.reserveOf(id), 100);
        assertEq(token.balanceOf(address(vault)), 100);
    }
}

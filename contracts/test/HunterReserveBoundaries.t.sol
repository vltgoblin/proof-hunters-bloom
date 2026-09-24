// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {ReserveLifecycleFixture} from "./helpers/HunterReserveFixtures.sol";
import {ReserveVaultTestBase} from "./HunterReserveCore.t.sol";

/// @notice Boundary tests around the fixed reserve wiring. TEST-ONLY fixtures:
/// no real loan/provider verification is claimed anywhere below.
contract HunterReserveBoundariesTest is ReserveVaultTestBase {
    /// @dev A lifecycle whose nft()==reserve()==the vault's own address is
    /// self-consistent, yet expectedNft == address(this) must still revert.
    function testConstructorRejectsSelfReferencedNft() public {
        uint64 n = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), n + 1);
        ReserveLifecycleFixture selfRef = new ReserveLifecycleFixture(predictedVault, predictedVault);
        vm.expectRevert(HunterReserveVault.InvalidConfiguration.selector);
        new HunterReserveVault(predictedVault, address(selfRef), address(this));
    }

    function testConstructionGuardsAndPreNftWiring() public {
        vm.expectRevert(HunterReserveVault.InvalidConfiguration.selector);
        new HunterReserveVault(address(0), address(lifecycle), address(this)); // zero nft

        vm.expectRevert(HunterReserveVault.InvalidConfiguration.selector);
        new HunterReserveVault(address(0xCAFE), address(lifecycle), address(0)); // zero token authority

        vm.expectRevert(HunterReserveVault.InvalidConfiguration.selector);
        new HunterReserveVault(address(0xCAFE), address(0xDEAD), address(this)); // no-code lifecycle

        ReserveLifecycleFixture badRef = new ReserveLifecycleFixture(address(0xCAFE), address(0xBEEF));
        vm.expectRevert(HunterReserveVault.InvalidConfiguration.selector);
        new HunterReserveVault(address(0xCAFE), address(badRef), address(this)); // reserve() mismatch

        // Construction before the NFT exists is allowed; the wiring guard blocks ops.
        uint64 n = vm.getNonce(address(this));
        address pendingVault = vm.computeCreateAddress(address(this), n + 1);
        address pendingNft = vm.computeCreateAddress(address(this), n + 2); // never deployed
        ReserveLifecycleFixture pre = new ReserveLifecycleFixture(pendingNft, pendingVault);
        HunterReserveVault preVault = new HunterReserveVault(pendingNft, address(pre), address(this));
        assertEq(address(preVault), pendingVault);
        vm.prank(ALICE);
        vm.expectRevert(HunterReserveVault.WiringMismatch.selector);
        preVault.deposit(1, 1);

        vm.prank(BOB);
        vm.expectRevert(HunterReserveVault.UnauthorizedLifecycle.selector);
        vault.settleBurn(1, BOB); // wallet may not settle directly

        uint256 missing = type(uint256).max;
        vm.prank(ALICE);
        vm.expectRevert(); // delegated ERC721 nonexistent-token error
        vault.deposit(missing, 100);
        assertEq(vault.reserveOf(missing), 0);
        assertEq(vault.totalReserved(), 0);
    }

    function testEscrowCustodyBlocksDepositAndBurn() public {
        uint256 id = _mintTo(ALICE);
        vm.prank(ALICE);
        vault.deposit(id, 100);

        vm.prank(ALICE);
        nft.escrowTo(id, address(escrow), "");
        assertEq(nft.ownerOf(id), address(escrow));

        // The escrow IS the owner, yet encumbrance still blocks the deposit.
        vm.prank(address(escrow));
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.TokenEncumbered.selector, id));
        vault.deposit(id, 100);
        vm.prank(address(escrow));
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        nft.redeemAndDestroy(id);

        escrow.release(IERC721(address(nft)), id, BOB);
        assertEq(nft.ownerOf(id), BOB);
        assertEq(vault.reserveOf(id), 100); // custody moves never touch the reserve
        vm.prank(BOB);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(vault.totalReserved(), 0);
        assertTrue(vault.settled(id));
    }

    function testCreditLockBlocksOwnerOpsUntilClosed() public {
        uint256 id = _mintTo(ALICE);
        vm.prank(ALICE);
        vault.deposit(id, 100);

        lifecycle.openCredit(id, address(escrow), ALICE, nft.authorizationNonce(id));
        assertEq(nft.creditPositionOf(id), address(escrow));
        assertEq(nft.activeCreditCount(ALICE), 1);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.TokenEncumbered.selector, id));
        vault.deposit(id, 100);
        vm.prank(ALICE);
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        nft.redeemAndDestroy(id);
        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.totalReserved(), 100);
        assertTrue(nft.isEncumbered(id));

        uint256 openNonce = nft.authorizationNonce(id);
        vm.expectRevert(HunterNFT.StaleAuthorization.selector);
        lifecycle.closeCredit(id, address(escrow), openNonce + 1); // stale nonce cannot close

        lifecycle.closeCredit(id, address(escrow), openNonce);
        assertFalse(nft.isEncumbered(id));
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(ALICE), 1_000);
        assertEq(vault.reserveOf(id), 0);
        assertTrue(vault.settled(id));
    }

    function testHistoryCoalescesSameTimestampAndBurn() public {
        uint256 id = _mintTo(ALICE);
        vm.warp(10);
        vm.startPrank(ALICE);
        vault.deposit(id, 40);
        vault.deposit(id, 60);
        vm.stopPrank();
        assertEq(vault.historyLength(id), 1); // same-timestamp deposits coalesce
        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.reserveBefore(id, 10), 0); // strictly-before cutoff

        vm.warp(11);
        assertEq(vault.reserveBefore(id, 11), 100);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id); // writes the zero checkpoint at t=11
        assertEq(vault.reserveBefore(id, 11), 100); // old history unchanged

        vm.warp(12);
        assertEq(vault.reserveBefore(id, 12), 0);
        assertEq(vault.historyLength(id), 2);

        uint256 missing = nft.mintedEver() + 1;
        vm.expectRevert(HunterReserveVault.InvalidTokenId.selector);
        vault.reserveBefore(missing, 12); // never minted
        vm.expectRevert(HunterReserveVault.FutureCutoff.selector);
        vault.reserveBefore(id, 13);
    }

    function testFuzzConservation(uint96 aRaw, uint96 bRaw, uint96 donationRaw) public {
        uint256 a = uint256(aRaw) + 1;
        uint256 b = uint256(bRaw) + 1;
        uint256 donation = uint256(donationRaw);

        uint256 idA = _mintTo(ALICE);
        uint256 idB = _mintTo(ALICE);
        token.mint(ALICE, a + b); // fixture math in uint256, cannot overflow
        vm.startPrank(ALICE);
        vault.deposit(idA, a);
        vault.deposit(idB, b);
        vm.stopPrank();
        token.mint(address(vault), donation); // uncredited excess

        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, idA);
        vm.prank(BOB);
        nft.redeemAndDestroy(idA);
        vm.prank(ALICE);
        nft.redeemAndDestroy(idB);

        assertEq(token.balanceOf(BOB), a);
        assertEq(token.balanceOf(ALICE), 1_000 + b);
        assertEq(token.balanceOf(address(vault)), donation);
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.reserveOf(idA), 0);
        assertEq(vault.reserveOf(idB), 0);
        assertTrue(vault.settled(idA));
        assertTrue(vault.settled(idB));
        assertEq(nft.mintedEver(), 2); // burns never restore mint cap
    }
}

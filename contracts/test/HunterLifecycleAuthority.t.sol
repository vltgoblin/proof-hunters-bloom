// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";

contract HunterLifecycleAuthorityTest is LifecycleTestBase {
    /// @notice Hook caller guards are sole authorities: a stranger hits the
    /// precise UnauthorizedNFT/UnauthorizedReserve errors on every hook, and an
    /// NFT-impersonated burn on a still-live token reverts inside settleBurn,
    /// rolling back the history end and beneficiary fix atomically.
    function testUnauthorizedHooksAndLiveBurnRollback() public {
        vm.warp(100);
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 100), 100);

        vm.prank(OP);
        vm.expectRevert(HunterLifecycle.UnauthorizedNFT.selector);
        lc.onMint(id, ALICE, basketA);

        // Otherwise fully valid: ALICE owns id, so ownerOf(id) == to holds.
        vm.prank(OP);
        vm.expectRevert(HunterLifecycle.UnauthorizedNFT.selector);
        lc.onTransfer(id, ALICE, ALICE);

        vm.prank(OP);
        vm.expectRevert(HunterLifecycle.UnauthorizedNFT.selector);
        lc.onBurn(id, ALICE);

        // Otherwise fully valid: member live, credited reserve unchanged at 100.
        vm.prank(OP);
        vm.expectRevert(HunterLifecycle.UnauthorizedReserve.selector);
        lc.onReserveChanged(id);

        // Sole-authority path spoofed: the NFT is the accepted caller, but the
        // token was never burned, so the vault refuses settlement and the whole
        // lifecycle write set rolls back.
        vm.prank(address(nft));
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.TokenNotBurned.selector, id));
        lc.onBurn(id, ALICE);

        assertEq(nft.ownerOf(id), ALICE);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, 100, 1);
        assertEq(lc.finalBeneficiary(id), address(0));
        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.totalReserved(), 100);
        assertFalse(vault.settled(id));
        assertEq(token.balanceOf(ALICE), 900);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(vault)), 100);
    }
}

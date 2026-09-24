// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";

contract HunterLifecycleCallbackTest is LifecycleTestBase {
    /// @notice A real ERC20 callback that self-transfers the depositing NFT
    /// mid-deposit trips the vault's actual nonce guard: owner/nonces,
    /// balances, reserve and lifecycle history all roll back atomically, and
    /// the same deposit succeeds untouched once the callback is disabled.
    function testCallbackSelfTransferStaleAuthorizationRollsBack() public {
        vm.warp(100);
        uint256 id = _mint(address(token), 1, basketA);
        token.mint(address(token), 200);
        uint256 nonce = nft.authorizationNonce(id);
        assertEq(nft.ownerOf(id), address(token));

        token.setCallback(address(nft), id, true);
        vm.expectRevert(HunterReserveVault.StaleAuthorization.selector);
        token.beginDeposit(id, 100);

        // Full atomic rollback: the self-transfer bumped the nonce inside the
        // token callback, so the vault's unchanged-owner/nonce guard fired —
        // and every leg (ERC20, NFT nonce, reserve, history) reverted together.
        assertEq(nft.ownerOf(id), address(token));
        assertEq(nft.authorizationNonce(id), nonce);
        assertEq(token.balanceOf(address(token)), 200);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.reserveOf(id), 0);
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.historyLength(id), 0);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, 0, 1);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 0, 1);
        assertEq(lc.finalBeneficiary(id), address(0));

        // Same deposit with the callback off credits the received amount only;
        // no NFT transfer occurs, so the authorization nonce is still the same.
        token.setCallback(address(nft), id, false);
        token.beginDeposit(id, 100);

        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.totalReserved(), 100);
        assertEq(vault.historyLength(id), 1);
        (uint256 ts, uint256 amount) = vault.history(id, 0);
        assertEq(ts, 100);
        assertEq(amount, 100);
        assertEq(token.balanceOf(address(token)), 100);
        assertEq(token.balanceOf(address(vault)), 100);
        assertEq(nft.authorizationNonce(id), nonce);
        assertEq(nft.ownerOf(id), address(token));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);
        _assertTotalsEq(lc.currentGlobal(), 100, 100, 1);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 100, 1);
        assertEq(lc.finalBeneficiary(id), address(0));
    }
}

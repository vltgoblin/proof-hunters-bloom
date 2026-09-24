// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";

/// @notice VLT-38 Stage 2: `setConvertedBasket` guard matrix. The lifecycle
/// completes a switch through this lifecycle-only write; the guards reject a
/// zero basket, encumbered custody and a stale expected nonce. The real
/// conversion path is covered by HunterBasketSwitch; this file covers the
/// defensive legs directly as the wired lifecycle caller.
contract HunterNFTEdgesTest is LifecycleTestBase {
    function testSetConvertedBasketGuards() public {
        uint256 id = _mint(ALICE, 1, basketA);
        uint256 nonce = nft.authorizationNonce(id);

        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.InvalidBasket.selector, address(0)));
        nft.setConvertedBasket(id, address(0), nonce);

        // A wrong expected nonce is stale — the write refuses.
        vm.prank(address(lc));
        vm.expectRevert(HunterNFT.StaleAuthorization.selector);
        nft.setConvertedBasket(id, basketB, nonce + 1);

        // Escrow-held custody is not owner-held.
        vm.prank(ALICE);
        nft.escrowTo(id, address(escrow), "");
        vm.prank(address(lc));
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        nft.setConvertedBasket(id, basketB, nonce);

        // Caller-side non-lifecycle still fails the outer authority check.
        vm.prank(ALICE);
        vm.expectRevert(HunterNFT.UnauthorizedLifecycle.selector);
        nft.setConvertedBasket(id, basketB, nonce);
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

/// @notice VLT-38 Stage 2: `HunterReserveVault` solvency and caller-side
/// guard legs. The balance-below-liability paths fire when custody storage
/// reads a deficit; the lifecycle-only `settleBurn` guards are exercised
/// through the wired lifecycle caller. The two post-transfer insolvency
/// rechecks (deposit line ~116, settleBurn line ~149) are dead by
/// construction: the liability moves by the same measured delta as the
/// balance, and `DebitMismatch` precedes the settleBurn post-check — they are
/// defensive asserts, recorded as residuals rather than contrived.
contract HunterReserveEdgesTest is LifecycleTestBase {
    using stdStorage for StdStorage;

    function testDepositRevertsWhenBalanceDropsBelowReserved() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        vault.deposit(id, 100);
        assertEq(vault.totalReserved(), 100);

        // Corrupt the vault's measured balance below the recorded liability.
        stdstore.target(address(token)).sig("balanceOf(address)").with_key(address(vault)).checked_write(50);

        vm.prank(ALICE);
        vm.expectRevert(HunterReserveVault.Insolvency.selector);
        vault.deposit(id, 10);

        vm.expectRevert(HunterReserveVault.Insolvency.selector);
        vault.unreservedBalance();
    }

    function testSettleBurnCallerGuards() public {
        uint256 id = _mint(ALICE, 1, basketA);

        // tokenId bounds.
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.InvalidTokenId.selector));
        vault.settleBurn(0, BOB);
        uint256 beyond = nft.mintedEver() + 1;
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.InvalidTokenId.selector));
        vault.settleBurn(beyond, BOB);

        // beneficiary may not be zero or the vault itself.
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.InvalidBeneficiary.selector));
        vault.settleBurn(id, address(0));
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.InvalidBeneficiary.selector));
        vault.settleBurn(id, address(vault));

        // A live token cannot be burn-settled.
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.TokenNotBurned.selector, id));
        vault.settleBurn(id, BOB);
    }

    function testSettleBurnRevertsWhenBalanceDropsBelowReserved() public {
        uint256 idA = _mint(ALICE, 1, basketA);
        uint256 idB = _mint(ALICE, 1, basketA);
        vm.startPrank(ALICE);
        vault.deposit(idA, 100);
        vault.deposit(idB, 100);
        nft.redeemAndDestroy(idA); // settles idA once; idB's reserve remains
        vm.stopPrank();
        assertEq(vault.totalReserved(), 100);
        assertTrue(vault.settled(idA));

        // Replay surface: mark the burned id unsettled and corrupt the
        // balance read below the remaining liability.
        stdstore.target(address(vault)).sig("settled(uint256)").with_key(idA).checked_write(false);
        stdstore.target(address(token)).sig("balanceOf(address)").with_key(address(vault)).checked_write(50);

        vm.prank(address(lc));
        vm.expectRevert(HunterReserveVault.Insolvency.selector);
        vault.settleBurn(idA, BOB);
    }
}

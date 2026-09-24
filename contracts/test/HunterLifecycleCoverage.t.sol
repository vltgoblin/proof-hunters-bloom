// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";

/// @notice Dependency-fault rejection tests, not reachable exploit claims.
/// Uses the real lifecycle/NFT/reserve. mockCall changes explicitly named
/// external responses; no storage overwrites or derived lifecycle bypasses.
contract HunterLifecycleCoverageTest is LifecycleTestBase {
    function testMintDependencyFaultsRollbackLifetimeCounter() public {
        vm.mockCall(address(nft), abi.encodeWithSelector(nft.ownerOf.selector, 1), abi.encode(BOB));
        _mintRejected(HunterLifecycle.OwnerMismatch.selector);
        vm.mockCall(address(nft), abi.encodeWithSelector(nft.basketOf.selector, 1), abi.encode(basketB));
        _mintRejected(HunterLifecycle.BasketMismatch.selector);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.reserveOf.selector, 1), abi.encode(uint256(1)));
        _mintRejected(HunterLifecycle.NonzeroReserve.selector);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.settled.selector, 1), abi.encode(true));
        _mintRejected(HunterLifecycle.AlreadySettled.selector);
        // A clean retry still receives id 1; failed hooks consumed no supply.
        assertEq(_mint(ALICE, 1, basketA), 1);
        _assertMemberEq(lc.currentMember(1), basketA, 100, 0, true, true);
    }

    function testTransferDependencyFaultsRollbackOwnerAndNonce() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        vault.deposit(id, 100);
        uint256 nonce = nft.authorizationNonce(id);
        vm.mockCall(address(nft), abi.encodeWithSelector(nft.ownerOf.selector, id), abi.encode(ALICE));
        _transferRejected(id, HunterLifecycle.OwnerMismatch.selector);
        vm.mockCall(address(nft), abi.encodeWithSelector(nft.basketOf.selector, id), abi.encode(basketB));
        _transferRejected(id, HunterLifecycle.BasketMismatch.selector);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.settled.selector, id), abi.encode(true));
        _transferRejected(id, HunterLifecycle.AlreadySettled.selector);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.reserveOf.selector, id), abi.encode(uint256(101)));
        _transferRejected(id, HunterLifecycle.ReserveMismatch.selector);
        assertEq(nft.authorizationNonce(id), nonce);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        assertEq(nft.ownerOf(id), BOB);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);
    }

    function testBurnDependencyFaultsRollbackAllRights() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        vault.deposit(id, 100);
        vm.mockCall(address(nft), abi.encodeWithSelector(nft.basketOf.selector, id), abi.encode(basketB));
        _burnRejected(id, HunterLifecycle.BasketMismatch.selector);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.reserveOf.selector, id), abi.encode(uint256(101)));
        _burnRejected(id, HunterLifecycle.ReserveMismatch.selector);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.settled.selector, id), abi.encode(true));
        _burnRejected(id, HunterLifecycle.AlreadySettled.selector);
        assertEq(token.balanceOf(ALICE), 900);
        assertEq(token.balanceOf(address(vault)), 100);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(ALICE), 1_000);
        assertEq(lc.finalBeneficiary(id), ALICE);
    }

    function testDepositBasketFaultRollsBackTokenAndCheckpoint() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.mockCall(address(nft), abi.encodeWithSelector(nft.basketOf.selector, id), abi.encode(basketB));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.BasketMismatch.selector, id));
        vault.deposit(id, 100);
        vm.clearMockedCalls();
        assertEq(token.balanceOf(ALICE), 1_000);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.historyLength(id), 0);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, true);
        vm.prank(ALICE);
        vault.deposit(id, 100);
        assertEq(vault.reserveOf(id), 100);
    }

    /// @dev These malformed hooks require impersonating the canonical module;
    /// the real NFT never emits a zero-owner mint/transfer/burn beneficiary.
    /// They verify defensive interface behavior, not attacker reachability.
    function testAuthenticatedMalformedHookArgumentsReject() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(address(nft));
        vm.expectRevert(HunterLifecycle.ZeroAddress.selector);
        lc.onMint(id, address(0), basketA);
        vm.prank(address(nft));
        vm.expectRevert(HunterLifecycle.ZeroAddress.selector);
        lc.onTransfer(id, address(0), ALICE);
        vm.prank(address(nft));
        vm.expectRevert(HunterLifecycle.ZeroAddress.selector);
        lc.onTransfer(id, ALICE, address(0));
        vm.prank(address(nft));
        vm.expectRevert(HunterLifecycle.InvalidBeneficiary.selector);
        lc.onBurn(id, address(0));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, true);
    }

    function testSettledReserveDependencyRejectsAuthenticatedCheckpoint() public {
        uint256 id = _mint(ALICE, 1, basketA);
        // Real reserve deposit already has a settled guard, so exercise the
        // lifecycle's independent dependency check at its authenticated boundary.
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.settled.selector, id), abi.encode(true));
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.AlreadySettled.selector, id));
        lc.onReserveChanged(id);
        vm.clearMockedCalls();
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, true);
    }

    function testBurnedHistoryRejectsReplayHooks() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        vm.prank(address(vault));
        vm.expectRevert(WeightedHistory.NotLive.selector);
        lc.onReserveChanged(id);
        vm.prank(address(nft));
        vm.expectRevert(WeightedHistory.NotLive.selector);
        lc.onBurn(id, ALICE);
        // A faulty dependency reports existence of the burned NFT. Immutable
        // lifecycle history still prevents resurrecting its transfer rights.
        vm.mockCall(address(nft), abi.encodeWithSelector(nft.ownerOf.selector, id), abi.encode(BOB));
        vm.prank(address(nft));
        vm.expectRevert(WeightedHistory.NotLive.selector);
        lc.onTransfer(id, ALICE, BOB);
        vm.clearMockedCalls();
        assertEq(lc.finalBeneficiary(id), ALICE);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, false, false);
        _assertTotalsEq(lc.currentGlobal(), 0, 0, 0);
    }

    function _mintRejected(bytes4 errorSelector) private {
        vm.expectRevert(abi.encodeWithSelector(errorSelector, uint256(1)));
        nft.mint(ALICE, bytes32(0), 0, 1, basketA);
        vm.clearMockedCalls();
        assertEq(nft.mintedEver(), 0);
        _assertTotalsEq(lc.currentGlobal(), 0, 0, 0);
        assertEq(vault.totalReserved(), 0);
    }

    function _transferRejected(uint256 id, bytes4 errorSelector) private {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(errorSelector, id));
        nft.transferFrom(ALICE, BOB, id);
        vm.clearMockedCalls();
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(vault.reserveOf(id), 100);
    }

    function _burnRejected(uint256 id, bytes4 errorSelector) private {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(errorSelector, id));
        nft.redeemAndDestroy(id);
        vm.clearMockedCalls();
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(lc.finalBeneficiary(id), address(0));
        assertFalse(vault.settled(id));
        assertEq(vault.reserveOf(id), 100);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);
    }
}

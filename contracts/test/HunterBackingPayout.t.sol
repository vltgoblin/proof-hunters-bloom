// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {HunterBackingVault} from "../src/bloom/HunterBackingVault.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {WeightedRoundMaterialisation} from "../src/bloom/WeightedRoundMaterialisation.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PayoutDebitToken is ERC20 {
    address public custody;
    uint256 public mode;
    bytes4 public callbackError;
    constructor() ERC20("Payout fixture", "PAY") {}

    function configure(address vault_, uint256 mode_) external {
        custody = vault_;
        mode = mode_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (msg.sender == custody && mode == 1) return true;
        bool ok = super.transfer(to, amount);
        if (msg.sender == custody && mode == 2) _burn(msg.sender, 1);
        if (msg.sender == custody && mode == 3) _mint(msg.sender, amount + 1);
        if (msg.sender == custody && mode == 4) {
            (bool success, bytes memory reason) =
                custody.call(abi.encodeWithSignature("claimBurned(uint32,uint256)", uint32(1), uint256(1)));
            require(!success && reason.length == 4, "callback must fail");
            callbackError = bytes4(reason);
        }
        return ok;
    }
}

contract HunterBackingPayoutTest is LifecycleTestBase {
    uint256 private id;
    ReserveTokenFixture private basketToken;

    function _cohort() private {
        vm.warp(86_399);
        id = _mint(ALICE, 1, basketA);
        uint256 other = _mint(ALICE, 1, basketA);
        vm.startPrank(ALICE);
        vault.deposit(id, 100);
        vault.deposit(other, 100);
        vm.stopPrank();
        basketToken = ReserveTokenFixture(basketA);
        basketToken.setVault(address(canonicalBacking));
        basketToken.mint(address(this), 1_000);
        basketToken.approve(address(canonicalBacking), type(uint256).max);
        vm.warp(86_400);
        canonicalLedger.recordRound(1, bytes32(uint256(1)), 2_000);
        canonicalLedger.freezeGroup(1, basketA);
        vm.warp(172_800);
        canonicalLedger.recordRound(2, bytes32(uint256(2)), 2_000);
        canonicalLedger.freezeGroup(2, basketA);
        vm.warp(172_801);
    }

    function testSaleBurnPaysBothAssetsAndLateFundingOnlyFinalBeneficiary() public {
        _cohort();
        basketToken.mint(address(canonicalBacking), 11);
        canonicalBacking.fund(1, basketA, 101);
        canonicalBacking.materialise(1, id);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        vm.prank(BOB);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(basketToken.balanceOf(BOB), 50);
        assertEq(lc.finalBeneficiary(id), BOB);
        assertTrue(canonicalBacking.burnSettled(id));
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 50);
        assertEq(vault.totalReserved(), 100);
        // Funding happens AFTER burn, but snapshot eligibility predates it.
        canonicalBacking.fund(2, basketA, 100);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.UnauthorizedBeneficiary.selector, id));
        canonicalBacking.claimBurned(2, id);
        assertFalse(canonicalBacking.consumed(2, id));
        vm.prank(BOB);
        canonicalBacking.claimBurned(2, id);
        assertEq(basketToken.balanceOf(BOB), 100);
        assertEq(canonicalBacking.totalReceived(basketA), 201);
        assertEq(canonicalBacking.totalReleased(basketA), 100);
        assertEq(basketToken.balanceOf(address(canonicalBacking)), 112);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 11);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundMaterialisation.AlreadyConsumed.selector, uint32(2), id));
        canonicalBacking.claimBurned(2, id);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundMaterialisation.AlreadyConsumed.selector, uint32(1), id));
        canonicalBacking.claimBurned(1, id);
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.BurnAlreadySettled.selector, id));
        canonicalBacking.onBurnBacking(id, BOB);
        vm.prank(BOB);
        vm.expectRevert();
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(basketToken.balanceOf(BOB), 100);
    }

    function testBasketPayoutFailureRollsBackHunterNFTAndEveryLedgerThenRetries() public {
        _cohort();
        canonicalBacking.fund(1, basketA, 100);
        canonicalBacking.materialise(1, id);
        basketToken.setBehavior(0, false, true, false);
        uint256 nonce = nft.authorizationNonce(id);
        vm.prank(ALICE);
        vm.expectRevert(ReserveTokenFixture.OutboundBlocked.selector);
        nft.redeemAndDestroy(id);
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.authorizationNonce(id), nonce);
        assertEq(token.balanceOf(ALICE), 800);
        assertEq(token.balanceOf(address(vault)), 200);
        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.totalReserved(), 200);
        assertFalse(vault.settled(id));
        assertEq(lc.finalBeneficiary(id), address(0));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 100, true, true);
        assertEq(canonicalBacking.backingOf(id), 50);
        assertFalse(canonicalBacking.burnSettled(id));
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertTrue(canonicalBacking.consumed(1, id));
        assertEq(basketToken.balanceOf(address(canonicalBacking)), 100);
        basketToken.setBehavior(0, false, false, false);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(ALICE), 900);
        assertEq(basketToken.balanceOf(ALICE), 50);
    }

    function testLateClaimFailurePreservesRightAndReleasedCounter() public {
        _cohort();
        canonicalBacking.fund(1, basketA, 100);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        basketToken.setBehavior(0, false, true, false);
        vm.prank(ALICE);
        vm.expectRevert(ReserveTokenFixture.OutboundBlocked.selector);
        canonicalBacking.claimBurned(1, id);
        assertFalse(canonicalBacking.consumed(1, id));
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertTrue(canonicalBacking.burnSettled(id));
        basketToken.setBehavior(0, false, false, false);
        vm.prank(ALICE);
        canonicalBacking.claimBurned(1, id);
        assertTrue(canonicalBacking.consumed(1, id));
        assertEq(basketToken.balanceOf(ALICE), 50);
        assertEq(canonicalBacking.totalReleased(basketA), 50);
    }

    function testZeroBurnAndZeroHistoricalClaimMakeNoBasketTokenCalls() public {
        _cohort();
        canonicalBacking.fund(1, basketA, 1);
        canonicalBacking.fund(2, basketA, 1);
        canonicalBacking.materialise(1, id);
        assertEq(canonicalBacking.backingOf(id), 0);
        // Any balanceOf or transfer would fail the transaction, even a view call.
        vm.mockCallRevert(basketA, abi.encodeWithSelector(basketToken.balanceOf.selector), hex"deadbeef");
        vm.mockCallRevert(basketA, abi.encodeWithSelector(basketToken.transfer.selector), hex"deadbeef");
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        vm.prank(ALICE);
        canonicalBacking.claimBurned(2, id);
        assertTrue(canonicalBacking.burnSettled(id));
        assertTrue(canonicalBacking.consumed(1, id));
        assertTrue(canonicalBacking.consumed(2, id));
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        vm.clearMockedCalls();
        assertEq(basketToken.balanceOf(address(canonicalBacking)), 2);
    }

    function testPayoutRejectsWrongCallerLiveUnknownAndWrongReciprocal() public {
        _cohort();
        vm.expectRevert(HunterBackingVault.UnauthorizedLifecycle.selector);
        canonicalBacking.onBurnBacking(id, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.MemberNotBurned.selector, id));
        canonicalBacking.claimBurned(1, id);
        vm.prank(ALICE);
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        canonicalBacking.claimBurned(1, 999);
        vm.mockCall(address(lc), abi.encodeWithSelector(lc.backing.selector), abi.encode(address(0xDEAD)));
        vm.prank(ALICE);
        vm.expectRevert(WeightedRoundMaterialisation.WiringMismatch.selector);
        nft.redeemAndDestroy(id);
        vm.clearMockedCalls();
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(token.balanceOf(ALICE), 800);
        assertEq(lc.finalBeneficiary(id), address(0));
        assertFalse(canonicalBacking.burnSettled(id));
    }

    function testSecondVaultOnSameLedgerRejectsConstruction() public {
        // Fixture is the positive case: predicted-address construction bound
        // this exact vault, so its reciprocal pointers resolve canonically.
        assertEq(address(canonicalBacking.lifecycle()), address(lc));
        assertEq(address(canonicalBacking.nft()), address(nft));
        assertEq(lc.backing(), address(canonicalBacking));
        // A second vault on the same ledger can never satisfy the check:
        // lc.backing() is immutable and already names canonicalBacking.
        vm.expectRevert(WeightedRoundMaterialisation.WiringMismatch.selector);
        new HunterBackingVault(address(canonicalLedger), address(this));
    }

    function testMandatoryBackingConstructorAndReciprocalGuards() public {
        uint64[4] memory weights = [uint64(100), uint64(110), uint64(125), uint64(150)];
        vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
        new HunterLifecycle(address(0x111), address(0x222), address(0), weights);
        vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
        new HunterLifecycle(address(0x111), address(0x222), address(0x111), weights);
        vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
        new HunterLifecycle(address(0x111), address(0x222), address(0x222), weights);
        address self = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
        new HunterLifecycle(address(0x111), address(0x222), self, weights);
        vm.mockCall(address(canonicalBacking), abi.encodeWithSignature("lifecycle()"), abi.encode(address(0xBAD)));
        vm.expectRevert(HunterLifecycle.WiringMismatch.selector);
        nft.mint(ALICE, bytes32(0), 0, 1, basketA);
        vm.clearMockedCalls();
        assertEq(nft.mintedEver(), 0);
        vm.mockCall(address(canonicalBacking), abi.encodeWithSignature("nft()"), abi.encode(address(0xBAD)));
        vm.expectRevert(HunterLifecycle.WiringMismatch.selector);
        nft.mint(ALICE, bytes32(0), 0, 1, basketA);
        vm.clearMockedCalls();
        assertEq(nft.mintedEver(), 0);
        assertEq(_mint(ALICE, 1, basketA), 1);
    }

    function testPositivePayoutRejectsNoDebitExtraDebitAndBalanceIncrease() public {
        PayoutDebitToken hostile = new PayoutDebitToken();
        registry.admitBasket(address(hostile), keccak256("test-only"));
        vm.warp(86_399);
        id = _mint(ALICE, 1, address(hostile));
        hostile.configure(address(canonicalBacking), 0);
        hostile.mint(address(this), 100);
        hostile.mint(address(canonicalBacking), 10);
        hostile.approve(address(canonicalBacking), 100);
        vm.warp(86_400);
        canonicalLedger.recordRound(1, bytes32(uint256(1)), 2_000);
        canonicalLedger.freezeGroup(1, address(hostile));
        canonicalBacking.fund(1, address(hostile), 100);
        canonicalBacking.materialise(1, id);
        for (uint256 mode = 1; mode <= 3; ++mode) {
            hostile.configure(address(canonicalBacking), mode);
            vm.prank(ALICE);
            vm.expectRevert(HunterBackingVault.DebitMismatch.selector);
            nft.redeemAndDestroy(id);
            assertEq(nft.ownerOf(id), ALICE);
            assertEq(canonicalBacking.backingOf(id), 100);
            assertFalse(canonicalBacking.burnSettled(id));
            assertEq(canonicalBacking.totalReleased(address(hostile)), 0);
            assertEq(hostile.balanceOf(address(canonicalBacking)), 110);
            assertEq(hostile.balanceOf(ALICE), 0);
        }
        hostile.configure(address(canonicalBacking), 4);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        assertEq(hostile.callbackError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(hostile.balanceOf(ALICE), 100);
        assertEq(canonicalBacking.unaccountedBalance(address(hostile)), 10);
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {IBasketConverter} from "../src/bloom/IBasketConverter.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @notice TEST-ONLY fixed-ratio converter. NOT production: no liquidity,
/// pricing or route logic — it records the exact call fields, pulls exactly
/// `amountIn` of `assetIn` from `msg.sender`, and pays `amountIn *
/// numerator / denominator` of a PRE-FUNDED `assetOut` balance back to
/// `msg.sender`. No recipient or calldata steering exists, matching the
/// narrow `IBasketConverter` surface.
contract AdmissionConverterFixture is IBasketConverter {
    uint256 public immutable numerator;
    uint256 public immutable denominator;

    uint256 public callCount;
    address public lastCaller;
    address public lastAssetIn;
    address public lastAssetOut;
    uint256 public lastAmountIn;
    uint256 public lastMinAmountOut;

    constructor(uint256 numerator_, uint256 denominator_) {
        require(denominator_ != 0);
        numerator = numerator_;
        denominator = denominator_;
    }

    function convert(address assetIn, address assetOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        ++callCount;
        lastCaller = msg.sender;
        lastAssetIn = assetIn;
        lastAssetOut = assetOut;
        lastAmountIn = amountIn;
        lastMinAmountOut = minAmountOut;
        require(IERC20(assetIn).transferFrom(msg.sender, address(this), amountIn));
        amountOut = (amountIn * numerator) / denominator;
        require(amountOut >= minAmountOut);
        require(IERC20(assetOut).transfer(msg.sender, amountOut));
    }
}

/// @notice TEST-ONLY contract wallet for the M2.3 admin-handoff proof. It
/// stores the actual `BasketRegistry` immutable and exposes ONLY the three
/// calls a registry owner needs — accepting an ownership nomination,
/// admitting a reviewed basket and flipping a basket's entry flag. There
/// is no signature or multisig simulation and no extra authority: every
/// call is still gated by the registry's own `onlyOwner`, so the wallet
/// has power only after `acceptOwnership` completes.
contract ContractWalletFixture {
    BasketRegistry public immutable registry;

    constructor(BasketRegistry registry_) {
        registry = registry_;
    }

    function accept() external {
        registry.acceptOwnership();
    }

    function admit(address basket, bytes32 reviewHash) external {
        registry.admitBasket(basket, reviewHash);
    }

    function setEntryEnabled(address basket, bool enabled) external {
        registry.setEntryEnabled(basket, enabled);
    }
}

contract HunterNewBasketAdmissionTest is LifecycleTestBase {
    /// @notice M2.3 requirements 1-4 over the actual assembled lifecycle: an
    /// existing basketA Hunter carrying a TEST-ONLY 50 HUNTER reserve and 30
    /// owner-deposited basketA units keeps owner, basket, authorization nonce,
    /// member, totals, reserve and history, both backing ledgers, per-source
    /// counters and every vault/user balance bit-identical when the registry
    /// admin later admits basketC — the stored record pins this chain's id,
    /// the admission-time codehash, the exact review hash and entryEnabled.
    /// A fresh tier-1 mint then selects basketC directly, and ALICE's Hunter
    /// moves A->C only through the reviewed M2.2 path: the day-1 request is
    /// immediately ready, the member stays paused until an exact measured
    /// 30 -> 60 conversion through the admitted 2:1 fixture, and completion
    /// changes the basket, bumps the authorization and switch nonces, clears
    /// the request and credits the owner-source ledger in C — with no HUNTER
    /// unlock and no wallet payout. NON-PRODUCTION values throughout.
    /// Requirement 5 (disable-entry: the pinned record loses only its
    /// entryEnabled flag while existing C positions still transfer,
    /// deposit and burn) runs in `_disableCAndProveEntryGatesAndTransfers`
    /// and `_proveDisabledCDepositsAndBurns`. Requirement 6 — the
    /// registry-ownership handoff to a TEST-ONLY contract wallet — runs
    /// last in `_proveContractWalletAdminHandoff`. All six frozen M2.3
    /// requirements are covered by this single integrated test.
    function testLateBasketAdmissionPreservesExistingAndSwitchesThroughM22() public {
        // 1. An existing basketA Hunter with HUNTER reserve and owner backing.
        vm.warp(1 days + 100);
        uint256 id = _mint(ALICE, 1, basketA);
        assertEq(id, 1);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 50), 50);
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assetA.mint(ALICE, 30);
        vm.prank(ALICE);
        assetA.approve(address(canonicalBacking), 30);
        vm.prank(ALICE);
        assertEq(canonicalBacking.depositOwnerBacking(id, 30), 30);
        uint256 authNonce = nft.authorizationNonce(id);
        uint256 aliceHunter = token.balanceOf(ALICE);
        _assertAlicePositionIntact(id, authNonce, aliceHunter);

        // 2. Late admission of basketC pins its record and moves nothing.
        ReserveTokenFixture assetC = new ReserveTokenFixture();
        address basketC = address(assetC);
        bytes32 reviewC = keccak256("reviewC");
        registry.admitBasket(basketC, reviewC);
        {
            BasketRegistry.Basket memory record = registry.basket(basketC);
            assertEq(record.chainId, block.chainid);
            assertEq(record.codeHashAtAdmission, basketC.codehash);
            assertEq(record.reviewHash, reviewC);
            assertTrue(record.entryEnabled);
        }
        assertTrue(registry.isEntryEnabled(basketC));
        _assertTotalsEq(lc.currentBasket(basketC), 0, 0, 0);
        _assertAlicePositionIntact(id, authNonce, aliceHunter);

        // 3. A new mint selects basketC directly.
        uint256 idC = _mint(BOB, 1, basketC);
        assertEq(idC, 2);
        assertEq(nft.mintedEver(), 2);
        assertEq(nft.ownerOf(idC), BOB);
        assertEq(nft.basketOf(idC), basketC);
        _assertMemberEq(lc.currentMember(idC), basketC, 100, 0, true, true);
        assertEq(vault.reserveOf(idC), 0);
        assertEq(canonicalBacking.backingOf(idC), 0);
        assertEq(canonicalBacking.ownerBackingOf(idC), 0);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 50, 1);
        _assertTotalsEq(lc.currentBasket(basketC), 100, 0, 1);
        _assertTotalsEq(lc.currentGlobal(), 200, 50, 2);

        // 4. The existing Hunter reaches C only through the M2.2 switch path.
        AdmissionConverterFixture converter = new AdmissionConverterFixture(2, 1);
        registry.admitConverter(address(converter), keccak256("review-converter-admission-2to1"));
        assetC.mint(address(converter), 60);
        assertTrue(registry.isConverterUsable(address(converter)));

        vm.prank(ALICE);
        assertEq(lc.requestSwitch(id, basketC), 1);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, basketC);
        assertEq(req.barrierDay, 1);
        assertEq(req.authorizationNonce, authNonce);
        assertEq(lc.switchNonce(id), 1);
        assertEq(lc.nextUncheckedDay(id), 2);
        // Day-1 mint: no eligible days precede the barrier — ready at once.
        assertTrue(lc.switchReady(id));
        // The pending request pauses the member until completion or cancel.
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, false);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketC), 100, 0, 1);
        _assertTotalsEq(lc.currentGlobal(), 100, 0, 1);

        vm.prank(ALICE);
        uint256 totalOut = lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        assertEq(totalOut, 60);
        assertEq(converter.callCount(), 1);
        assertEq(converter.lastCaller(), address(canonicalBacking));
        assertEq(converter.lastAssetIn(), basketA);
        assertEq(converter.lastAssetOut(), basketC);
        assertEq(converter.lastAmountIn(), 30);
        assertEq(converter.lastMinAmountOut(), 60);

        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.basketOf(id), basketC);
        assertEq(nft.authorizationNonce(id), authNonce + 1);
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        assertEq(lc.switchNonce(id), 2);
        assertEq(lc.nextUncheckedDay(id), 2);
        assertFalse(lc.switchReady(id));
        _assertMemberEq(lc.currentMember(id), basketC, 100, 50, true, true);
        assertEq(nft.basketOf(idC), basketC);
        _assertMemberEq(lc.currentMember(idC), basketC, 100, 0, true, true);
        assertEq(canonicalBacking.totalBackingOf(idC), 0);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketC), 200, 50, 2);
        _assertTotalsEq(lc.currentGlobal(), 200, 50, 2);

        // No HUNTER unlock and no wallet payout of any asset to ALICE.
        assertEq(vault.reserveOf(id), 50);
        assertEq(vault.totalReserved(), 50);
        assertEq(token.balanceOf(address(vault)), 50);
        assertEq(token.balanceOf(ALICE), aliceHunter);
        assertEq(assetA.balanceOf(ALICE), 0);
        assertEq(assetC.balanceOf(ALICE), 0);

        // Round-source ledger stays zero; the whole 60-unit output lands on
        // the owner-source ledger and the per-source counters move exactly.
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 60);
        assertEq(canonicalBacking.totalBackingOf(id), 60);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 30);
        assertEq(canonicalBacking.totalReceived(basketC), 0);
        assertEq(canonicalBacking.totalReleased(basketC), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketC), 60);
        assertEq(canonicalBacking.totalOwnerReleased(basketC), 0);
        assertEq(canonicalBacking.totalReceived(basketB), 0);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        assertEq(assetA.balanceOf(address(canonicalBacking)), 0);
        assertEq(assetC.balanceOf(address(canonicalBacking)), 60);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketC), 0);
        assertEq(assetA.balanceOf(address(converter)), 30);
        assertEq(assetC.balanceOf(address(converter)), 0);
        assertEq(assetA.allowance(address(canonicalBacking), address(converter)), 0);

        // 5. Disable-entry and its exit paths run in the two helpers;
        // `id3` is the still-enabled basketA Hunter that survives them.
        uint256 id3 = _disableCAndProveEntryGatesAndTransfers(id, idC, basketC, reviewC);
        _proveDisabledCDepositsAndBurns(id, idC, id3, basketC, reviewC);

        // 6. Registry-ownership handoff to a TEST-ONLY contract wallet:
        // nomination, acceptance, the former owner's rejected calls and
        // the wallet's own admit/disable moves — all proven against the
        // surviving basketA position.
        _proveContractWalletAdminHandoff(id3, basketC, reviewC);
    }

    /// @dev Snapshot of every existing-position value a basket admission must
    /// leave untouched: owner, basket, authorization nonce, empty switch
    /// state, live member, current totals, beneficiary, reserve plus its
    /// history, both backing ledgers, per-source counters, settlement flags,
    /// minted supply and the relevant vault/user token balances. Called
    /// immediately before and immediately after `admitBasket` — the second
    /// call proves admission moved nothing. All expected values are TEST-ONLY.
    function _assertAlicePositionIntact(uint256 id, uint256 authNonce, uint256 aliceHunter) private {
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.basketOf(id), basketA);
        assertEq(nft.authorizationNonce(id), authNonce);
        assertEq(lc.switchNonce(id), 0);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 50, 1);
        _assertTotalsEq(lc.currentBasket(basketB), 0, 0, 0);
        _assertTotalsEq(lc.currentGlobal(), 100, 50, 1);
        assertEq(lc.finalBeneficiary(id), address(0));
        assertEq(nft.mintedEver(), 1);
        assertEq(vault.reserveOf(id), 50);
        assertEq(vault.totalReserved(), 50);
        assertEq(vault.historyLength(id), 1);
        (uint256 ts, uint256 amount) = vault.history(id, 0);
        assertEq(ts, 1 days + 100);
        assertEq(amount, 50);
        assertFalse(vault.settled(id));
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);
        assertEq(canonicalBacking.totalBackingOf(id), 30);
        assertFalse(canonicalBacking.burnSettled(id));
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 0);
        assertEq(canonicalBacking.totalReceived(basketB), 0);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        assertEq(token.balanceOf(address(vault)), 50);
        assertEq(vault.unreservedBalance(), 0);
        assertEq(token.balanceOf(ALICE), aliceHunter);
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assertEq(assetA.balanceOf(ALICE), 0);
        assertEq(assetA.balanceOf(address(canonicalBacking)), 30);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 0);
    }

    /// @dev M2.3 requirement 5 over the actual assembled lifecycle: the
    /// registry admin disables basketC entry, which must rewrite ONLY the
    /// `entryEnabled` flag of the admission-pinned record — chain id,
    /// admission-time codehash and review hash stay bit-identical. With C
    /// disabled, the real fixed-minter `nft.mint` rejects a new tier-1 C
    /// mint with `HunterNFT.InvalidBasket` and `requestSwitch` into C
    /// reverts with `HunterLifecycle.BasketNotEnabled` without touching
    /// request, member, totals or authorization nonce — while the
    /// still-enabled basketA mints a third Hunter normally and both
    /// pre-existing C Hunters still transfer between owners, bumping only
    /// owner and authorization nonce. All addresses and amounts are
    /// TEST-ONLY. Returns the third Hunter id so the disabled-basket
    /// deposit/burn and contract-wallet handoff proofs can keep using it.
    function _disableCAndProveEntryGatesAndTransfers(uint256 id, uint256 idC, address basketC, bytes32 reviewC)
        private
        returns (uint256 id3)
    {
        // 5. Disabling entry flips only entryEnabled on the pinned record.
        registry.setEntryEnabled(basketC, false);
        {
            BasketRegistry.Basket memory record = registry.basket(basketC);
            assertEq(record.chainId, block.chainid);
            assertEq(record.codeHashAtAdmission, basketC.codehash);
            assertEq(record.reviewHash, reviewC);
            assertFalse(record.entryEnabled);
        }
        assertFalse(registry.isEntryEnabled(basketC));

        // The real mint entry point rejects disabled-basket mints and
        // minted supply does not move.
        address small = address(0x5A11); // TEST-ONLY recipient address.
        assertEq(nft.mintedEver(), 2);
        uint256 challengeId = nft.mintedEver();
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.InvalidBasket.selector, basketC));
        nft.mint(small, bytes32(0), challengeId, 1, basketC);
        assertEq(nft.mintedEver(), 2);

        // The still-enabled basketA mints a third tier-1 Hunter normally.
        id3 = _mint(small, 1, basketA);
        assertEq(id3, 3);
        assertEq(nft.mintedEver(), 3);
        assertEq(nft.ownerOf(id3), small);
        assertEq(nft.basketOf(id3), basketA);
        assertEq(nft.authorizationNonce(id3), 1);
        _assertMemberEq(lc.currentMember(id3), basketA, 100, 0, true, true);
        assertEq(vault.reserveOf(id3), 0);
        assertEq(canonicalBacking.backingOf(id3), 0);
        assertEq(canonicalBacking.ownerBackingOf(id3), 0);

        // A switch request into the disabled basket reverts exactly and
        // changes nothing.
        vm.prank(small);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.BasketNotEnabled.selector, basketC));
        lc.requestSwitch(id3, basketC);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id3);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        assertEq(lc.switchNonce(id3), 0);
        assertEq(nft.authorizationNonce(id3), 1);
        _assertMemberEq(lc.currentMember(id3), basketA, 100, 0, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 0, 1);
        _assertTotalsEq(lc.currentBasket(basketC), 200, 50, 2);
        _assertTotalsEq(lc.currentGlobal(), 300, 50, 3);

        // With C still disabled, both existing C Hunters swap owners:
        // ALICE hands the switched Hunter to BOB, BOB hands the minted one
        // to ALICE. Only owner and authorization nonce move.
        assertEq(nft.authorizationNonce(id), 2);
        assertEq(nft.authorizationNonce(idC), 1);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        vm.prank(BOB);
        nft.transferFrom(BOB, ALICE, idC);
        assertEq(nft.authorizationNonce(id), 3);
        assertEq(nft.authorizationNonce(idC), 2);
        assertEq(nft.ownerOf(id), BOB);
        assertEq(nft.ownerOf(idC), ALICE);
        assertEq(nft.basketOf(id), basketC);
        assertEq(nft.basketOf(idC), basketC);
        _assertMemberEq(lc.currentMember(id), basketC, 100, 50, true, true);
        _assertMemberEq(lc.currentMember(idC), basketC, 100, 0, true, true);
        assertEq(vault.reserveOf(id), 50);
        assertEq(canonicalBacking.ownerBackingOf(id), 60);
        assertEq(canonicalBacking.totalBackingOf(id), 60);
        assertEq(vault.reserveOf(idC), 0);
        assertEq(canonicalBacking.backingOf(idC), 0);
        assertEq(canonicalBacking.ownerBackingOf(idC), 0);
        assertEq(canonicalBacking.totalBackingOf(idC), 0);
        assertEq(lc.switchNonce(id), 2);
        assertEq(lc.switchNonce(idC), 0);
        _assertTotalsEq(lc.currentBasket(basketC), 200, 50, 2);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 0, 1);
        _assertTotalsEq(lc.currentGlobal(), 300, 50, 3);
        assertFalse(registry.isEntryEnabled(basketC));
        assertEq(nft.mintedEver(), 3);
    }

    /// @dev The remaining requirement-5 exit proof over the actual
    /// assembled lifecycle: with basketC entry still disabled, TEST-ONLY
    /// owner-source deposits of 20 C into `id` (BOB) and 10 C into `idC`
    /// (ALICE) still land exactly on the owner ledger — owners,
    /// authorization nonces, members, totals, reserves and histories stay
    /// bit-identical. Burning both through `nft.redeemAndDestroy` then
    /// pays each owner exactly: BOB gets the 50 HUNTER reserve plus 80 C
    /// of owner backing, ALICE gets 10 C. Both C members end dead and
    /// ineligible with rarity100/HUNTER0, C totals and both vaults drain
    /// to zero, the reserve and backing ledgers settle, and the
    /// per-source counters balance at 90 received/released for C (30/30
    /// for the old basketA owner source, round source still zero) — while
    /// the surviving basketA Hunter `id3` and the disabled basketC record
    /// keep their pinned identity. All addresses and amounts are
    /// TEST-ONLY. Repeat-burn generic coverage stays a later slice; the
    /// frozen requirement-6 ownership handoff runs next in
    /// `_proveContractWalletAdminHandoff`.
    function _proveDisabledCDepositsAndBurns(uint256 id, uint256 idC, uint256 id3, address basketC, bytes32 reviewC)
        private
    {
        ReserveTokenFixture assetC = ReserveTokenFixture(basketC);
        address small = address(0x5A11); // TEST-ONLY recipient address.

        // Owner-source deposits still land exactly while C stays disabled.
        assetC.mint(BOB, 20);
        vm.prank(BOB);
        assetC.approve(address(canonicalBacking), 20);
        vm.prank(BOB);
        assertEq(canonicalBacking.depositOwnerBacking(id, 20), 20);
        assetC.mint(ALICE, 10);
        vm.prank(ALICE);
        assetC.approve(address(canonicalBacking), 10);
        vm.prank(ALICE);
        assertEq(canonicalBacking.depositOwnerBacking(idC, 10), 10);

        assertEq(nft.ownerOf(id), BOB);
        assertEq(nft.authorizationNonce(id), 3);
        assertEq(nft.ownerOf(idC), ALICE);
        assertEq(nft.authorizationNonce(idC), 2);
        assertEq(lc.switchNonce(id), 2);
        assertEq(lc.switchNonce(idC), 0);
        _assertMemberEq(lc.currentMember(id), basketC, 100, 50, true, true);
        _assertMemberEq(lc.currentMember(idC), basketC, 100, 0, true, true);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.backingOf(idC), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 80);
        assertEq(canonicalBacking.ownerBackingOf(idC), 10);
        assertEq(canonicalBacking.totalBackingOf(id), 80);
        assertEq(canonicalBacking.totalBackingOf(idC), 10);
        assertEq(canonicalBacking.totalOwnerReceived(basketC), 90);
        assertEq(canonicalBacking.totalOwnerReleased(basketC), 0);
        assertEq(assetC.balanceOf(address(canonicalBacking)), 90);
        assertEq(canonicalBacking.unaccountedBalance(basketC), 0);

        // Reserves, histories and totals are untouched by the deposits.
        assertEq(vault.reserveOf(id), 50);
        assertEq(vault.reserveOf(idC), 0);
        assertEq(vault.reserveOf(id3), 0);
        assertEq(vault.totalReserved(), 50);
        assertEq(token.balanceOf(address(vault)), 50);
        assertEq(vault.historyLength(id), 1);
        (uint256 ts, uint256 amount) = vault.history(id, 0);
        assertEq(ts, 1 days + 100);
        assertEq(amount, 50);
        assertEq(vault.historyLength(idC), 0);
        assertEq(vault.historyLength(id3), 0);
        _assertTotalsEq(lc.currentBasket(basketC), 200, 50, 2);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 0, 1);
        _assertTotalsEq(lc.currentGlobal(), 300, 50, 3);

        // Burning through redeemAndDestroy pays each owner exactly.
        uint256 bobHunter = token.balanceOf(BOB);
        uint256 bobC = assetC.balanceOf(BOB);
        uint256 aliceHunter = token.balanceOf(ALICE);
        uint256 aliceC = assetC.balanceOf(ALICE);
        vm.prank(BOB);
        nft.redeemAndDestroy(id);
        vm.prank(ALICE);
        nft.redeemAndDestroy(idC);
        assertEq(token.balanceOf(BOB), bobHunter + 50);
        assertEq(assetC.balanceOf(BOB), bobC + 80);
        assertEq(assetC.balanceOf(ALICE), aliceC + 10);
        assertEq(token.balanceOf(ALICE), aliceHunter);

        // Both C members are dead; the surviving A Hunter keeps everything.
        assertEq(lc.finalBeneficiary(id), BOB);
        assertEq(lc.finalBeneficiary(idC), ALICE);
        _assertMemberEq(lc.currentMember(id), basketC, 100, 0, false, false);
        _assertMemberEq(lc.currentMember(idC), basketC, 100, 0, false, false);
        _assertTotalsEq(lc.currentBasket(basketC), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 0, 1);
        _assertTotalsEq(lc.currentGlobal(), 100, 0, 1);
        assertEq(nft.ownerOf(id3), small);
        assertEq(nft.basketOf(id3), basketA);
        assertEq(nft.authorizationNonce(id3), 1);
        assertEq(lc.switchNonce(id3), 0);
        assertEq(lc.finalBeneficiary(id3), address(0));
        _assertMemberEq(lc.currentMember(id3), basketA, 100, 0, true, true);
        assertEq(vault.reserveOf(id3), 0);
        assertEq(canonicalBacking.backingOf(id3), 0);
        assertEq(canonicalBacking.ownerBackingOf(id3), 0);

        // Reserve and backing ledgers settle; every per-source counter
        // balances and both vaults are empty.
        assertEq(vault.reserveOf(id), 0);
        assertTrue(vault.settled(id));
        assertEq(vault.reserveOf(idC), 0);
        assertTrue(vault.settled(idC));
        assertEq(vault.totalReserved(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.unreservedBalance(), 0);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 0);
        assertEq(canonicalBacking.totalBackingOf(id), 0);
        assertTrue(canonicalBacking.burnSettled(id));
        assertEq(canonicalBacking.backingOf(idC), 0);
        assertEq(canonicalBacking.ownerBackingOf(idC), 0);
        assertEq(canonicalBacking.totalBackingOf(idC), 0);
        assertTrue(canonicalBacking.burnSettled(idC));
        assertEq(canonicalBacking.totalOwnerReceived(basketC), 90);
        assertEq(canonicalBacking.totalOwnerReleased(basketC), 90);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 30);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalReceived(basketC), 0);
        assertEq(canonicalBacking.totalReleased(basketC), 0);
        assertEq(canonicalBacking.totalReceived(basketB), 0);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        assertEq(assetC.balanceOf(address(canonicalBacking)), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketC), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 0);
        assertEq(nft.mintedEver(), 3);

        // basketC stays disabled with its admission-pinned identity.
        {
            BasketRegistry.Basket memory record = registry.basket(basketC);
            assertEq(record.chainId, block.chainid);
            assertEq(record.codeHashAtAdmission, basketC.codehash);
            assertEq(record.reviewHash, reviewC);
            assertFalse(record.entryEnabled);
        }
        assertFalse(registry.isEntryEnabled(basketC));
    }

    /// @dev M2.3 requirement 6 over the actual assembled lifecycle: the
    /// current registry owner hands administration to a TEST-ONLY contract
    /// wallet through the real two-step Ownable transfer. Nomination alone
    /// moves no power — owner stays this contract, the wallet sits in
    /// `pendingOwner` and its premature `admitBasket` reverts with the
    /// exact `OwnableUnauthorizedAccount` error. Acceptance then makes
    /// the wallet the owner, strips the former owner of every registry
    /// call, and lets the wallet admit a fourth reviewed basketD and
    /// disable basketA entry — while the surviving basketA Hunter `id3`,
    /// the settled basketC accounting, every balance and the immutable
    /// module wiring stay bit-identical. All addresses and amounts are
    /// TEST-ONLY.
    function _proveContractWalletAdminHandoff(uint256 id3, address basketC, bytes32 reviewC) private {
        // The existing-position invariant before any ownership move.
        _assertHandoffInvariant(id3, basketC, reviewC);

        // A fourth reviewed basket and the contract-wallet admin fixture.
        ReserveTokenFixture assetD = new ReserveTokenFixture();
        address basketD = address(assetD);
        bytes32 reviewD = keccak256("reviewD"); // TEST-ONLY nonzero review hash.
        ContractWalletFixture wallet = new ContractWalletFixture(registry);

        // Nomination only stages the handoff: owner is unchanged, the
        // wallet is pending, and its early admit reverts with the exact
        // Ownable error — position, accounting and registry state intact.
        registry.transferOwnership(address(wallet));
        assertEq(registry.owner(), address(this));
        assertEq(registry.pendingOwner(), address(wallet));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(wallet)));
        wallet.admit(basketD, reviewD);
        assertEq(registry.owner(), address(this));
        assertEq(registry.pendingOwner(), address(wallet));
        assertFalse(registry.isEntryEnabled(basketD));
        _assertHandoffInvariant(id3, basketC, reviewC);

        // Acceptance completes the handoff in one step.
        wallet.accept();
        assertEq(registry.owner(), address(wallet));
        assertEq(registry.pendingOwner(), address(0));

        // The former owner retains no registry power: both direct calls
        // revert with the exact Ownable error, so D stays unadmitted until
        // the wallet acts and A keeps its entry flag.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.admitBasket(basketD, reviewD);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setEntryEnabled(basketA, false);
        assertTrue(registry.isEntryEnabled(basketA));

        // The new admin admits basketD; the stored record pins this
        // chain's id, the admission-time codehash, reviewD and enabled.
        wallet.admit(basketD, reviewD);
        {
            BasketRegistry.Basket memory record = registry.basket(basketD);
            assertEq(record.chainId, block.chainid);
            assertEq(record.codeHashAtAdmission, basketD.codehash);
            assertEq(record.reviewHash, reviewD);
            assertTrue(record.entryEnabled);
        }
        assertTrue(registry.isEntryEnabled(basketD));
        _assertTotalsEq(lc.currentBasket(basketD), 0, 0, 0);

        // The new admin flips real entry status: basketA keeps its pinned
        // identity and loses only the entryEnabled flag.
        wallet.setEntryEnabled(basketA, false);
        {
            BasketRegistry.Basket memory record = registry.basket(basketA);
            assertEq(record.chainId, block.chainid);
            assertEq(record.codeHashAtAdmission, basketA.codehash);
            assertEq(record.reviewHash, keccak256("reviewA"));
            assertFalse(record.entryEnabled);
        }
        assertFalse(registry.isEntryEnabled(basketA));

        // Nomination, acceptance, the rejected former-owner calls, the D
        // admission and the A status change leave every Hunter-side value
        // and the module wiring bit-identical; no balances moved.
        _assertHandoffInvariant(id3, basketC, reviewC);
        assertEq(assetD.balanceOf(address(canonicalBacking)), 0);
        assertEq(assetD.balanceOf(address(wallet)), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketD), 0);
        assertEq(vault.totalReserved(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(wallet)), 0);
        assertEq(registry.owner(), address(wallet));
    }

    /// @dev Everything the registry-ownership handoff must leave
    /// bit-identical: the surviving basketA Hunter `id3` (owner
    /// address(0x5A11), basket, authorization nonce 1, empty switch
    /// request and final beneficiary, live member, zero reserve with
    /// empty history and both backing ledgers empty), minted supply, the
    /// basketA and global totals, the disabled basketC record's pinned
    /// identity with its settled 90/90 owner-source counters, and the
    /// immutable NFT/lifecycle/reserve/backing/registry wiring. Called
    /// before the nomination, after the wallet's premature admit reverts,
    /// and again after the wallet's admit/disable calls. All values are
    /// TEST-ONLY.
    function _assertHandoffInvariant(uint256 id3, address basketC, bytes32 reviewC) private {
        assertEq(nft.ownerOf(id3), address(0x5A11));
        assertEq(nft.basketOf(id3), basketA);
        assertEq(nft.authorizationNonce(id3), 1);
        assertEq(lc.switchNonce(id3), 0);
        HunterLifecycle.SwitchRequest memory req3 = lc.switchRequestOf(id3);
        assertEq(req3.target, address(0));
        assertEq(req3.barrierDay, 0);
        assertEq(req3.authorizationNonce, 0);
        assertEq(lc.finalBeneficiary(id3), address(0));
        _assertMemberEq(lc.currentMember(id3), basketA, 100, 0, true, true);
        assertEq(vault.reserveOf(id3), 0);
        assertEq(vault.historyLength(id3), 0);
        assertFalse(vault.settled(id3));
        assertEq(canonicalBacking.backingOf(id3), 0);
        assertEq(canonicalBacking.ownerBackingOf(id3), 0);
        assertEq(canonicalBacking.totalBackingOf(id3), 0);
        assertFalse(canonicalBacking.burnSettled(id3));
        assertEq(nft.mintedEver(), 3);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 0, 1);
        _assertTotalsEq(lc.currentGlobal(), 100, 0, 1);
        {
            BasketRegistry.Basket memory record = registry.basket(basketC);
            assertEq(record.chainId, block.chainid);
            assertEq(record.codeHashAtAdmission, basketC.codehash);
            assertEq(record.reviewHash, reviewC);
            assertFalse(record.entryEnabled);
        }
        assertFalse(registry.isEntryEnabled(basketC));
        assertEq(canonicalBacking.totalOwnerReceived(basketC), 90);
        assertEq(canonicalBacking.totalOwnerReleased(basketC), 90);
        assertEq(canonicalBacking.totalReceived(basketC), 0);
        assertEq(canonicalBacking.totalReleased(basketC), 0);
        assertEq(ReserveTokenFixture(basketC).balanceOf(address(canonicalBacking)), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketC), 0);
        assertEq(address(nft.LIFECYCLE()), address(lc));
        assertEq(address(nft.REGISTRY()), address(registry));
        assertEq(lc.nft(), address(nft));
        assertEq(lc.reserve(), address(vault));
        assertEq(lc.backing(), address(canonicalBacking));
        assertEq(address(vault.NFT()), address(nft));
        assertEq(address(vault.LIFECYCLE()), address(lc));
        assertEq(address(canonicalBacking.nft()), address(nft));
        assertEq(address(canonicalBacking.lifecycle()), address(lc));
    }
}

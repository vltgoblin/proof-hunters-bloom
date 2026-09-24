// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HunterBackingVault} from "../src/bloom/HunterBackingVault.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";
import {WeightedRoundMaterialisation} from "../src/bloom/WeightedRoundMaterialisation.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {HostileReceiptFixture} from "./WeightedRoundFundingHostile.t.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice TEST-ONLY basket asset that mutates NFT custody mid-pull: after
/// an honest inbound `_update` to the configured backing vault it calls the
/// real `nft.escrowTo` while still the Hunter's owner. Open mint/config; it
/// never calls the backing vault itself and adds no production authority —
/// custody moves only through the NFT's own `escrowTo` during `transferFrom`.
contract OwnerBackingCallbackTokenFixture is ERC20 {
    address public backingVault;
    HunterNFT public callbackNft;
    uint256 public callbackTokenId;
    address public callbackHolder;
    bool public callbackEnabled;

    constructor() ERC20("Fixture CALLBACK", "fCALL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev TEST-ONLY wiring for the escrow callback.
    function setCallback(address vault, address nft_, uint256 tokenId, address holder, bool enabled) external {
        backingVault = vault;
        callbackNft = HunterNFT(nft_);
        callbackTokenId = tokenId;
        callbackHolder = holder;
        callbackEnabled = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (callbackEnabled && from == address(this) && to == backingVault) {
            callbackNft.escrowTo(callbackTokenId, callbackHolder, "");
        }
    }
}

/// @notice Owner-backing deposit leg of the REAL canonical assembly:
/// HunterLifecycle <-> HunterNFT <-> HunterBackingVault. Only the token and
/// escrow fixtures are reused — every Hunter here is a real mint. Owner
/// deposits are a second liability source beside materialised round backing;
/// the two counter families never mix.
contract HunterOwnerBackingDepositTest is LifecycleTestBase {
    /// @dev Mirrors HunterBackingVault.OwnerBackingDeposited so expectEmit
    /// can match the real event exactly.
    event OwnerBackingDeposited(
        uint256 indexed tokenId,
        address indexed asset,
        address indexed owner,
        uint256 requested,
        uint256 received,
        uint256 backing
    );

    /// @notice Measured receipts only: a taxed pull credits the net amount,
    /// deposits repeat, survive basket disabling and stay on the tokenId
    /// across a sale. A direct donation is held but never accounted.
    function testOwnerDepositsMeasuredRepeatSaleDisabledAndDonation() public {
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(canonicalBacking)); // TEST-ONLY hook binding

        // TEST-ONLY non-production balances and approvals.
        asset.mint(ALICE, 1_000);
        asset.mint(BOB, 1_000);
        asset.mint(address(this), 1_000);
        vm.prank(ALICE);
        asset.approve(address(canonicalBacking), type(uint256).max);
        vm.prank(BOB);
        asset.approve(address(canonicalBacking), type(uint256).max);

        uint256 tokenId = _mint(ALICE, 1, basketA);

        // Direct donation of exactly 7: sender -7, vault +7, counted nowhere.
        uint256 senderBefore = asset.balanceOf(address(this));
        uint256 vaultBefore = asset.balanceOf(address(canonicalBacking));
        assertTrue(asset.transfer(address(canonicalBacking), 7));
        assertEq(asset.balanceOf(address(this)), senderBefore - 7);
        assertEq(asset.balanceOf(address(canonicalBacking)), vaultBefore + 7);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 0);

        // TEST-ONLY 10% receipt tax: requested 100 measures to a 90 credit
        // while ALICE is still debited the full 100.
        asset.setBehavior(1_000, false, false, false);
        uint256 aliceBefore = asset.balanceOf(ALICE);
        vaultBefore = asset.balanceOf(address(canonicalBacking));
        vm.expectEmit(true, true, true, true, address(canonicalBacking));
        emit OwnerBackingDeposited(tokenId, basketA, ALICE, 100, 90, 90);
        vm.prank(ALICE);
        uint256 received = canonicalBacking.depositOwnerBacking(tokenId, 100);
        assertEq(received, 90);
        assertEq(asset.balanceOf(ALICE), aliceBefore - 100);
        assertEq(asset.balanceOf(address(canonicalBacking)), vaultBefore + 90);
        _assertCounters(tokenId, 0, 90, 0, 0, 90, 0);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);

        asset.setBehavior(0, false, false, false); // reset TEST-ONLY tax
        vm.prank(ALICE);
        assertEq(canonicalBacking.depositOwnerBacking(tokenId, 20), 20);
        _assertCounters(tokenId, 0, 110, 0, 0, 110, 0);
        assertEq(asset.balanceOf(address(canonicalBacking)), 117); // 110 liability + 7 donation
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);

        // Disabled basket entry never freezes an already-minted Hunter.
        registry.setEntryEnabled(basketA, false);
        vm.prank(ALICE);
        assertEq(canonicalBacking.depositOwnerBacking(tokenId, 10), 10);
        _assertCounters(tokenId, 0, 120, 0, 0, 120, 0);

        // The full 120 stays bound to the tokenId through the sale.
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, tokenId);
        assertEq(nft.ownerOf(tokenId), BOB);
        _assertCounters(tokenId, 0, 120, 0, 0, 120, 0);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);

        // The previous owner is rejected exactly and nothing moves.
        aliceBefore = asset.balanceOf(ALICE);
        vaultBefore = asset.balanceOf(address(canonicalBacking));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.NotTokenOwner.selector, tokenId));
        canonicalBacking.depositOwnerBacking(tokenId, 5);
        assertEq(asset.balanceOf(ALICE), aliceBefore);
        assertEq(asset.balanceOf(address(canonicalBacking)), vaultBefore);
        _assertCounters(tokenId, 0, 120, 0, 0, 120, 0);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);

        // The new owner continues the same backing position.
        uint256 bobBefore = asset.balanceOf(BOB);
        vaultBefore = asset.balanceOf(address(canonicalBacking));
        vm.expectEmit(true, true, true, true, address(canonicalBacking));
        emit OwnerBackingDeposited(tokenId, basketA, BOB, 30, 30, 150);
        vm.prank(BOB);
        assertEq(canonicalBacking.depositOwnerBacking(tokenId, 30), 30);
        assertEq(asset.balanceOf(BOB), bobBefore - 30);
        assertEq(asset.balanceOf(address(canonicalBacking)), vaultBefore + 30);
        _assertCounters(tokenId, 0, 150, 0, 0, 150, 0);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);
    }

    /// @notice Every deposit gate rejects exactly, in order, without moving
    /// any accounting: zero amount, wrong owner, nonexistent and burned ids,
    /// escrowed and credit-locked tokens. The zero-backed burn itself
    /// settles normally — its expectations are kept separate below.
    function testRejectsZeroWrongOwnerDeadEscrowAndCreditLocked() public {
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(canonicalBacking)); // TEST-ONLY hook binding
        asset.mint(ALICE, 1_000); // TEST-ONLY non-production balance
        vm.prank(ALICE);
        asset.approve(address(canonicalBacking), type(uint256).max); // TEST-ONLY

        // One fresh Hunter per independent rejection state.
        uint256 idZero = _mint(ALICE, 1, basketA);
        uint256 idWrongOwner = _mint(ALICE, 1, basketA);
        uint256 idBurn = _mint(ALICE, 1, basketA);
        uint256 idEscrow = _mint(ALICE, 1, basketA);
        uint256 idCredit = _mint(ALICE, 1, basketA);
        uint256 idNone = nft.mintedEver() + 1; // never minted

        uint256 aliceStart = asset.balanceOf(ALICE);

        // Zero amount from the correct owner: the inherited gate fires first.
        vm.prank(ALICE);
        vm.expectRevert(WeightedRoundFunding.InvalidAmount.selector);
        canonicalBacking.depositOwnerBacking(idZero, 0);
        _assertRejectionKeptState(idZero, aliceStart);

        // Wrong owner on a live token.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.NotTokenOwner.selector, idWrongOwner));
        canonicalBacking.depositOwnerBacking(idWrongOwner, 10);
        _assertRejectionKeptState(idWrongOwner, aliceStart);

        // Never-minted id: the canonical OpenZeppelin ownerOf revert.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, idNone));
        canonicalBacking.depositOwnerBacking(idNone, 10);
        _assertRejectionKeptState(idNone, aliceStart);

        // Burn settlement expectations, kept separate: the zero-backed burn
        // runs the real lifecycle hook, emits both zero payout events and
        // sets burnSettled — no counter or balance moves.
        vm.prank(ALICE);
        nft.redeemAndDestroy(idBurn);
        assertTrue(canonicalBacking.burnSettled(idBurn));
        assertEq(lc.finalBeneficiary(idBurn), ALICE);
        _assertRejectionKeptState(idBurn, aliceStart);

        // The dead id now carries the same nonexistent-token rejection.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, idBurn));
        canonicalBacking.depositOwnerBacking(idBurn, 10);
        _assertRejectionKeptState(idBurn, aliceStart);

        // Escrowed: the escrow contract is the new ownerOf, yet even it is
        // blocked because the token is encumbered.
        vm.prank(ALICE);
        nft.escrowTo(idEscrow, address(escrow), "");
        assertTrue(nft.isEncumbered(idEscrow));
        vm.prank(address(escrow));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.TokenEncumbered.selector, idEscrow));
        canonicalBacking.depositOwnerBacking(idEscrow, 10);
        _assertRejectionKeptState(idEscrow, aliceStart);

        // Credit lock: the production loan opener is milestone M3 — the prank
        // below reaches the real NFT's lockCredit through the lifecycle
        // address purely as TEST-ONLY reachability setup; the NFT and the
        // backing vault here are the actual contracts.
        uint256 creditNonce = nft.authorizationNonce(idCredit);
        vm.prank(address(lc));
        nft.lockCredit(idCredit, address(escrow), ALICE, creditNonce);
        assertTrue(nft.isEncumbered(idCredit));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.TokenEncumbered.selector, idCredit));
        canonicalBacking.depositOwnerBacking(idCredit, 10);
        _assertRejectionKeptState(idCredit, aliceStart);
    }

    /// @notice Hostile measured-receipt paths for owner deposits: a false
    /// success flag, a bonus mint and a recipient decrease each revert with
    /// the exact error and roll back atomically — the pre-seeded donation
    /// stays unaccounted. A 50% inbound tax credits only the measured 50.
    /// The same guards hold on basketB: a 100% tax yields a zero receipt
    /// and `UnsupportedTokenReceipt`, the fixture's inbound revert bubbles
    /// exactly, and a reset retry succeeds. TEST-ONLY fixtures — no claim
    /// of arbitrary-token support is made or implied.
    function testHostileReceiptsRollbackZeroFalseBonusDecreaseRevertAndTaxed() public {
        // TEST-ONLY misreporting basket admitted through the real registry.
        HostileReceiptFixture hostile = new HostileReceiptFixture();
        registry.admitBasket(address(hostile), keccak256("reviewH-owner"));

        // A real Hunter minted into the hostile basket; ALICE funds and
        // approves the canonical backing vault.
        uint256 tokenId = _mint(ALICE, 1, address(hostile));
        hostile.mint(ALICE, 1_000); // TEST-ONLY non-production balance
        vm.prank(ALICE);
        hostile.approve(address(canonicalBacking), type(uint256).max); // TEST-ONLY

        // Real 50-unit donation from this contract: sender -50, vault +50,
        // counted nowhere.
        hostile.mint(address(this), 50);
        uint256 senderBefore = hostile.balanceOf(address(this));
        uint256 vaultBefore = hostile.balanceOf(address(canonicalBacking));
        assertTrue(hostile.transfer(address(canonicalBacking), 50));
        assertEq(hostile.balanceOf(address(this)), senderBefore - 50);
        assertEq(hostile.balanceOf(address(canonicalBacking)), vaultBefore + 50);
        assertEq(canonicalBacking.unaccountedBalance(address(hostile)), 50);
        assertEq(canonicalBacking.totalReceived(address(hostile)), 0);
        assertEq(canonicalBacking.totalOwnerReceived(address(hostile)), 0);

        uint256 nonceBefore = nft.authorizationNonce(tokenId);

        // Moves the units then reports false: SafeERC20 rejects the receipt.
        hostile.setMode(HostileReceiptFixture.Mode.FalseReturn);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("SafeERC20FailedOperation(address)")), address(hostile))
        );
        canonicalBacking.depositOwnerBacking(tokenId, 100);
        _assertHostileRollback(hostile, tokenId, nonceBefore);

        // Delivers 101 against a 100 request: measured exceeds requested.
        hostile.setMode(HostileReceiptFixture.Mode.BonusReceipt);
        vm.prank(ALICE);
        vm.expectRevert(WeightedRoundFunding.UnsupportedTokenReceipt.selector);
        canonicalBacking.depositOwnerBacking(tokenId, 100);
        _assertHostileRollback(hostile, tokenId, nonceBefore);

        // Burns 1 of the donation: post-pull balance reads below pre-pull.
        hostile.setMode(HostileReceiptFixture.Mode.DecreaseRecipient);
        vm.prank(ALICE);
        vm.expectRevert(WeightedRoundFunding.UnsupportedTokenReceipt.selector);
        canonicalBacking.depositOwnerBacking(tokenId, 100);
        _assertHostileRollback(hostile, tokenId, nonceBefore);

        // TEST-ONLY 50% inbound tax: requested 100 measures to a 50 credit
        // while ALICE is still debited the full 100.
        hostile.setMode(HostileReceiptFixture.Mode.TaxHalf);
        uint256 aliceBefore = hostile.balanceOf(ALICE);
        vaultBefore = hostile.balanceOf(address(canonicalBacking));
        vm.prank(ALICE);
        assertEq(canonicalBacking.depositOwnerBacking(tokenId, 100), 50);
        assertEq(hostile.balanceOf(ALICE), aliceBefore - 100);
        assertEq(hostile.balanceOf(address(canonicalBacking)), vaultBefore + 50);
        assertEq(canonicalBacking.ownerBackingOf(tokenId), 50);
        assertEq(canonicalBacking.totalOwnerReceived(address(hostile)), 50);
        assertEq(canonicalBacking.totalOwnerReleased(address(hostile)), 0);
        assertEq(canonicalBacking.backingOf(tokenId), 0);
        assertEq(canonicalBacking.totalReceived(address(hostile)), 0);
        assertEq(canonicalBacking.totalReleased(address(hostile)), 0);
        assertEq(canonicalBacking.unaccountedBalance(address(hostile)), 50);

        // The same guards hold independently on basketB through the shared
        // ReserveTokenFixture hooks bound to the canonical vault.
        ReserveTokenFixture assetB = ReserveTokenFixture(basketB);
        assetB.setVault(address(canonicalBacking)); // TEST-ONLY hook binding
        uint256 idB = _mint(BOB, 1, basketB);
        assetB.mint(BOB, 1_000); // TEST-ONLY non-production balance
        vm.prank(BOB);
        assetB.approve(address(canonicalBacking), type(uint256).max); // TEST-ONLY

        // 100% tax: the pull succeeds honestly but the measured receipt is 0.
        assetB.setBehavior(10_000, false, false, false);
        vm.prank(BOB);
        vm.expectRevert(WeightedRoundFunding.UnsupportedTokenReceipt.selector);
        canonicalBacking.depositOwnerBacking(idB, 10);
        _assertBasketBRollback(assetB, idB);

        // The fixture's own inbound revert bubbles exactly.
        assetB.setBehavior(0, true, false, false);
        vm.prank(BOB);
        vm.expectRevert(ReserveTokenFixture.InboundBlocked.selector);
        canonicalBacking.depositOwnerBacking(idB, 10);
        _assertBasketBRollback(assetB, idB);

        // Back to honest behaviour: the retry credits exactly 10, and the
        // hostile basket's accounting is untouched by the basketB flow.
        assetB.setBehavior(0, false, false, false);
        vm.prank(BOB);
        assertEq(canonicalBacking.depositOwnerBacking(idB, 10), 10);
        assertEq(assetB.balanceOf(BOB), 990);
        assertEq(assetB.balanceOf(address(canonicalBacking)), 10);
        assertEq(canonicalBacking.ownerBackingOf(idB), 10);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 10);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        assertEq(canonicalBacking.backingOf(idB), 0);
        assertEq(canonicalBacking.totalReceived(basketB), 0);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketB), 0);
        assertEq(canonicalBacking.ownerBackingOf(tokenId), 50);
        assertEq(canonicalBacking.totalOwnerReceived(address(hostile)), 50);
    }

    /// @notice Custody mutations during the owner-deposit pull trip the
    /// authorization-nonce guard: (1) the basketA fixture self-transfers
    /// the NFT mid-pull, (2) a TEST-ONLY callback token escrows the NFT to
    /// the base's real code-bearing escrow holder mid-pull. Both revert
    /// `StaleDepositState` and roll back atomically — owner, nonce,
    /// custody, balances and every counter restored — and each deposit
    /// succeeds once the callback is disabled.
    function testCallbackOwnerNonceAndEscrowMutationRollbackThenRetry() public {
        // Self-transfer branch: the token contract owns the Hunter and its
        // own inbound pull self-transfers it, bumping authorizationNonce.
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(canonicalBacking)); // TEST-ONLY hook binding
        asset.mint(address(asset), 100); // TEST-ONLY: the contract funds itself
        uint256 id = _mint(address(asset), 1, basketA);
        vm.prank(address(asset));
        asset.approve(address(canonicalBacking), type(uint256).max); // TEST-ONLY
        asset.setCallback(address(nft), id, true);

        address ownerBefore = nft.ownerOf(id);
        uint256 nonceBefore = nft.authorizationNonce(id);
        assertEq(ownerBefore, address(asset));
        assertFalse(nft.isEncumbered(id));

        vm.prank(address(asset));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.StaleDepositState.selector, id));
        canonicalBacking.depositOwnerBacking(id, 20);

        // Atomic rollback: custody, nonce, balances and counters restored.
        assertEq(nft.ownerOf(id), ownerBefore);
        assertEq(nft.authorizationNonce(id), nonceBefore);
        assertFalse(nft.isEncumbered(id));
        assertEq(asset.balanceOf(address(asset)), 100);
        assertEq(asset.balanceOf(address(canonicalBacking)), 0);
        _assertCounters(id, 0, 0, 0, 0, 0, 0);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 0);

        asset.setCallback(address(nft), id, false);
        vm.prank(address(asset));
        assertEq(canonicalBacking.depositOwnerBacking(id, 20), 20);
        assertEq(nft.ownerOf(id), ownerBefore);
        assertEq(nft.authorizationNonce(id), nonceBefore);
        assertEq(asset.balanceOf(address(asset)), 80);
        assertEq(asset.balanceOf(address(canonicalBacking)), 20);
        _assertCounters(id, 0, 20, 0, 0, 20, 0);

        // Escrow branch: a TEST-ONLY callback token escrows its own Hunter
        // to the base's real escrow holder mid-pull.
        OwnerBackingCallbackTokenFixture callAsset = new OwnerBackingCallbackTokenFixture();
        registry.admitBasket(address(callAsset), keccak256("reviewCB-escrow"));
        callAsset.mint(address(callAsset), 100); // TEST-ONLY self-funding
        uint256 idEsc = _mint(address(callAsset), 1, address(callAsset));
        callAsset.setCallback(address(canonicalBacking), address(nft), idEsc, address(escrow), true);
        vm.prank(address(callAsset));
        callAsset.approve(address(canonicalBacking), type(uint256).max); // TEST-ONLY

        ownerBefore = nft.ownerOf(idEsc);
        nonceBefore = nft.authorizationNonce(idEsc);
        assertEq(ownerBefore, address(callAsset));
        assertFalse(nft.isEncumbered(idEsc));
        assertEq(nft.escrowedTo(idEsc), address(0));

        vm.prank(address(callAsset));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.StaleDepositState.selector, idEsc));
        canonicalBacking.depositOwnerBacking(idEsc, 20);

        // Atomic rollback: the escrow mutation is undone with everything else.
        assertEq(nft.ownerOf(idEsc), ownerBefore);
        assertEq(nft.authorizationNonce(idEsc), nonceBefore);
        assertFalse(nft.isEncumbered(idEsc));
        assertEq(nft.escrowedTo(idEsc), address(0));
        assertEq(callAsset.balanceOf(address(callAsset)), 100);
        assertEq(callAsset.balanceOf(address(canonicalBacking)), 0);
        assertEq(canonicalBacking.backingOf(idEsc), 0);
        assertEq(canonicalBacking.ownerBackingOf(idEsc), 0);
        assertEq(canonicalBacking.totalBackingOf(idEsc), 0);
        assertEq(canonicalBacking.totalReceived(address(callAsset)), 0);
        assertEq(canonicalBacking.totalReleased(address(callAsset)), 0);
        assertEq(canonicalBacking.totalOwnerReceived(address(callAsset)), 0);
        assertEq(canonicalBacking.totalOwnerReleased(address(callAsset)), 0);
        assertEq(canonicalBacking.unaccountedBalance(address(callAsset)), 0);

        callAsset.setCallback(address(canonicalBacking), address(nft), idEsc, address(escrow), false);
        vm.prank(address(callAsset));
        assertEq(canonicalBacking.depositOwnerBacking(idEsc, 20), 20);
        assertEq(nft.ownerOf(idEsc), ownerBefore);
        assertFalse(nft.isEncumbered(idEsc));
        assertEq(callAsset.balanceOf(address(callAsset)), 80);
        assertEq(callAsset.balanceOf(address(canonicalBacking)), 20);
        assertEq(canonicalBacking.ownerBackingOf(idEsc), 20);
        assertEq(canonicalBacking.totalOwnerReceived(address(callAsset)), 20);
    }

    /// @notice Burn aggregation across BOTH liability sources on the real
    /// canonical assembly: one tier-1 Hunter carries a materialised 40-unit
    /// day-1 round share plus a 30-unit owner deposit, and the real burn
    /// pays the fixed beneficiary ONE aggregate 70-unit basketA transfer
    /// while each source advances only its own released counter. A blocked
    /// outbound fixture leg reverts the whole burn atomically — NFT custody,
    /// authorization nonce, member history, beneficiary and both counter
    /// families — and the unblocked retry settles once. The funded but
    /// unmaterialised day-2 15-unit share then answers to the late
    /// beneficiary claim alone; the replayed claim and a lifecycle-pranked
    /// second `onBurnBacking` are rejected exactly. TEST-ONLY fixture asset,
    /// FAKE recorder-asserted income and exact-mint balances — every figure
    /// is proven by recorded logs, stored counters and measured deltas.
    function testBurnAggregatesRoundAndOwnerBackingRollbackRetryAndLateClaim() public {
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(canonicalBacking)); // TEST-ONLY hook binding

        // TEST-ONLY non-production balances: ALICE mints exactly the 30 she
        // deposits; this contract mints exactly the 55 round funding plus
        // the 7 direct donation — exact-mint totals keep conservation tight.
        asset.mint(ALICE, 30);
        asset.mint(address(this), 62);
        vm.prank(ALICE);
        asset.approve(address(canonicalBacking), type(uint256).max);
        asset.approve(address(canonicalBacking), type(uint256).max);

        // One real tier-1 Hunter one second before the day-1 cutoff: the
        // sole eligible member of the sole basketA group in both rounds.
        vm.warp(86_399);
        uint256 id = _mint(ALICE, 1, basketA); // rarity 100
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, true);

        // The owner deposit credits exactly 30 into the second liability
        // source while the Hunter is live, owner-held and unencumbered.
        vm.prank(ALICE);
        assertEq(canonicalBacking.depositOwnerBacking(id, 30), 30);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);

        // Day 1 at the exact cutoff: FAKE recorder-asserted income 80 fixes
        // the nominal backing budget at 40; the sole group freezes the whole
        // budget, pulls a measured 40 and the sole member materialises all
        // 40 — the round and owner counter families stay strictly separate.
        vm.warp(86_400);
        canonicalLedger.recordRound(1, bytes32(uint256(0xDA21)), 80); // fake receipt, fake income
        assertEq(canonicalLedger.round(1).assertedIncome, 80);
        assertEq(canonicalLedger.round(1).nominalBackingBudget, 40);
        assertEq(canonicalLedger.round(1).globalCount, 1);
        canonicalLedger.freezeGroup(1, basketA);
        assertEq(canonicalLedger.group(1, basketA).budget, 40);
        canonicalBacking.fund(1, basketA, 40);
        assertEq(canonicalBacking.funding(1, basketA).received, 40);
        canonicalBacking.materialise(1, id);
        assertTrue(canonicalBacking.consumed(1, id));
        _assertCounters(id, 40, 30, 40, 0, 30, 0);

        // Day 2: asserted income 30 -> nominal backing 15, frozen and funded
        // for real, but the 15-unit member share is deliberately left
        // unconsumed for the post-burn late claim.
        vm.warp(172_800);
        canonicalLedger.recordRound(2, bytes32(uint256(0xDA22)), 30);
        assertEq(canonicalLedger.round(2).nominalBackingBudget, 15);
        canonicalLedger.freezeGroup(2, basketA);
        assertEq(canonicalLedger.group(2, basketA).budget, 15);
        canonicalBacking.fund(2, basketA, 15);
        assertEq(canonicalBacking.funding(2, basketA).received, 15);
        assertFalse(canonicalBacking.consumed(2, id));
        (address shareBasket, uint256 shareUnits) = canonicalBacking.memberReceivedShare(2, id);
        assertEq(shareBasket, basketA);
        assertEq(shareUnits, 15);
        _assertCounters(id, 40, 30, 55, 0, 30, 0);

        vm.warp(172_801);

        // Real 7-unit direct donation from this contract: exact sender and
        // vault deltas, credited nowhere.
        uint256 funderBefore = asset.balanceOf(address(this));
        uint256 vaultBefore = asset.balanceOf(address(canonicalBacking));
        assertTrue(asset.transfer(address(canonicalBacking), 7));
        assertEq(funderBefore - asset.balanceOf(address(this)), 7);
        assertEq(asset.balanceOf(address(canonicalBacking)) - vaultBefore, 7);

        // Pre-burn custody: 92 = 55 round outstanding + 30 owner
        // outstanding + 7 unaccounted, every release counter still zero.
        assertEq(asset.balanceOf(address(canonicalBacking)), 92);
        assertEq(canonicalBacking.totalReceived(basketA) - canonicalBacking.totalReleased(basketA), 55);
        assertEq(canonicalBacking.totalOwnerReceived(basketA) - canonicalBacking.totalOwnerReleased(basketA), 30);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);
        _assertCounters(id, 40, 30, 55, 0, 30, 0);

        // The fixture's outbound block reverts the real burn atomically.
        asset.setBehavior(0, false, true, false); // outbound leg blocked
        address ownerBefore = nft.ownerOf(id);
        uint256 nonceBefore = nft.authorizationNonce(id);
        uint256 aliceBefore = asset.balanceOf(ALICE);
        vaultBefore = asset.balanceOf(address(canonicalBacking));
        vm.prank(ALICE);
        vm.expectRevert(ReserveTokenFixture.OutboundBlocked.selector);
        nft.redeemAndDestroy(id);

        // Full rollback: custody, nonce, liveness, beneficiary, both counter
        // families, consumed flags and every balance restored exactly.
        assertEq(nft.ownerOf(id), ownerBefore);
        assertEq(nft.authorizationNonce(id), nonceBefore);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, true);
        assertEq(lc.finalBeneficiary(id), address(0));
        assertFalse(canonicalBacking.burnSettled(id));
        assertFalse(vault.settled(id));
        _assertCounters(id, 40, 30, 55, 0, 30, 0);
        assertTrue(canonicalBacking.consumed(1, id));
        assertFalse(canonicalBacking.consumed(2, id));
        assertEq(asset.balanceOf(address(canonicalBacking)), vaultBefore); // still 92
        assertEq(asset.balanceOf(ALICE), 0); // still net 30 down on her exact mint
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);

        // The retry pays ONE aggregate 70-unit transfer — 40 round + 30
        // owner — each source advancing only its own released counter.
        asset.setBehavior(0, false, false, false);
        vm.recordLogs();
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        nft.ownerOf(id);
        assertEq(nft.mintedEver(), 1); // no replay mint
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, false, false);
        assertEq(lc.finalBeneficiary(id), ALICE);
        assertTrue(canonicalBacking.burnSettled(id));
        assertTrue(vault.settled(id));
        _assertCounters(id, 0, 0, 55, 40, 30, 30);
        assertEq(asset.balanceOf(ALICE) - aliceBefore, 70); // one aggregate payout
        assertEq(vaultBefore - asset.balanceOf(address(canonicalBacking)), 70);
        assertEq(asset.balanceOf(address(canonicalBacking)), 22); // = 15 + 0 + 7
        assertEq(canonicalBacking.totalReceived(basketA) - canonicalBacking.totalReleased(basketA), 15);
        assertEq(canonicalBacking.totalOwnerReceived(basketA) - canonicalBacking.totalOwnerReleased(basketA), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);
        assertFalse(canonicalBacking.consumed(2, id)); // the day-2 right survives the burn

        bytes32 backingPayoutSig = keccak256("BackingPayout(uint256,address,address,uint256)");
        bytes32 ownerPayoutSig = keccak256("OwnerBackingPayout(uint256,address,address,uint256)");
        _assertSolePayoutLog(logs, backingPayoutSig, id, basketA, ALICE, 40);
        _assertSolePayoutLog(logs, ownerPayoutSig, id, basketA, ALICE, 30);
        _assertSoleTransferLog(logs, basketA, address(canonicalBacking), ALICE, 70);

        // Late claim: the unconsumed day-2 15-unit share belongs to the
        // fixed beneficiary alone — BOB is rejected exactly, nothing moves.
        uint256 bobBefore = asset.balanceOf(BOB);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.UnauthorizedBeneficiary.selector, id));
        canonicalBacking.claimBurned(2, id);
        assertFalse(canonicalBacking.consumed(2, id));
        assertEq(asset.balanceOf(BOB), bobBefore);
        assertEq(asset.balanceOf(address(canonicalBacking)), 22);
        _assertCounters(id, 0, 0, 55, 40, 30, 30);

        aliceBefore = asset.balanceOf(ALICE);
        vaultBefore = asset.balanceOf(address(canonicalBacking));
        vm.recordLogs();
        vm.prank(ALICE);
        canonicalBacking.claimBurned(2, id);
        logs = vm.getRecordedLogs();
        _assertSoleBurnedShareClaimed(logs, 2, id, basketA, ALICE, 15);
        assertEq(asset.balanceOf(ALICE) - aliceBefore, 15);
        assertEq(vaultBefore - asset.balanceOf(address(canonicalBacking)), 15);
        assertTrue(canonicalBacking.consumed(2, id));
        _assertCounters(id, 0, 0, 55, 55, 30, 30); // owner released stays 30
        // Both sources fully released; custody holds only the unaccounted
        // 7-unit donation and conservation is exact over the whole test.
        assertEq(canonicalBacking.totalReceived(basketA) - canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA) - canonicalBacking.totalOwnerReleased(basketA), 0);
        assertEq(asset.balanceOf(address(canonicalBacking)), 7);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);
        assertEq(asset.totalSupply(), 92); // 85 ALICE + 7 vault, nothing burned

        // One-shot replay guards: the same late claim and a direct second
        // burn hook under the real lifecycle address both reject exactly.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundMaterialisation.AlreadyConsumed.selector, uint32(2), id));
        canonicalBacking.claimBurned(2, id);

        aliceBefore = asset.balanceOf(ALICE);
        vaultBefore = asset.balanceOf(address(canonicalBacking));
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.BurnAlreadySettled.selector, id));
        canonicalBacking.onBurnBacking(id, ALICE);
        assertEq(asset.balanceOf(ALICE), aliceBefore);
        assertEq(asset.balanceOf(address(canonicalBacking)), vaultBefore);
        _assertCounters(id, 0, 0, 55, 55, 30, 30);
        assertTrue(canonicalBacking.burnSettled(id));
        assertEq(lc.finalBeneficiary(id), ALICE);

        // The NFT gate itself is the canonical nonexistent-token revert.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        nft.redeemAndDestroy(id);
    }

    /// @dev Asserts the six split counters for `tokenId` on basketA — round
    /// backing/received/released vs owner backing/received/released — plus
    /// the additive combined view.
    function _assertCounters(
        uint256 tokenId,
        uint256 roundBacking,
        uint256 ownerBacking,
        uint256 roundReceived,
        uint256 roundReleased,
        uint256 ownerReceived,
        uint256 ownerReleased
    ) private view {
        assertEq(canonicalBacking.backingOf(tokenId), roundBacking);
        assertEq(canonicalBacking.ownerBackingOf(tokenId), ownerBacking);
        assertEq(canonicalBacking.totalBackingOf(tokenId), roundBacking + ownerBacking);
        assertEq(canonicalBacking.totalReceived(basketA), roundReceived);
        assertEq(canonicalBacking.totalReleased(basketA), roundReleased);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), ownerReceived);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), ownerReleased);
    }

    /// @dev TEST-ONLY post-rejection invariant: every split counter stays
    /// zero, the vault holds no basketA, nothing is unaccounted, and ALICE's
    /// fixture balance is untouched.
    function _assertRejectionKeptState(uint256 tokenId, uint256 aliceBalance) private view {
        _assertCounters(tokenId, 0, 0, 0, 0, 0, 0);
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        assertEq(asset.balanceOf(address(canonicalBacking)), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 0);
        assertEq(asset.balanceOf(ALICE), aliceBalance);
    }

    /// @dev TEST-ONLY post-rejection invariant for the hostile basket:
    /// ALICE keeps 1_000, the vault holds only the 50-unit donation (all
    /// unaccounted), every split counter stays zero, and the Hunter's owner
    /// and authorization nonce are unchanged.
    function _assertHostileRollback(HostileReceiptFixture hostile, uint256 tokenId, uint256 nonce) private view {
        assertEq(hostile.balanceOf(ALICE), 1_000);
        assertEq(hostile.balanceOf(address(canonicalBacking)), 50);
        assertEq(canonicalBacking.backingOf(tokenId), 0);
        assertEq(canonicalBacking.ownerBackingOf(tokenId), 0);
        assertEq(canonicalBacking.totalBackingOf(tokenId), 0);
        assertEq(canonicalBacking.totalReceived(address(hostile)), 0);
        assertEq(canonicalBacking.totalReleased(address(hostile)), 0);
        assertEq(canonicalBacking.totalOwnerReceived(address(hostile)), 0);
        assertEq(canonicalBacking.totalOwnerReleased(address(hostile)), 0);
        assertEq(canonicalBacking.unaccountedBalance(address(hostile)), 50);
        assertEq(nft.ownerOf(tokenId), ALICE);
        assertEq(nft.authorizationNonce(tokenId), nonce);
    }

    /// @dev TEST-ONLY post-rejection invariant for basketB: BOB keeps
    /// 1_000, the vault holds no basketB, every split counter stays zero,
    /// nothing is unaccounted, and BOB still owns the Hunter.
    function _assertBasketBRollback(ReserveTokenFixture assetB, uint256 tokenId) private view {
        assertEq(assetB.balanceOf(BOB), 1_000);
        assertEq(assetB.balanceOf(address(canonicalBacking)), 0);
        assertEq(canonicalBacking.backingOf(tokenId), 0);
        assertEq(canonicalBacking.ownerBackingOf(tokenId), 0);
        assertEq(canonicalBacking.totalBackingOf(tokenId), 0);
        assertEq(canonicalBacking.totalReceived(basketB), 0);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketB), 0);
        assertEq(nft.ownerOf(tokenId), BOB);
    }

    /// @dev Finds exactly one payout log of signature `sig` emitted by
    /// canonicalBacking — `BackingPayout` and `OwnerBackingPayout` share the
    /// `(uint256,address,address,uint256)` layout — and checks the indexed
    /// tokenId/asset/beneficiary topics plus the gross-units data.
    function _assertSolePayoutLog(
        Vm.Log[] memory logs,
        bytes32 sig,
        uint256 tokenId,
        address asset,
        address beneficiary,
        uint256 grossUnits
    ) private view {
        Vm.Log memory hit;
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(canonicalBacking) && log.topics.length != 0 && log.topics[0] == sig) {
                hit = log;
                ++found;
            }
        }
        assertEq(found, 1);
        assertEq(hit.topics.length, 4);
        assertEq(uint256(hit.topics[1]), tokenId);
        assertEq(address(uint160(uint256(hit.topics[2]))), asset);
        assertEq(address(uint160(uint256(hit.topics[3]))), beneficiary);
        assertEq(abi.decode(hit.data, (uint256)), grossUnits);
    }

    /// @dev Finds exactly one ERC20 `Transfer(address,address,uint256)` log
    /// emitted by `asset` and checks the indexed from/to topics plus the
    /// value data — the aggregate outbound leg's real emitted record.
    function _assertSoleTransferLog(Vm.Log[] memory logs, address asset, address from, address to, uint256 value)
        private
        pure
    {
        bytes32 sig = keccak256("Transfer(address,address,uint256)");
        Vm.Log memory hit;
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == asset && log.topics.length != 0 && log.topics[0] == sig) {
                hit = log;
                ++found;
            }
        }
        assertEq(found, 1);
        assertEq(hit.topics.length, 3);
        assertEq(address(uint160(uint256(hit.topics[1]))), from);
        assertEq(address(uint160(uint256(hit.topics[2]))), to);
        assertEq(abi.decode(hit.data, (uint256)), value);
    }

    /// @dev Finds exactly one `BurnedShareClaimed(uint32,uint256,address,address,uint256)`
    /// log emitted by canonicalBacking and checks the indexed day/tokenId/
    /// asset topics plus the beneficiary and gross-units data.
    function _assertSoleBurnedShareClaimed(
        Vm.Log[] memory logs,
        uint32 day,
        uint256 tokenId,
        address asset,
        address beneficiary,
        uint256 grossUnits
    ) private view {
        bytes32 sig = keccak256("BurnedShareClaimed(uint32,uint256,address,address,uint256)");
        Vm.Log memory hit;
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter == address(canonicalBacking) && log.topics.length != 0 && log.topics[0] == sig) {
                hit = log;
                ++found;
            }
        }
        assertEq(found, 1);
        assertEq(hit.topics.length, 4);
        assertEq(uint256(hit.topics[1]), uint256(day));
        assertEq(uint256(hit.topics[2]), tokenId);
        assertEq(address(uint160(uint256(hit.topics[3]))), asset);
        (address beneficiary_, uint256 grossUnits_) = abi.decode(hit.data, (address, uint256));
        assertEq(beneficiary_, beneficiary);
        assertEq(grossUnits_, grossUnits);
    }
}

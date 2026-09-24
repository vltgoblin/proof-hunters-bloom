// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HunterBackingVault} from "../src/bloom/HunterBackingVault.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {IBasketConverter} from "../src/bloom/IBasketConverter.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @notice TEST-ONLY fixed-ratio converter. NOT production: no liquidity,
/// pricing or route logic — it records the exact call fields, pulls exactly
/// `amountIn` of `assetIn` from `msg.sender`, and pays `amountIn *
/// numerator / denominator` of a PRE-FUNDED `assetOut` balance back to
/// `msg.sender`. No recipient or calldata steering exists, matching the
/// narrow `IBasketConverter` surface.
contract SwitchConverterFixture is IBasketConverter {
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

/// @notice TEST-ONLY/NON-PRODUCTION adversarial converter: the same narrow
/// `IBasketConverter` surface as the fixed-ratio fixture plus a storage
/// `mode` setter, so ONE admission (one pinned codehash) stays usable while
/// behaviour changes between calls — no etch needed. Every mode reports the
/// same `minAmountOut` return regardless of what it actually pulled or
/// paid; the vault must measure real debits/credits and never trust it.
/// Modes: Revert (explicit fixture custom error), UnderDebit (pulls
/// `amountIn - 1` yet still pays the full `minAmountOut`), NoOutput (pulls
/// `amountIn`, pays zero), ShortOutput (pulls `amountIn`, pays
/// `minAmountOut - 1`) and Normal (pulls `amountIn`, pays exactly
/// `minAmountOut`). Converter-side writes and token moves inside a failed
/// completion revert with it, so `callCount` stays zero until one succeeds.
contract AdversarialConverterFixture is IBasketConverter {
    error ConverterExploded();

    enum Mode {
        Revert,
        UnderDebit,
        NoOutput,
        ShortOutput,
        Normal
    }

    Mode public mode;
    uint256 public callCount;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function convert(address assetIn, address assetOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256)
    {
        ++callCount;
        if (mode == Mode.Revert) revert ConverterExploded();
        uint256 pull = mode == Mode.UnderDebit ? amountIn - 1 : amountIn;
        require(IERC20(assetIn).transferFrom(msg.sender, address(this), pull));
        if (mode != Mode.NoOutput) {
            uint256 send = mode == Mode.ShortOutput ? minAmountOut - 1 : minAmountOut;
            require(IERC20(assetOut).transfer(msg.sender, send));
        }
        return minAmountOut;
    }
}

contract HunterBasketSwitchTest is LifecycleTestBase {
    /// @dev Mirrors HunterLifecycle.SwitchInvalidated so expectEmit can
    /// match the real event exactly.
    event SwitchInvalidated(uint256 indexed tokenId, address indexed basket, uint256 switchNonce);

    function testRequestCancelAndGuards() public {
        vm.warp(1 days + 100);
        uint256 id = _mint(ALICE, 1, basketA);

        uint256 reserveA = vault.reserveOf(id);
        uint256 backing = canonicalBacking.backingOf(id);

        vm.prank(ALICE);
        uint256 nonce = lc.requestSwitch(id, basketB);
        assertEq(nonce, 1);
        assertEq(lc.switchNonce(id), 1);

        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 1);
        assertEq(req.authorizationNonce, nft.authorizationNonce(id));

        WeightedHistory.Member memory cur = lc.currentMember(id);
        assertTrue(cur.alive);
        assertFalse(cur.eligible);
        assertEq(cur.basket, basketA);
        assertEq(cur.rarity, 100);
        assertEq(cur.hunter, 0);

        // no pre-existing eligible days to settle
        assertTrue(lc.switchReady(id));

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.SwitchRequestActive.selector, id));
        lc.requestSwitch(id, basketB);
        req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 1);
        assertEq(lc.switchNonce(id), 1);
        assertEq(nft.basketOf(id), basketA);
        assertEq(canonicalBacking.backingOf(id), backing);

        vm.prank(ALICE);
        uint256 nonce2 = lc.cancelSwitch(id);
        assertEq(nonce2, 2);
        assertEq(lc.switchNonce(id), 2);

        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(nft.basketOf(id), basketA);
        assertEq(vault.reserveOf(id), reserveA);
        assertEq(canonicalBacking.backingOf(id), backing);

        cur = lc.currentMember(id);
        assertTrue(cur.alive);
        assertTrue(cur.eligible);
        assertEq(cur.basket, basketA);
        assertEq(cur.rarity, 100);
        assertEq(cur.hunter, 0);

        vm.prank(makeAddr("bob"));
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NotTokenOwner.selector, id));
        lc.requestSwitch(id, basketB);
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(lc.switchNonce(id), 2);
        assertEq(nft.basketOf(id), basketA);
        assertEq(canonicalBacking.backingOf(id), backing);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.InvalidSwitchTarget.selector, address(0)));
        lc.requestSwitch(id, address(0));
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(lc.switchNonce(id), 2);
        assertEq(nft.basketOf(id), basketA);
        assertEq(canonicalBacking.backingOf(id), backing);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.InvalidSwitchTarget.selector, basketA));
        lc.requestSwitch(id, basketA);
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(lc.switchNonce(id), 2);
        assertEq(nft.basketOf(id), basketA);
        assertEq(canonicalBacking.backingOf(id), backing);

        registry.setEntryEnabled(basketB, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.BasketNotEnabled.selector, basketB));
        lc.requestSwitch(id, basketB);
        registry.setEntryEnabled(basketB, true);
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(lc.switchNonce(id), 2);
        assertEq(nft.basketOf(id), basketA);
        assertEq(canonicalBacking.backingOf(id), backing);

        vm.prank(ALICE);
        nft.escrowTo(id, address(escrow), "");
        vm.prank(address(escrow));
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.TokenNotOwnerHeld.selector, id));
        lc.requestSwitch(id, basketB);
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(lc.switchNonce(id), 2);
        assertEq(nft.basketOf(id), basketA);
        assertEq(canonicalBacking.backingOf(id), backing);
    }

    /// @notice Zero-backing completion into a basket admitted AFTER the mint:
    /// no approval, token transfer or converter call occurs, so a zero
    /// converter address is accepted and returns zero output.
    function testZeroBackingSwitchesToBasketAdmittedAfterMintWithoutConverter() public {
        vm.warp(1 days + 100);
        uint256 id = _mint(ALICE, 1, basketA);

        // TEST-ONLY stand-in asset and review hash; NOT production values.
        address basketC = address(new ReserveTokenFixture());
        registry.admitBasket(basketC, keccak256("reviewC"));

        uint256 authNonce = nft.authorizationNonce(id);
        uint256 reserve = vault.reserveOf(id);
        // Both backing sources are zero: no materialised round units and no
        // owner-deposited units.
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 0);
        uint256 aliceA = ReserveTokenFixture(basketA).balanceOf(ALICE);
        uint256 vaultA = ReserveTokenFixture(basketA).balanceOf(address(canonicalBacking));
        uint256 aliceC = ReserveTokenFixture(basketC).balanceOf(ALICE);
        uint256 vaultC = ReserveTokenFixture(basketC).balanceOf(address(canonicalBacking));

        vm.prank(ALICE);
        uint256 nonce = lc.requestSwitch(id, basketC);
        assertEq(nonce, 1);
        assertEq(lc.switchNonce(id), 1);
        // No pre-existing eligible days before the first eligible day.
        assertTrue(lc.switchReady(id));

        // address(0) is the intentional proof: the zero-backing path makes
        // no converter call at all.
        vm.prank(ALICE);
        assertEq(lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 1), 0);

        assertEq(nft.basketOf(id), basketC);
        assertEq(nft.authorizationNonce(id), authNonce + 1);
        assertEq(lc.switchRequestOf(id).target, address(0));
        assertEq(lc.switchNonce(id), 2);
        _assertMemberEq(lc.currentMember(id), basketC, 100, 0, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketC), 100, 0, 1);
        _assertTotalsEq(lc.currentGlobal(), 100, 0, 1);

        assertEq(vault.reserveOf(id), reserve);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 0);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 0);
        assertEq(canonicalBacking.totalReceived(basketC), 0);
        assertEq(canonicalBacking.totalReleased(basketC), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketC), 0);
        assertEq(canonicalBacking.totalOwnerReleased(basketC), 0);
        assertEq(ReserveTokenFixture(basketA).balanceOf(ALICE), aliceA);
        assertEq(ReserveTokenFixture(basketA).balanceOf(address(canonicalBacking)), vaultA);
        assertEq(ReserveTokenFixture(basketC).balanceOf(ALICE), aliceC);
        assertEq(ReserveTokenFixture(basketC).balanceOf(address(canonicalBacking)), vaultC);
    }

    /// @notice TEST-ONLY positive-conversion switch over BOTH backing
    /// sources: a funded+materialised day-1 round share (40) plus an owner
    /// deposit (30) convert 70 -> 140 through the admitted fixed-ratio
    /// fixture. The old asset's round/owner released counters advance to
    /// fully released while the new asset's received counters absorb the
    /// source-preserving 80/60 split; HUNTER reserve, wallet balances and
    /// the consumed historical share are untouched. All amounts (income 80,
    /// funding 40, owner 30, donations 7/11, output 140, 2:1 ratio) are
    /// non-production test values.
    function testPositiveConversionPreservesSourceLedgersAndLockedValue() public {
        vm.warp(100);
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 50), 50);
        uint256 reserve = vault.reserveOf(id);
        uint256 aliceHunter = token.balanceOf(ALICE);

        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        ReserveTokenFixture assetB = ReserveTokenFixture(basketB);
        assetA.mint(ALICE, 30);
        vm.prank(ALICE);
        assetA.approve(address(canonicalBacking), 30);
        vm.prank(ALICE);
        assertEq(canonicalBacking.depositOwnerBacking(id, 30), 30);
        assetA.mint(address(canonicalBacking), 7); // TEST-ONLY donation
        assetB.mint(address(canonicalBacking), 11); // TEST-ONLY donation
        uint256 aliceA = assetA.balanceOf(ALICE);
        uint256 aliceB = assetB.balanceOf(ALICE);

        vm.warp(1 days + 100);
        canonicalLedger.recordRound(1, keccak256("receipt-switch-day-1"), 80);
        canonicalLedger.freezeGroup(1, basketA);
        assetA.mint(address(this), 40);
        assetA.approve(address(canonicalBacking), 40);
        canonicalBacking.fund(1, basketA, 40);
        canonicalBacking.materialise(1, id);
        assertEq(canonicalBacking.backingOf(id), 40);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);
        assertEq(canonicalBacking.totalReceived(basketA), 40);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 0);
        assertEq(canonicalBacking.totalBackingOf(id), 70);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);

        SwitchConverterFixture converter = new SwitchConverterFixture(2, 1);
        registry.admitConverter(address(converter), keccak256("review-converter"));
        assetB.mint(address(converter), 140);

        vm.prank(ALICE);
        assertEq(lc.requestSwitch(id, basketB), 1);
        // nextUncheckedDay is day 1 and that share is already consumed, so
        // the permissionless scan just advances the cursor past the barrier.
        (uint256 examined, bool ready) = lc.prepareSwitch(id, 1);
        assertEq(examined, 1);
        assertTrue(ready);
        assertEq(lc.nextUncheckedDay(id), 2);

        uint256 authNonce = nft.authorizationNonce(id);
        vm.prank(ALICE);
        uint256 totalOut = lc.completeSwitch(id, address(converter), 70, 140, block.timestamp, 1);
        assertEq(totalOut, 140);
        assertEq(converter.callCount(), 1);
        assertEq(converter.lastCaller(), address(canonicalBacking));
        assertEq(converter.lastAssetIn(), basketA);
        assertEq(converter.lastAssetOut(), basketB);
        assertEq(converter.lastAmountIn(), 70);
        assertEq(converter.lastMinAmountOut(), 140);

        assertEq(nft.basketOf(id), basketB);
        assertEq(nft.authorizationNonce(id), authNonce + 1);
        assertEq(lc.switchRequestOf(id).target, address(0));
        assertEq(lc.switchNonce(id), 2);
        _assertMemberEq(lc.currentMember(id), basketB, 100, 50, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketB), 100, 50, 1);
        _assertTotalsEq(lc.currentGlobal(), 100, 50, 1);
        assertEq(vault.reserveOf(id), reserve);
        assertEq(token.balanceOf(ALICE), aliceHunter);

        // Source preservation: the old asset is fully released per source
        // while the new asset credits the 80/60 split into the same ledgers.
        assertEq(canonicalBacking.totalReceived(basketA), 40);
        assertEq(canonicalBacking.totalReleased(basketA), 40);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 30);
        assertEq(canonicalBacking.totalReceived(basketB), 80);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 60);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        assertEq(canonicalBacking.backingOf(id), 80);
        assertEq(canonicalBacking.ownerBackingOf(id), 60);
        assertEq(canonicalBacking.totalBackingOf(id), 140);
        assertEq(assetA.balanceOf(address(canonicalBacking)), 7);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 7);
        assertEq(assetB.balanceOf(address(canonicalBacking)), 151);
        assertEq(canonicalBacking.unaccountedBalance(basketB), 11);
        assertEq(assetA.balanceOf(address(converter)), 70);
        assertEq(assetB.balanceOf(address(converter)), 0);
        assertEq(assetA.allowance(address(canonicalBacking), address(converter)), 0);
        assertEq(assetA.balanceOf(ALICE), aliceA);
        assertEq(assetB.balanceOf(ALICE), aliceB);

        // The consumed day-1 share and its frozen basket are immutable.
        _assertConsumedDayOneShare(id);
    }

    /// @notice Bounded `prepareSwitch` cursor over three real recorded days:
    /// exact 00:00 UTC cutoffs, a day consumed BEFORE the request, a funded
    /// ZERO-unit day and an unfunded funding gap that blocks the scan in
    /// place. All amounts (asserted income 80/80/1, funding 40/40, the 80
    /// pre-mint) are TEST-ONLY, NON-PRODUCTION values.
    function testPreparationUsesExactUtcCutoffsAndBoundedCursor() public {
        vm.warp(100);
        uint256 id = _mint(ALICE, 1, basketA);

        // Strictly-before at the mint timestamp excludes the same-timestamp
        // mint; the exact day-1 cutoff already contains it (asserted once
        // the clock passes that cutoff — earlier reads revert FutureCutoff).
        _assertMemberEq(lc.memberBefore(id, 100), address(0), 0, 0, false, false);

        // TEST-ONLY funding units pre-staged for the whole scenario: the
        // day-1 and day-3 pulls draw 40 each; the day-2 zero-budget fund
        // makes no token call.
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assetA.mint(address(this), 80);
        assetA.approve(address(canonicalBacking), 80);

        vm.warp(1 days + 100);
        _assertMemberEq(lc.memberBefore(id, 1 days), basketA, 100, 0, true, true);

        canonicalLedger.recordRound(1, keccak256("receipt-prepare-day-1"), 80);
        canonicalLedger.freezeGroup(1, basketA);
        canonicalBacking.fund(1, basketA, 40);
        canonicalBacking.materialise(1, id);
        assertEq(canonicalLedger.round(1).cutoff, 1 days);
        _assertConsumedDayOneShare(id);
        assertEq(canonicalBacking.backingOf(id), 40);

        vm.warp(2 days + 100);
        // TEST-ONLY income of 1 floors the nominal backing budget to 0.
        canonicalLedger.recordRound(2, keccak256("receipt-prepare-day-2"), 1);
        canonicalLedger.freezeGroup(2, basketA);
        canonicalBacking.fund(2, basketA, 0);
        WeightedRoundFunding.Funding memory funded2 = canonicalBacking.funding(2, basketA);
        assertTrue(funded2.finalised);
        assertEq(funded2.received, 0);
        assertEq(canonicalLedger.round(2).cutoff, 2 days);
        assertEq(canonicalLedger.round(2).nominalBackingBudget, 0);
        _assertMemberEq(canonicalLedger.memberSnapshot(2, id), basketA, 100, 0, true, true);
        assertFalse(canonicalBacking.consumed(2, id));

        vm.warp(3 days + 100);
        canonicalLedger.recordRound(3, keccak256("receipt-prepare-day-3"), 80);
        canonicalLedger.freezeGroup(3, basketA);
        // Deliberately left unfunded: the funding gap must stall the cursor.
        assertEq(canonicalLedger.round(3).cutoff, 3 days);
        _assertMemberEq(canonicalLedger.memberSnapshot(3, id), basketA, 100, 0, true, true);
        assertFalse(canonicalBacking.isFunded(3, basketA));
        assertFalse(canonicalBacking.consumed(3, id));

        vm.prank(ALICE);
        assertEq(lc.requestSwitch(id, basketB), 1);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 3);
        assertEq(req.authorizationNonce, nft.authorizationNonce(id));
        assertEq(lc.switchNonce(id), 1);
        assertEq(lc.nextUncheckedDay(id), 1);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, false);
        assertFalse(lc.switchReady(id));

        // Day 1 was consumed before the request: one examined day advances
        // the cursor past it with no new backing.
        (uint256 examined, bool ready) = lc.prepareSwitch(id, 1);
        assertEq(examined, 1);
        assertFalse(ready);
        assertEq(lc.nextUncheckedDay(id), 2);
        assertEq(canonicalBacking.backingOf(id), 40);
        assertFalse(canonicalBacking.consumed(2, id));
        assertFalse(lc.switchReady(id));

        // Day 2's finalised zero-unit share is consumed and adds nothing.
        (examined, ready) = lc.prepareSwitch(id, 1);
        assertEq(examined, 1);
        assertFalse(ready);
        assertEq(lc.nextUncheckedDay(id), 3);
        assertEq(canonicalBacking.backingOf(id), 40);
        assertTrue(canonicalBacking.consumed(2, id));
        (address shareBasket, uint256 shareUnits) = canonicalBacking.memberReceivedShare(2, id);
        assertEq(shareBasket, basketA);
        assertEq(shareUnits, 0);
        assertFalse(lc.switchReady(id));

        // Day 3 is recorded and frozen but unfunded: the scan counts the
        // examined day yet stops in place — cursor, consumption, backing,
        // request and nonce all unchanged.
        (examined, ready) = lc.prepareSwitch(id, 1);
        assertEq(examined, 1);
        assertFalse(ready);
        assertEq(lc.nextUncheckedDay(id), 3);
        assertFalse(canonicalBacking.consumed(3, id));
        assertFalse(canonicalBacking.isFunded(3, basketA));
        assertEq(canonicalBacking.backingOf(id), 40);
        req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 3);
        assertEq(lc.switchNonce(id), 1);

        canonicalBacking.fund(3, basketA, 40);
        (examined, ready) = lc.prepareSwitch(id, 1);
        assertEq(examined, 1);
        assertTrue(ready);
        assertEq(lc.nextUncheckedDay(id), 4);
        assertTrue(lc.switchReady(id));
        assertTrue(canonicalBacking.consumed(3, id));
        assertEq(canonicalBacking.backingOf(id), 80);
        req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 3);
        assertEq(lc.switchNonce(id), 1);

        // Exact historical basketA rights across all three days.
        _assertConsumedDayOneShare(id);
        _assertMemberEq(canonicalLedger.memberSnapshot(1, id), basketA, 100, 0, true, true);
        _assertMemberEq(canonicalLedger.memberSnapshot(2, id), basketA, 100, 0, true, true);
        _assertMemberEq(canonicalLedger.memberSnapshot(3, id), basketA, 100, 0, true, true);
        assertTrue(canonicalBacking.consumed(1, id));
        assertTrue(canonicalBacking.consumed(2, id));
        assertTrue(canonicalBacking.consumed(3, id));
        (shareBasket, shareUnits) = canonicalBacking.memberReceivedShare(2, id);
        assertEq(shareBasket, basketA);
        assertEq(shareUnits, 0);
        (shareBasket, shareUnits) = canonicalBacking.memberReceivedShare(3, id);
        assertEq(shareBasket, basketA);
        assertEq(shareUnits, 40);

        // The live member stays paused until the request is cancelled or
        // completed.
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, false);

        vm.prank(ALICE);
        assertEq(lc.cancelSwitch(id), 2);
        assertEq(lc.switchNonce(id), 2);
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        assertEq(nft.basketOf(id), basketA);
        assertEq(canonicalBacking.backingOf(id), 80);
        assertEq(canonicalBacking.ownerBackingOf(id), 0);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 0, 1);
        _assertTotalsEq(lc.currentBasket(basketB), 0, 0, 0);
        _assertTotalsEq(lc.currentGlobal(), 100, 0, 1);
    }

    /// @notice M2.2 sale invalidation with live value attached: a real
    /// owner-held basketA Hunter carrying a TEST-ONLY 50 HUNTER reserve and
    /// 30 units of owner-deposited basketA backing has ALICE's pending
    /// basketB request pause eligibility, then the sale transfer atomically
    /// clears the request — exactly one switchNonce increment, the basketA
    /// member resumed, reserve and backing preserved — and every switch
    /// right travels with the tokenId to BOB. NON-PRODUCTION test values.
    function testSaleClearsPendingSwitchAndKeepsValueOnTokenId() public {
        uint256 id = _mintBackedPendingSwitch();
        uint256 authNonce = nft.authorizationNonce(id);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 1);
        assertEq(req.authorizationNonce, authNonce);
        assertTrue(lc.switchReady(id));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, false);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentGlobal(), 0, 0, 0);

        // The sale itself is the invalidation path: one nonce, one resume.
        vm.expectEmit(true, true, false, true, address(lc));
        emit SwitchInvalidated(id, basketA, 2);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);

        assertEq(nft.ownerOf(id), BOB);
        assertEq(nft.authorizationNonce(id), authNonce + 1);
        // Exactly once: the request consumed 1, the invalidation consumed 2.
        assertEq(lc.switchNonce(id), 2);
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        assertFalse(lc.switchReady(id));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 50, 1);
        _assertTotalsEq(lc.currentGlobal(), 100, 50, 1);
        assertEq(nft.basketOf(id), basketA);
        assertEq(vault.reserveOf(id), 50);
        assertEq(vault.totalReserved(), 50);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);
        assertEq(canonicalBacking.totalBackingOf(id), 30);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 0);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);

        // Rights travel with the tokenId: ALICE keeps no request or cancel
        // power over BOB's Hunter.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NotTokenOwner.selector, id));
        lc.requestSwitch(id, basketB);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NotTokenOwner.selector, id));
        lc.cancelSwitch(id);
        assertEq(lc.switchNonce(id), 2);

        // BOB opens and cancels a fresh request on the same tokenId.
        vm.prank(BOB);
        assertEq(lc.requestSwitch(id, basketB), 3);
        req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 1);
        assertEq(req.authorizationNonce, nft.authorizationNonce(id));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, false);
        vm.prank(BOB);
        assertEq(lc.cancelSwitch(id), 4);
        assertEq(lc.switchNonce(id), 4);
        assertEq(lc.switchRequestOf(id).target, address(0));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, true);
        assertEq(vault.reserveOf(id), 50);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);
    }

    /// @notice M2.2 escrow invalidation with live value attached: entering
    /// the inherited escrow fixture runs the same pending-request
    /// invalidation as a sale — request cleared, exactly one switchNonce
    /// increment, basketA eligibility resumed — while the release leg can
    /// neither resurrect the request nor consume another nonce. Reserve and
    /// owner backing are preserved throughout. NON-PRODUCTION test values.
    function testEscrowEntryClearsPendingSwitchAndReleaseLeavesItCleared() public {
        uint256 id = _mintBackedPendingSwitch();
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, false);

        // Escrow entry is a custody transfer: the request is invalidated.
        vm.expectEmit(true, true, false, true, address(lc));
        emit SwitchInvalidated(id, basketA, 2);
        vm.prank(ALICE);
        nft.escrowTo(id, address(escrow), "");

        assertEq(nft.ownerOf(id), address(escrow));
        assertEq(nft.escrowedTo(id), address(escrow));
        assertTrue(nft.isEncumbered(id));
        assertTrue(nft.custody(id) == HunterNFT.Custody.Escrowed);
        assertEq(lc.switchNonce(id), 2);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 50, 1);
        assertEq(vault.reserveOf(id), 50);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);
        assertEq(canonicalBacking.totalBackingOf(id), 30);

        // Release is another transfer with NO request left: no resurrection,
        // no second nonce, no history write.
        escrow.release(IERC721(address(nft)), id, BOB);
        assertEq(nft.ownerOf(id), BOB);
        assertEq(nft.escrowedTo(id), address(0));
        assertFalse(nft.isEncumbered(id));
        assertTrue(nft.custody(id) == HunterNFT.Custody.OwnerHeld);
        assertEq(lc.switchNonce(id), 2);
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        assertFalse(lc.switchReady(id));
        assertEq(nft.basketOf(id), basketA);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 100, 50, 1);
        _assertTotalsEq(lc.currentGlobal(), 100, 50, 1);
        assertEq(vault.reserveOf(id), 50);
        assertEq(vault.totalReserved(), 50);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);
        assertEq(canonicalBacking.totalBackingOf(id), 30);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 0);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
    }

    /// @notice M2.2 pending-request burn cleanup: after the escrow
    /// invalidation and release, BOB opens a fresh pending switch and burns
    /// through `nft.redeemAndDestroy`. The burn clears the request inside
    /// the same transaction WITHOUT consuming a switch nonce, marks history
    /// dead and ineligible, fixes the beneficiary to BOB, returns the exact
    /// locked HUNTER and owner backing, zeroes both live ledgers and makes
    /// every repeat burn/settlement path impossible. TEST-ONLY values.
    function testBurnClearsPendingSwitchAndSettlesReserveAndBackingOnce() public {
        uint256 id = _mintBackedPendingSwitch();

        // Ride the escrow invalidation first, then let BOB re-request.
        vm.prank(ALICE);
        nft.escrowTo(id, address(escrow), "");
        assertEq(lc.switchNonce(id), 2);
        escrow.release(IERC721(address(nft)), id, BOB);
        assertEq(nft.ownerOf(id), BOB);
        assertEq(lc.switchNonce(id), 2);

        vm.prank(BOB);
        assertEq(lc.requestSwitch(id, basketB), 3);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 1);
        assertEq(req.authorizationNonce, nft.authorizationNonce(id));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, false);
        assertEq(vault.reserveOf(id), 50);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);

        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        vm.prank(BOB);
        nft.redeemAndDestroy(id);

        // Token gone; the pending request died inside the same transaction.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        nft.ownerOf(id);
        req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        assertFalse(lc.switchReady(id));
        // Burn clears the request WITHOUT consuming a switch nonce.
        assertEq(lc.switchNonce(id), 3);

        assertEq(lc.finalBeneficiary(id), BOB);
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, false, false);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentGlobal(), 0, 0, 0);

        // Exact payout: locked HUNTER plus owner backing to BOB, both live
        // ledgers zeroed, both settlement flags set.
        assertEq(token.balanceOf(BOB), 50);
        assertEq(assetA.balanceOf(BOB), 30);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(assetA.balanceOf(address(canonicalBacking)), 0);
        assertEq(vault.reserveOf(id), 0);
        assertEq(vault.totalReserved(), 0);
        assertTrue(vault.settled(id));
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 0);
        assertEq(canonicalBacking.totalBackingOf(id), 0);
        assertTrue(canonicalBacking.burnSettled(id));

        // The owner-source release counter advanced exactly; the ecosystem
        // round counters were never touched by deposit or burn.
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 30);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.unaccountedBalance(basketA), 0);

        // Dead history stays dead at later cutoffs.
        vm.warp(2 days);
        _assertMemberEq(lc.memberBefore(id, 2 days), basketA, 100, 0, false, false);
        _assertTotalsEq(lc.basketBefore(basketA, 2 days), 0, 0, 0);
        _assertTotalsEq(lc.globalBefore(2 days), 0, 0, 0);
        assertEq(vault.reserveBefore(id, 2 days), 0);

        // No repeat burn or settlement through any current public surface.
        assertEq(nft.mintedEver(), 1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        nft.redeemAndDestroy(id);
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.AlreadySettled.selector, id));
        vault.settleBurn(id, BOB);
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.BurnAlreadySettled.selector, id));
        canonicalBacking.onBurnBacking(id, BOB);

        // No stale switch request survives on the dead id.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        lc.requestSwitch(id, basketB);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        lc.cancelSwitch(id);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        lc.completeSwitch(id, address(0), 0, 0, block.timestamp, 3);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NoSwitchRequest.selector, id));
        lc.prepareSwitch(id, 1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(HunterReserveVault.AlreadySettled.selector, id));
        vault.deposit(id, 1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        canonicalBacking.depositOwnerBacking(id, 1);
        assertEq(token.balanceOf(BOB), 50);
        assertEq(assetA.balanceOf(BOB), 30);
        assertEq(vault.totalReserved(), 0);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 30);
    }

    /// @notice M2.2 positive-backing completion controls: on ALICE's pending
    /// basketA->basketB switch carrying 30 TEST-ONLY owner-backing units (plus
    /// the 50 HUNTER reserve), every stale quote or route-policy rejection —
    /// expired deadline, wrong switch nonce, wrong expected input, zero
    /// minOutput, disabled destination entry, unknown, disabled then
    /// codehash-mismatched converter — reverts with the exact error and
    /// leaves the request, paused member, ledgers, balances, allowance and
    /// converter callCount bit-identical. Restoring the admitted runtime code
    /// makes the route usable again and the valid retry then completes once:
    /// owner backing 30 -> 60 through the 2:1 fixture with HUNTER preserved.
    /// NON-PRODUCTION values throughout.
    function testCompletionRejectsStaleQuotesPolicyAndCodehashThenRetries() public {
        uint256 id = _mintBackedPendingSwitch();
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        ReserveTokenFixture assetB = ReserveTokenFixture(basketB);
        uint256 authNonce = nft.authorizationNonce(id);
        uint256 aliceA = assetA.balanceOf(ALICE);
        uint256 aliceB = assetB.balanceOf(ALICE);
        uint256 aliceHunter = token.balanceOf(ALICE);
        // nextUncheckedDay (2) is already past the day-1 barrier.
        assertTrue(lc.switchReady(id));

        // TEST-ONLY 2:1 route, admitted for real and pre-funded with exactly
        // the 60 basketB units the 30-unit input must produce.
        SwitchConverterFixture converter = new SwitchConverterFixture(2, 1);
        registry.admitConverter(address(converter), keccak256("review-converter-2to1"));
        assetB.mint(address(converter), 60);
        assertTrue(registry.isConverterUsable(address(converter)));
        _assertPendingSwitchIntact(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // Expired deadline: rejected before any owner/custody/request check.
        uint256 staleDeadline = block.timestamp - 1;
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.SwitchDeadlineExpired.selector, staleDeadline));
        lc.completeSwitch(id, address(converter), 30, 60, staleDeadline, 1);
        _assertPendingSwitchIntact(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // Stale supplied switch nonce: the pending request consumed nonce 1.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.StaleSwitchNonce.selector, id));
        lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 2);
        _assertPendingSwitchIntact(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // Wrong expected input: combined backing is exactly 30.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.InvalidSwitchQuote.selector));
        lc.completeSwitch(id, address(converter), 31, 60, block.timestamp, 1);
        _assertPendingSwitchIntact(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // Zero minOutput is forbidden while combined backing is positive.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.InvalidSwitchQuote.selector));
        lc.completeSwitch(id, address(converter), 30, 0, block.timestamp, 1);
        _assertPendingSwitchIntact(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // Destination entry disabled AFTER the request still blocks completion.
        registry.setEntryEnabled(basketB, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.BasketNotEnabled.selector, basketB));
        lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        registry.setEntryEnabled(basketB, true);
        _assertPendingSwitchIntact(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // A deployed but never-admitted converter is unusable; its code is
        // never reached, so its own callCount stays at zero too.
        SwitchConverterFixture unknown = new SwitchConverterFixture(2, 1);
        assertFalse(registry.isConverterUsable(address(unknown)));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.ConverterNotUsable.selector, address(unknown)));
        lc.completeSwitch(id, address(unknown), 30, 60, block.timestamp, 1);
        assertEq(unknown.callCount(), 0);
        _assertPendingSwitchIntact(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // Disabling the admitted route blocks completion until re-enabled.
        registry.setConverterEnabled(address(converter), false);
        assertFalse(registry.isConverterUsable(address(converter)));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.ConverterNotUsable.selector, address(converter)));
        lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        registry.setConverterEnabled(address(converter), true);
        assertTrue(registry.isConverterUsable(address(converter)));
        _assertPendingSwitchIntact(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // A post-admission code change breaks usability even while enabled:
        // the pinned codehash no longer matches. The reverting TEST-ONLY
        // runtime is never executed — policy rejects before interaction.
        bytes memory admittedCode = address(converter).code;
        vm.etch(address(converter), hex"60006000fd"); // PUSH1 0; PUSH1 0; REVERT
        assertFalse(registry.isConverterUsable(address(converter)));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.ConverterNotUsable.selector, address(converter)));
        lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        vm.etch(address(converter), admittedCode);
        assertTrue(registry.isConverterUsable(address(converter)));
        _assertPendingSwitchIntact(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // The exact valid retry succeeds once: 30 basketA owner units in,
        // 60 basketB out through the admitted route.
        vm.prank(ALICE);
        uint256 totalOut = lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        assertEq(totalOut, 60);
        assertEq(converter.callCount(), 1);
        assertEq(converter.lastCaller(), address(canonicalBacking));
        assertEq(converter.lastAssetIn(), basketA);
        assertEq(converter.lastAssetOut(), basketB);
        assertEq(converter.lastAmountIn(), 30);
        assertEq(converter.lastMinAmountOut(), 60);

        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.basketOf(id), basketB);
        assertEq(nft.authorizationNonce(id), authNonce + 1);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        assertEq(lc.switchNonce(id), 2);
        assertEq(lc.nextUncheckedDay(id), 2);
        assertFalse(lc.switchReady(id));
        _assertMemberEq(lc.currentMember(id), basketB, 100, 50, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketB), 100, 50, 1);
        _assertTotalsEq(lc.currentGlobal(), 100, 50, 1);

        // HUNTER reserve untouched; with zero round-source input the whole
        // 60-unit output lands on the owner-source ledger.
        assertEq(vault.reserveOf(id), 50);
        assertEq(vault.totalReserved(), 50);
        assertEq(token.balanceOf(address(vault)), 50);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 60);
        assertEq(canonicalBacking.totalBackingOf(id), 60);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 30);
        assertEq(canonicalBacking.totalReceived(basketB), 0);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 60);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        assertEq(assetA.balanceOf(address(canonicalBacking)), 0);
        assertEq(assetB.balanceOf(address(canonicalBacking)), 60);
        assertEq(assetA.balanceOf(address(converter)), 30);
        assertEq(assetB.balanceOf(address(converter)), 0);
        assertEq(assetA.balanceOf(ALICE), aliceA);
        assertEq(assetB.balanceOf(ALICE), aliceB);
        assertEq(token.balanceOf(ALICE), aliceHunter);
        assertEq(assetA.allowance(address(canonicalBacking), address(converter)), 0);

        // Exactly once: no request remains for a replay.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NoSwitchRequest.selector, id));
        lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 2);
        assertEq(converter.callCount(), 1);
        assertEq(lc.switchNonce(id), 2);
        assertEq(nft.authorizationNonce(id), authNonce + 1);
    }

    /// @notice M2.2 positive-backing completion against a live ADMITTED
    /// adversarial converter — the interaction failures the pre-call quote,
    /// policy and codehash checks cannot cover. On ALICE's pending
    /// basketA->basketB switch carrying 30 TEST-ONLY owner-backing units
    /// (plus the 50 HUNTER reserve), one fixture admitted once walks four
    /// storage-switched failure modes with a stable codehash: explicit
    /// custom-error revert, under-debit (pulls 29 of the exact-30 input yet
    /// pays the full 60), no-output (pulls 30, delivers zero, reports a
    /// misleading nonzero return) and short-output (pulls 30, delivers 59
    /// against minOutput 60, reports a misleading return). Each reverts with
    /// its exact error — the fixture's own or the vault's measured
    /// debit/output one — and every converter-side write and token move
    /// rolls back with it: request, nonces, paused member, totals, reserve,
    /// ledgers, counters, balances, allowance and callCount stay
    /// bit-identical. The normal-mode retry then completes once: the exact
    /// 30 owner units become 60 basketB units on the owner-source ledger
    /// with HUNTER untouched. NON-PRODUCTION values throughout.
    function testConverterFailuresRollbackAtomicallyThenRetry() public {
        uint256 id = _mintBackedPendingSwitch();
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        ReserveTokenFixture assetB = ReserveTokenFixture(basketB);
        uint256 authNonce = nft.authorizationNonce(id);
        uint256 aliceA = assetA.balanceOf(ALICE);
        uint256 aliceB = assetB.balanceOf(ALICE);
        uint256 aliceHunter = token.balanceOf(ALICE);
        assertTrue(lc.switchReady(id));

        // TEST-ONLY adversarial route: admitted once, pre-funded with exactly
        // the 60 basketB the retry must pay, then storage-switched between
        // modes so the admission-pinned codehash never moves.
        AdversarialConverterFixture converter = new AdversarialConverterFixture();
        registry.admitConverter(address(converter), keccak256("review-converter-adversarial"));
        assetB.mint(address(converter), 60);
        assertTrue(registry.isConverterUsable(address(converter)));
        _assertAdversarialRollback(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // Explicit converter revert: the fixture custom error bubbles
        // verbatim through the vault and the lifecycle.
        converter.setMode(AdversarialConverterFixture.Mode.Revert);
        assertTrue(registry.isConverterUsable(address(converter)));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(AdversarialConverterFixture.ConverterExploded.selector));
        lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        _assertAdversarialRollback(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // Under-debit: only 29 of the quoted 30 leave the vault even though
        // the full 60 arrive — the measured debit must equal totalIn exactly.
        converter.setMode(AdversarialConverterFixture.Mode.UnderDebit);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.DebitMismatch.selector));
        lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        _assertAdversarialRollback(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // No-output: the full 30 are pulled, zero basketB arrives and the
        // misleading 60 return is ignored for accounting.
        converter.setMode(AdversarialConverterFixture.Mode.NoOutput);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.InsufficientConversionOutput.selector, 60, 0));
        lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        _assertAdversarialRollback(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // Short-output: 59 arrive against the 60 minimum, again under a
        // misleading reported 60.
        converter.setMode(AdversarialConverterFixture.Mode.ShortOutput);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.InsufficientConversionOutput.selector, 60, 59));
        lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        _assertAdversarialRollback(id, converter, authNonce, aliceA, aliceB, aliceHunter);

        // The honest retry completes once on the same quote: exact 30 -> 60.
        converter.setMode(AdversarialConverterFixture.Mode.Normal);
        assertTrue(registry.isConverterUsable(address(converter)));
        vm.prank(ALICE);
        uint256 totalOut = lc.completeSwitch(id, address(converter), 30, 60, block.timestamp, 1);
        assertEq(totalOut, 60);
        assertEq(converter.callCount(), 1);

        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.basketOf(id), basketB);
        assertEq(nft.authorizationNonce(id), authNonce + 1);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, address(0));
        assertEq(req.barrierDay, 0);
        assertEq(req.authorizationNonce, 0);
        assertEq(lc.switchNonce(id), 2);
        assertEq(lc.nextUncheckedDay(id), 2);
        assertFalse(lc.switchReady(id));
        _assertMemberEq(lc.currentMember(id), basketB, 100, 50, true, true);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketB), 100, 50, 1);
        _assertTotalsEq(lc.currentGlobal(), 100, 50, 1);

        // HUNTER reserve untouched; with zero round-source input the whole
        // 60-unit output lands on the owner-source ledger.
        assertEq(vault.reserveOf(id), 50);
        assertEq(vault.totalReserved(), 50);
        assertEq(token.balanceOf(address(vault)), 50);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 60);
        assertEq(canonicalBacking.totalBackingOf(id), 60);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 30);
        assertEq(canonicalBacking.totalReceived(basketB), 0);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 60);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        assertEq(assetA.balanceOf(address(canonicalBacking)), 0);
        assertEq(assetB.balanceOf(address(canonicalBacking)), 60);
        assertEq(assetA.balanceOf(address(converter)), 30);
        assertEq(assetB.balanceOf(address(converter)), 0);
        assertEq(assetA.balanceOf(ALICE), aliceA);
        assertEq(assetB.balanceOf(ALICE), aliceB);
        assertEq(token.balanceOf(ALICE), aliceHunter);
        assertEq(assetA.allowance(address(canonicalBacking), address(converter)), 0);
    }

    function _assertConsumedDayOneShare(uint256 id) private view {
        assertTrue(canonicalBacking.consumed(1, id));
        (address shareBasket, uint256 shareUnits) = canonicalBacking.memberReceivedShare(1, id);
        assertEq(shareBasket, basketA);
        assertEq(shareUnits, 40);
    }

    /// @dev TEST-ONLY small-value setup for the pending-switch invalidation
    /// and burn-cleanup proofs — NOT production values: at day 1, mint
    /// ALICE a tier-1 basketA Hunter, credit a 50 HUNTER reserve, add 30
    /// units of owner-deposited basketA backing, then leave ALICE's basketB
    /// request pending (member paused, switchNonce consumed once).
    function _mintBackedPendingSwitch() private returns (uint256 id) {
        vm.warp(1 days + 100);
        id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        assertEq(vault.deposit(id, 50), 50);
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assetA.mint(ALICE, 30);
        vm.prank(ALICE);
        assetA.approve(address(canonicalBacking), 30);
        vm.prank(ALICE);
        assertEq(canonicalBacking.depositOwnerBacking(id, 30), 30);
        vm.prank(ALICE);
        assertEq(lc.requestSwitch(id, basketB), 1);
    }

    /// @dev Snapshot assertion for the stale-quote/policy rejection proof
    /// above: the pending request, paused member, totals, reserve, both
    /// backing sources, per-source counters, vault/converter/user balances,
    /// converter callCount and allowance must be bit-identical after every
    /// failed completion attempt. All expected values are TEST-ONLY.
    function _assertPendingSwitchIntact(
        uint256 id,
        SwitchConverterFixture converter,
        uint256 authNonce,
        uint256 aliceA,
        uint256 aliceB,
        uint256 aliceHunter
    ) private {
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.basketOf(id), basketA);
        assertEq(nft.authorizationNonce(id), authNonce);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 1);
        assertEq(req.authorizationNonce, authNonce);
        assertEq(lc.switchNonce(id), 1);
        assertEq(lc.nextUncheckedDay(id), 2);
        assertTrue(lc.switchReady(id));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, false);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketB), 0, 0, 0);
        _assertTotalsEq(lc.currentGlobal(), 0, 0, 0);
        assertEq(vault.reserveOf(id), 50);
        assertEq(vault.totalReserved(), 50);
        assertEq(token.balanceOf(address(vault)), 50);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);
        assertEq(canonicalBacking.totalBackingOf(id), 30);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 0);
        assertEq(canonicalBacking.totalReceived(basketB), 0);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        ReserveTokenFixture assetB = ReserveTokenFixture(basketB);
        assertEq(assetA.balanceOf(address(canonicalBacking)), 30);
        assertEq(assetB.balanceOf(address(canonicalBacking)), 0);
        assertEq(assetA.balanceOf(address(converter)), 0);
        assertEq(assetB.balanceOf(address(converter)), 60);
        assertEq(assetA.balanceOf(ALICE), aliceA);
        assertEq(assetB.balanceOf(ALICE), aliceB);
        assertEq(token.balanceOf(ALICE), aliceHunter);
        assertEq(converter.callCount(), 0);
        assertEq(assetA.allowance(address(canonicalBacking), address(converter)), 0);
    }

    /// @dev Snapshot assertion for the converter-failure atomicity proof
    /// above: after every failed completion the pending request, paused
    /// member, totals, reserve, both backing ledgers, per-source counters,
    /// backing-vault and converter balances, user balances, converter
    /// callCount and allowance must be bit-identical — every write the vault
    /// or converter made inside the failed call rolls back with it.
    /// All expected values are TEST-ONLY.
    function _assertAdversarialRollback(
        uint256 id,
        AdversarialConverterFixture converter,
        uint256 authNonce,
        uint256 aliceA,
        uint256 aliceB,
        uint256 aliceHunter
    ) private {
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.basketOf(id), basketA);
        assertEq(nft.authorizationNonce(id), authNonce);
        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(id);
        assertEq(req.target, basketB);
        assertEq(req.barrierDay, 1);
        assertEq(req.authorizationNonce, authNonce);
        assertEq(lc.switchNonce(id), 1);
        assertEq(lc.nextUncheckedDay(id), 2);
        assertTrue(lc.switchReady(id));
        _assertMemberEq(lc.currentMember(id), basketA, 100, 50, true, false);
        _assertTotalsEq(lc.currentBasket(basketA), 0, 0, 0);
        _assertTotalsEq(lc.currentBasket(basketB), 0, 0, 0);
        _assertTotalsEq(lc.currentGlobal(), 0, 0, 0);
        assertEq(vault.reserveOf(id), 50);
        assertEq(vault.totalReserved(), 50);
        assertEq(token.balanceOf(address(vault)), 50);
        assertEq(canonicalBacking.backingOf(id), 0);
        assertEq(canonicalBacking.ownerBackingOf(id), 30);
        assertEq(canonicalBacking.totalBackingOf(id), 30);
        assertEq(canonicalBacking.totalReceived(basketA), 0);
        assertEq(canonicalBacking.totalReleased(basketA), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketA), 30);
        assertEq(canonicalBacking.totalOwnerReleased(basketA), 0);
        assertEq(canonicalBacking.totalReceived(basketB), 0);
        assertEq(canonicalBacking.totalReleased(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReceived(basketB), 0);
        assertEq(canonicalBacking.totalOwnerReleased(basketB), 0);
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        ReserveTokenFixture assetB = ReserveTokenFixture(basketB);
        assertEq(assetA.balanceOf(address(canonicalBacking)), 30);
        assertEq(assetB.balanceOf(address(canonicalBacking)), 0);
        assertEq(assetA.balanceOf(address(converter)), 0);
        assertEq(assetB.balanceOf(address(converter)), 60);
        assertEq(assetA.balanceOf(ALICE), aliceA);
        assertEq(assetB.balanceOf(ALICE), aliceB);
        assertEq(token.balanceOf(ALICE), aliceHunter);
        assertEq(converter.callCount(), 0);
        assertEq(assetA.allowance(address(canonicalBacking), address(converter)), 0);
    }
}

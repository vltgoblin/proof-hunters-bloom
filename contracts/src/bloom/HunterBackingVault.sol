// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBasketConverter} from "./IBasketConverter.sol";
import {WeightedRoundMaterialisation} from "./WeightedRoundMaterialisation.sol";
import {WeightedHistory} from "./libraries/WeightedHistory.sol";

/// @notice Canonical lifecycle views needed for fixed-beneficiary payouts.
interface IHunterBackingLifecycle {
    function backing() external view returns (address);

    function finalBeneficiary(uint256 tokenId) external view returns (address);

    function currentMember(uint256 tokenId) external view returns (WeightedHistory.Member memory);
}

/// @notice Same-address funded backing custody with atomic burn and late-share payouts.
/// @dev Candidate: no lending or release-readiness claim; the M2.2
/// lifecycle-only measured switch conversion IS implemented.
/// Construction and payout legs require lifecycle.backing()==this; inherited
/// fund validates frozen ledger state and materialise validates canonical
/// NFT/lifecycle wiring.
/// Shares consumed before burn become backing; remaining funded historical
/// shares can only be claimed by the fixed burn beneficiary. Zero units make
/// no token calls. Positive releases verify exact gross debit and solvency;
/// recipient net amounts remain subject to approved token behavior.
/// Owner backing is a SECOND, separate liability source: a live owner-held
/// Hunter's current owner can deposit measured units of that NFT's basket
/// asset, tracked by `ownerBackingOf`/`totalOwnerReceived`/`totalOwnerReleased`
/// and never inside the ecosystem-round `totalReceived`/`totalReleased`
/// counters. The `_outstanding` override folds both sources into the combined
/// solvency bound, so inherited `fund` and `unaccountedBalance` already cover
/// owner custody. Burn makes one exact aggregate transfer to the fixed
/// beneficiary while advancing each source's own released counter.
contract HunterBackingVault is WeightedRoundMaterialisation {
    using SafeERC20 for IERC20;

    mapping(uint256 => bool) public burnSettled;
    /// @notice Owner-deposited backing units per tokenId, denominated in that
    /// NFT's live basket asset. Cleared once at burn settlement; a separate
    /// liability from materialised `_backing`, never re-denominated.
    mapping(uint256 => uint256) public ownerBackingOf;
    /// @notice Cumulative measured owner-deposit receipts per asset.
    /// @dev Strictly additive at deposit; owner releases never decrease it.
    /// Ecosystem round receipts stay in `totalReceived` — the counters never mix.
    mapping(address => uint256) public totalOwnerReceived;
    /// @notice Cumulative per-asset owner-deposit units released by the burn
    /// payout leg. Advanced atomically with the aggregate outbound transfer
    /// and bounded by `totalOwnerReceived`.
    mapping(address => uint256) public totalOwnerReleased;

    /// @dev Old- and new-asset balance snapshots bracketing the
    /// `convertForSwitch` interaction leg, packed into one memory instance to
    /// keep the four balances off the stack.
    struct SwitchBalances {
        uint256 inBefore;
        uint256 outBefore;
        uint256 inAfter;
        uint256 outAfter;
    }

    event BackingPayout(
        uint256 indexed tokenId, address indexed asset, address indexed beneficiary, uint256 grossUnits
    );
    /// @dev `grossUnits` is the owner-deposit component of the burn payout —
    /// `BackingPayout.grossUnits` stays round-only; the aggregate transfer is
    /// their sum.
    event OwnerBackingPayout(
        uint256 indexed tokenId, address indexed asset, address indexed beneficiary, uint256 grossUnits
    );
    /// @dev `backing` is the tokenId's cumulative owner backing after the credit.
    event OwnerBackingDeposited(
        uint256 indexed tokenId,
        address indexed asset,
        address indexed owner,
        uint256 requested,
        uint256 received,
        uint256 backing
    );
    event BurnedShareClaimed(
        uint32 indexed day, uint256 indexed tokenId, address indexed asset, address beneficiary, uint256 grossUnits
    );
    /// @dev One conversion, two sources: `roundIn`/`ownerIn` are the consumed
    /// old-asset liabilities; `roundOut`/`ownerOut` are the replacement
    /// new-asset credits — `roundOut + ownerOut` equals the measured output
    /// exactly, with the at-most-one-unit floor remainder staying
    /// owner-source.
    event SwitchConverted(
        uint256 indexed tokenId,
        address indexed assetIn,
        address indexed assetOut,
        address converter,
        uint256 roundIn,
        uint256 ownerIn,
        uint256 roundOut,
        uint256 ownerOut
    );

    error UnauthorizedLifecycle();
    error InvalidBeneficiary();
    error BeneficiaryMismatch(uint256 tokenId);
    error MemberNotBurned(uint256 tokenId);
    error TokenNotBurned(uint256 tokenId);
    error BurnAlreadySettled(uint256 tokenId);
    error BurnNotSettled(uint256 tokenId);
    error UnauthorizedBeneficiary(uint256 tokenId);
    error InvalidAsset(uint256 tokenId);
    error DebitMismatch();
    error NotTokenOwner(uint256 tokenId);
    error TokenEncumbered(uint256 tokenId);
    error StaleDepositState(uint256 tokenId);
    error InvalidConversion();
    error InsufficientConversionOutput(uint256 required, uint256 actual);
    error StaleConversionState(uint256 tokenId);

    constructor(address ledger_, address funder_) WeightedRoundMaterialisation(ledger_, funder_) {
        _canonicalLifecycle();
    }

    /// @notice Owner backing deposit: the current owner of a live owner-held
    /// Hunter pulls `requested` units of that NFT's basket asset into custody
    /// and is credited the measured `received` delta. Repeatable; no cap, fee
    /// or fixed amount. The asset is derived ONLY from `nft.basketOf` — no
    /// caller-selected asset or beneficiary, and no registry entryEnabled
    /// read, so disabling a basket after mint never freezes its Hunters.
    /// @dev Ordered gates: `_custodyWired`; nonzero `requested`; canonical
    /// `ownerOf` (a nonexistent or burned id reverts through the NFT);
    /// `owner == msg.sender`; unencumbered (no escrow, no credit lock). Owner
    /// and `authorizationNonce` are snapshotted before the pull and re-verified
    /// after the token callback along with the unencumbered state — a callback
    /// that transfers, self-transfers or encumbers the NFT reverts
    /// `StaleDepositState` atomically. Receipt is the measured balance delta:
    /// `0 < received <= requested` (taxed receipt supported); a decrease, zero
    /// or over-receipt reverts `UnsupportedTokenReceipt`, and a false-returning
    /// or reverting transfer rolls back through SafeERC20. Solvency is checked
    /// against the combined `_outstanding` liability before the pull and again
    /// after the commit.
    function depositOwnerBacking(uint256 tokenId, uint256 requested) external nonReentrant returns (uint256 received) {
        _custodyWired();
        if (requested == 0) revert InvalidAmount();
        address owner = nft.ownerOf(tokenId);
        if (owner != msg.sender) revert NotTokenOwner(tokenId);
        if (nft.isEncumbered(tokenId)) revert TokenEncumbered(tokenId);
        address asset = nft.basketOf(tokenId);
        uint256 nonce = nft.authorizationNonce(tokenId);
        {
            IERC20 token = IERC20(asset);
            uint256 balBefore = token.balanceOf(address(this));
            if (balBefore < _outstanding(asset)) revert Insolvency();

            token.safeTransferFrom(msg.sender, address(this), requested);

            uint256 balAfter = token.balanceOf(address(this));
            if (balAfter < balBefore) revert UnsupportedTokenReceipt();
            received = balAfter - balBefore;
            if (received == 0 || received > requested) revert UnsupportedTokenReceipt();
        }
        try nft.ownerOf(tokenId) returns (address current) {
            if (current != owner) revert StaleDepositState(tokenId);
        } catch {
            revert StaleDepositState(tokenId);
        }
        if (nft.authorizationNonce(tokenId) != nonce || nft.isEncumbered(tokenId)) {
            revert StaleDepositState(tokenId);
        }

        ownerBackingOf[tokenId] += received;
        totalOwnerReceived[asset] += received;
        emit OwnerBackingDeposited(tokenId, asset, owner, requested, received, ownerBackingOf[tokenId]);

        if (IERC20(asset).balanceOf(address(this)) < _outstanding(asset)) revert Insolvency();
    }

    /// @notice Canonical lifecycle calls after history ends and beneficiary is fixed.
    /// @dev Clears materialised round backing AND owner backing for the tokenId,
    /// then makes ONE exact aggregate transfer to the fixed beneficiary. Each
    /// source advances only its own released counter and emits its own payout
    /// event — `BackingPayout.grossUnits` stays round-only. Any payout failure
    /// reverts the burn hook and both accounting sources atomically.
    function onBurnBacking(uint256 tokenId, address beneficiary) external nonReentrant {
        if (msg.sender != address(lifecycle)) revert UnauthorizedLifecycle();
        _custodyWired();
        IHunterBackingLifecycle lc = _canonicalLifecycle();
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary();
        if (beneficiary != lc.finalBeneficiary(tokenId)) revert BeneficiaryMismatch(tokenId);
        _requireBurned(lc, tokenId);
        if (burnSettled[tokenId]) revert BurnAlreadySettled(tokenId);
        burnSettled[tokenId] = true;
        uint256 roundUnits = _backing[tokenId];
        uint256 ownerUnits = ownerBackingOf[tokenId];
        address asset = nft.basketOf(tokenId);
        if (roundUnits + ownerUnits != 0 && asset == address(0)) revert InvalidAsset(tokenId);
        _backing[tokenId] = 0;
        ownerBackingOf[tokenId] = 0;
        _release(asset, beneficiary, roundUnits, ownerUnits);
        emit BackingPayout(tokenId, asset, beneficiary, roundUnits);
        emit OwnerBackingPayout(tokenId, asset, beneficiary, ownerUnits);
    }

    /// @notice Claim one unconsumed historical share after the burn hook settled.
    function claimBurned(uint32 day, uint256 tokenId) external nonReentrant {
        _custodyWired();
        IHunterBackingLifecycle lc = _canonicalLifecycle();
        _requireBurned(lc, tokenId);
        if (!burnSettled[tokenId]) revert BurnNotSettled(tokenId);
        address beneficiary = lc.finalBeneficiary(tokenId);
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary();
        if (msg.sender != beneficiary) revert UnauthorizedBeneficiary(tokenId);
        if (_consumed[day][tokenId]) revert AlreadyConsumed(day, tokenId);
        (address asset, uint256 units) = _memberShare(day, tokenId);
        _consumed[day][tokenId] = true;
        _release(asset, beneficiary, units, 0);
        emit BurnedShareClaimed(day, tokenId, asset, beneficiary, units);
    }

    /// @notice Combined backing of `tokenId`: materialised round units plus
    /// owner-deposited units, both denominated in the NFT's basket asset.
    /// @dev Additive view — `backingOf` keeps its round-only semantics and the
    /// per-source counters stay separate.
    function totalBackingOf(uint256 tokenId) external view returns (uint256) {
        return _backing[tokenId] + ownerBackingOf[tokenId];
    }

    /// @notice Lifecycle-only measured switch conversion: converts the
    /// tokenId's whole combined backing — `roundIn` materialised round units
    /// plus `ownerIn` owner-deposited units — out of the live `basketOf` asset
    /// into `newBasket` through the admitted `converter`, then REPLACES the
    /// per-token ledgers with the source-preserving output split.
    /// @dev Caller: the canonical lifecycle only (`completeSwitch` has already
    /// authenticated owner, custody, request, nonces, readiness and route).
    /// Requires `expectedInput == roundIn + ownerIn > 0` and a nonzero
    /// `minOutput`; the zero-backing switch never reaches this function — no
    /// approval, token transfer or converter call occurs there.
    ///
    /// Effects before interaction: the old asset's round released counter
    /// advances by `roundIn` and the owner released counter by `ownerIn` —
    /// bounded by their received counters — before the converter is touched.
    /// The converter gets exactly `totalIn` of old-asset allowance via
    /// zero-then-exact `forceApprove`, is invoked on the narrow
    /// `IBasketConverter` surface (no target, recipient or calldata blob — the
    /// converter must deliver to this address), and the allowance is cleared
    /// before returning. Return values are never trusted: the old-asset debit
    /// must equal `totalIn` exactly and the measured new-asset increase is
    /// `totalOut`, required `>= minOutput`.
    ///
    /// Source split: `roundOut = floor(totalOut * roundIn / totalIn)` and
    /// `ownerOut = totalOut - roundOut`; the at-most-one-unit floor remainder
    /// stays with the NFT as owner-source backing. `_backing` and
    /// `ownerBackingOf` are REPLACED, never added to; the new asset's round
    /// received counter credits `roundOut` and its owner received counter
    /// `ownerOut`, keeping both source ledgers separate under one swap.
    ///
    /// Owner, authorization nonce and unencumbered state are snapshotted
    /// before and revalidated after the token/converter calls; old- and
    /// new-asset solvency against combined `_outstanding` is checked before
    /// and after. Any deviation reverts the whole conversion.
    function convertForSwitch(
        uint256 tokenId,
        address converter,
        address newBasket,
        uint256 expectedInput,
        uint256 minOutput
    ) external nonReentrant returns (uint256 totalOut) {
        if (msg.sender != address(lifecycle)) revert UnauthorizedLifecycle();
        _custodyWired();
        _canonicalLifecycle();
        uint256 roundIn = _backing[tokenId];
        uint256 ownerIn = ownerBackingOf[tokenId];
        uint256 totalIn = roundIn + ownerIn;
        if (totalIn == 0 || expectedInput != totalIn || minOutput == 0) revert InvalidConversion();
        address assetIn = nft.basketOf(tokenId);
        if (assetIn == address(0) || newBasket == address(0) || newBasket == assetIn) {
            revert InvalidAsset(tokenId);
        }
        SwitchBalances memory b;
        {
            address owner = nft.ownerOf(tokenId);
            uint256 nonce = nft.authorizationNonce(tokenId);
            if (nft.isEncumbered(tokenId)) revert TokenEncumbered(tokenId);

            b.inBefore = IERC20(assetIn).balanceOf(address(this));
            b.outBefore = IERC20(newBasket).balanceOf(address(this));
            if (b.inBefore < _outstanding(assetIn) || b.outBefore < _outstanding(newBasket)) revert Insolvency();
            {
                uint256 released_ = _totalReleased[assetIn] + roundIn;
                if (released_ > totalReceived[assetIn]) revert Insolvency();
                _totalReleased[assetIn] = released_;
                uint256 ownerReleased_ = totalOwnerReleased[assetIn] + ownerIn;
                if (ownerReleased_ > totalOwnerReceived[assetIn]) revert Insolvency();
                totalOwnerReleased[assetIn] = ownerReleased_;
            }

            IERC20(assetIn).forceApprove(converter, totalIn);
            IBasketConverter(converter).convert(assetIn, newBasket, totalIn, minOutput);
            IERC20(assetIn).forceApprove(converter, 0);

            b.inAfter = IERC20(assetIn).balanceOf(address(this));
            b.outAfter = IERC20(newBasket).balanceOf(address(this));
            if (b.inAfter > b.inBefore || b.inBefore - b.inAfter != totalIn) revert DebitMismatch();
            if (b.outAfter <= b.outBefore) revert InsufficientConversionOutput(minOutput, 0);
            totalOut = b.outAfter - b.outBefore;
            if (totalOut < minOutput) revert InsufficientConversionOutput(minOutput, totalOut);

            _requireUnchanged(tokenId, owner, nonce);
        }

        uint256 roundOut = Math.mulDiv(totalOut, roundIn, totalIn);
        uint256 ownerOut = totalOut - roundOut;
        _backing[tokenId] = roundOut;
        ownerBackingOf[tokenId] = ownerOut;
        totalReceived[newBasket] += roundOut;
        totalOwnerReceived[newBasket] += ownerOut;

        if (b.inAfter < _outstanding(assetIn) || b.outAfter < _outstanding(newBasket)) revert Insolvency();
        emit SwitchConverted(tokenId, assetIn, newBasket, converter, roundIn, ownerIn, roundOut, ownerOut);
    }

    function _canonicalLifecycle() private view returns (IHunterBackingLifecycle lc) {
        lc = IHunterBackingLifecycle(address(lifecycle));
        try lc.backing() returns (address bound) {
            if (bound != address(this)) revert WiringMismatch();
        } catch {
            revert WiringMismatch();
        }
    }

    /// @dev Cross-contract race defense for the conversion leg, same shape as
    /// the reserve's `_requireUnchanged`: the NFT must keep the same owner,
    /// authorization nonce and unencumbered status across the external
    /// token/converter calls.
    function _requireUnchanged(uint256 tokenId, address owner, uint256 nonce) private view {
        if (nft.ownerOf(tokenId) != owner || nft.authorizationNonce(tokenId) != nonce || nft.isEncumbered(tokenId)) {
            revert StaleConversionState(tokenId);
        }
    }

    /// @dev Known dead history first; an ownerOf revert alone is insufficient.
    function _requireBurned(IHunterBackingLifecycle lc, uint256 tokenId) private view {
        WeightedHistory.Member memory m = lc.currentMember(tokenId);
        if (m.alive || m.eligible) revert MemberNotBurned(tokenId);
        bool burned;
        try nft.ownerOf(tokenId) returns (address) {}
        catch {
            burned = true;
        }
        if (!burned) revert TokenNotBurned(tokenId);
    }

    /// @dev Combined per-asset custody liability: checked round outstanding
    /// (`totalReceived - _totalReleased`) plus checked owner outstanding
    /// (`totalOwnerReceived - totalOwnerReleased`). `released > received` on
    /// EITHER source is an impossible-by-construction accounting break and
    /// reverts `Insolvency`; the sum uses checked arithmetic. Inherited `fund`
    /// and `unaccountedBalance` thereby cover both liability sources.
    function _outstanding(address asset) internal view override returns (uint256) {
        uint256 ownerReceived_ = totalOwnerReceived[asset];
        uint256 ownerReleased_ = totalOwnerReleased[asset];
        if (ownerReleased_ > ownerReceived_) revert Insolvency();
        return super._outstanding(asset) + (ownerReceived_ - ownerReleased_);
    }

    /// @dev Effects precede interaction; failure reverts the whole outer
    /// operation. `roundUnits` advances only `_totalReleased` (bounded by
    /// `totalReceived`); `ownerUnits` advances only `totalOwnerReleased`
    /// (bounded by `totalOwnerReceived`). A positive aggregate checks the
    /// pre-balance against combined `_outstanding` BEFORE the counters move,
    /// makes one exact gross debit, then rechecks the post-balance against the
    /// reduced combined liability. Zero aggregate makes no token call.
    function _release(address asset, address beneficiary, uint256 roundUnits, uint256 ownerUnits) private {
        uint256 units = roundUnits + ownerUnits;
        if (units == 0) return;
        IERC20 token = IERC20(asset);
        uint256 balBefore = token.balanceOf(address(this));
        if (balBefore < _outstanding(asset)) revert Insolvency();
        uint256 released_ = _totalReleased[asset] + roundUnits;
        if (released_ > totalReceived[asset]) revert Insolvency();
        _totalReleased[asset] = released_;
        uint256 ownerReleased_ = totalOwnerReleased[asset] + ownerUnits;
        if (ownerReleased_ > totalOwnerReceived[asset]) revert Insolvency();
        totalOwnerReleased[asset] = ownerReleased_;
        token.safeTransfer(beneficiary, units);
        uint256 balAfter = token.balanceOf(address(this));
        if (balAfter > balBefore || balBefore - balAfter != units) revert DebitMismatch();
        if (balAfter < _outstanding(asset)) revert Insolvency();
    }
}

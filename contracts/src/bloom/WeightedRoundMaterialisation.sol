// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {WeightedRoundFunding} from "./WeightedRoundFunding.sol";
import {IWeightedRoundHistory} from "./WeightedRoundLedger.sol";
import {HunterNFT, IHunterLifecycle} from "./HunterNFT.sol";

/// @title WeightedRoundMaterialisation
/// @notice INCOMPLETE ABSTRACT BASE — converts a funded `(day, basket)`
/// member share into stored NFT backing at the SAME address and storage as
/// the funding custody (inheritance, not a module). NOT deployable and NOT
/// production-complete: this slice performs a permissionless accounting
/// relabel only — it moves NO tokens and is not complete launch custody.
/// @dev Like its base, custody is completable only by a concrete derived
/// contract at the same address — the final custody/payout composition — so
/// nothing deployable can permanently lock assets.
///
/// Canonical wiring: `lifecycle` and `nft` are DERIVED from
/// `ledger.lifecycle().nft()` — never caller-supplied. A constructor NFT
/// argument could counterfeit the liveness and basket reads `materialise`
/// depends on; the binding instead reuses the exact getters the ledger's own
/// constructor already validated (deployed lifecycle code, nonzero distinct
/// `nft()`/`reserve()`). `nft` may still be a predicted, not-yet-deployed
/// address at construction under the launch build order; that is safe ONLY
/// because the binding is canonical and `_custodyWired` verifies code
/// presence plus the `LIFECYCLE` backpointer before `materialise` — a
/// miswired or undeployed NFT reverts `WiringMismatch` before any dependent
/// state read.
///
/// What `materialise` records: `(day, tokenId)` is consumed exactly once — a
/// zero-unit share still consumes — and its frozen received-unit share is
/// added to `_backing[tokenId]`, denominated in that live NFT's single
/// basket asset. The call is effects-only: no token transfer, no
/// `totalReceived` or `_totalReleased` change — `_totalReleased` stays 0
/// with no mutator in this file. The caller is irrelevant: credit accrues
/// only to `backing[tokenId]`, never to `msg.sender`.
///
/// Conservation (per asset, provable from existing state):
/// `balance == unaccountedBalance + (totalReceived - totalReleased)` with
/// the outstanding liability partitioned into — A: funded unconsumed shares
/// of LIVE ids (the materialisable surface); B: funded unconsumed shares of
/// BURNED ids (reserved for the future fixed-beneficiary claim leg — they
/// are NOT consumed, released or cash-claimed here); C: `_backing[tokenId]`
/// over every consumed id, live or burned — a burn leaves materialised units
/// inside C because no release leg exists yet; D: floor residues (group
/// received minus summed shares, staying reserved). `materialise` moves
/// units A -> C; a later burn relabels that id's unconsumed shares A -> B
/// and leaves its `_backing` in C. Neither moves tokens, so the identity
/// holds in every phase.
///
/// Basket semantics: `backing[tokenId]` is single-asset in the NFT's live
/// fixed basket; the stored amount is NEVER re-denominated, overwritten or
/// switched, and there is no live old-basket cash claim. Under the approved
/// settle-then-convert switch policy, old-basket rights keep settling into
/// `_backing` while `basketOf` still reads the old basket — exactly what the
/// later conversion consumes — and a leftover old-basket share after a real
/// conversion reverts `BasketMismatch` rather than silently claiming or
/// re-denominating. No switch seam exists in this file.
///
/// Deliberately absent here — future gates, NOT implemented and NOT claimed:
/// the typed burn-payout hook, which must require the canonical lifecycle as
/// sole caller AND the canonical `finalBeneficiary` destination AND
/// burned-state validation, run under this custody's shared `nonReentrant`
/// level with `fund`/`materialise`, debit the measured outbound units
/// against the solvency bound, advance `_totalReleased` atomically with a
/// one-shot release, and execute inside the NFT burn transaction so any
/// failure rolls back the HUNTER settlement and the basket leg together;
/// and the post-burn beneficiary claim leg for still-unconsumed shares. No
/// deadline, expiry, carry or batch API either: a funded share is
/// materialisable at any time while the NFT is live.
abstract contract WeightedRoundMaterialisation is WeightedRoundFunding {
    /// @dev Canonical lifecycle — DERIVED, never caller-supplied:
    /// `ledger.lifecycle()`. The ledger's own constructor already enforced
    /// code presence and nonzero `nft()`/`reserve()` on it.
    IWeightedRoundHistory public immutable lifecycle;

    /// @dev Canonical NFT — DERIVED: `lifecycle.nft()`. Sole authority for
    /// live existence (`ownerOf`) and the live basket (`basketOf`).
    /// Immutable; code presence is proven by `_custodyWired` inside
    /// `materialise`, not at construction, because the launch build order
    /// may legitimately predict this address before the NFT is deployed.
    HunterNFT public immutable nft;

    /// @dev `(day, tokenId)` share consumed exactly once — set even for a
    /// zero-unit share, matching the model's `settled` flag.
    mapping(uint32 => mapping(uint256 => bool)) internal _consumed;

    /// @dev `tokenId` -> materialised units, denominated in that live NFT's
    /// single basket asset. Outstanding liability — never re-denominated,
    /// never overwritten, never decreased in this slice: no release mutator
    /// exists.
    mapping(uint256 => uint256) internal _backing;

    /// @dev `units` is the just-consumed share; `backing` is the tokenId's
    /// cumulative stored backing after the credit.
    event Materialised(
        uint32 indexed day, uint256 indexed tokenId, address indexed basket, uint256 units, uint256 backing
    );

    error AlreadyConsumed(uint32 day, uint256 tokenId);
    error BasketMismatch(uint256 tokenId);
    error NotLive(uint256 tokenId);
    error WiringMismatch();

    /// @param ledger_ Deployed canonical `WeightedRoundLedger` — the base
    /// constructor's `ledger_.code.length` check is KEPT unchanged.
    /// @param funder_ Sole `fund` caller, forwarded to the base.
    /// @dev `lifecycle`/`nft` are read back out of the deployed ledger —
    /// there is deliberately NO `nft_` argument. Nonzero `lifecycle` and
    /// `nft` are already guaranteed by the ledger's own constructor; the
    /// distinctness checks below pin the family binding anyway. NO code
    /// check runs on `nft`: it may legitimately be a predicted address under
    /// the launch build order — `_custodyWired` enforces code presence and
    /// the backpointer operationally instead.
    constructor(address ledger_, address funder_) WeightedRoundFunding(ledger_, funder_) {
        IWeightedRoundHistory lifecycle_ = ledger.lifecycle();
        HunterNFT nft_ = HunterNFT(lifecycle_.nft());
        if (
            address(lifecycle_) == address(0) || address(nft_) == address(0) || address(lifecycle_) == address(this)
                || address(lifecycle_) == funder_ || address(nft_) == address(this) || address(nft_) == ledger_
                || address(nft_) == funder_
        ) {
            revert InvalidConfiguration();
        }
        lifecycle = lifecycle_;
        nft = nft_;
    }

    /// @notice Permissionless one-day/one-NFT materialisation: consumes the
    /// funded `(day, tokenId)` member share once and adds its frozen
    /// received units to `backing[tokenId]`. Single allocation operation —
    /// no batch API.
    /// @dev Ordered gates: (1) `_custodyWired` — deployed lifecycle and NFT
    /// code plus the `LIFECYCLE` backpointer, else `WiringMismatch`; (2)
    /// `_memberShare` — frozen snapshot, eligible member and finalised
    /// funding; `basket` is the HISTORICAL basket at the cutoff; (3) live
    /// check via `ownerOf` ALONE, `NotLive` for a burned or never-minted id —
    /// `basketOf` is NOT cleared by burn (the lifecycle's own burn path
    /// depends on that persistence), so a `basketOf`-based liveness read
    /// would be a burn-spoof hole and burned rights route to the future
    /// late-claim leg instead; (4) `basketOf == basket`, else
    /// `BasketMismatch` — the live-vs-historical tripwire the switch seam
    /// needs, enforced even though `basketOf` currently has no setter; (5)
    /// not consumed, else `AlreadyConsumed`. Effects only: consumed flag,
    /// `_backing` credit, event — NO token call, NO release.
    function materialise(uint32 day, uint256 tokenId) external nonReentrant {
        _custodyWired();
        (address basket, uint256 units) = _memberShare(day, tokenId);
        try nft.ownerOf(tokenId) returns (address) {}
        catch {
            revert NotLive(tokenId);
        }
        if (nft.basketOf(tokenId) != basket) revert BasketMismatch(tokenId);
        if (_consumed[day][tokenId]) revert AlreadyConsumed(day, tokenId);
        _consumed[day][tokenId] = true;
        _backing[tokenId] += units;
        emit Materialised(day, tokenId, basket, units, _backing[tokenId]);
    }

    /// @notice Whether the funded `(day, tokenId)` share has been consumed.
    /// @dev True even for a consumed ZERO-unit share — consumption, not the
    /// amount, is the one-shot fact.
    function consumed(uint32 day, uint256 tokenId) external view returns (bool) {
        return _consumed[day][tokenId];
    }

    /// @notice Materialised units backing `tokenId`, denominated in that
    /// live NFT's single basket asset.
    /// @dev Outstanding custody liability. A 0 read does not distinguish
    /// "never consumed" from "consumed a zero-unit share" — pair with
    /// `consumed`. Never decreased in this slice: no release leg exists.
    function backingOf(uint256 tokenId) external view returns (uint256 units) {
        return _backing[tokenId];
    }

    /// @dev Operational wiring proof run before `materialise` only — the
    /// inherited `fund` and the shared views are unchanged and do not
    /// invoke this guard. The canonical lifecycle and the canonically bound
    /// NFT must both have deployed code, and the NFT's `LIFECYCLE` must
    /// point back at the same immutable `lifecycle` the ledger reads — the
    /// reciprocal binding that proves `nft` is the canonical deployed
    /// contract, not a look-alike at the predicted address. Any deviation —
    /// missing code, a non-conforming contract, or a wrong backpointer —
    /// reverts `WiringMismatch`. This is the operational replacement for
    /// the impossible constructor-time NFT code check; it asserts nothing
    /// about a burn hook, which does not exist yet.
    function _custodyWired() internal view {
        if (address(lifecycle).code.length == 0 || address(nft).code.length == 0) {
            revert WiringMismatch();
        }
        try nft.LIFECYCLE() returns (IHunterLifecycle bound) {
            if (address(bound) != address(lifecycle)) revert WiringMismatch();
        } catch {
            revert WiringMismatch();
        }
    }
}

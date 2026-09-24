// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BasketRegistry} from "./BasketRegistry.sol";
import {HunterNFT} from "./HunterNFT.sol";
import {HunterReserveVault, IHunterReserveLifecycle} from "./HunterReserveVault.sol";
import {WeightedHistory} from "./libraries/WeightedHistory.sol";

/// @notice Fixed reciprocal interface for the same-address backing custody:
/// the burn payout leg plus the switch-preparation reads and the
/// lifecycle-only measured conversion used by M2.2 basket switching.
interface IHunterBackingPayout {
    function nft() external view returns (address);
    function lifecycle() external view returns (address);
    function onBurnBacking(uint256 tokenId, address beneficiary) external;
    function backingOf(uint256 tokenId) external view returns (uint256);
    function ownerBackingOf(uint256 tokenId) external view returns (uint256);
    function consumed(uint32 day, uint256 tokenId) external view returns (bool);
    function isFunded(uint32 day, address basket) external view returns (bool);
    function materialise(uint32 day, uint256 tokenId) external;
    function convertForSwitch(
        uint256 tokenId,
        address converter,
        address newBasket,
        uint256 expectedInput,
        uint256 minOutput
    ) external returns (uint256 totalOut);
}

/// @title HunterLifecycle
/// @notice Fixed lifecycle candidate wiring the canonical HunterNFT and
/// HunterReserveVault hooks into WeightedHistory rarity/HUNTER accounting.
/// @dev REAL hook-connection slice, NOT a complete production lifecycle:
/// daily income routing and independently verified loan open/close remain
/// future work; the M2.2 basket-switch request/prepare/complete surface IS
/// implemented. Burn currently settles credited HUNTER and materialised
/// basket backing atomically. The late-share path pays only the fixed burn
/// beneficiary. There is no admin, module replacement or generic external
/// call in this lifecycle. The NFT stays sole authority on ownership and the
/// 5000 lifetime cap; the reserve stays sole authority on credited HUNTER.
/// No duplicate owner registry, no token-balance-derived reserve, and no
/// registry entryEnabled checks on existing transfers/deposits/burns —
/// disabling new basket entry must not strip old rights. Credit locking stays
/// HunterNFT-controlled by the future reviewed loan integration; sales and
/// escrow entry/release never pause eligibility — rights stay on the
/// tokenId. A pending basket switch DOES pause new-round eligibility from
/// the request checkpoint until it is cancelled, completed or invalidated by
/// a custody change; invalidation resumes the current basket from that
/// checkpoint so the NFT is never left permanently ineligible.
contract HunterLifecycle is IHunterReserveLifecycle, ReentrancyGuard {
    using WeightedHistory for WeightedHistory.Store;

    /// @dev One pending basket-switch request per token. `target` nonzero is
    /// the active sentinel. `barrierDay` is the request-day day number —
    /// eligible daily rights at and before it must be settled through
    /// `prepareSwitch` before completion. `authorizationNonce` snapshots the
    /// NFT authorization nonce at request time; a stale value at completion
    /// means the NFT changed hands or custody since the request.
    struct SwitchRequest {
        address target;
        uint32 barrierDay;
        uint256 authorizationNonce;
    }

    error InvalidConfiguration();
    error WiringMismatch();
    error UnauthorizedNFT();
    error UnauthorizedReserve();
    error ZeroAddress();
    error InvalidTier(uint8 tier);
    error InvalidBeneficiary();
    error OwnerMismatch(uint256 tokenId);
    error BasketMismatch(uint256 tokenId);
    error ReserveMismatch(uint256 tokenId);
    error NonzeroReserve(uint256 tokenId);
    error AlreadySettled(uint256 tokenId);
    error BeneficiaryAlreadySet(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId);
    error TokenNotOwnerHeld(uint256 tokenId);
    error InvalidSwitchTarget(address target);
    error BasketNotEnabled(address basket);
    error SwitchRequestActive(uint256 tokenId);
    error NoSwitchRequest(uint256 tokenId);
    error SwitchNotReady(uint256 tokenId);
    error InvalidDayBound();
    error StaleSwitchNonce(uint256 tokenId);
    error StaleAuthorization();
    error SwitchDeadlineExpired(uint256 deadline);
    error InvalidSwitchQuote();
    error ConverterNotUsable(address converter);
    error StaleSwitchState(uint256 tokenId);
    error DayOverflow();

    /// @dev Canonical modules; immutable at construction, revalidated against
    /// their reciprocal pointers by `_requireWired` on every operational call.
    address public immutable nft;
    address public immutable reserve;
    address public immutable backing;

    uint256 private constant EXPECTED_MAX_NFTS_EVER = 5_000;
    /// @dev `prepareSwitch` examines at most this many cursor days per call.
    uint256 private constant MAX_PREPARE_DAYS = 32;
    uint256 private constant SECONDS_PER_DAY = 86_400;

    WeightedHistory.Store internal _history;

    /// @notice Sole payout recipient fixed at burn; zero while the member is
    /// live. This is not an owner registry — ownership stays with the NFT.
    mapping(uint256 => address) public finalBeneficiary;

    /// @notice First daily round a minted token can join:
    /// `floor(mintTimestamp / 1 days) + 1`.
    mapping(uint256 => uint32) public firstEligibleDay;
    /// @notice Durable preparation cursor — the next day not yet checked for
    /// an unsettled eligible entitlement. Survives requests, cancels and
    /// completions; only ever advances while a request is pending.
    mapping(uint256 => uint32) public nextUncheckedDay;
    /// @notice Monotonic per-token switch nonce: incremented on every request,
    /// cancel, transfer/escrow/credit invalidation and successful completion.
    /// Completion compares the supplied nonce before consuming it.
    mapping(uint256 => uint256) public switchNonce;
    /// @dev Pending switch requests keyed by tokenId; `target != 0` is active.
    mapping(uint256 => SwitchRequest) private _switches;

    /// @dev Fixed rarity weight per proof tier 1..4; set once, no setter.
    uint64[4] private _rarityWeight;

    event LifecycleMint(uint256 indexed tokenId, address indexed owner, address indexed basket, uint64 rarity);
    event ReserveCheckpoint(uint256 indexed tokenId, uint256 credited);
    event LifecycleBurn(uint256 indexed tokenId, address indexed beneficiary, uint256 hunter);
    event SwitchRequested(
        uint256 indexed tokenId,
        address indexed fromBasket,
        address indexed toBasket,
        uint32 barrierDay,
        uint256 switchNonce
    );
    event SwitchCancelled(uint256 indexed tokenId, address indexed basket, uint256 switchNonce);
    event SwitchInvalidated(uint256 indexed tokenId, address indexed basket, uint256 switchNonce);
    event SwitchPreparationAdvanced(uint256 indexed tokenId, uint32 nextUncheckedDay, uint256 examined);
    event SwitchCompleted(
        uint256 indexed tokenId,
        address indexed fromBasket,
        address indexed toBasket,
        uint256 inputUnits,
        uint256 outputUnits,
        uint256 switchNonce
    );

    /// @param expectedNft Canonical HunterNFT address; may be a predicted,
    /// not-yet-deployed address (lifecycle -> ledger -> backing -> reserve -> NFT build order), so
    /// no code check here — `_requireWired` enforces it operationally.
    /// @param expectedReserve Canonical HunterReserveVault address; same rule.
    /// @param expectedBacking Predicted mandatory backing custody; checked operationally.
    /// @param tierWeights Positive rarity weight for each proof tier 1..4.
    /// Each must satisfy `weight * HunterNFT.MAX_NFTS_EVER <= type(uint64).max`
    /// so a full 5000-NFT cohort fits the uint64 rarity totals. This is
    /// representability only, not an economic cap — HUNTER stays an uncapped
    /// uint256 and no weight/rarity fraction is chosen here.
    constructor(address expectedNft, address expectedReserve, address expectedBacking, uint64[4] memory tierWeights) {
        if (
            expectedNft == address(0) || expectedReserve == address(0) || expectedNft == expectedReserve
                || expectedNft == address(this) || expectedReserve == address(this) || expectedBacking == address(0)
                || expectedBacking == address(this) || expectedBacking == expectedNft
                || expectedBacking == expectedReserve
        ) {
            revert InvalidConfiguration();
        }
        nft = expectedNft;
        reserve = expectedReserve;
        backing = expectedBacking;
        uint256 maxWeight = type(uint64).max / EXPECTED_MAX_NFTS_EVER;
        for (uint256 i; i < 4; ++i) {
            uint64 w = tierWeights[i];
            if (w == 0 || w > maxWeight) revert InvalidConfiguration();
            _rarityWeight[i] = w;
        }
    }

    /// @notice Rarity weight of proof `tier` (1..4); fixed at construction.
    function rarityWeight(uint8 tier) external view returns (uint64) {
        return _weightOf(tier);
    }

    /// @notice Canonical-NFT mint hook. Authenticates the actual minted state —
    /// owner, basket and birth-data proof tier all come from the NFT itself;
    /// no caller-supplied tier or HUNTER is ever accepted.
    function onMint(uint256 tokenId, address owner, address basket) external override nonReentrant {
        if (msg.sender != nft) revert UnauthorizedNFT();
        _requireWired();
        if (owner == address(0)) revert ZeroAddress();
        HunterNFT _nft = HunterNFT(nft);
        if (_nft.ownerOf(tokenId) != owner) revert OwnerMismatch(tokenId);
        if (_nft.basketOf(tokenId) != basket) revert BasketMismatch(tokenId);
        (,,, uint8 proofTier) = _nft.birthData(tokenId);
        uint64 rarity = _weightOf(proofTier);
        HunterReserveVault _reserve = HunterReserveVault(reserve);
        if (_reserve.reserveOf(tokenId) != 0) revert NonzeroReserve(tokenId);
        if (_reserve.settled(tokenId)) revert AlreadySettled(tokenId);
        _history.mint(tokenId, basket, rarity);
        uint256 today = _today();
        firstEligibleDay[tokenId] = uint32(today) + 1;
        nextUncheckedDay[tokenId] = uint32(today) + 1;
        emit LifecycleMint(tokenId, owner, basket, rarity);
    }

    /// @notice Canonical-reserve hook fired AFTER a credit lands. Reads the
    /// actual credited reserve and checkpoints it; the library enforces live
    /// monotonic credit, so no stored-vs-new equality check exists here (that
    /// would reject every top-up). No owner or amount argument is taken.
    function onReserveChanged(uint256 tokenId) external override nonReentrant {
        if (msg.sender != reserve) revert UnauthorizedReserve();
        _requireWired();
        WeightedHistory.Member memory m = _history.currentMember(tokenId);
        if (!m.alive) revert WeightedHistory.NotLive();
        HunterNFT _nft = HunterNFT(nft);
        _nft.ownerOf(tokenId); // canonical existence check; reverts when burned
        if (_nft.basketOf(tokenId) != m.basket) revert BasketMismatch(tokenId);
        HunterReserveVault _reserve = HunterReserveVault(reserve);
        if (_reserve.settled(tokenId)) revert AlreadySettled(tokenId);
        uint256 credited = _reserve.reserveOf(tokenId);
        _history.setHunter(tokenId, credited);
        emit ReserveCheckpoint(tokenId, credited);
    }

    /// @notice Canonical-NFT transfer hook. Validates consistency only — an
    /// ordinary sale or escrow entry/release mutates no history and pauses no
    /// eligibility: rights stay on the tokenId and the canonical NFT is
    /// trusted for the true `from` (no duplicate owner tracking here). With a
    /// pending switch the same callback is the invalidation path: the request
    /// is cleared, the CURRENT basket resumes from this checkpoint and one
    /// switch nonce is consumed. Idle transfers write no history.
    function onTransfer(uint256 tokenId, address from, address to) external override nonReentrant {
        if (msg.sender != nft) revert UnauthorizedNFT();
        _requireWired();
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        HunterNFT _nft = HunterNFT(nft);
        if (_nft.ownerOf(tokenId) != to) revert OwnerMismatch(tokenId);
        WeightedHistory.Member memory m = _history.currentMember(tokenId);
        if (!m.alive) revert WeightedHistory.NotLive();
        if (_nft.basketOf(tokenId) != m.basket) revert BasketMismatch(tokenId);
        HunterReserveVault _reserve = HunterReserveVault(reserve);
        if (_reserve.settled(tokenId)) revert AlreadySettled(tokenId);
        if (m.hunter != _reserve.reserveOf(tokenId)) revert ReserveMismatch(tokenId);
        _invalidateSwitch(tokenId, m);
    }

    /// @notice Canonical-NFT burn hook. The NFT calls after destruction, so no
    /// ownerOf check is possible or required. History is ended, the canonical
    /// hook beneficiary is fixed once, then the reserve settles atomically —
    /// any payout failure rolls back the NFT burn, history and beneficiary
    /// together. A live-token spoof reverts inside `settleBurn` with the same
    /// full rollback. No historical-day scan and no onReserveChanged occurs
    /// while settling.
    function onBurn(uint256 tokenId, address beneficiary) external override nonReentrant {
        if (msg.sender != nft) revert UnauthorizedNFT();
        _requireWired();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        WeightedHistory.Member memory m = _history.currentMember(tokenId);
        if (!m.alive) revert WeightedHistory.NotLive();
        HunterNFT _nft = HunterNFT(nft);
        if (_nft.basketOf(tokenId) != m.basket) revert BasketMismatch(tokenId);
        HunterReserveVault _reserve = HunterReserveVault(reserve);
        if (m.hunter != _reserve.reserveOf(tokenId)) revert ReserveMismatch(tokenId);
        if (_reserve.settled(tokenId)) revert AlreadySettled(tokenId);
        if (finalBeneficiary[tokenId] != address(0)) revert BeneficiaryAlreadySet(tokenId);
        // A pending switch request dies with the token — no resume: history is
        // ended in this same transaction, so no eligibility gap remains.
        delete _switches[tokenId];
        _history.burn(tokenId);
        finalBeneficiary[tokenId] = beneficiary;
        _reserve.settleBurn(tokenId, beneficiary);
        IHunterBackingPayout(backing).onBurnBacking(tokenId, beneficiary);
        emit LifecycleBurn(tokenId, beneficiary, m.hunter);
    }

    /// @notice Owner request to move this Hunter's basket to `target`: records
    /// the request-day barrier, stores the NFT authorization nonce, consumes
    /// one switch nonce and pauses eligibility from this checkpoint forward.
    /// Eligible daily rights at and before the barrier day stay attached and
    /// must settle through `prepareSwitch`; the pause cannot rewrite a cohort
    /// already frozen at an earlier cutoff. Returns the new switch nonce.
    /// @dev Requires the current owner, owner-held custody (no escrow, no
    /// credit lock), no active request, a live history member consistent with
    /// `basketOf`, and an enabled destination basket different from the
    /// current one. Reverts `SwitchRequestActive` when a request is pending.
    function requestSwitch(uint256 tokenId, address target) external nonReentrant returns (uint256) {
        _requireWired();
        return _requestSwitch(tokenId, target);
    }

    /// @notice Owner cancellation: keeps the old basket and backing, clears
    /// the request, consumes one switch nonce and resumes eligibility from
    /// this checkpoint — at the NEXT cutoff, with no catch-up for days paused
    /// in between. Always available while the request is pending, even when
    /// preparation is blocked by an unfunded day. Returns the new nonce.
    function cancelSwitch(uint256 tokenId) external nonReentrant returns (uint256) {
        _requireWired();
        HunterNFT _nft = HunterNFT(nft);
        if (_nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (_switches[tokenId].target == address(0)) revert NoSwitchRequest(tokenId);
        address current = _nft.basketOf(tokenId);
        delete _switches[tokenId];
        uint256 nonce = ++switchNonce[tokenId];
        _history.resume(tokenId, current);
        emit SwitchCancelled(tokenId, current, nonce);
        return nonce;
    }

    /// @notice Permissionless bounded preparation: examines at most
    /// `MAX_PREPARE_DAYS` (32) days per call — callers may pass any smaller
    /// positive bound and repeat. For each cursor day `d` the member snapshot
    /// is read strictly before the exact `d * 86_400` cutoff: not alive or not
    /// eligible days are skipped, already-`consumed` days advance, a day whose
    /// `(d, snapshot.basket)` group is not `isFunded` stops the scan WITHOUT
    /// advancing (funding gap), and any other day is settled through the
    /// canonical backing vault's `materialise` — whose errors bubble. Every
    /// visited or skipped day counts against `maxDays`. Readiness is
    /// `nextUncheckedDay > barrierDay`; an unresolved old entitlement blocks
    /// completion but never cancellation, transfer or burn.
    function prepareSwitch(uint256 tokenId, uint256 maxDays)
        external
        nonReentrant
        returns (uint256 examined, bool ready)
    {
        _requireWired();
        return _prepareSwitch(tokenId, maxDays);
    }

    /// @notice Owner-authorized atomic completion: settles all materialised
    /// round units and owner-deposited units of the old basket into the
    /// request's destination through an admitted converter, then rewrites
    /// `basketOf` via the dedicated lifecycle-only NFT write and resumes
    /// eligibility in the new basket from this checkpoint. Never unlocks
    /// HUNTER, never pays the wallet, never creates two live basket
    /// identities. Any failure reverts the whole transaction — the request,
    /// basket, backing, history and balances are left unchanged.
    /// @dev Requires a fresh `deadline`, the current owner, owner-held
    /// custody, the stored request authorization nonce still current on the
    /// NFT, the supplied `switchNonce_` still equal to the stored one, and
    /// readiness (`nextUncheckedDay > barrierDay`). The destination basket
    /// must still be entry-enabled; the origin basket need not be. With
    /// positive combined backing `expectedInput` must equal it, `minOutput`
    /// must be nonzero and `converter` must be usable; with zero combined
    /// backing `expectedInput` and `minOutput` must both be zero and no
    /// approval, token transfer or converter call occurs.
    function completeSwitch(
        uint256 tokenId,
        address converter,
        uint256 expectedInput,
        uint256 minOutput,
        uint256 deadline,
        uint256 switchNonce_
    ) external nonReentrant returns (uint256 totalOut) {
        _requireWired();
        return _completeSwitch(tokenId, converter, expectedInput, minOutput, deadline, switchNonce_);
    }

    /// @notice Composes request, bounded preparation and completion in one
    /// transaction. `switchNonce_` is the value current AFTER the embedded
    /// request consumes its increment — `switchNonce(tokenId) + 1` at call
    /// time. If preparation cannot reach readiness within `maxDays` (bounded
    /// by `MAX_PREPARE_DAYS`) or conversion fails, the whole transaction
    /// reverts and leaves no pause or request behind.
    function switchNow(
        uint256 tokenId,
        address target,
        address converter,
        uint256 expectedInput,
        uint256 minOutput,
        uint256 deadline,
        uint256 switchNonce_,
        uint256 maxDays
    ) external nonReentrant returns (uint256 totalOut) {
        _requireWired();
        _requestSwitch(tokenId, target);
        (, bool ready) = _prepareSwitch(tokenId, maxDays);
        if (!ready) revert SwitchNotReady(tokenId);
        return _completeSwitch(tokenId, converter, expectedInput, minOutput, deadline, switchNonce_);
    }

    /// @notice The pending switch request for `tokenId`; a zero `target` means
    /// none is active.
    function switchRequestOf(uint256 tokenId) external view returns (SwitchRequest memory) {
        return _switches[tokenId];
    }

    /// @notice Whether a pending request has finished preparation:
    /// `nextUncheckedDay` strictly past the request-day barrier.
    function switchReady(uint256 tokenId) external view returns (bool) {
        SwitchRequest storage req = _switches[tokenId];
        return req.target != address(0) && nextUncheckedDay[tokenId] > req.barrierDay;
    }

    /// @notice Member state strictly before `cutoff`; mirrors the store helper.
    function memberBefore(uint256 tokenId, uint256 cutoff) external view returns (WeightedHistory.Member memory) {
        return _history.memberBefore(tokenId, cutoff);
    }

    /// @notice Global eligible totals strictly before `cutoff`.
    function globalBefore(uint256 cutoff) external view returns (WeightedHistory.Totals memory) {
        return _history.globalBefore(cutoff);
    }

    /// @notice Eligible totals of `basket` strictly before `cutoff`.
    function basketBefore(address basket, uint256 cutoff) external view returns (WeightedHistory.Totals memory) {
        return _history.basketBefore(basket, cutoff);
    }

    /// @notice Latest member state; burned ids stay known.
    function currentMember(uint256 tokenId) external view returns (WeightedHistory.Member memory) {
        return _history.currentMember(tokenId);
    }

    /// @notice Latest global eligible totals; zero before any history.
    function currentGlobal() external view returns (WeightedHistory.Totals memory) {
        return _history.currentGlobal();
    }

    /// @notice Latest eligible totals of `basket`; zero for an unknown one.
    function currentBasket(address basket) external view returns (WeightedHistory.Totals memory) {
        return _history.currentBasket(basket);
    }

    /// @dev Both modules must be deployed and point back at each other and at
    /// this contract, and the NFT must carry the canonical 5000 lifetime cap —
    /// catches incompatible or miswired deployments on every operational call.
    /// The NFT constructor requires a predeployed lifecycle and the reserve
    /// constructor requires the final NFT address, so code presence can only
    /// be checked here, not at construction.
    function _requireWired() internal view {
        if (nft.code.length == 0 || reserve.code.length == 0 || backing.code.length == 0) revert WiringMismatch();
        HunterNFT _nft = HunterNFT(nft);
        HunterReserveVault _reserve = HunterReserveVault(reserve);
        if (
            address(_nft.LIFECYCLE()) != address(this) || address(_reserve.NFT()) != nft
                || address(_reserve.LIFECYCLE()) != address(this) || _nft.MAX_NFTS_EVER() != EXPECTED_MAX_NFTS_EVER
                || IHunterBackingPayout(backing).lifecycle() != address(this)
                || IHunterBackingPayout(backing).nft() != nft
        ) {
            revert WiringMismatch();
        }
    }

    /// @dev Weight lookup with the tier-1..4 range check in one place.
    function _weightOf(uint8 tier) private view returns (uint64) {
        if (tier < 1 || tier > 4) revert InvalidTier(tier);
        return _rarityWeight[tier - 1];
    }

    /// @dev The canonical basket/converter registry, read through the NFT's
    /// immutable pointer — no duplicate wiring to drift from the NFT's own.
    function _registry() private view returns (BasketRegistry) {
        return HunterNFT(nft).REGISTRY();
    }

    /// @dev Current day number; day values are uint32 across the round bases.
    function _today() private view returns (uint256 day) {
        day = block.timestamp / SECONDS_PER_DAY;
        if (day >= type(uint32).max) revert DayOverflow();
    }

    /// @dev Shared request body: current owner, owner-held custody, live
    /// member consistent with `basketOf`, enabled destination different from
    /// the current basket, and no active request. Stores the request-day
    /// barrier and the NFT authorization nonce, consumes one switch nonce and
    /// pauses eligibility from this checkpoint forward.
    function _requestSwitch(uint256 tokenId, address target) internal returns (uint256) {
        HunterNFT _nft = HunterNFT(nft);
        if (_nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (_nft.isEncumbered(tokenId)) revert TokenNotOwnerHeld(tokenId);
        WeightedHistory.Member memory m = _history.currentMember(tokenId);
        if (!m.alive) revert WeightedHistory.NotLive();
        address current = _nft.basketOf(tokenId);
        if (m.basket != current) revert BasketMismatch(tokenId);
        if (target == address(0) || target == current) revert InvalidSwitchTarget(target);
        if (!_registry().isEntryEnabled(target)) revert BasketNotEnabled(target);
        if (_switches[tokenId].target != address(0)) revert SwitchRequestActive(tokenId);
        uint256 today = _today();
        _switches[tokenId] = SwitchRequest({
            target: target, barrierDay: uint32(today), authorizationNonce: _nft.authorizationNonce(tokenId)
        });
        uint256 nonce = ++switchNonce[tokenId];
        _history.pause(tokenId);
        emit SwitchRequested(tokenId, current, target, uint32(today), nonce);
        return nonce;
    }

    /// @dev Shared preparation body: advances `nextUncheckedDay` toward and
    /// through the stored barrier day, examining at most `maxDays` days. The
    /// day snapshot is the exact `d * 86_400` strictly-before read — never
    /// `currentMember`, never `d` itself, never `(d + 1) * 86_400`.
    function _prepareSwitch(uint256 tokenId, uint256 maxDays) internal returns (uint256 examined, bool ready) {
        if (maxDays == 0 || maxDays > MAX_PREPARE_DAYS) revert InvalidDayBound();
        SwitchRequest storage req = _switches[tokenId];
        if (req.target == address(0)) revert NoSwitchRequest(tokenId);
        IHunterBackingPayout vault = IHunterBackingPayout(backing);
        uint32 day = nextUncheckedDay[tokenId];
        uint32 barrier = req.barrierDay;
        while (day <= barrier && examined < maxDays) {
            ++examined;
            WeightedHistory.Member memory snap = _history.memberBefore(tokenId, uint256(day) * SECONDS_PER_DAY);
            if (snap.alive && snap.eligible) {
                if (vault.consumed(day, tokenId)) {
                    ++day;
                } else if (!vault.isFunded(day, snap.basket)) {
                    break; // funding gap: stop without advancing the cursor
                } else {
                    vault.materialise(day, tokenId); // unexpected errors bubble
                    ++day;
                }
            } else {
                ++day; // not alive/eligible at that cutoff: nothing to settle
            }
        }
        nextUncheckedDay[tokenId] = day;
        ready = day > barrier;
        emit SwitchPreparationAdvanced(tokenId, day, examined);
    }

    /// @dev Shared completion body. Quotes bind exact combined input, nonzero
    /// minimum output (positive path only), a fresh deadline, the stored
    /// request authorization nonce and the supplied switch nonce. For zero
    /// combined backing `converter` is ignored entirely — no approval, token
    /// transfer or converter call occurs. Owner, authorization nonce and
    /// encumbrance are revalidated after the vault conversion leg and before
    /// the dedicated NFT basket write; any mismatch reverts the transaction.
    function _completeSwitch(
        uint256 tokenId,
        address converter,
        uint256 expectedInput,
        uint256 minOutput,
        uint256 deadline,
        uint256 switchNonce_
    ) internal returns (uint256 totalOut) {
        if (block.timestamp > deadline) revert SwitchDeadlineExpired(deadline);
        HunterNFT _nft = HunterNFT(nft);
        address owner = _nft.ownerOf(tokenId);
        if (owner != msg.sender) revert NotTokenOwner(tokenId);
        if (_nft.isEncumbered(tokenId)) revert TokenNotOwnerHeld(tokenId);
        SwitchRequest memory req = _switches[tokenId];
        if (req.target == address(0)) revert NoSwitchRequest(tokenId);
        if (switchNonce[tokenId] != switchNonce_) revert StaleSwitchNonce(tokenId);
        if (_nft.authorizationNonce(tokenId) != req.authorizationNonce) revert StaleAuthorization();
        if (nextUncheckedDay[tokenId] <= req.barrierDay) revert SwitchNotReady(tokenId);
        if (!_registry().isEntryEnabled(req.target)) revert BasketNotEnabled(req.target);
        address current;
        {
            WeightedHistory.Member memory m = _history.currentMember(tokenId);
            if (m.basket != _nft.basketOf(tokenId)) revert BasketMismatch(tokenId);
            current = m.basket;
        }

        IHunterBackingPayout vault = IHunterBackingPayout(backing);
        uint256 totalIn = vault.backingOf(tokenId);
        totalIn += vault.ownerBackingOf(tokenId);
        if (totalIn == 0) {
            if (expectedInput != 0 || minOutput != 0) revert InvalidSwitchQuote();
        } else {
            if (expectedInput != totalIn || minOutput == 0) revert InvalidSwitchQuote();
            if (!_registry().isConverterUsable(converter)) revert ConverterNotUsable(converter);
            totalOut = vault.convertForSwitch(tokenId, converter, req.target, expectedInput, minOutput);
        }
        if (
            _nft.ownerOf(tokenId) != owner || _nft.authorizationNonce(tokenId) != req.authorizationNonce
                || _nft.isEncumbered(tokenId)
        ) {
            revert StaleSwitchState(tokenId);
        }

        _nft.setConvertedBasket(tokenId, req.target, req.authorizationNonce);
        delete _switches[tokenId];
        uint256 nonce = ++switchNonce[tokenId];
        _history.resume(tokenId, req.target);
        emit SwitchCompleted(tokenId, current, req.target, totalIn, totalOut, nonce);
    }

    /// @dev Shared request invalidation for custody changes: clears the
    /// pending request, consumes one switch nonce and resumes the CURRENT
    /// basket from this checkpoint so the token is never left permanently
    /// ineligible. Idle transfers return without writing history. The future
    /// lifecycle credit-entry path MUST run this before `lockCredit`: a
    /// pending request never survives into a credit lock.
    function _invalidateSwitch(uint256 tokenId, WeightedHistory.Member memory m) internal {
        if (_switches[tokenId].target == address(0)) return;
        delete _switches[tokenId];
        uint256 nonce = ++switchNonce[tokenId];
        _history.resume(tokenId, m.basket);
        emit SwitchInvalidated(tokenId, m.basket, nonce);
    }
}

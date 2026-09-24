// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WeightedRoundLedger} from "./WeightedRoundLedger.sol";
import {WeightedHistory} from "./libraries/WeightedHistory.sol";
import {WeightedRewardMath} from "../../specs/hunter-bloom/src/WeightedRewardMath.sol";

/// @title WeightedRoundFunding
/// @notice INCOMPLETE ABSTRACT BASE — one-shot measured ERC20 pull funding of
/// ledger-frozen `(day, basket)` groups. NOT deployable and NOT
/// production-complete: custody recording only, with no exit surface.
/// @dev This contract is deliberately `abstract`: the custody it records can
/// only ever be completed by INHERITANCE. The future backing/materialisation
/// contract derives from this base and therefore holds the SAME token
/// balances and the SAME storage at the SAME address — no external module,
/// adapter or trusted spender can ever consume this custody, because this
/// base exposes no withdrawal, release, export, sweep, admin or generic-call
/// surface whatsoever. Any "separate module later withdraws" design is
/// impossible by construction, not merely unimplemented. A test-only derived
/// harness may instantiate this base for the suite; that is a test fixture,
/// not a launch artifact.
///
/// What this slice records: for each ledger-frozen `(day, basket)` group the
/// basket's ERC20 — basket identity IS the asset token address — is pulled
/// from the immutable `funder` exactly once, and the measured balance delta
/// is stored as `received`. Per-member received-unit shares are computed
/// lazily through the canonical `WeightedRewardMath` over the ledger's
/// frozen snapshots; nothing per-member is stored and no enumeration exists.
///
/// Per-asset accounting is CUMULATIVE ACROSS DAYS: within one day the group
/// key (the basket/asset address itself) is unique, but the same asset
/// legitimately keys a different `(day, basket)` group on different days, so
/// `totalReceived[asset]` sums every finalised receipt of that asset.
/// `_totalReleased[asset]` is the mirror cumulative counter that ONLY the
/// derived payout leg may advance — in the SAME transaction that moves units
/// out, after proving each release's destination and consumed-share
/// accounting. The outstanding liability is `totalReceived - totalReleased`,
/// and every solvency check here already uses that checked difference so
/// later valid releases never leave custody stranded behind a
/// forever-`totalReceived` bound. This slice establishes the baseline
/// `totalReleased == 0` and deliberately provides no mutator for it.
///
/// Deliberately absent here (not foreclosed — the derived same-address
/// contract adds them, or they stay open gates): any payout/withdrawal/
/// release function, consumed-bitmap, residue or dust distribution, income
/// authentication, price/provider/oracle checks, basket `entryEnabled`
/// gating (entry status governs new selections only — old frozen rights fund
/// regardless), member or basket enumeration, loans/switches handling, ETH
/// handling (force-fed ETH is inert and never token custody), deadlines and
/// every launch parameter. Zero-cohort rounds can never be funded because no
/// group can ever freeze for them in the ledger.
///
/// Zero-budget groups finalise `received == 0` against `requested == 0`
/// only. That folds the integer ledger's floor-dust case (`N(basket) > 0`
/// but `g.budget == 0`) into the undistributable case — an integer
/// REPRESENTATION tightening of this slice, not a claim of exact
/// rational/Fraction-model equivalence, and no terminal residue/carry policy
/// is decided by it. Nominal `g.budget` is a different denomination from
/// token units and is never compared to `requested`/`received` — doing so
/// would be fake price verification.
abstract contract WeightedRoundFunding is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev One record per `(day, basket)`, written once by `fund`, never
    /// amended. `finalised` is the existence sentinel: `received == 0` is a
    /// genuine finalized record (the zero-budget path), so funded-ness can
    /// never be derived from the amount.
    struct Funding {
        uint256 received; // measured token units actually delivered by the funder
        bool finalised; // one-shot existence flag — no top-up, amendment or re-funding
    }

    /// @dev Canonical round/group/member authority; fixed at construction.
    /// Every cohort/history read hits its frozen records — no duplicate
    /// ledger, receipt registry or weight recomputation lives here.
    WeightedRoundLedger public immutable ledger;
    /// @dev Sole caller of `fund`; fixed at construction. Deliberately a
    /// separate role from `ledger.recorder()`: the recorder asserts nominal
    /// income while the funder delivers measured token custody. Deployment
    /// MAY assign both to one operator key — not required to be distinct.
    address public immutable funder;

    /// @dev INTERNAL for future same-contract consumption: the derived
    /// materialisation contract reads these records at the same address.
    /// Never exposed as a mutable surface.
    mapping(uint32 => mapping(address => Funding)) internal _funding;
    /// @notice Cumulative measured receipts per asset across ALL days.
    /// @dev Strictly additive at finalisation; donations and later valid
    /// releases never decrease it. Pair with `totalReleased` for the
    /// outstanding liability — this counter alone is not the solvency bound.
    mapping(address => uint256) public totalReceived;
    /// @dev Cumulative per-asset units released by the derived payout leg.
    /// Always 0 in this base — there is intentionally NO mutator here. The
    /// derived contract must advance it atomically with each outbound
    /// transfer (same transaction, proven destination, accounted consumed
    /// shares) and must never let it exceed `totalReceived`.
    mapping(address => uint256) internal _totalReleased;

    /// @dev `receipt` echoes the day's recorded `ledger.round(day).receipt`;
    /// it is read before the token transfer, so no ledger call exists after
    /// the external token interaction.
    event GroupFunded(
        uint32 indexed day, address indexed basket, bytes32 indexed receipt, uint256 requested, uint256 received
    );

    error InvalidConfiguration();
    error UnauthorizedFunder();
    error InvalidAmount();
    error GroupAlreadyFunded(uint32 day, address basket);
    error FundingNotFinalized(uint32 day, address basket);
    error UnsupportedTokenReceipt();
    error Insolvency();

    /// @param ledger_ Deployed canonical `WeightedRoundLedger`; must already
    /// have code. @param funder_ Sole address allowed to call `fund`; an EOA
    /// or contract, deliberately distinct wiring from the ledger recorder.
    /// @dev Zero economic or numeric parameters: rarity fraction, cohort,
    /// budgets and denominators are all inherited already-frozen from the
    /// ledger — this base selects nothing.
    constructor(address ledger_, address funder_) {
        if (
            ledger_ == address(0) || funder_ == address(0) || ledger_ == funder_ || ledger_ == address(this)
                || funder_ == address(this) || ledger_.code.length == 0
        ) {
            revert InvalidConfiguration();
        }
        ledger = WeightedRoundLedger(ledger_);
        funder = funder_;
    }

    /// @notice Pulls the basket asset from `funder` exactly once for the
    /// ledger-frozen `(day, basket)` group and records the measured delta.
    /// @dev Ordering: caller auth, then `ledger.group` establishes the
    /// recorded round AND frozen group in one call, then the one-shot
    /// finalised check. The event's `receipt` is read before the transfer.
    ///
    /// `g.budget == 0` (undistributable numerator or floor-dust): finalises
    /// `received == 0` with `requested == 0` only — NO token call is made —
    /// so a zero-income round never traps member rights and a positive
    /// receipt can never be over-credited into an unsplittable group.
    ///
    /// Positive path: `requested != 0` is required (finalising a
    /// distributable entitlement to zero would silently burn it). Credit is
    /// the actual measured delta, supporting fee-on-transfer receipts
    /// `0 < received <= requested`; `received == 0`, `received > requested`
    /// and any balance DECREASE all revert `UnsupportedTokenReceipt`
    /// (explicit check, never an underflow panic). A reverting,
    /// false-returning or fully-fee-eaten transfer aborts atomically: the
    /// group stays unfunded and retryable. Funding is unrestricted in time
    /// and order across groups and days — no deadline, expiry or carry.
    ///
    /// Solvency is checked against the outstanding liability
    /// `totalReceived - totalReleased`, before the pull and again after the
    /// commit; a misreporting/rebasing token surfaces as `Insolvency`.
    function fund(uint32 day, address basket, uint256 requested) external nonReentrant {
        if (msg.sender != funder) revert UnauthorizedFunder();
        WeightedRoundLedger.Group memory g = ledger.group(day, basket);
        Funding storage f = _funding[day][basket];
        if (f.finalised) revert GroupAlreadyFunded(day, basket);
        bytes32 receipt = ledger.round(day).receipt;

        if (g.budget == 0) {
            if (requested != 0) revert InvalidAmount();
            f.finalised = true; // f.received stays 0
            emit GroupFunded(day, basket, receipt, 0, 0);
            return;
        }

        if (requested == 0) revert InvalidAmount();
        IERC20 token = IERC20(basket);
        uint256 balBefore = token.balanceOf(address(this));
        if (balBefore < _outstanding(basket)) revert Insolvency();

        token.safeTransferFrom(msg.sender, address(this), requested);

        uint256 balAfter = token.balanceOf(address(this));
        if (balAfter < balBefore) revert UnsupportedTokenReceipt();
        uint256 received = balAfter - balBefore;
        if (received == 0 || received > requested) revert UnsupportedTokenReceipt();

        f.received = received;
        f.finalised = true;
        totalReceived[basket] += received;
        emit GroupFunded(day, basket, receipt, requested, received);

        if (token.balanceOf(address(this)) < _outstanding(basket)) revert Insolvency();
    }

    /// @notice The finalised funding record of `(day, basket)` — never a
    /// defaulted zero record.
    /// @dev Validates through `ledger.group` first, so an unrecorded day
    /// reverts `RoundNotRecorded`, a zero basket `InvalidBasket` and an
    /// unfrozen group `GroupNotFrozen`; only then does a missing record
    /// revert `FundingNotFinalized`.
    function funding(uint32 day, address basket) external view returns (Funding memory f) {
        ledger.group(day, basket);
        f = _funding[day][basket];
        if (!f.finalised) revert FundingNotFinalized(day, basket);
    }

    /// @notice Non-reverting funded-ness probe for indexers/UI; does not
    /// touch the ledger.
    function isFunded(uint32 day, address basket) external view returns (bool) {
        return _funding[day][basket].finalised;
    }

    /// @notice The member's immutable received-unit share: `(basket,
    /// floor(received * N(nft) / N(basket)))` via the canonical
    /// `WeightedRewardMath.allocation` over frozen ledger snapshots.
    /// @dev A pure function of frozen ledger inputs plus the immutable
    /// `received` — constant for all time, including after the member's
    /// later burn, transfer or pause. `ledger.memberSnapshot` reverts for an
    /// unrecorded day, unknown id, ineligible-at-cutoff member or malformed
    /// snapshot; an unfinalised `(day, m.basket)` record reverts
    /// `FundingNotFinalized` (a finalised record implies a frozen group).
    /// This is the ONLY per-member input the derived materialisation leg
    /// needs; no enumeration, bitmap or stored per-NFT rows live here.
    function memberReceivedShare(uint32 day, uint256 tokenId) external view returns (address basket, uint256 units) {
        return _memberShare(day, tokenId);
    }

    /// @dev Shared body of `memberReceivedShare`, also the internal entry
    /// point for the derived materialisation leg — one copy of the snapshot
    /// validation, finalised-funding gate and `WeightedRewardMath`
    /// computation, with no external `this` round-trip.
    function _memberShare(uint32 day, uint256 tokenId) internal view returns (address basket, uint256 units) {
        WeightedHistory.Member memory m = ledger.memberSnapshot(day, tokenId);
        basket = m.basket;
        Funding storage f = _funding[day][basket];
        if (!f.finalised) revert FundingNotFinalized(day, basket);
        WeightedRoundLedger.Round memory r = ledger.round(day);
        WeightedRoundLedger.Group memory g = ledger.group(day, basket);
        units = WeightedRewardMath.allocation(
            f.received,
            WeightedRewardMath.RoundWeights({
                numerator: r.rarityNum, denominator: r.rarityDen, rarity: r.globalRarity, hunter: r.globalHunter
            }),
            WeightedRewardMath.Weights({rarity: g.rarity, hunter: g.hunter}),
            WeightedRewardMath.Weights({rarity: m.rarity, hunter: m.hunter})
        );
    }

    /// @notice Cumulative per-asset units released by the derived payout leg.
    /// @dev Always 0 in this base slice — no mutator exists here. The derived
    /// contract is the only future writer of `_totalReleased` and must
    /// advance it atomically inside each proven release.
    function totalReleased(address asset) external view returns (uint256) {
        return _totalReleased[asset];
    }

    /// @notice Live balance above the outstanding liability
    /// `totalReceived - totalReleased` — unsolicited direct transfers
    /// accumulate here and are never credited to any group, member or total
    /// (no donation overcredit). Reverts `Insolvency` rather than narrowing
    /// when the balance reads below the liability (e.g. rebasing shrinkage).
    /// @dev This slice gives the excess no exit; the derived same-address
    /// contract decides its terminal handling under the same solvency rule.
    function unaccountedBalance(address asset) external view returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 outstanding = _outstanding(asset);
        if (bal < outstanding) revert Insolvency();
        return bal - outstanding;
    }

    /// @dev Outstanding per-asset custody liability: measured receipts minus
    /// cumulative releases, with checked arithmetic. `released > received`
    /// is an impossible-by-construction accounting break in the derived
    /// contract and reverts `Insolvency` rather than underflowing into a
    /// panic. Available to the derived payout leg for its own solvency proof.
    function _outstanding(address asset) internal view virtual returns (uint256) {
        uint256 received_ = totalReceived[asset];
        uint256 released_ = _totalReleased[asset];
        if (released_ > received_) revert Insolvency();
        return received_ - released_;
    }
}

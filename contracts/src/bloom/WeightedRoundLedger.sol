// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {WeightedHistory} from "./libraries/WeightedHistory.sol";
import {WeightedRewardMath} from "../../specs/hunter-bloom/src/WeightedRewardMath.sol";

/// @title IWeightedRoundHistory
/// @notice Minimal strictly-before-cutoff read surface of the canonical
/// lifecycle (HunterLifecycle) consumed by WeightedRoundLedger.
/// @dev Signatures mirror the real lifecycle views exactly, including the
/// WeightedHistory struct types, so the immutable `lifecycle` address is the
/// production wiring — no fake history writer or alternate source exists.
/// Current-state views are deliberately absent: every cohort fact is derived
/// strictly before a round's frozen cutoff.
interface IWeightedRoundHistory {
    /// @dev Canonical NFT module address wired into the lifecycle.
    function nft() external view returns (address);

    /// @dev Canonical reserve module address wired into the lifecycle.
    function reserve() external view returns (address);

    /// @dev Member state strictly before `cutoff`; reverts for unknown ids.
    function memberBefore(uint256 tokenId, uint256 cutoff) external view returns (WeightedHistory.Member memory);

    /// @dev Global eligible totals strictly before `cutoff`.
    function globalBefore(uint256 cutoff) external view returns (WeightedHistory.Totals memory);

    /// @dev Eligible totals of `basket` strictly before `cutoff`.
    function basketBefore(address basket, uint256 cutoff) external view returns (WeightedHistory.Totals memory);
}

/// @title WeightedRoundLedger
/// @notice CANDIDATE daily-round recorder of NOMINAL weighted acquisition
/// budgets — not verified income, custody, backing proof or payment.
/// @dev Recording only: NO financial asset moves here — no token or ETH
/// transfer, no custody, no provider or oracle check, no setter, no
/// withdrawal, no admin, no pause, no amendment and no cancellation path.
/// Records and receipts are one-shot.
///
/// Every cohort fact is derived from the immutable `lifecycle` strictly-
/// before-cutoff views at `cutoff = day * 86_400` (00:00 UTC day boundary);
/// an event exactly at the cutoff belongs to the next day, and a recorded
/// round is unaffected by all later history. Snapshots that violate aggregate
/// consistency — a subgroup count above the frozen global count, member
/// weights above the frozen globals, nonzero totals behind a zero count —
/// are rejected as malformed, never silently narrowed to fit.
///
/// `recordRound` accepts a recorder-ASSERTED income figure and stores
/// `assertedIncome / 2` as the nominal backing budget: a recording convention
/// for the backing portion only. It does NOT implement the 50/25/15/10
/// settlement split, does not authenticate any real income (receipt
/// authenticity stays an off-chain accounting gate; only uniqueness is
/// enforced here), and pays nothing out.
///
/// NOT implemented here, by design: verified or measured income/custody,
/// per-basket receipt of units, per-NFT payable allocation, basket
/// enumeration, round finalization, unfunded-round timeout or carry
/// resolution, and any payout destination. `memberBudget` is a nominal global
/// budget view and `unallocated` is a provisional remainder bound — neither
/// is spendable value. The rarity fraction is constructor configuration
/// gated on the economics model; this module chooses no economics and makes
/// no production-readiness claim.
contract WeightedRoundLedger {
    /// @dev One record per day, written once by `recordRound`, never amended.
    /// `cutoff` doubles as the existence sentinel: 0 means unrecorded (day 0
    /// can never be recorded). All cohort fields are exact-width copies of the
    /// lifecycle strictly-before-cutoff snapshot — no narrowing casts. Every
    /// budget figure is a NOMINAL accounting quantity: nothing stored here is
    /// verified income, custody, backing or payable value.
    struct Round {
        uint64 cutoff; // day * 86_400 — the 00:00 UTC day boundary
        uint64 globalRarity; // frozen eligible global rarity total
        uint32 rarityNum; // rarity fraction numerator, copied per round for a self-contained record
        uint32 rarityDen; // rarity fraction denominator
        uint32 globalCount; // frozen eligible member count
        uint256 globalHunter; // frozen eligible global HUNTER total
        uint256 assertedIncome; // recorder-asserted distributable income (unverified)
        uint256 nominalBackingBudget; // assertedIncome / 2 — nominal backing portion budget only
        uint256 allocatedBudget; // monotone sum of frozen group budgets; <= nominalBackingBudget
        bytes32 receipt; // unique opaque distribution identifier
    }

    /// @dev One record per (day, basket), written once by `freezeGroup`.
    /// `count` doubles as the existence sentinel: a frozen group always has
    /// count > 0, so a nominal `budget` of exactly 0 is still a clearly
    /// recorded freeze — no separate flag is needed.
    struct Group {
        uint64 rarity; // frozen eligible rarity total of the basket
        uint32 count; // frozen eligible member count of the basket
        uint256 hunter; // frozen eligible HUNTER total of the basket
        uint256 budget; // floor(nominalBackingBudget * N(basket) / N(global)) — nominal only
    }

    /// @dev Canonical lifecycle supplying the strictly-before history views;
    /// fixed at construction, no setter.
    IWeightedRoundHistory public immutable lifecycle;
    /// @dev Sole address allowed to record rounds; fixed at construction.
    address public immutable recorder;
    /// @dev Immutable rarity fraction — deployment configuration awaiting the
    /// economics gate; validated `denominator > 0`, `numerator <= denominator`.
    /// `numerator == 0` (all-HUNTER) and `numerator == denominator`
    /// (all-rarity) are valid configurations, not special-cased.
    uint32 public immutable rarityNum;
    uint32 public immutable rarityDen;

    uint64 private constant SECONDS_PER_DAY = 86_400;

    /// @dev Private mappings with struct-return views: a public struct mapping
    /// getter would invite stack-too-deep under the unoptimized build.
    mapping(uint32 => Round) private _rounds;
    mapping(uint32 => mapping(address => Group)) private _groups;
    mapping(bytes32 => uint32) private _receiptDay;

    event RoundRecorded(
        uint32 indexed day,
        bytes32 indexed receipt,
        uint64 cutoff,
        uint64 globalRarity,
        uint32 globalCount,
        uint256 globalHunter,
        uint256 assertedIncome,
        uint256 nominalBackingBudget
    );
    event GroupFrozen(
        uint32 indexed day, address indexed basket, uint64 rarity, uint32 count, uint256 hunter, uint256 budget
    );

    error InvalidConfiguration();
    error UnauthorizedRecorder();
    error InvalidDay(); // day 0 is never a valid round
    error DayNotStarted(uint32 day); // day * 86_400 must satisfy <= block.timestamp
    error RoundAlreadyRecorded(uint32 day);
    error RoundNotRecorded(uint32 day);
    error InvalidReceipt(); // receipt must be nonzero
    error ReceiptAlreadyUsed(bytes32 receipt);
    error UnknownReceipt(bytes32 receipt);
    error InvalidBasket(); // basket address must be nonzero
    error EmptyGroup(uint32 day, address basket); // no eligible members at the cutoff
    error GroupAlreadyFrozen(uint32 day, address basket);
    error GroupNotFrozen(uint32 day, address basket);
    error MemberNotEligible(uint32 day, uint256 tokenId); // not alive or not eligible at the cutoff
    error InconsistentSnapshot(); // lifecycle snapshot violates aggregate consistency
    error AccountingInvariant(); // allocatedBudget would exceed nominalBackingBudget

    /// @param lifecycle_ Canonical lifecycle exposing the strictly-before
    /// history views; must already be deployed and report nonzero, distinct
    /// `nft()`/`reserve()` modules.
    /// @param recorder_ Sole address allowed to record rounds.
    /// @param rarityNum_ Rarity fraction numerator; `<= rarityDen_`.
    /// @param rarityDen_ Rarity fraction denominator; must be nonzero. The
    /// fraction is deployment configuration gated on the economics model —
    /// this module selects no default.
    constructor(address lifecycle_, address recorder_, uint32 rarityNum_, uint32 rarityDen_) {
        if (
            lifecycle_ == address(0) || recorder_ == address(0) || lifecycle_ == recorder_
                || lifecycle_ == address(this) || lifecycle_.code.length == 0
        ) {
            revert InvalidConfiguration();
        }
        if (rarityDen_ == 0 || rarityNum_ > rarityDen_) revert WeightedRewardMath.InvalidFraction();
        IWeightedRoundHistory history = IWeightedRoundHistory(lifecycle_);
        address nft_ = history.nft();
        address reserve_ = history.reserve();
        if (nft_ == address(0) || reserve_ == address(0) || nft_ == reserve_) revert InvalidConfiguration();
        lifecycle = history;
        recorder = recorder_;
        rarityNum = rarityNum_;
        rarityDen = rarityDen_;
    }

    /// @notice Records the nominal budget round for `day`: freezes the
    /// eligible cohort strictly before `day * 86_400` and stores
    /// `assertedIncome / 2` as the nominal backing budget.
    /// @dev `recorder` only; once per day, any time after the cutoff has been
    /// reached — the strictly-before lookup already isolates the day, so the
    /// day need not have ended. `assertedIncome` is RECORDER-ASSERTED: only
    /// receipt uniqueness is enforced on-chain (one nonzero receipt per
    /// round, never reused across days); binding it to real reconciled income
    /// remains an off-chain accounting gate. The /2 records the nominal
    /// backing portion only — this is not the 50/25/15/10 settlement and no
    /// value moves. A zero-cohort round is legal: it records
    /// `nominalBackingBudget` with `allocatedBudget == 0`, so the full budget
    /// stays recorded as unallocated.
    function recordRound(uint32 day, bytes32 receipt, uint256 assertedIncome) external {
        if (msg.sender != recorder) revert UnauthorizedRecorder();
        if (day == 0) revert InvalidDay();
        uint64 cutoff = uint64(day) * SECONDS_PER_DAY; // cannot overflow: day <= 2^32-1
        if (cutoff > block.timestamp) revert DayNotStarted(day);
        if (_rounds[day].cutoff != 0) revert RoundAlreadyRecorded(day);
        if (receipt == bytes32(0)) revert InvalidReceipt();
        if (_receiptDay[receipt] != 0) revert ReceiptAlreadyUsed(receipt);

        WeightedHistory.Totals memory g = lifecycle.globalBefore(cutoff);
        // An eligible member always contributes count 1 and rarity > 0, so a
        // zero count with nonzero totals — or the reverse — is malformed.
        if ((g.count == 0) != (g.rarity == 0) || (g.count == 0 && g.hunter != 0)) {
            revert InconsistentSnapshot();
        }

        uint256 nominalBackingBudget_ = assertedIncome / 2;
        Round storage r = _rounds[day];
        r.cutoff = cutoff;
        r.globalRarity = g.rarity;
        r.rarityNum = rarityNum;
        r.rarityDen = rarityDen;
        r.globalCount = g.count;
        r.globalHunter = g.hunter;
        r.assertedIncome = assertedIncome;
        r.nominalBackingBudget = nominalBackingBudget_;
        r.receipt = receipt; // r.allocatedBudget stays 0
        _receiptDay[receipt] = day;
        emit RoundRecorded(day, receipt, cutoff, g.rarity, g.count, g.hunter, assertedIncome, nominalBackingBudget_);
    }

    /// @notice Freezes one basket's eligible subgroup of a recorded round and
    /// adds its nominal budget `floor(nominalBackingBudget * N(basket) /
    /// N(global))` to `allocatedBudget`.
    /// @dev Permissionless and one-shot per (day, basket): the result is
    /// deterministic at the frozen cutoff, so late freezing gains the caller
    /// nothing. A memberless basket can never freeze — for a zero-cohort
    /// round no basket has count > 0. `budget` may be 0; the stored
    /// `count > 0` is the group's existence flag. Subgroup/global bounds on
    /// rarity and HUNTER are revalidated inside `WeightedRewardMath`; the
    /// count bound and the accounting bound are checked explicitly here.
    function freezeGroup(uint32 day, address basket) external {
        Round storage r = _requireRecorded(day);
        if (basket == address(0)) revert InvalidBasket();
        if (_groups[day][basket].count != 0) revert GroupAlreadyFrozen(day, basket);

        WeightedHistory.Totals memory b = lifecycle.basketBefore(basket, r.cutoff);
        if (b.count == 0) revert EmptyGroup(day, basket);
        if (b.count > r.globalCount) revert InconsistentSnapshot();

        WeightedRewardMath.Weights memory bw = WeightedRewardMath.Weights({rarity: b.rarity, hunter: b.hunter});
        uint256 budget = WeightedRewardMath.basketBudget(r.nominalBackingBudget, _roundWeights(r), bw);
        uint256 allocated_ = r.allocatedBudget + budget;
        if (allocated_ > r.nominalBackingBudget) revert AccountingInvariant();

        r.allocatedBudget = allocated_;
        Group storage g = _groups[day][basket];
        g.rarity = b.rarity;
        g.count = b.count;
        g.hunter = b.hunter;
        g.budget = budget;
        emit GroupFrozen(day, basket, b.rarity, b.count, b.hunter, budget);
    }

    /// @notice The validated frozen member record of `tokenId` in round `day`.
    /// @dev Reverts for an unrecorded day, a never-minted id
    /// (`WeightedHistory.UnknownId`), a member not alive or not eligible at
    /// the cutoff (minted at/after the cutoff, paused at the cutoff, or
    /// burned before it), or a snapshot inconsistent with the frozen globals.
    function memberSnapshot(uint32 day, uint256 tokenId) external view returns (WeightedHistory.Member memory) {
        return _eligibleMember(_requireRecorded(day), day, tokenId);
    }

    /// @notice NOMINAL global budget view of an eligible member: the exact
    /// `floor(nominalBackingBudget * N(nft) / N(global))` combined rarity/
    /// HUNTER share via `WeightedRewardMath.allocation`.
    /// @dev A share of the recorded nominal budget only — NOT an actual
    /// delivered basket allocation and not payable value; no custody,
    /// receipt-of-units or payment leg exists in this module. Reverts for the
    /// same cases as `memberSnapshot`.
    function memberBudget(uint32 day, uint256 tokenId) external view returns (uint256) {
        Round storage r = _requireRecorded(day);
        WeightedHistory.Member memory m = _eligibleMember(r, day, tokenId);
        WeightedRewardMath.Weights memory gw =
            WeightedRewardMath.Weights({rarity: r.globalRarity, hunter: r.globalHunter});
        WeightedRewardMath.Weights memory nw = WeightedRewardMath.Weights({rarity: m.rarity, hunter: m.hunter});
        return WeightedRewardMath.allocation(r.nominalBackingBudget, _roundWeights(r), gw, nw);
    }

    /// @notice `nominalBackingBudget - allocatedBudget` for a recorded round.
    /// @dev PROVISIONAL upper bound on the unbudgeted remainder — not
    /// spendable dust and not a finalized carry amount. Baskets are not
    /// enumerable on-chain, so the module never asserts that every membered
    /// basket has frozen; until they have, the remainder can still shrink via
    /// further freezes, and no terminal resolution is implied.
    function unallocated(uint32 day) external view returns (uint256) {
        Round storage r = _requireRecorded(day);
        return r.nominalBackingBudget - r.allocatedBudget;
    }

    /// @notice The full recorded round for `day`; reverts when unrecorded —
    /// never a defaulted zero record.
    function round(uint32 day) external view returns (Round memory) {
        return _requireRecorded(day);
    }

    /// @notice The frozen group record of `(day, basket)`; reverts for an
    /// unrecorded day, a zero basket, or a basket never frozen — never a
    /// defaulted zero record.
    function group(uint32 day, address basket) external view returns (Group memory) {
        _requireRecorded(day);
        if (basket == address(0)) revert InvalidBasket();
        Group storage g = _groups[day][basket];
        if (g.count == 0) revert GroupNotFrozen(day, basket);
        return g;
    }

    /// @notice The day a nonzero `receipt` was recorded against; reverts for
    /// an unused receipt — never a defaulted 0.
    function receiptDay(bytes32 receipt) external view returns (uint32 day) {
        day = _receiptDay[receipt];
        if (day == 0) revert UnknownReceipt(receipt);
    }

    /// @dev Recorded round or revert; `cutoff == 0` is the unrecorded
    /// sentinel since day 0 can never be recorded.
    function _requireRecorded(uint32 day) private view returns (Round storage r) {
        r = _rounds[day];
        if (r.cutoff == 0) revert RoundNotRecorded(day);
    }

    /// @dev Frozen round weights in the exact `WeightedRewardMath` shape —
    /// the immutable fraction plus the stored global totals, no recomputation.
    function _roundWeights(Round storage r) private view returns (WeightedRewardMath.RoundWeights memory) {
        return WeightedRewardMath.RoundWeights({
            numerator: r.rarityNum, denominator: r.rarityDen, rarity: r.globalRarity, hunter: r.globalHunter
        });
    }

    /// @dev Frozen member at the round cutoff, requiring `alive && eligible`
    /// and consistency with the frozen global totals — a member's rarity or
    /// HUNTER above the recorded globals, a zero basket, or zero rarity on an
    /// eligible member is a malformed snapshot, rejected rather than cast.
    function _eligibleMember(Round storage r, uint32 day, uint256 tokenId)
        private
        view
        returns (WeightedHistory.Member memory m)
    {
        m = lifecycle.memberBefore(tokenId, r.cutoff);
        if (!m.alive || !m.eligible) revert MemberNotEligible(day, tokenId);
        if (m.basket == address(0) || m.rarity == 0 || m.rarity > r.globalRarity || m.hunter > r.globalHunter) {
            revert InconsistentSnapshot();
        }
    }
}

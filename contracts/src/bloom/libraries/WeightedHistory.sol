// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

/// @title WeightedHistory
/// @notice EXPERIMENT: timestamped historical storage of per-member,
/// per-basket and global rarity/HUNTER/count totals. Pure storage helper —
/// no custody, income source, owner registry or launch values.
/// @dev Internal historical-storage component for the fixed future lifecycle,
/// NOT an externally callable controller: every function is `internal`, so
/// this helper adds no new external withdrawal or admin surface. ALL mutators
/// must only be reached by that lifecycle AFTER authenticating the real
/// NFT/reserve hooks — this library cannot and does not check that:
/// - The canonical NFT is the sole authority on token existence/ownership:
///   no duplicate owner registry and no mint cap here — the NFT enforces the
///   5000 lifetime supply and the caller authenticates each actual mint.
/// - `setHunter` amounts must be read from the fixed reserve's accounting,
///   never inferred from raw token balances.
/// - `pause`/`resume` may only run behind an approved pending basket switch;
///   `resume` does NOT prove conversion completed — the controller must
///   enforce the pending-switch / old-rights / funding barrier, including a
///   same-basket cancel, before calling. No bypass API. Ordinary sales and
///   both loan modes never pause; eligibility stays on.
/// - `burn` requires the caller to have enforced the canonical NFT's
///   external burn authorization. No beneficiary/payout data lives here.
/// Weighting ratios are out of scope: future WeightedRewardMath consumes sums.
library WeightedHistory {
    /// @dev One member NFT: accrual `basket` (retained while paused/burned),
    /// fixed `rarity`, reserve-credited `hunter` (monotone while live);
    /// `eligible` marks contribution to the totals traces.
    struct Member {
        address basket;
        uint64 rarity;
        uint256 hunter;
        bool alive;
        bool eligible;
    }

    /// @dev Aggregate rarity/HUNTER/member-count over eligible members.
    struct Totals {
        uint64 rarity;
        uint256 hunter;
        uint32 count;
    }

    /// @dev `value` valid from `timestamp` until the next trace entry.
    struct MemberCheckpoint {
        uint256 timestamp;
        Member value;
    }

    /// @dev `value` valid from `timestamp` until the next trace entry.
    struct TotalsCheckpoint {
        uint256 timestamp;
        Totals value;
    }

    /// @dev Per-id member traces plus global and per-basket totals traces.
    struct Store {
        mapping(uint256 => MemberCheckpoint[]) members;
        TotalsCheckpoint[] globalHistory;
        mapping(address => TotalsCheckpoint[]) basketHistory;
    }

    error InvalidId(); // id of zero is never a valid member
    error InvalidBasket(); // basket address must be nonzero
    error InvalidRarity(); // minted rarity must be positive
    error IdAlreadyKnown(); // mint on an id already seen (live, paused, burned)
    error UnknownId(); // operation on a never-minted id
    error NotLive(); // operation requires a live member
    error NotEligible(); // `pause` requires an eligible member
    error StillEligible(); // `resume` requires a paused member
    error HunterDecrease(); // credited below stored hunter; reserves never withdraw
    error FutureCutoff(); // cutoff must satisfy cutoff <= block.timestamp
    error BackwardTimestamp(); // decreasing key observed; traces stay sorted

    /// @notice Records a freshly minted member: alive + eligible, hunter 0.
    /// @dev Caller authenticates the actual NFT mint; the canonical NFT
    /// enforces the 5000 lifetime cap, so there is no separate cap here.
    function mint(Store storage self, uint256 id, address basket, uint64 rarity) internal {
        if (id == 0) revert InvalidId();
        if (basket == address(0)) revert InvalidBasket();
        if (rarity == 0) revert InvalidRarity();
        if (self.members[id].length != 0) revert IdAlreadyKnown();
        Member memory m = Member({basket: basket, rarity: rarity, hunter: 0, alive: true, eligible: true});
        _append(self.members[id], m);
        _apply(self, _zeroMember(), m);
    }

    /// @notice Raises the reserve-credited HUNTER of a live member.
    /// @dev `credited` MUST come from the fixed reserve's accounting — never
    /// inferred from raw balances. Live reserves never withdraw: a lower
    /// value reverts, an equal one is a no-op. Basket/rarity/eligibility are
    /// preserved; a paused member's trace moves without touching totals.
    function setHunter(Store storage self, uint256 id, uint256 credited) internal {
        Member memory m = _live(self, id);
        if (credited < m.hunter) revert HunterDecrease();
        if (credited == m.hunter) return;
        Member memory n =
            Member({basket: m.basket, rarity: m.rarity, hunter: m.hunter, alive: m.alive, eligible: m.eligible});
        n.hunter = credited;
        _append(self.members[id], n);
        _apply(self, m, n);
    }

    /// @notice Marks a live eligible member ineligible and removes its
    /// contribution from the basket and global totals; fields are retained.
    /// @dev Only an approved pending basket switch may pause — never sales
    /// or either loan mode.
    function pause(Store storage self, uint256 id) internal {
        Member memory m = _live(self, id);
        if (!m.eligible) revert NotEligible();
        Member memory n =
            Member({basket: m.basket, rarity: m.rarity, hunter: m.hunter, alive: m.alive, eligible: m.eligible});
        n.eligible = false;
        _append(self.members[id], n);
        _apply(self, m, n);
    }

    /// @notice Restores eligibility of a paused member into `basket` — which
    /// may differ from its previous basket — keeping rarity and hunter.
    /// @dev Does NOT prove a switch converted: the future controller must
    /// have enforced the pending-switch / old-rights / funding barrier,
    /// including a same-basket cancel, before calling.
    function resume(Store storage self, uint256 id, address basket) internal {
        Member memory m = _live(self, id);
        if (m.eligible) revert StillEligible();
        if (basket == address(0)) revert InvalidBasket();
        Member memory n =
            Member({basket: m.basket, rarity: m.rarity, hunter: m.hunter, alive: m.alive, eligible: m.eligible});
        n.basket = basket;
        n.eligible = true;
        _append(self.members[id], n);
        _apply(self, m, n);
    }

    /// @notice Ends a live member: removes any eligible contribution, then
    /// alive/eligible false and hunter 0. Historical basket/rarity retained.
    /// @dev Valid while paused too — the caller enforces external burn
    /// authorization. Burned ids stay known: no reuse, no resurrection.
    function burn(Store storage self, uint256 id) internal {
        Member memory m = _live(self, id);
        Member memory n = Member({basket: m.basket, rarity: m.rarity, hunter: 0, alive: false, eligible: false});
        _append(self.members[id], n);
        _apply(self, m, n);
    }

    /// @notice Member state strictly before `cutoff` (timestamp < cutoff).
    /// @dev A checkpoint at exactly `cutoff` is excluded, so a same-block
    /// mint/deposit/burn creates no membership at the cutoff. Before the
    /// first checkpoint — or for cutoff 0 — returns zero. Burned ids stay
    /// queryable; past lookups never substitute current state.
    function memberBefore(Store storage self, uint256 id, uint256 cutoff) internal view returns (Member memory m) {
        MemberCheckpoint[] storage trace = self.members[id];
        if (trace.length == 0) revert UnknownId();
        if (cutoff > block.timestamp) revert FutureCutoff();
        uint256 i = _lowerBound(trace, cutoff);
        if (i != 0) m = trace[i - 1].value;
    }

    /// @notice Global eligible totals strictly before `cutoff`.
    function globalBefore(Store storage self, uint256 cutoff) internal view returns (Totals memory) {
        if (cutoff > block.timestamp) revert FutureCutoff();
        return _before(self.globalHistory, cutoff);
    }

    /// @notice Eligible totals of `basket` strictly before `cutoff`; an
    /// unknown basket returns zero.
    function basketBefore(Store storage self, address basket, uint256 cutoff) internal view returns (Totals memory) {
        if (basket == address(0)) revert InvalidBasket();
        if (cutoff > block.timestamp) revert FutureCutoff();
        return _before(self.basketHistory[basket], cutoff);
    }

    /// @notice Latest member state; the id must be known (burned is known).
    function currentMember(Store storage self, uint256 id) internal view returns (Member memory) {
        MemberCheckpoint[] storage trace = self.members[id];
        if (trace.length == 0) revert UnknownId();
        return trace[trace.length - 1].value;
    }

    /// @notice Latest global eligible totals; zero before any history.
    function currentGlobal(Store storage self) internal view returns (Totals memory) {
        return _latest(self.globalHistory);
    }

    /// @notice Latest eligible totals of `basket`; zero for an unknown one.
    function currentBasket(Store storage self, address basket) internal view returns (Totals memory) {
        if (basket == address(0)) revert InvalidBasket();
        return _latest(self.basketHistory[basket]);
    }

    /// @dev Latest known member, reverting for unknown or burned ids.
    function _live(Store storage self, uint256 id) private view returns (Member memory) {
        MemberCheckpoint[] storage trace = self.members[id];
        if (trace.length == 0) revert UnknownId();
        Member memory m = trace[trace.length - 1].value;
        if (!m.alive) revert NotLive();
        return m;
    }

    /// @dev Moves a member's old contribution to its new one across the
    /// global trace and the at-most-two affected basket traces — never a
    /// scan over NFTs, days or baskets.
    function _apply(Store storage self, Member memory oldM, Member memory newM) private {
        Totals memory oldC = _contribution(oldM);
        Totals memory newC = _contribution(newM);
        _setTotals(self.globalHistory, _add(_sub(_latest(self.globalHistory), oldC), newC));
        if (oldM.basket == newM.basket) {
            // Same basket: subtract old and add new, then checkpoint once so
            // no intermediate state ever lands in the trace.
            Totals memory cur = _latest(self.basketHistory[oldM.basket]);
            _setBasket(self, oldM.basket, _add(_sub(cur, oldC), newC));
        } else {
            _setBasket(self, oldM.basket, _sub(_latest(self.basketHistory[oldM.basket]), oldC));
            _setBasket(self, newM.basket, _add(_latest(self.basketHistory[newM.basket]), newC));
        }
    }

    /// @dev Weights a member adds to totals: (rarity, hunter, 1) while
    /// eligible, zero otherwise.
    function _contribution(Member memory m) private pure returns (Totals memory t) {
        if (m.eligible) t = Totals({rarity: m.rarity, hunter: m.hunter, count: 1});
    }

    /// @dev Writes `t` to a basket trace; the zero address never owns a trace.
    function _setBasket(Store storage self, address basket, Totals memory t) private {
        if (basket == address(0)) return;
        _setTotals(self.basketHistory[basket], t);
    }

    /// @dev Appends `t` to `trace`, skipping unchanged totals so no-op
    /// updates leave no needless history.
    function _setTotals(TotalsCheckpoint[] storage trace, Totals memory t) private {
        if (_eq(_latest(trace), t)) return;
        _append(trace, t);
    }

    /// @dev Appends at the current EVM block timestamp — never a
    /// user-supplied key. A same-timestamp write replaces the trace's latest
    /// value; an observed backward key reverts, keeping traces sorted.
    function _append(MemberCheckpoint[] storage trace, Member memory v) private {
        uint256 n = trace.length;
        if (n == 0 || block.timestamp > trace[n - 1].timestamp) {
            trace.push(MemberCheckpoint({timestamp: block.timestamp, value: v}));
        } else if (block.timestamp == trace[n - 1].timestamp) {
            trace[n - 1].value = v;
        } else {
            revert BackwardTimestamp();
        }
    }

    /// @dev Totals-trace overload of `_append`; same timestamp rules.
    function _append(TotalsCheckpoint[] storage trace, Totals memory v) private {
        uint256 n = trace.length;
        if (n == 0 || block.timestamp > trace[n - 1].timestamp) {
            trace.push(TotalsCheckpoint({timestamp: block.timestamp, value: v}));
        } else if (block.timestamp == trace[n - 1].timestamp) {
            trace[n - 1].value = v;
        } else {
            revert BackwardTimestamp();
        }
    }

    /// @dev Value of the last entry strictly before `cutoff`, or zero —
    /// binary lower_bound for the first timestamp >= cutoff, then prior.
    function _before(TotalsCheckpoint[] storage trace, uint256 cutoff) private view returns (Totals memory t) {
        uint256 i = _lowerBound(trace, cutoff);
        if (i != 0) t = trace[i - 1].value;
    }

    /// @dev First index whose timestamp is >= `cutoff` in a sorted trace.
    function _lowerBound(MemberCheckpoint[] storage trace, uint256 cutoff) private view returns (uint256 lo) {
        uint256 hi = trace.length;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (trace[mid].timestamp < cutoff) lo = mid + 1;
            else hi = mid;
        }
    }

    /// @dev Totals-trace overload of `_lowerBound`.
    function _lowerBound(TotalsCheckpoint[] storage trace, uint256 cutoff) private view returns (uint256 lo) {
        uint256 hi = trace.length;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (trace[mid].timestamp < cutoff) lo = mid + 1;
            else hi = mid;
        }
    }

    /// @dev Latest totals in `trace`, or zero when empty.
    function _latest(TotalsCheckpoint[] storage trace) private view returns (Totals memory t) {
        uint256 n = trace.length;
        if (n != 0) t = trace[n - 1].value;
    }

    /// @dev Checked component-wise arithmetic: uint64 rarity, uint256 HUNTER
    /// and uint32 count overflow/underflow revert atomically — no
    /// saturation, truncation or economics cap.
    function _add(Totals memory a, Totals memory b) private pure returns (Totals memory) {
        return Totals({rarity: a.rarity + b.rarity, hunter: a.hunter + b.hunter, count: a.count + b.count});
    }

    /// @dev Checked subtraction; only ever removes a previously added share.
    function _sub(Totals memory a, Totals memory b) private pure returns (Totals memory) {
        return Totals({rarity: a.rarity - b.rarity, hunter: a.hunter - b.hunter, count: a.count - b.count});
    }

    function _eq(Totals memory a, Totals memory b) private pure returns (bool) {
        return a.rarity == b.rarity && a.hunter == b.hunter && a.count == b.count;
    }

    /// @dev Zero member used as the "before" side of a mint transition.
    function _zeroMember() private pure returns (Member memory) {}
}

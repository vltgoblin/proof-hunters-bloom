// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title WeightedRatioMath
/// @notice EXPERIMENT: exact floor(amount * N / D) for unsigned 512-bit N and D.
/// @dev Pure arithmetic primitive only. N = nHi * 2^256 + nLo, D = dHi * 2^256 + dLo.
/// This deliberately does NOT decide how a rarity/HUNTER numerator is composed, and
/// adds no deposit cap, ratio constants, custody, or configuration. Callers composing
/// N from several terms must preserve combined-floor semantics: evaluate one
/// floor(amount * N / D), never floor terms separately (their overflow bounds are a
/// separate concern of the composer).
library WeightedRatioMath {
    /// @dev Denominator must satisfy D > 0.
    error DenominatorZero();

    /// @dev Ratio must satisfy N <= D so the result never exceeds `amount`.
    error NumeratorExceedsDenominator();

    /// @notice Returns the exact floor(amount * N / D).
    /// @dev Exact over the whole valid input range: no intermediate overflow, no
    /// fixed-point approximation. Worst case is 256 binary-search iterations; the
    /// bound depends only on the 256-bit width of `amount`, never on NFT counts or
    /// history. Gas is therefore bounded but NOT claimed optimal — it must be
    /// measured on the target chain before any production use.
    function floorRatio(uint256 amount, uint256 nHi, uint256 nLo, uint256 dHi, uint256 dLo)
        internal
        pure
        returns (uint256)
    {
        // Validate even when amount == 0: a malformed ratio is always a caller bug.
        if (dHi == 0 && dLo == 0) revert DenominatorZero();
        if (nHi > dHi || (nHi == dHi && nLo > dLo)) {
            revert NumeratorExceedsDenominator();
        }

        if (amount == 0 || (nHi == 0 && nLo == 0)) return 0;
        if (nHi == dHi && nLo == dLo) return amount; // N == D

        // With dHi == 0, validation forces nHi == 0, so both fit in 256 bits and
        // mulDiv yields the exact floor in one division; result <= amount.
        if (dHi == 0) return Math.mulDiv(amount, nLo, dLo);

        // General case: D >= 2^256. Search max q in [0, amount] with q * D <= T,
        // where T = amount * N held exactly once as 768-bit limbs.
        (uint256 tTop, uint256 tMid, uint256 tLow) = _mul768(amount, nHi, nLo);

        // Invariant: lo * D <= T and the answer lies in [lo, hi]. Both hold at
        // start (0 * D == 0 <= T; answer <= amount because N <= D) and each step
        // preserves them, so termination returns floor(T / D).
        uint256 lo = 0;
        uint256 hi = amount;
        while (lo < hi) {
            // Range size hi - lo + 1 shrinks by half each step: <= 256 iterations.
            uint256 diff = hi - lo; // 1 <= diff <= 2^256 - 1, no underflow
            // Upper midpoint q = lo + ceil(diff / 2), so lo < q <= hi. Written this
            // way because (lo + hi + 1) / 2 overflows when amount == type(uint256).max.
            uint256 q = lo + (diff >> 1) + (diff & 1);
            (uint256 qTop, uint256 qMid, uint256 qLow) = _mul768(q, dHi, dLo);
            if (_leq768(qTop, qMid, qLow, tTop, tMid, tLow)) {
                lo = q; // q * D <= T: q feasible
            } else {
                hi = q - 1; // q * D > T: answer < q
            }
        }
        return lo;
    }

    /// @dev Exact 768-bit product s * (vHi * 2^256 + vLo), returned as limbs
    /// top * 2^512 + mid * 2^256 + low.
    function _mul768(uint256 s, uint256 vHi, uint256 vLo) private pure returns (uint256 top, uint256 mid, uint256 low) {
        (uint256 hiLo, uint256 loLo) = Math.mul512(s, vLo); // s*vLo = hiLo*2^256 + loLo
        (uint256 hiHi, uint256 loHi) = Math.mul512(s, vHi); // s*vHi = hiHi*2^256 + loHi
        unchecked {
            // hiLo + loHi <= (2^256 - 1) + (2^256 - 1) can legitimately wrap; the
            // wrap is the carry into the top limb, not an error, so recover it below.
            mid = hiLo + loHi;
        }
        uint256 carry = mid < hiLo ? 1 : 0;
        // Checked and cannot overflow: s * v < 2^256 * 2^512 = 2^768, so the true
        // top limb hiHi + carry is at most 2^256 - 1.
        top = hiHi + carry;
        low = loLo;
    }

    /// @dev Lexicographic (top, mid, low) comparison of 768-bit values: is a <= b?
    function _leq768(uint256 aTop, uint256 aMid, uint256 aLow, uint256 bTop, uint256 bMid, uint256 bLow)
        private
        pure
        returns (bool)
    {
        if (aTop != bTop) return aTop < bTop;
        if (aMid != bMid) return aMid < bMid;
        return aLow <= bLow;
    }
}

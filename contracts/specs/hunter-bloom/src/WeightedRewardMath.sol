// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeightedRatioMath} from "./WeightedRatioMath.sol";

/// @title WeightedRewardMath
/// @notice EXPERIMENT: folds a rarity/HUNTER weight pair into one 512-bit
/// numerator, then takes a single exact floor ratio of it. Pure arithmetic
/// helper only — no custody, income sourcing, or launch constants.
/// @dev Supplied snapshots are NOT authenticated: the caller must freeze and
/// pass coherent round/basket/NFT weights. Zero-cohort handling is deliberately
/// out of scope for this per-existing-group helper.
library WeightedRewardMath {
    /// @dev Round-frozen rarity fraction numerator/denominator plus the global
    /// historical rarity/HUNTER totals of that round.
    struct RoundWeights {
        uint32 numerator;
        uint32 denominator;
        uint64 rarity;
        uint256 hunter;
    }

    /// @dev Historical rarity/HUNTER sums for a basket or a member NFT.
    struct Weights {
        uint64 rarity;
        uint256 hunter;
    }

    /// @dev Rarity fraction must satisfy denominator > 0 and numerator <= denominator.
    error InvalidFraction();
    /// @dev Global rarity total must be positive.
    error GlobalRarityZero();
    /// @dev Basket must satisfy 0 < rarity <= global rarity and hunter <= global hunter.
    error InvalidBasketWeights();
    /// @dev Member must satisfy 0 < rarity <= basket rarity and hunter <= basket hunter.
    error InvalidNftWeights();
    /// @dev Combined basket numerator is zero while `received` is nonzero.
    error ZeroBasketBudget();

    /// @notice Returns the exact floor(received * N(nft) / N(basket)).
    /// @dev One combined floor over the whole 512-bit numerator — never
    /// separately floored rarity/HUNTER pieces. Configuration is validated even
    /// when received == 0.
    function allocation(uint256 received, RoundWeights memory round, Weights memory basket, Weights memory nft)
        internal
        pure
        returns (uint256)
    {
        _validateRound(round);
        _validateBasket(round, basket);
        if (nft.rarity == 0 || nft.rarity > basket.rarity || nft.hunter > basket.hunter) {
            revert InvalidNftWeights();
        }
        (uint256 dHi, uint256 dLo) = _combinedN(round, basket.rarity, basket.hunter);
        if (dHi == 0 && dLo == 0) {
            // Zero-budget basket: fraction numerator 0 and basket.hunter 0 while
            // global H > 0. Nothing to split a positive receipt against.
            if (received == 0) return 0;
            revert ZeroBasketBudget();
        }
        (uint256 nHi, uint256 nLo) = _combinedN(round, nft.rarity, nft.hunter);
        return WeightedRatioMath.floorRatio(received, nHi, nLo, dHi, dLo);
    }

    /// @notice Returns the exact floor(backingBudget * N(basket) / N(global)).
    /// @dev Integer spending-budget arithmetic only. The remainder left after
    /// summing per-basket floors is neither allocated nor discarded here; the
    /// future revenue/round controller must account for it explicitly.
    function basketBudget(uint256 backingBudget, RoundWeights memory round, Weights memory basket)
        internal
        pure
        returns (uint256)
    {
        _validateRound(round);
        _validateBasket(round, basket);
        (uint256 nHi, uint256 nLo) = _combinedN(round, basket.rarity, basket.hunter);
        (uint256 dHi, uint256 dLo) = _combinedN(round, round.rarity, round.hunter);
        return WeightedRatioMath.floorRatio(backingBudget, nHi, nLo, dHi, dLo);
    }

    /// @dev Combined numerator as a 512-bit value nHi * 2^256 + nLo. For global
    /// H > 0: N(x) = n * x.rarity * H + (d - n) * x.hunter * R. For H == 0:
    /// N(x) = x.rarity, the rarity-only fallback — the hunter <= global bound
    /// then already forces every local hunter amount to 0.
    /// Representation bounds, NOT a cap or bonus limit on HUNTER deposits: each
    /// coefficient (uint32 * uint64) fits in 96 bits, times a uint256 factor
    /// fits in 352 bits, and the sum fits in 353 bits — safely inside 512.
    /// Inputs are widened before multiplication; no HUNTER bits are truncated.
    function _combinedN(RoundWeights memory round, uint64 rarity, uint256 hunter)
        private
        pure
        returns (uint256 nHi, uint256 nLo)
    {
        if (round.hunter == 0) return (0, uint256(rarity));
        (uint256 aHi, uint256 aLo) = Math.mul512(uint256(round.numerator) * uint256(rarity), round.hunter);
        (uint256 bHi, uint256 bLo) =
            Math.mul512(uint256(round.denominator - round.numerator) * uint256(round.rarity), hunter);
        uint256 carry;
        (carry, nLo) = Math.add512(aLo, bLo);
        nHi = aHi + bHi + carry; // each term < 2^96, so this checked add cannot overflow
    }

    /// @dev Shared round invariants; callers validate before any subtraction or
    /// numerator composition.
    function _validateRound(RoundWeights memory round) private pure {
        if (round.denominator == 0 || round.numerator > round.denominator) {
            revert InvalidFraction();
        }
        if (round.rarity == 0) revert GlobalRarityZero();
    }

    /// @dev Basket must be a nonempty subgroup of the global totals. With the
    /// member bounds these are what force member numerator <= group numerator.
    function _validateBasket(RoundWeights memory round, Weights memory basket) private pure {
        if (basket.rarity == 0 || basket.rarity > round.rarity || basket.hunter > round.hunter) {
            revert InvalidBasketWeights();
        }
    }
}

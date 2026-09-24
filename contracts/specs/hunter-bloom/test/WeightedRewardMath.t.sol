// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedRewardMath} from "../src/WeightedRewardMath.sol";

/// @dev External wrapper around the internal library seam so tests can use
///      expectRevert and measure gas across a real call boundary. Struct
///      arguments arrive as calldata to keep stack pressure low.
contract RewardMathWrapper {
    function allocation(
        uint256 received,
        WeightedRewardMath.RoundWeights calldata round,
        WeightedRewardMath.Weights calldata basket,
        WeightedRewardMath.Weights calldata nft
    ) external pure returns (uint256) {
        return WeightedRewardMath.allocation(received, round, basket, nft);
    }

    function basketBudget(
        uint256 backingBudget,
        WeightedRewardMath.RoundWeights calldata round,
        WeightedRewardMath.Weights calldata basket
    ) external pure returns (uint256) {
        return WeightedRewardMath.basketBudget(backingBudget, round, basket);
    }
}

contract WeightedRewardMathTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    string internal constant VECTORS = "test/fixtures/weighted-reward-vectors.json";

    RewardMathWrapper internal w;

    /// @dev One fixture row: fraction a/d, global totals R/H, basket br/bh,
    ///      member nr/nh, plus the independently computed expectations.
    struct Vector {
        WeightedRewardMath.RoundWeights round;
        WeightedRewardMath.Weights basket;
        WeightedRewardMath.Weights nft;
        uint256 received;
        uint256 budget;
        uint256 expectedAllocation;
        uint256 expectedBudget;
    }

    function setUp() public {
        w = new RewardMathWrapper();
    }

    function _f(string memory json, string memory base, string memory key) internal returns (uint256) {
        return uint256(vm.parseJsonBytes32(json, string.concat(base, key)));
    }

    /// @dev Reads one vector field-by-field so the stack stays shallow.
    function _vector(string memory json, uint256 i) internal returns (Vector memory v) {
        string memory base = string.concat(".vectors[", vm.toString(i), "].");
        v.round.numerator = uint32(_f(json, base, "a"));
        v.round.denominator = uint32(_f(json, base, "d"));
        v.round.rarity = uint64(_f(json, base, "R"));
        v.round.hunter = _f(json, base, "H");
        v.basket.rarity = uint64(_f(json, base, "br"));
        v.basket.hunter = _f(json, base, "bh");
        v.nft.rarity = uint64(_f(json, base, "nr"));
        v.nft.hunter = _f(json, base, "nh");
        v.received = _f(json, base, "received");
        v.budget = _f(json, base, "budget");
        v.expectedAllocation = _f(json, base, "expectedAllocation");
        v.expectedBudget = _f(json, base, "expectedBudget");
    }

    /// Invalid round fraction, zero global rarity, out-of-subset basket and
    /// member weights all revert with the exact error — on both entry points
    /// and even when the amount being split is 0.
    function testRevertsOnInvalidConfig() public {
        WeightedRewardMath.RoundWeights memory okRound = WeightedRewardMath.RoundWeights(3, 10, 250, 4000);
        WeightedRewardMath.Weights memory okBasket = WeightedRewardMath.Weights(100, 500);
        WeightedRewardMath.Weights memory okNft = WeightedRewardMath.Weights(50, 250);

        vm.expectRevert(WeightedRewardMath.InvalidFraction.selector);
        w.allocation(1, WeightedRewardMath.RoundWeights(1, 0, 250, 4000), okBasket, okNft); // d == 0
        vm.expectRevert(WeightedRewardMath.InvalidFraction.selector);
        w.allocation(0, WeightedRewardMath.RoundWeights(8, 7, 250, 4000), okBasket, okNft); // a > d
        vm.expectRevert(WeightedRewardMath.GlobalRarityZero.selector);
        w.allocation(1, WeightedRewardMath.RoundWeights(3, 10, 0, 4000), okBasket, okNft); // R == 0
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.allocation(0, okRound, WeightedRewardMath.Weights(0, 500), okNft); // br == 0
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.allocation(1, okRound, WeightedRewardMath.Weights(251, 500), okNft); // br > R
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.allocation(1, okRound, WeightedRewardMath.Weights(100, 4001), okNft); // bh > H
        vm.expectRevert(WeightedRewardMath.InvalidNftWeights.selector);
        w.allocation(0, okRound, okBasket, WeightedRewardMath.Weights(0, 0)); // nr == 0
        vm.expectRevert(WeightedRewardMath.InvalidNftWeights.selector);
        w.allocation(1, okRound, okBasket, WeightedRewardMath.Weights(101, 0)); // nr > br
        vm.expectRevert(WeightedRewardMath.InvalidNftWeights.selector);
        w.allocation(1, okRound, okBasket, WeightedRewardMath.Weights(50, 501)); // nh > bh

        // basketBudget shares the same round/basket validation.
        vm.expectRevert(WeightedRewardMath.InvalidFraction.selector);
        w.basketBudget(0, WeightedRewardMath.RoundWeights(1, 0, 250, 4000), okBasket); // d == 0
        vm.expectRevert(WeightedRewardMath.InvalidFraction.selector);
        w.basketBudget(1, WeightedRewardMath.RoundWeights(8, 7, 250, 4000), okBasket); // a > d
        vm.expectRevert(WeightedRewardMath.GlobalRarityZero.selector);
        w.basketBudget(1, WeightedRewardMath.RoundWeights(3, 10, 0, 4000), okBasket); // R == 0
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.basketBudget(1, okRound, WeightedRewardMath.Weights(0, 500)); // br == 0
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.basketBudget(1, okRound, WeightedRewardMath.Weights(100, 4001)); // bh > H
    }

    /// H == 0 falls back to rarity-only numerators; a combined basket numerator
    /// of 0 returns 0 for a zero receipt but reverts ZeroBasketBudget for a
    /// positive one; a == d cancels the hunter term entirely.
    function testHunterFallbackAndZeroBudget() public {
        // Rarity-only fallback when global H == 0.
        WeightedRewardMath.RoundWeights memory noH = WeightedRewardMath.RoundWeights(3, 10, 250, 0);
        WeightedRewardMath.Weights memory basket = WeightedRewardMath.Weights(200, 0);
        WeightedRewardMath.Weights memory nft = WeightedRewardMath.Weights(100, 0);
        assertEq(w.allocation(1000, noH, basket, nft), 500); // 1000 * 100/200
        assertEq(w.basketBudget(1000, noH, basket), 800); // 1000 * 200/250

        // a == 0 and basket.hunter == 0 under H > 0 -> zero combined numerator.
        WeightedRewardMath.RoundWeights memory zeroA = WeightedRewardMath.RoundWeights(0, 10, 250, 4000);
        WeightedRewardMath.Weights memory empty = WeightedRewardMath.Weights(100, 0);
        WeightedRewardMath.Weights memory member = WeightedRewardMath.Weights(50, 0);
        assertEq(w.allocation(0, zeroA, empty, member), 0);
        vm.expectRevert(WeightedRewardMath.ZeroBasketBudget.selector);
        w.allocation(1, zeroA, empty, member);

        // Config is still validated when received == 0.
        vm.expectRevert(WeightedRewardMath.InvalidNftWeights.selector);
        w.allocation(0, zeroA, empty, WeightedRewardMath.Weights(0, 0));

        // a == d -> N(x) = d * x.rarity * H: the hunter term cancels, so the
        // result matches the rarity-only fallback regardless of H or nh.
        WeightedRewardMath.RoundWeights memory full = WeightedRewardMath.RoundWeights(7, 7, 250, 4000);
        uint256 withH =
            w.allocation(1000, full, WeightedRewardMath.Weights(200, 3000), WeightedRewardMath.Weights(100, 3000));
        uint256 noHunter = w.allocation(1000, WeightedRewardMath.RoundWeights(7, 7, 250, 0), basket, nft);
        assertEq(withH, 500);
        assertEq(withH, noHunter);

        // Positive local hunter is invalid while global H == 0.
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.allocation(1, noH, WeightedRewardMath.Weights(100, 1), member);
        vm.expectRevert(WeightedRewardMath.InvalidNftWeights.selector);
        w.allocation(1, noH, basket, WeightedRewardMath.Weights(50, 1));
    }

    /// All 100 supplied vectors, produced by an independent Python rational
    /// oracle: compare both entry points against the literal expected values.
    function testFixtureVectors() public {
        string memory json = vm.readFile(VECTORS);
        assertEq(vm.parseJsonUint(json, ".count"), 100);
        for (uint256 i = 0; i < 100; i++) {
            Vector memory v = _vector(json, i);
            uint256 alloc = w.allocation(v.received, v.round, v.basket, v.nft);
            uint256 budget = w.basketBudget(v.budget, v.round, v.basket);
            assertEq(alloc, v.expectedAllocation);
            assertEq(budget, v.expectedBudget);
            assertLe(alloc, v.received);
            assertLe(budget, v.budget);
        }
    }

    /// Two single-NFT baskets over one round: per-basket budget floors leave a
    /// retained remainder, while same-basket member allocations split the
    /// grouped receipt exactly. At fraction 0 the hunter term stands alone —
    /// equal h gives equal allocations even when rarity differs, so H is a
    /// weight of its own, not a rarity multiplier.
    function testTwoBasketConservation() public {
        WeightedRewardMath.RoundWeights memory round = WeightedRewardMath.RoundWeights(7, 10, 250, 4000);
        WeightedRewardMath.Weights memory nftA = WeightedRewardMath.Weights(100, 1000);
        WeightedRewardMath.Weights memory nftB = WeightedRewardMath.Weights(150, 3000);
        WeightedRewardMath.Weights memory all = WeightedRewardMath.Weights(250, 4000);

        uint256 budgetA = w.basketBudget(500, round, nftA);
        uint256 budgetB = w.basketBudget(500, round, nftB);
        assertEq(budgetA, 177);
        assertEq(budgetB, 322);
        assertEq(500 - budgetA - budgetB, 1); // retained remainder
        assertLe(budgetA + budgetB, 500);

        uint256 allocA = w.allocation(1000, round, all, nftA);
        uint256 allocB = w.allocation(1000, round, all, nftB);
        assertEq(allocA, 355);
        assertEq(allocB, 645);
        assertLe(allocA + allocB, 1000); // sum bounded by actual units

        // a == 0 -> N(x) = d * R * x.hunter: equal hunter, differing rarity.
        WeightedRewardMath.RoundWeights memory round0 = WeightedRewardMath.RoundWeights(0, 10, 250, 4000);
        WeightedRewardMath.Weights memory group = WeightedRewardMath.Weights(250, 1000);
        uint256 eqA = w.allocation(1000, round0, group, WeightedRewardMath.Weights(100, 500));
        uint256 eqB = w.allocation(1000, round0, group, WeightedRewardMath.Weights(150, 500));
        assertEq(eqA, 500);
        assertEq(eqA, eqB);
        assertLe(eqA + eqB, 1000);
    }

    /// Small-input fuzz: the oracle is the direct rational share
    /// received * (a*r*H + (d-a)*R*h) / (d*R*H) computed natively over
    /// uint16-bounded weights and a uint64 receipt, so every product stays
    /// far below 256 bits. Denominator is the all-NFT group (r in 1..R,
    /// h <= H), which keeps the combined numerator nonzero and the config
    /// valid; H == 0 uses the rarity-only fallback.
    function testFuzzDirectWeightedFormula(
        uint16 a16,
        uint16 d16,
        uint16 R16,
        uint16 H16,
        uint16 r16,
        uint16 h16,
        uint64 received
    ) public {
        uint256 d = bound(d16, 1, type(uint16).max);
        uint256 a = bound(a16, 0, d);
        uint256 R = bound(R16, 1, type(uint16).max);
        uint256 H = uint256(H16);
        uint256 r = bound(r16, 1, R);
        uint256 h = bound(h16, 0, H);

        WeightedRewardMath.RoundWeights memory round =
            WeightedRewardMath.RoundWeights(uint32(a), uint32(d), uint64(R), H);
        WeightedRewardMath.Weights memory group = WeightedRewardMath.Weights(uint64(R), H);
        WeightedRewardMath.Weights memory nft = WeightedRewardMath.Weights(uint64(r), h);

        uint256 expected =
            H == 0 ? uint256(received) * r / R : uint256(received) * (a * r * H + (d - a) * R * h) / (d * R * H);
        uint256 got = w.allocation(received, round, group, nft);
        assertEq(got, expected);
        assertLe(got, received);
    }

    /// Call-region gas sample on fixture vector 5 (index): near-max a/d, R,
    /// H and received == MAX. The call is warmed once before measuring; the
    /// logged cost is a local observation, not a promised bound.
    function testAllocationGasSample() public {
        string memory json = vm.readFile(VECTORS);
        Vector memory v = _vector(json, 5);
        assertEq(v.received, MAX);
        uint256 got = w.allocation(v.received, v.round, v.basket, v.nft); // warm
        assertEq(got, v.expectedAllocation);
        uint256 gasBefore = gasleft();
        got = w.allocation(v.received, v.round, v.basket, v.nft);
        emit log_named_uint("allocation near-max call gas", gasBefore - gasleft());
        assertEq(got, v.expectedAllocation);
    }
}

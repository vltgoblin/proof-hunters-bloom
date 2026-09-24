// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedRewardMath} from "../specs/hunter-bloom/src/WeightedRewardMath.sol";

contract RewardMathHarness {
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

/// @notice Root-campaign tests for weighted combined-floor math: invalid
/// fractions/weights, zero-budget baskets, and 512-bit numerators.
contract WeightedRewardMathCoverageTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    RewardMathHarness internal w;

    function setUp() public {
        w = new RewardMathHarness();
    }

    function testInvalidFractionAndWeightsRevertEvenAtZeroAmount() public {
        WeightedRewardMath.RoundWeights memory okRound = WeightedRewardMath.RoundWeights(3, 10, 250, 4000);
        WeightedRewardMath.Weights memory okBasket = WeightedRewardMath.Weights(100, 500);
        WeightedRewardMath.Weights memory okNft = WeightedRewardMath.Weights(50, 250);

        vm.expectRevert(WeightedRewardMath.InvalidFraction.selector);
        w.allocation(0, WeightedRewardMath.RoundWeights(1, 0, 250, 4000), okBasket, okNft);
        vm.expectRevert(WeightedRewardMath.InvalidFraction.selector);
        w.allocation(1, WeightedRewardMath.RoundWeights(11, 10, 250, 4000), okBasket, okNft);
        vm.expectRevert(WeightedRewardMath.GlobalRarityZero.selector);
        w.allocation(0, WeightedRewardMath.RoundWeights(3, 10, 0, 4000), okBasket, okNft);
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.allocation(0, okRound, WeightedRewardMath.Weights(0, 500), okNft);
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.allocation(1, okRound, WeightedRewardMath.Weights(251, 500), okNft);
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.allocation(1, okRound, WeightedRewardMath.Weights(100, 4001), okNft);
        vm.expectRevert(WeightedRewardMath.InvalidNftWeights.selector);
        w.allocation(0, okRound, okBasket, WeightedRewardMath.Weights(0, 0));
        vm.expectRevert(WeightedRewardMath.InvalidNftWeights.selector);
        w.allocation(1, okRound, okBasket, WeightedRewardMath.Weights(101, 0));
        vm.expectRevert(WeightedRewardMath.InvalidNftWeights.selector);
        w.allocation(1, okRound, okBasket, WeightedRewardMath.Weights(50, 501));

        vm.expectRevert(WeightedRewardMath.InvalidFraction.selector);
        w.basketBudget(0, WeightedRewardMath.RoundWeights(1, 0, 250, 4000), okBasket);
        vm.expectRevert(WeightedRewardMath.GlobalRarityZero.selector);
        w.basketBudget(1, WeightedRewardMath.RoundWeights(3, 10, 0, 4000), okBasket);
        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.basketBudget(1, okRound, WeightedRewardMath.Weights(0, 0));
    }

    function testZeroBudgetHunterFallbackAndFullRarityFraction() public {
        WeightedRewardMath.RoundWeights memory noH = WeightedRewardMath.RoundWeights(3, 10, 250, 0);
        WeightedRewardMath.Weights memory basket = WeightedRewardMath.Weights(200, 0);
        WeightedRewardMath.Weights memory nft = WeightedRewardMath.Weights(100, 0);
        assertEq(w.allocation(1000, noH, basket, nft), 500);
        assertEq(w.basketBudget(1000, noH, basket), 800);

        WeightedRewardMath.RoundWeights memory zeroA = WeightedRewardMath.RoundWeights(0, 10, 250, 4000);
        WeightedRewardMath.Weights memory empty = WeightedRewardMath.Weights(100, 0);
        WeightedRewardMath.Weights memory member = WeightedRewardMath.Weights(50, 0);
        assertEq(w.allocation(0, zeroA, empty, member), 0);
        vm.expectRevert(WeightedRewardMath.ZeroBasketBudget.selector);
        w.allocation(1, zeroA, empty, member);

        WeightedRewardMath.RoundWeights memory full = WeightedRewardMath.RoundWeights(7, 7, 250, 4000);
        uint256 withH =
            w.allocation(1000, full, WeightedRewardMath.Weights(200, 3000), WeightedRewardMath.Weights(100, 3000));
        assertEq(withH, 500);

        vm.expectRevert(WeightedRewardMath.InvalidBasketWeights.selector);
        w.allocation(1, noH, WeightedRewardMath.Weights(100, 1), member);
        vm.expectRevert(WeightedRewardMath.InvalidNftWeights.selector);
        w.allocation(1, noH, basket, WeightedRewardMath.Weights(50, 1));
    }

    function testWide512BitNumeratorAndAdd512Carry() public view {
        // a=1, d=2, R=1, H=MAX: N(x) = x.rarity*MAX + x.hunter.
        // Basket with hunter 0 => N = MAX; global N = 2*MAX = 2^257-2 (dHi != 0).
        WeightedRewardMath.RoundWeights memory round = WeightedRewardMath.RoundWeights(1, 2, 1, MAX);
        WeightedRewardMath.Weights memory globalW = WeightedRewardMath.Weights(1, MAX);
        WeightedRewardMath.Weights memory rarityOnly = WeightedRewardMath.Weights(1, 0);
        assertEq(w.basketBudget(1000, round, rarityOnly), 500);
        assertEq(w.allocation(1000, round, globalW, rarityOnly), 500);
        // N(basket)==N(global) on the wide limbs returns the full amount.
        assertEq(w.basketBudget(777, round, globalW), 777);

        // Max uint32/uint64/uint256 coefficients: N has 352 bits, still N==D.
        WeightedRewardMath.RoundWeights memory maxRound =
            WeightedRewardMath.RoundWeights(type(uint32).max, type(uint32).max, type(uint64).max, MAX);
        WeightedRewardMath.Weights memory maxW = WeightedRewardMath.Weights(type(uint64).max, MAX);
        assertEq(w.basketBudget(1, maxRound, maxW), 1);
        assertEq(w.allocation(MAX, maxRound, maxW, maxW), MAX);
    }

    function testTwoBasketRemainderIsRetainedNotAllocated() public view {
        WeightedRewardMath.RoundWeights memory round = WeightedRewardMath.RoundWeights(7, 10, 250, 4000);
        uint256 budgetA = w.basketBudget(500, round, WeightedRewardMath.Weights(100, 1000));
        uint256 budgetB = w.basketBudget(500, round, WeightedRewardMath.Weights(150, 3000));
        assertEq(budgetA, 177);
        assertEq(budgetB, 322);
        assertEq(500 - budgetA - budgetB, 1);
    }

    function testFuzzDirectWeightedFormula(
        uint16 a16,
        uint16 d16,
        uint16 r16,
        uint16 h16,
        uint16 R16,
        uint16 H16,
        uint64 received
    ) public view {
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
}

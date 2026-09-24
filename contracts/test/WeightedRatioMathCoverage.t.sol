// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedRatioMath} from "../specs/hunter-bloom/src/WeightedRatioMath.sol";

/// @dev External wrapper so expectRevert observes the library call.
contract FloorRatioHarness {
    function floorRatio(uint256 amount, uint256 nHi, uint256 nLo, uint256 dHi, uint256 dLo)
        external
        pure
        returns (uint256)
    {
        return WeightedRatioMath.floorRatio(amount, nHi, nLo, dHi, dLo);
    }
}

/// @notice Root-campaign behavior tests for the 512-bit ratio primitive.
/// Spec-local tests remain the prototype suite; this file exists so the
/// first-party coverage denominator actually executes the wide path.
contract WeightedRatioMathCoverageTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    FloorRatioHarness internal w;

    function setUp() public {
        w = new FloorRatioHarness();
    }

    function testZeroEqualityAndInvalidRatios() public {
        vm.expectRevert(WeightedRatioMath.DenominatorZero.selector);
        w.floorRatio(1, 0, 1, 0, 0);
        vm.expectRevert(WeightedRatioMath.DenominatorZero.selector);
        w.floorRatio(0, 0, 0, 0, 0);
        vm.expectRevert(WeightedRatioMath.NumeratorExceedsDenominator.selector);
        w.floorRatio(9, 1, 8, 1, 7);
        vm.expectRevert(WeightedRatioMath.NumeratorExceedsDenominator.selector);
        w.floorRatio(9, 2, 0, 1, MAX);
        vm.expectRevert(WeightedRatioMath.NumeratorExceedsDenominator.selector);
        w.floorRatio(0, 1, 0, 0, MAX);

        assertEq(w.floorRatio(0, 0, 5, 0, 7), 0);
        assertEq(w.floorRatio(123, 0, 0, 0, 7), 0);
        assertEq(w.floorRatio(77, 0, 9, 0, 9), 77);
        assertEq(w.floorRatio(55, MAX, MAX, MAX, MAX), 55);
        assertEq(w.floorRatio(1000, 0, MAX, 0, MAX), 1000);
    }

    function testNarrowMulDivMatchesNativeQuotient() public view {
        assertEq(w.floorRatio(1000, 0, 1, 0, 3), 333);
        assertEq(w.floorRatio(MAX, 0, 1, 0, 2), MAX / 2);
        assertEq(w.floorRatio(7, 0, 0, 0, 1), 0);
    }

    function testWideHalfAndExactDivision() public view {
        // D = 2N with N = 2^256: floor(amount / 2), including odd amounts.
        assertEq(w.floorRatio(1e18, 1, 0, 2, 0), 5e17);
        assertEq(w.floorRatio(11, 1, 0, 2, 0), 5);
        // Exact: 10 * 2^256 / 2^257 == 5, so the 768-bit compare hits equality.
        assertEq(w.floorRatio(10, 1, 0, 2, 0), 5);
        // Low-limb-only difference with equal high limbs: 100*(2^256+5)/(2^256+6).
        assertEq(w.floorRatio(100, 1, 5, 1, 6), 99);
        // Mid-limb difference: 3 * 2^256 / (2^256 + 2^128) == 2.
        assertEq(w.floorRatio(3, 1, 0, 1, uint256(1) << 128), 2);
        assertEq(w.floorRatio(7, MAX, 0, MAX, 1), 6);
        assertEq(w.floorRatio(MAX, MAX, MAX - 1, MAX, MAX), MAX - 1);
    }

    function testWideMul768CarryIntoTopLimb() public view {
        // s = MAX, vLo = MAX, vHi = 1 forces hiLo + loHi to wrap; D = 2^257.
        // Independent oracle: floor((2^256-1)*(2^257-1)/2^257) == 2^256-2.
        assertEq(w.floorRatio(MAX, 1, MAX, 2, 0), MAX - 1);
    }

    function testFuzzNarrowMatchesNative(uint128 amount, uint128 n, uint128 d) public view {
        uint256 den = uint256(d) + 1;
        uint256 num = uint256(n) % den;
        assertEq(w.floorRatio(amount, 0, num, 0, den), uint256(amount) * num / den);
    }

    function testFuzzWideHalf(uint256 amount, uint256 nHiSeed, uint256 nLo) public view {
        uint256 nHi = bound(nHiSeed, 1, MAX >> 1);
        uint256 dLo = nLo << 1;
        uint256 dHi = (nHi << 1) | (nLo >> 255);
        assertEq(w.floorRatio(amount, nHi, nLo, dHi, dLo), amount / 2);
    }
}

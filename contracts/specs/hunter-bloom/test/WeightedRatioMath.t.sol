// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity >=0.8.0 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {WeightedRatioMath} from "../src/WeightedRatioMath.sol";

/// @dev External wrapper around the internal library seam so tests can use
///      expectRevert and measure gas across a real call boundary.
contract FloorRatioWrapper {
    function floorRatio(uint256 amount, uint256 nHi, uint256 nLo, uint256 dHi, uint256 dLo)
        external
        pure
        returns (uint256)
    {
        return WeightedRatioMath.floorRatio(amount, nHi, nLo, dHi, dLo);
    }
}

contract WeightedRatioMathTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    FloorRatioWrapper internal w;

    function setUp() public {
        w = new FloorRatioWrapper();
    }

    /// D == 0 or N > D must revert, including when amount == 0. Revert
    /// payloads are intentionally unspecified, so match any revert.
    function testRevertsOnInvalidRatio() public {
        vm.expectRevert();
        w.floorRatio(1, 0, 1, 0, 0); // D == 0
        vm.expectRevert();
        w.floorRatio(0, 0, 0, 0, 0); // D == 0 with amount == 0
        vm.expectRevert();
        w.floorRatio(9, 1, 8, 1, 7); // same high limb, larger low -> N > D
        vm.expectRevert();
        w.floorRatio(9, 2, 0, 1, MAX); // larger high limb -> N > D
        vm.expectRevert();
        w.floorRatio(0, 1, 0, 0, MAX); // N > D even though amount == 0
    }

    /// Boundary quantities checked against independently derived literals.
    function testEdgeQuantities() public {
        assertEq(w.floorRatio(0, 0, 5, 0, 7), 0); // amount == 0
        assertEq(w.floorRatio(123, 0, 0, 0, 7), 0); // N == 0
        assertEq(w.floorRatio(77, 0, 9, 0, 9), 77); // N == D
        assertEq(w.floorRatio(55, MAX, MAX, MAX, MAX), 55); // N == D, full 512-bit limbs
        assertEq(w.floorRatio(1000, 0, MAX, 0, MAX), 1000); // max 256-bit denominator
        // Full carry: (2^256-1) * (2^256+1) == 2^512-1 exactly, so floor is 1.
        assertEq(w.floorRatio(MAX, 1, 1, MAX, MAX), 1);
        assertEq(w.floorRatio(MAX, 1, 0, MAX, MAX), 0); // (2^256-1)*2^256 < 2^512-1
        // Near-equal max ratio: (2^256-1)*(2^512-2)/(2^512-1) == 2^256-2.
        assertEq(w.floorRatio(MAX, MAX, MAX - 1, MAX, MAX), MAX - 1);
    }

    /// 139 vectors generated with Python arbitrary-precision arithmetic,
    /// independent of any limb decomposition used by the implementation.
    function testFixtureVectors() public {
        string memory json = vm.readFile("test/fixtures/weighted-ratio-vectors.json");
        uint256 count = vm.parseJsonUint(json, ".count");
        assertEq(count, 139);
        for (uint256 i = 0; i < count; i++) {
            string memory base = string.concat(".vectors[", vm.toString(i), "].");
            uint256 amount = uint256(vm.parseJsonBytes32(json, string.concat(base, "amount")));
            uint256 nHi = uint256(vm.parseJsonBytes32(json, string.concat(base, "nHi")));
            uint256 nLo = uint256(vm.parseJsonBytes32(json, string.concat(base, "nLo")));
            uint256 dHi = uint256(vm.parseJsonBytes32(json, string.concat(base, "dHi")));
            uint256 dLo = uint256(vm.parseJsonBytes32(json, string.concat(base, "dLo")));
            uint256 expected = uint256(vm.parseJsonBytes32(json, string.concat(base, "expected")));
            uint256 got = w.floorRatio(amount, nHi, nLo, dHi, dLo);
            assertEq(got, expected);
            assertLe(got, amount);
        }
    }

    /// Narrow path: 128-bit inputs keep a*num inside one 256-bit product so the
    /// native quotient is an independent oracle.
    function testFuzzSmall(uint128 a, uint128 n, uint128 d) public {
        uint256 den = uint256(d) + 1; // 1..2^128, always nonzero
        uint256 num = uint256(n) % den; // guarantees N < D
        assertEq(w.floorRatio(a, 0, num, 0, den), a * num / den);
    }

    /// Wide path: build D == 2N via shift/carry so the exact floor is amount/2.
    /// nHi is forced into [1, 2^255) to exercise the general 512-bit branch.
    function testFuzzHalfWide(uint256 amount, uint256 nHiSeed, uint256 nLo) public {
        uint256 nHi = bound(nHiSeed, 1, MAX >> 1);
        uint256 dLo = nLo << 1;
        uint256 dHi = (nHi << 1) | (nLo >> 255);
        assertEq(w.floorRatio(amount, nHi, nLo, dHi, dLo), amount / 2);
    }

    /// Call-region gas sample for the wide branch: a local measurement, not a
    /// promised bound. N = 2^44*2^256+1, D = 2^45*2^256+3, so 2N == D-1 and
    /// floor(MAX*N/D) == 2^255-1.
    function testWideBranchGasSample() public {
        uint256 expected = (uint256(1) << 255) - 1;
        uint256 nHi = uint256(1) << 44;
        uint256 dHi = uint256(1) << 45;
        assertEq(w.floorRatio(MAX, nHi, 1, dHi, 3), expected);
        uint256 gasBefore = gasleft();
        uint256 got = w.floorRatio(MAX, nHi, 1, dHi, 3);
        emit log_named_uint("floorRatio wide-branch call gas", gasBefore - gasleft());
        assertEq(got, expected);
        // Denominator high limb max with a near-equal ratio: 7*N/(N+1) -> 6.
        assertEq(w.floorRatio(7, MAX, 0, MAX, 1), 6);
    }
}

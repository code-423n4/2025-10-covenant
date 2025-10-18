// SPDX-License-Identifier: GPLv3
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {Uint512} from "../src/lex/latentswap/libraries/Uint512.sol";
import {console} from "forge-std/console.sol";

contract Uint512FuzzTest is Test {
    using Uint512 for *;

    // Test constants
    uint256 constant MAX_UINT256 = type(uint256).max;
    uint256 constant MAX_UINT128 = type(uint128).max;

    // Fuzz test for mul256x256 with same number and sqrt512 round-trip
    function testFuzz_Mul256x256_Sqrt512_RoundTrip(uint256 a) public pure {
        // Skip edge cases
        if (a == 0) return;

        // Multiply number by itself (square it)
        (uint256 r1, uint256 r0) = Math.mul512(a, a);

        // Take square root
        uint256 sqrtResult = Uint512.sqrt512(r0, r1);

        // Should get back the original number
        assertEq(sqrtResult, a, "Round trip multiplication and square root failed");
    }

    // Test sub512x512 properties
    function testFuzz_Sub512x512_WithZero(uint256 a0, uint256 a1) public pure {
        (uint256 r0, uint256 r1) = Uint512.sub512x512(a0, a1, 0, 0);
        assertEq(r0, a0, "Subtracting zero should return original number (low bits)");
        assertEq(r1, a1, "Subtracting zero should return original number (high bits)");
    }

    // Test sqrt512 with zero
    function testFuzz_Sqrt512_Zero() public pure {
        uint256 result = Uint512.sqrt512(0, 0);
        assertEq(result, 0, "Square root of zero should return zero");
    }

    // Test sqrt512 with one
    function testFuzz_Sqrt512_One() public pure {
        uint256 result = Uint512.sqrt512(1, 0);
        assertEq(result, 1, "Square root of one should return one");
    }

    // Test that sqrt512 result squared is less than or equal to input
    function testFuzz_Sqrt512_UpperBound(uint256 a0, uint256 a1) public pure {
        if (a0 == 0 && a1 == 0) return; // Skip zero case

        uint256 sqrtResult = Uint512.sqrt512(a0, a1);

        // Square the result
        (uint256 square1, uint256 square0) = Math.mul512(sqrtResult, sqrtResult);

        // The square should be less than or equal to the original input
        assertTrue(
            square1 < a1 || (square1 == a1 && square0 <= a0),
            "Square of sqrt result should be <= original input"
        );
    }

    // Test that (sqrt + 1)^2 > input (for non-perfect squares)
    function testFuzz_Sqrt512_LowerBound(uint256 a0, uint256 a1) public pure {
        // Skip zero case and ensure sqrtResult + 1 doesn't overflow
        if (a0 == 0 && a1 == 0) return;
        if (a0 == MAX_UINT256) return; // Avoid overflow when adding 1

        uint256 sqrtResult = Uint512.sqrt512(a0, a1);

        // Check if it's a perfect square
        (uint256 square1, uint256 square0) = Math.mul512(sqrtResult, sqrtResult);
        bool isPerfectSquare = (square1 == a1 && square0 == a0);

        if (!isPerfectSquare) {
            // Ensure sqrtResult + 1 doesn't overflow
            if (sqrtResult < MAX_UINT256) {
                // Square of (sqrt + 1) should be greater than input
                (uint256 nextSquare1, uint256 nextSquare0) = Math.mul512(sqrtResult + 1, sqrtResult + 1);
                assertTrue(
                    nextSquare1 > a1 || (nextSquare1 == a1 && nextSquare0 > a0),
                    "Square of (sqrt + 1) should be > original input for non-perfect squares"
                );
            }
        }
    }

    // Test edge cases with maximum values
    function testFuzz_MaxValues() public pure {
        // Test sqrt512 with max uint256
        uint256 sqrtResult = Uint512.sqrt512(MAX_UINT256, 0);
        assertTrue(sqrtResult <= MAX_UINT256, "Sqrt result should fit in uint256");
    }

    // Test that sqrt512 correctly handles numbers just below perfect squares
    function testFuzz_Sqrt512_NearPerfectSquare(uint256 a) public pure {
        if (a <= 1) return;

        // Create a perfect square
        (uint256 square1, uint256 square0) = Math.mul512(a, a);

        // Test with number just below perfect square
        if (square0 > 0) {
            uint256 sqrtResult = Uint512.sqrt512(square0 - 1, square1);
            assertEq(sqrtResult, a - 1, "Sqrt of (perfect square - 1) should be (sqrt - 1)");
        }
    }
}

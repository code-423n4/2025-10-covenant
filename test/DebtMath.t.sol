// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {Math} from "@openzeppelin/utils/math/Math.sol";
import {DebtMath} from "../src/lex/latentswap/libraries/DebtMath.sol";
import {FixedPoint} from "../src/lex/latentswap/libraries/FixedPoint.sol";

// In the `LatentMath` functions,

contract DebtMathTest is Test {
    using Math for uint256;
    using DebtMath for uint256;

    function test_accrueInterest_noInterest() public pure {
        // If discount price is 1, then there is no interest accrued
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD;
        uint256 elapsedTime = 10000; // seconds

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, 0);
        assertEq(updatedAmount, amount, "DebtMath.accrueInterest: no interest accrued");
    }

    function test_accrueInterest_withInterest() public pure {
        // If discount price is 0.9, then there is interest accrued
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = (FixedPoint.WAD * 9) / 10;
        uint256 elapsedTime = 10000; // seconds

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, 0);
        assertEq(updatedAmount, 1000135503670093738, "DebtMath.accrueInterest: interest accrued");
    }

    function test_accrueInterest_withLargeInterest() public pure {
        // If discount price is 0.9, then there is interest accrued
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD / 10000;
        uint256 elapsedTime = 10000 days; // seconds

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, 0);
        assertEq(updatedAmount, 179152144495620097893258219, "DebtMath.accrueInterest: interest accrued");
    }

    function test_accrueInterest_withNegativeInterest() public pure {
        // If discount price is above 1, then interest is negative
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = (FixedPoint.WAD * 10) / 9;
        uint256 elapsedTime = 10000; // seconds

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, 0);
        assertEq(updatedAmount, 999864514688663191, "DebtMath.accrueInterest: interest accrued");
    }

    function test_accrueInterest_withLargeNegativeInterest() public pure {
        // If discount price is above 1, then interest is negative
        // Ensure it does not revert for really large positive numbers
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = 10000 * FixedPoint.WAD;
        uint256 elapsedTime = 10000 days; // seconds

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, 0);
        assertEq(updatedAmount, 5581847779, "DebtMath.accrueInterest: interest accrued");
    }

    // ========================================
    // Tests with positive lnRateBias
    // ========================================

    function test_accrueInterest_positiveBias_noDiscount() public pure {
        // With positive bias and no discount (price = 1), should accrue positive interest
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD; // 1.0 (no discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = 405465108108164000; // ln(1.5) ≈ 0.4055, positive bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1000521567435204182, "DebtMath.accrueInterest: positive bias with no discount");
    }

    function test_accrueInterest_positiveBias_withDiscount() public pure {
        // With positive bias and discount (price < 1), should accrue more interest
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = (FixedPoint.WAD * 9) / 10; // 0.9 (10% discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = 405465108108164000; // ln(1.5) ≈ 0.4055, positive bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1000657141779594926, "DebtMath.accrueInterest: positive bias with discount");
    }

    function test_accrueInterest_positiveBias_largeDiscount() public pure {
        // With positive bias and large discount, should accrue significant interest
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD / 10000; // 0.0001 (99.99% discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = 405465108108164000; // ln(1.5) ≈ 0.4055, positive bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1012442779193813369, "DebtMath.accrueInterest: positive bias with large discount");
    }

    function test_accrueInterest_positiveBias_premium() public pure {
        // With positive bias and premium (price > 1), should still accrue positive interest
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = (FixedPoint.WAD * 10) / 9; // 1.111... (premium)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = 405465108108164000; // ln(1.5) ≈ 0.4055, positive bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1000386011459143173, "DebtMath.accrueInterest: positive bias with premium");
    }

    // ========================================
    // Tests with negative lnRateBias
    // ========================================

    function test_accrueInterest_negativeBias_noDiscount() public pure {
        // With negative bias and no discount (price = 1), should accrue negative interest
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD; // 1.0 (no discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = -223143551314209704; // ln(0.8) ≈ -0.2231, negative bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 999713076726795467, "DebtMath.accrueInterest: negative bias with no discount");
    }

    function test_accrueInterest_negativeBias_withDiscount() public pure {
        // With negative bias and discount (price < 1), should accrue less interest than without bias
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = (FixedPoint.WAD * 9) / 10; // 0.9 (10% discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = -223143551314209704; // ln(0.8) ≈ -0.2231, negative bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 999848541517732404, "DebtMath.accrueInterest: negative bias with discount");
    }

    function test_accrueInterest_negativeBias_largeDiscount() public pure {
        // With negative bias and large discount, should still accrue positive interest but less
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD / 10000; // 0.0001 (99.99% discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = -223143551314209704; // ln(0.8) ≈ -0.2231, negative bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1011624655551575348, "DebtMath.accrueInterest: negative bias with large discount");
    }

    function test_accrueInterest_negativeBias_premium() public pure {
        // With negative bias and premium (price > 1), should accrue more negative interest
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = (FixedPoint.WAD * 10) / 9; // 1.111... (premium)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = -223143551314209704; // ln(0.8) ≈ -0.2231, negative bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 999577630289348688, "DebtMath.accrueInterest: negative bias with premium");
    }

    // ========================================
    // Tests with extreme lnRateBias values
    // ========================================

    function test_accrueInterest_largePositiveBias() public pure {
        // With very large positive bias, should accrue significant interest
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD; // 1.0 (no discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = 693147180559945309; // ln(2) ≈ 0.6931, large positive bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1000891790387884150, "DebtMath.accrueInterest: large positive bias");
    }

    function test_accrueInterest_largeNegativeBias() public pure {
        // With very large negative bias, should accrue significant negative interest
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD; // 1.0 (no discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = -693147180559945309; // ln(0.5) ≈ -0.6931, large negative bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 999109004193611631, "DebtMath.accrueInterest: large negative bias");
    }

    // ========================================
    // Tests with different time periods
    // ========================================

    function test_accrueInterest_positiveBias_longTime() public pure {
        // With positive bias over a long time period
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD; // 1.0 (no discount)
        uint256 elapsedTime = 30 * 24 * 60 * 60; // 30 days
        int256 lnRateBias = 405465108108164000; // ln(1.5) ≈ 0.4055, positive bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1144699954807949553, "DebtMath.accrueInterest: positive bias over long time");
    }

    function test_accrueInterest_negativeBias_longTime() public pure {
        // With negative bias over a long time period
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD; // 1.0 (no discount)
        uint256 elapsedTime = 30 * 24 * 60 * 60; // 30 days
        int256 lnRateBias = -223143551314209704; // ln(0.8) ≈ -0.2231, negative bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 928318882372091521, "DebtMath.accrueInterest: negative bias over long time");
    }

    // ========================================
    // Edge case tests
    // ========================================

    function test_accrueInterest_zeroBias_shouldMatchOriginal() public pure {
        // With zero bias, should match the original behavior
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = (FixedPoint.WAD * 9) / 10; // 0.9 (10% discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = 0; // zero bias

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1000135503670093738, "DebtMath.accrueInterest: zero bias should match original");
    }

    function test_accrueInterest_biasCancelsDiscount() public pure {
        // With bias that exactly cancels the discount effect
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = (FixedPoint.WAD * 9) / 10; // 0.9 (10% discount)
        uint256 elapsedTime = 10000; // seconds
        // ln(0.9) ≈ -0.1054, so positive bias of 0.1054 should cancel it
        int256 lnRateBias = 105360515657826300; // ln(1.111...) ≈ 0.1054

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1000271025701431889, "DebtMath.accrueInterest: bias cancels discount");
    }

    function test_accrueInterest_smallBias() public pure {
        // With very small bias values
        uint256 amount = 10 ** 18;
        uint256 duration = 90 * 24 * 60 * 60; // 3 months
        uint256 discountPrice = FixedPoint.WAD; // 1.0 (no discount)
        uint256 elapsedTime = 10000; // seconds
        int256 lnRateBias = 1000000000000000; // very small positive bias (0.001)

        uint256 updatedAmount = DebtMath.accrueInterest(amount, duration, discountPrice, elapsedTime, lnRateBias);
        assertEq(updatedAmount, 1000001286009057361, "DebtMath.accrueInterest: small positive bias");
    }

    // ========================================
    // Tests for accrueInterestLnRate saturating properties
    // ========================================

    function test_accrueInterestLnRate_maxPositiveLnRate() public pure {
        // Test with large positive lnRate (within uint96 but safe)
        uint256 amount = type(uint256).max;
        uint256 duration = 1; // Very short duration to maximize rate
        int256 lnRate = int256(FixedPoint.WAD * 1000); // Large positive lnRate but safe
        uint256 elapsedTime = 1000000; // Large elapsedTime but safe

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        assertEq(updatedAmount, type(uint256).max, "accrueInterestLnRate: should saturate with large positive lnRate");
    }

    function test_accrueInterestLnRate_maxNegativeLnRate() public pure {
        // Test with large negative lnRate (within uint96 but safe)
        uint256 amount = 1000; // Small amount to test underflow protection
        uint256 duration = 1; // Very short duration
        int256 lnRate = -int256(FixedPoint.WAD * 1000); // Large negative lnRate but safe
        uint256 elapsedTime = 1000000; // Large elapsedTime but safe

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        // Should not revert and should return a small positive value (minimum 1)
        assertTrue(updatedAmount >= 1, "accrueInterestLnRate: should not underflow to zero");
        assertTrue(updatedAmount <= amount, "accrueInterestLnRate: negative rate should decrease amount");
    }

    function test_accrueInterestLnRate_maxElapsedTime() public pure {
        // Test with large elapsedTime (within uint96 but safe)
        uint256 amount = type(uint256).max;
        uint256 duration = 1; // Very short duration
        int256 lnRate = int256(FixedPoint.WAD); // Moderate positive lnRate
        uint256 elapsedTime = 1000000; // Large elapsedTime but safe

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        assertEq(updatedAmount, type(uint256).max, "accrueInterestLnRate: should saturate with large elapsedTime");
    }

    function test_accrueInterestLnRate_maxDuration() public pure {
        // Test with large duration (within uint96 but safe)
        uint256 amount = type(uint256).max;
        uint256 duration = 1000000; // Large duration but safe
        int256 lnRate = int256(FixedPoint.RAY); // Moderate positive lnRate
        uint256 elapsedTime = 1; // Very short elapsed time

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        // With large duration and short elapsed time, should be close to original amount
        assertTrue(updatedAmount >= amount, "accrueInterestLnRate: should not decrease with short elapsed time");
    }

    function test_accrueInterestLnRate_extremePositiveRate() public pure {
        // Test with large positive rate (within uint96 but safe)
        uint256 amount = type(uint256).max;
        uint256 duration = 1;
        int256 lnRate = int256(FixedPoint.RAY * 100); // Large positive lnRate but safe
        uint256 elapsedTime = 100000; // Large elapsedTime but safe

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        assertEq(updatedAmount, type(uint256).max, "accrueInterestLnRate: should saturate with large positive rate");
    }

    function test_accrueInterestLnRate_extremeNegativeRate() public pure {
        // Test with large negative rate (within uint96 but safe)
        uint256 amount = 10000; // Moderate amount
        uint256 duration = 1;
        int256 lnRate = -int256(FixedPoint.RAY * 100); // Large negative lnRate but safe
        uint256 elapsedTime = 100000; // Large elapsedTime but safe

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        // Should not revert and should return a small positive value
        assertTrue(updatedAmount >= 1, "accrueInterestLnRate: should not underflow with large negative rate");
        assertTrue(updatedAmount <= amount, "accrueInterestLnRate: large negative rate should decrease amount");
    }

    function test_accrueInterestLnRate_maxTimeDelta() public pure {
        // Test with large timeDelta (within uint96 but safe)
        uint256 amount = type(uint256).max;
        uint256 duration = 1;
        int256 lnRate = int256(FixedPoint.RAY * 100); // Large positive lnRate
        uint256 elapsedTime = 100000; // Large elapsedTime but safe

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        assertEq(updatedAmount, type(uint256).max, "accrueInterestLnRate: should saturate with large timeDelta");
    }

    function test_accrueInterestLnRate_zeroLnRate() public pure {
        // Test with zero lnRate
        uint256 amount = 1000e18;
        uint256 duration = 365 days;
        int256 lnRate = 0; // Zero lnRate
        uint256 elapsedTime = 1000000; // Large elapsedTime but safe

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        assertEq(updatedAmount, amount, "accrueInterestLnRate: zero lnRate should return original amount");
    }

    function test_accrueInterestLnRate_zeroElapsedTime() public pure {
        // Test with zero elapsedTime
        uint256 amount = 1000e18;
        uint256 duration = 365 days;
        int256 lnRate = int256(FixedPoint.RAY); // Positive lnRate
        uint256 elapsedTime = 0; // Zero elapsedTime

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        assertEq(updatedAmount, amount, "accrueInterestLnRate: zero elapsedTime should return original amount");
    }

    function test_accrueInterestLnRate_boundaryValues() public pure {
        // Test with large boundary values (within uint96 but safe)
        uint256 amount = type(uint256).max;
        uint256 duration = 1;
        int256 lnRate = int256(FixedPoint.RAY * 50); // Large lnRate but safe
        uint256 elapsedTime = 500000; // Large elapsedTime but safe

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        // Should still saturate due to large amount and rate
        assertEq(updatedAmount, type(uint256).max, "accrueInterestLnRate: should saturate with large boundary values");
    }

    function test_accrueInterestLnRate_smallAmountLargeRate() public pure {
        // Test with small amount but large rate to test non-saturating case
        uint256 amount = 1000; // Small amount
        uint256 duration = 1;
        int256 lnRate = int256(FixedPoint.RAY * 10); // Large positive lnRate
        uint256 elapsedTime = 1000; // Moderate elapsedTime

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        // Should not saturate and should be larger than original amount
        assertTrue(updatedAmount > amount, "accrueInterestLnRate: should increase amount with positive rate");
        assertTrue(updatedAmount < type(uint256).max, "accrueInterestLnRate: should not saturate with small amount");
    }

    function test_accrueInterestLnRate_negativeRateSmallAmount() public pure {
        // Test with negative rate and small amount
        uint256 amount = 1000; // Small amount
        uint256 duration = 1;
        int256 lnRate = -int256(FixedPoint.RAY * 10); // Large negative lnRate
        uint256 elapsedTime = 1000; // Moderate elapsedTime

        uint256 updatedAmount = DebtMath.accrueInterestLnRate(amount, lnRate, elapsedTime, duration);
        // Should decrease amount but not go to zero
        assertTrue(updatedAmount < amount, "accrueInterestLnRate: should decrease amount with negative rate");
        assertTrue(updatedAmount >= 1, "accrueInterestLnRate: should not go to zero");
    }
}

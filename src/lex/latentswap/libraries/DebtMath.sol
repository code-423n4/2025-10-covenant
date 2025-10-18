// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SaturatingMath} from "./SaturatingMath.sol";
import {FixedPoint} from "./FixedPoint.sol";

/**
 * @title DebtMath library
 * @author Covenant Labs
 * @notice Provides approximations for Perpetual Debt calculations
 */
library DebtMath {
    using SaturatingMath for uint256;
    using FixedPointMathLib for int256;
    using Math for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /**
     * @notice calculates interest update factor given perpetual debt duration, debt notional price and elapsed time.
     * @param _amount amount on which interest is being applied
     * @param _duration effective duration of the debt (in seconds)
     * @param _discountPrice discount price (vs debt notional) in WADs
     * @param _elapsedTime time over which to accrue interest (in seconds)
     * @param _lnRateBias additional market rate bias (that is not determined by price), in WADs
     * @return updatedAmount_  the updated amount given debt interest rate and elapsed time
     **/
    function accrueInterest(
        uint256 _amount,
        uint256 _duration,
        uint256 _discountPrice,
        uint256 _elapsedTime,
        int256 _lnRateBias
    ) internal pure returns (uint256 updatedAmount_) {
        // Calculate rate = - ln(price) + lnRateBias
        // and then updates amount.
        return accrueInterestLnRate(_amount, _lnRateBias - int256(_discountPrice).lnWad(), _elapsedTime, _duration);
    }

    /**
     * @notice updates amount given duration, lnRate and elapsed time.
     * @dev interest accrual saturates.  ie, calculation will not revert,
     * and instead updatedAmount will be >0 and <=type(uint256).max
     * @param _amount amount to be update given duration, lnRate and elapsed time.
     * @param _duration effective duration of the debt (in seconds)
     * @param _lnRate lnRate in WADs (lnRate < 1 is a negative interest rate)
     * @param _elapsedTime time over which to accrue interest (in seconds)
     * @return updatedAmount_  the updated amount given debt interest rate and elapsed time
     **/
    function accrueInterestLnRate(
        uint256 _amount,
        int256 _lnRate,
        uint256 _elapsedTime,
        uint256 _duration
    ) internal pure returns (uint256 updatedAmount_) {
        uint256 updateFactor = calculateApproxExponentialUpdate(
            uint256((_lnRate >= 0) ? _lnRate : -_lnRate),
            _elapsedTime,
            _duration
        );

        if (_lnRate >= 0) {
            return _amount.saturatingMulDiv(updateFactor, FixedPoint.RAY);
        } else {
            // @dev - when lnRate < 0, we calculate exp(x), but then divide _amount by that updatefactor.
            // given e(-x) = 1 / e(x). Amount is never allowed to get to 0 from interest accrual.
            updatedAmount_ = _amount.mulDiv(FixedPoint.RAY, updateFactor);
            if (updatedAmount_ == 0 && _amount > 0) updatedAmount_ = 1;
        }
    }

    /**
     * @notice Calculates approximation of exp(lnRate * timeDelta / duration) for small values of rate * timeDelta / duration
     * @dev rate * timeDelta / duration is considered small, given timeDelta << duration, and rangebound rate
     * @dev A taylor expansion is used to calculate exp(rate * timeDelta / duration), and output will alwas be <= to the exact calculation.
     * @dev Below calculation does not overflow, even in extremes.  e.g, max lnRAte
     * @dev below does not overflow for reasonable extremes.  E.g, duration of 1 year (in seconds), time elapsed of 10,000 years, lnRate = 7.9 RAYS (= 250000% daily rate)
     * @param _lnRate logaritmic rate. -ln(price) in WADs
     * @param _timeDelta time over which to accrue interest (in seconds)
     * @param _duration effective duration of the debt (in seconds)
     * @return updateMultiplier_ the update multiplier (in RAYs) with which to update an amount
     **/
    function calculateApproxExponentialUpdate(
        uint256 _lnRate,
        uint256 _timeDelta,
        uint256 _duration
    ) internal pure returns (uint256 updateMultiplier_) {
        // @dev- for extreme cases (e.g., daily 10000% interest rate over 10000 years, with duration = 1 day),
        // both _lnRate and _timeDelta are expected to be < uint96.max, and the below
        // calculation not to revert.

        // approximation for exp(lnRate * timeDelta / duration)
        uint256 rate1 = (_lnRate * _timeDelta * FixedPoint.WAD_RAY_RATIO) / _duration;
        uint256 rate2 = rate1.mulDiv(rate1, 2 * FixedPoint.RAY);
        uint256 rate3 = rate2.mulDiv(rate1, 3 * FixedPoint.RAY);
        return FixedPoint.RAY + rate1 + rate2 + rate3;
    }

    // returns linear update multiplier (ray units)
    // assumes rate in BPS for a yearly duration
    // @dev - output value saturates at type(uint256).max
    function calculateLinearAccrual(
        uint256 _value,
        uint256 _rateBPS,
        uint256 _timeDelta
    ) internal pure returns (uint256 accrualValue_) {
        // @dev - Even for extreme rate and timeDelta cases, _rate expected to be < type(uint160).max
        // and _timeDelta < type(uint96).max.  Given this, below does not revert for any
        // _value <= type(uint256).max.

        return _value.saturatingMulDiv(_rateBPS * _timeDelta, SECONDS_PER_YEAR * FixedPoint.PERCENTAGE_FACTOR);
    }
}

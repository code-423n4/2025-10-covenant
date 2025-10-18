// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";

/**
 * @title SaturatingMath library
 * @author Covenant Labs
 * @notice Provides a saturating mulDiv operation
 */
library SaturatingMath {
    // Returns a saturating mulDiv operation
    // @dev - does not overflow, but instead returns type(uint256).max if so.
    function saturatingMulDiv(
        uint256 _numerator1,
        uint256 _numerator2,
        uint256 _denominator
    ) internal pure returns (uint256) {
        (uint256 high, uint256 low) = Math.mul512(_numerator1, _numerator2);

        // @dev - below follows the logic of Math.mulDiv, but saturates instead of reverting.
        if (high >= _denominator) {
            // returns type(uint256).max for all overflow and _denominator == 0 conditions
            return type(uint256).max;
        } else if (high == 0) {
            // @dev - execute 256 bit division here directly.
            // already checked for denominator == 0
            unchecked {
                return low / _denominator;
            }
        } else {
            // @dev - would be more efficient to do a 512 division here,
            // but OpenZeppelin does not have a separate (already audited) function.
            // So below recomputes Math.mul512 internally, and then performs the division.
            // Does not revert given checks above.
            return Math.mulDiv(_numerator1, _numerator2, _denominator);
        }
    }

    function saturatingMulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator,
        Math.Rounding rounding
    ) internal pure returns (uint256 result) {
        result = saturatingMulDiv(x, y, denominator);
        return
            result +
            SafeCast.toUint(
                Math.unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0 && result < type(uint256).max
            );
    }

    /**
     * @dev Calculates floor(x * y >> n) with full precision. saturates instead of reverting.
     * @dev Code copies @openzeppelin/utils/math/Math.sol:mulShr, but saturates instead of reverting.
     */
    function saturatingMulShr(uint256 x, uint256 y, uint8 n) internal pure returns (uint256 result) {
        unchecked {
            (uint256 high, uint256 low) = Math.mul512(x, y);
            if (high >= 1 << n) {
                return type(uint256).max; // @dev - saturates instead of reverting for overflow.
            }
            return (high << (256 - n)) | (low >> n);
        }
    }
}

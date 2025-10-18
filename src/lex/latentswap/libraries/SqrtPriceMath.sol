// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {FixedPoint} from "./FixedPoint.sol";

/// @title Functions based on Q64.96 sqrt price and liquidity
/// @notice Contains the math that uses square root of price as a Q64.96 and liquidity to compute deltas
library SqrtPriceMath {
    using SafeCast for uint256;

    /// @notice Gets the next sqrt price given a delta of token0
    /// The most precise formula for this is liquidity * sqrtPX96 / (liquidity +- amount * sqrtPX96),
    /// if this is impossible because of overflow, we calculate liquidity / (liquidity / sqrtPX96 +- amount).
    /// @param sqrtPX96 The starting price, i.e. before accounting for the token0 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of token0 to add or remove from virtual reserves
    /// @param add Whether to add or remove the amount of token0
    /// @param rounding Whether to round result up or down
    /// @return The price after adding or removing amount, depending on add
    function getNextSqrtPriceFromAmount0(
        uint160 sqrtPX96,
        uint160 liquidity,
        uint256 amount,
        bool add,
        Math.Rounding rounding
    ) internal pure returns (uint160) {
        require(sqrtPX96 > 0);
        require(liquidity > 0);

        // we short circuit amount == 0 because the result is otherwise not guaranteed to equal the input price
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << FixedPoint.RESOLUTION;

        if (add) {
            unchecked {
                uint256 product;
                if ((product = amount * sqrtPX96) / amount == sqrtPX96) {
                    uint256 denominator = numerator1 + product;
                    if (denominator >= numerator1)
                        // always fits in 160 bits
                        return uint160(Math.mulDiv(numerator1, sqrtPX96, denominator, rounding));
                }
            }
            // denominator is checked for overflow
            uint256 denominator2 = (numerator1 / sqrtPX96) + amount;
            if (rounding == Math.Rounding.Ceil) return uint160(Math.ceilDiv(numerator1, denominator2));
            else return uint160(numerator1 / denominator2);
        } else {
            unchecked {
                uint256 product;
                // if the product overflows, we know the denominator underflows
                // in addition, we must check that the denominator does not underflow
                require((product = amount * sqrtPX96) / amount == sqrtPX96 && numerator1 > product);
                uint256 denominator = numerator1 - product;
                return Math.mulDiv(numerator1, sqrtPX96, denominator, rounding).toUint160();
            }
        }
    }

    /// @notice Gets the next sqrt price given a delta of token1
    /// The formula we compute is within <1 wei of the lossless version: sqrtPX96 +- amount / liquidity
    /// @param sqrtPX96 The starting price, i.e., before accounting for the token1 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of token1 to add, or remove, from virtual reserves
    /// @param add Whether to add, or remove, the amount of token1
    /// @param rounding Whether to round result up or down
    /// @return The price after adding or removing `amount`
    function getNextSqrtPriceFromAmount1(
        uint160 sqrtPX96,
        uint160 liquidity,
        uint256 amount,
        bool add,
        Math.Rounding rounding
    ) internal pure returns (uint160) {
        require(sqrtPX96 > 0);
        require(liquidity > 0);

        // if we're adding (subtracting), rounding down requires rounding the quotient down (up)
        // in both cases, avoid a mulDiv for most inputs
        if (add) {
            uint256 quotient = (
                amount <= type(uint160).max
                    ? (
                        (rounding == Math.Rounding.Ceil)
                            ? Math.ceilDiv((amount << FixedPoint.RESOLUTION), liquidity)
                            : (amount << FixedPoint.RESOLUTION) / liquidity
                    )
                    : Math.mulDiv(amount, FixedPoint.Q96, liquidity, rounding)
            );

            return (uint256(sqrtPX96) + quotient).toUint160();
        } else {
            Math.Rounding invRounding = Math.Rounding(1 - uint8(rounding));
            uint256 quotient = (
                amount <= type(uint160).max
                    ? (invRounding == Math.Rounding.Ceil)
                        ? Math.ceilDiv(amount << FixedPoint.RESOLUTION, liquidity)
                        : ((amount << FixedPoint.RESOLUTION) / liquidity)
                    : Math.mulDiv(amount, FixedPoint.Q96, liquidity, invRounding)
            );

            require(sqrtPX96 > quotient);
            // always fits 160 bits
            unchecked {
                return uint160(sqrtPX96 - quotient);
            }
        }
    }

    /// @notice Gets the amount0 delta between two prices
    /// @dev Calculates liquidity / sqrt(lower) - liquidity / sqrt(upper),
    /// i.e. liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
    /// @param sqrtRatioAX96 A sqrt price
    /// @param sqrtRatioBX96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param rounding Whether to round the amount up or down
    /// @return amount0 Amount of token0 required to cover a position of size liquidity between the two passed prices
    function getAmount0Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint160 liquidity,
        Math.Rounding rounding
    ) internal pure returns (uint256 amount0) {
        unchecked {
            if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

            uint256 numerator1 = uint256(liquidity) << FixedPoint.RESOLUTION;
            uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

            require(sqrtRatioAX96 > 0);

            uint256 numerator3 = Math.mulDiv(numerator1, numerator2, sqrtRatioBX96, rounding);
            return
                (rounding == Math.Rounding.Ceil) ? Math.ceilDiv(numerator3, sqrtRatioAX96) : numerator3 / sqrtRatioAX96;
        }
    }

    /// @notice Gets the amount1 delta between two prices
    /// @dev Calculates liquidity * (sqrt(upper) - sqrt(lower))
    /// @param sqrtRatioAX96 A sqrt price
    /// @param sqrtRatioBX96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param rounding Whether to round the amount up, or down
    /// @return amount1 Amount of token1 required to cover a position of size liquidity between the two passed prices
    function getAmount1Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint160 liquidity,
        Math.Rounding rounding
    ) internal pure returns (uint256 amount1) {
        unchecked {
            if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
            return Math.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint.Q96, rounding);
        }
    }
}

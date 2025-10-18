// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {FixedPoint} from "../../src/lex/latentswap/libraries/FixedPoint.sol";
import {LatentMath, AssetType} from "../../src/lex/latentswap/libraries/LatentMath.sol";
import {WadRayMath} from "@aave/libraries/math/WadRayMath.sol";
import {console} from "forge-std/console.sol";

library TestMath {
    using SafeCast for uint256;
    using Math for uint256;
    using SafeCast for bool;

    // Token index constants
    uint8 private constant C_X = 0;
    uint8 private constant C_Y = 1;

    // Token index constants
    uint8 private constant BASE = 0;
    uint8 private constant DEBT = 1;
    uint8 private constant LEVERAGE = 2;

    // SqrtPrice constants
    uint8 private constant P_B = 1;
    uint8 private constant P_A = 0;

    function encodePriceSqrtQ96(uint256 reserve1, uint256 reserve2) internal pure returns (uint160) {
        return Math.sqrt(Math.mulDiv(reserve1, 1 << (FixedPoint.RESOLUTION << 1), reserve2)).toUint160();
    }

    /**
     * @notice Calculate dex spot price of token1/token0 given token balances
     * @dev - Assumes sqrtRatioX96_A = 1/sqrtRatioX96_B
     * @param  sqrtRatioX96_B high market price edge ( price (token1/token0) when token1 = 0)
     * @param zTokenAmount amount of zTokens in market
     * @param aTokenAmount amount of aTokens in market
     * @return sqrtRatioX96 Return current spot price given balances
     */
    function getSqrtPriceX96(
        uint160 sqrtRatioX96_B,
        uint256 zTokenAmount,
        uint256 aTokenAmount
    ) internal pure returns (uint160 sqrtRatioX96) {
        require(aTokenAmount > 0 || zTokenAmount > 0);

        bool zAmountIsLarger = zTokenAmount > aTokenAmount;
        Math.Rounding rounding = (zAmountIsLarger) ? Math.Rounding.Ceil : Math.Rounding.Floor;
        (uint256 amountL, uint256 amountS) = zAmountIsLarger
            ? (zTokenAmount, aTokenAmount)
            : (aTokenAmount, zTokenAmount);

        uint256 betaX96 = Math.mulDiv(sqrtRatioX96_B, amountL - amountS, amountL << 1, rounding);
        uint256 qX196 = Math.mulDiv(FixedPoint.Q192, amountS, amountL, rounding);
        sqrtRatioX96 = (betaX96 + Math.sqrt(betaX96 * betaX96 + qX196, rounding)).toUint160();
        if (!zAmountIsLarger) sqrtRatioX96 = (FixedPoint.Q192 / sqrtRatioX96).toUint160();
        return sqrtRatioX96;
    }

    function getDebtDiscount(
        uint160 currentSqrtPriceX96,
        uint160 edgeSqrtPriceX96_A,
        uint160 edgeSqrtPriceX96_B
    ) internal pure returns (uint256 currentDebtDiscountPrice) {
        uint256 current_dXdL_X96 = LatentMath.get_XvsL(
            currentSqrtPriceX96,
            edgeSqrtPriceX96_A,
            edgeSqrtPriceX96_B,
            AssetType.DEBT
        );

        uint256 target_dXdL_X96 = LatentMath.get_XvsL(
            uint160(FixedPoint.Q96),
            edgeSqrtPriceX96_A,
            edgeSqrtPriceX96_B,
            AssetType.DEBT
        );

        return Math.mulDiv(target_dXdL_X96, WadRayMath.WAD, current_dXdL_X96);
    }
}

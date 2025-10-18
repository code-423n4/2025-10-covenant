// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {AssetType} from "../../../interfaces/ILiquidExchangeModel.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {FixedPoint} from "./FixedPoint.sol";
import {SqrtPriceMath} from "./SqrtPriceMath.sol";
import {Uint512} from "./Uint512.sol";

/**
 * @title Latent Math
 * @author Covenant Labs
 * @dev Library containing all the DEX functions for the exchange of liquidity vs leverage value and debt value.
 **/

library LatentMath {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for bool;

    struct ComputeLiquidityVars {
        uint256 pDiffX96;
        uint256 betaX96;
        uint256 b2X192_0;
        uint256 b2X192_1;
        uint256 qX192_0;
        uint256 qX192_1;
        uint256 dX192_0;
        uint256 dX192_1;
    }

    /**
     * @notice Computes the liquidity invariant given the current balances.
     * @dev - For covenant market limts (max 90% > LTV >= 50%, 1.6 > Pb/Pa > 1.004, price = 1 at target LTV),
     * we find aTokenAmount and zTokenAmount should be < 2^152 to ensure no overflows and liquidity < 2^160.
     * @param sqrtRatioX96_A low market price edge (price (token1/token0) when token0 = 0)
     * @param sqrtRatioX96_B high market price edge ( price (token1/token0) when token1 = 0)
     * @param zTokenAmount amount of zTokens in market
     * @param aTokenAmount amount of aTokens in market
     * @return liquidity The calculated liquidity of the pool
     */
    function computeLiquidity(
        uint160 sqrtRatioX96_A,
        uint160 sqrtRatioX96_B,
        uint256 zTokenAmount,
        uint256 aTokenAmount
    ) internal pure returns (uint160) {
        /**********************************************************************************************
        // invariant                                                                                 //
        // L = invariant                               (L/PA - BX)(L.PB - BY) = L^2                  //
        // PA = sqrt(price_0)                                                                        // 
        // PB = sqrt(price_1)                                                                        //
        // BX = balance of coin X                                                                    //
        // BY = balance of coin Y          `                                                         //
        // @dev - reverts on overflow                                                                //
        //                                                                                           //
        // Computes L using square root solution                                                     //
        //    L = beta + sqrt(beta^2 - q)                                                            //
        // where                                                                                     //
        //    beta = (Y + X*sqrt(p_a)*sqrt(p_b))/(2*(sqrt(p_b)-sqrt(p_a)))                           //
        //    q = X*Y*sqrt(p_a)/(sqrt(p_b)-sqrt(p_a))                                                //
        //                                                                                           //
        //                                                                                           //
        **********************************************************************************************/
        ComputeLiquidityVars memory vars;
        // @dev - For covenant market limts (max LTV = 90%, 1.6 > Pb/Pa > 1.004),
        // we find that BaseTokenValue < Liquidity < 2^8 * BaseTokenValue.
        // So BaseTokenValue < 2^152 to ensure Liquidity < 2^160 across markets.
        // In addition, given market concavity, aTokenAmount < BaseTokenValue, and zTokenAmount < BaseTokenValue.
        // At any point within the market limits.

        // @dev - assumes sqrtPrice_B > sqrtPrice_A (otherwise reverts)
        vars.pDiffX96 = (sqrtRatioX96_B - sqrtRatioX96_A);

        // beta with X96 precision
        // b = (Y + X*sqrt(p_a)*sqrt(p_b))/(2*(sqrt(p_b)-sqrt(p_a)))
        // @dev - For covenant market limts (max LTV = 90%, Pb/Pa < 1.004),
        // we have 1/(2*(sqrt(p_b)-sqrt(p_a))) < 2^8
        // For markets with LTV > 50%, we also have sqrtRatioX96_A * sqrtRatioX96_B <= FixedPoint.Q192
        // so, combined, FixedPoint.Q192 / (2 * vars.pDiffX96) < 2^8 * FixedPoint.Q96 < 2^102
        // Thus, aTokenAmount and zTokenAmount < 2^154 for betaX96 to fit in uint256.
        // (but should be further constrained to < 2^152 given previous comments)
        vars.betaX96 =
            Math.mulDiv(aTokenAmount, FixedPoint.Q192, vars.pDiffX96 << 1) +
            Math.mulDiv(zTokenAmount * sqrtRatioX96_A, sqrtRatioX96_B, vars.pDiffX96 << 1);

        // beta^2 with X192 precision (512)
        (vars.b2X192_1, vars.b2X192_0) = Math.mul512(vars.betaX96, vars.betaX96);

        // q = X*Y*sqrt(p_a)/(sqrt(p_b)-sqrt(p_a)), with X192 precision (512 bits)
        // biggest aTokenAmount <= biggest zTokenAmount for markets with LTV >= 50%
        // Liquidity =< aTokenAmount + zTokenAmount (== when currentPrice == 1 only).
        // Given market constraints, sqrtA / (sqrtB - sqrtA) < 2^8.  Thus, aTokenAmount < 2^152 so as to not overflow.
        // zTokenAmount can be < 2^160 in calculation below.
        (vars.qX192_1, vars.qX192_0) = Math.mul512(
            Math.mulDiv(
                aTokenAmount,
                uint256(sqrtRatioX96_A) << FixedPoint.RESOLUTION,
                vars.pDiffX96,
                Math.Rounding.Ceil
            ),
            zTokenAmount * FixedPoint.Q96
        );

        // add (beta^2 - q) if it is > 0. otherwise disrgard this term. (this could happen due to rounding for lower balances)
        // check beta^2 > q for 512 bit numbers.
        if ((vars.qX192_1 == vars.b2X192_1 || vars.qX192_0 < vars.b2X192_0) || vars.qX192_1 < vars.b2X192_1) {
            // calculate difference.
            (vars.dX192_0, vars.dX192_1) = Uint512.sub512x512(vars.b2X192_0, vars.b2X192_1, vars.qX192_0, vars.qX192_1);
            // add sqrt of difference
            vars.betaX96 += Uint512.sqrt512(vars.dX192_0, vars.dX192_1);
        }

        // @dev Return does not require toUint160() SafeCast given FixedPoint.RESOLUTION shiftRight.
        return uint160(vars.betaX96 >> FixedPoint.RESOLUTION);
    }

    /**
     * @notice Computes the required swap amounts
     * @dev Does not verify price limits
     * @dev - For large liquidity amounts, and low tokenIn amounts, the output will be zero
     * @dev - Reverts for currentLiquidity == 0, currentSqrtRatioX96 == 0
     * @param currentLiquidity The current liquidity
     * @param currentSqrtRatioX96 The current market price
     * @param tokenSpecified The index of the token that is specified for the swap
     * @param amountSpecified The exact amount specified for the swap
     * @param isExactIn Whether the amounts specified are for the token coming into the swap or not.
     * @return amountCalculated The calculated amount (amountOut if isExactIn, or amountIn if !IsExactIn)
     * @return nextSqrtRatioX96 The next market price after swap
     */
    function computeSwap(
        uint160 currentLiquidity,
        uint160 currentSqrtRatioX96,
        AssetType tokenSpecified,
        uint256 amountSpecified,
        bool isExactIn
    ) internal pure returns (uint256 amountCalculated, uint160 nextSqrtRatioX96) {
        // In latent swaps, when an amount is coming in, it 'decreases' the balance of that token
        // The amount out comes from an 'increase' in balance
        if (tokenSpecified == AssetType.DEBT) {
            // For exactIn, round to make sure we do not pass the target price. Given price is going down, round up.
            // For !exactIn, round to make sure we pass the target price. Given price is going up, round up.
            nextSqrtRatioX96 = SqrtPriceMath.getNextSqrtPriceFromAmount0(
                currentSqrtRatioX96,
                currentLiquidity,
                amountSpecified,
                isExactIn,
                Math.Rounding.Ceil
            );

            // round down is exactIn, up otherwise
            amountCalculated = SqrtPriceMath.getAmount1Delta(
                currentSqrtRatioX96,
                nextSqrtRatioX96,
                currentLiquidity,
                isExactIn ? Math.Rounding.Floor : Math.Rounding.Ceil
            );
        } else if (tokenSpecified == AssetType.LEVERAGE) {
            // For exactIn, round to make sure we do not pass the target price. Given price is going up, round down.
            // For !exactIn, round to make sure we pass the target price. Given price is going down, round down.
            nextSqrtRatioX96 = SqrtPriceMath.getNextSqrtPriceFromAmount1(
                currentSqrtRatioX96,
                currentLiquidity,
                amountSpecified,
                isExactIn,
                Math.Rounding.Floor
            );

            // round down is exactIn, up otherwise
            amountCalculated = SqrtPriceMath.getAmount0Delta(
                currentSqrtRatioX96,
                nextSqrtRatioX96,
                currentLiquidity,
                isExactIn ? Math.Rounding.Floor : Math.Rounding.Ceil
            );
        } else revert();
    }

    /**
     * @notice Calculate amount of a + z Tokens minted when a fixed amount of liquidity is added
     * @dev Does not change current market price
     * @dev Round calculated balance down.
     * @param currentSqrtRatioX96 current market price
     * @param  edgeSqrtRatioX96_A low market price edge
     * @param  edgeSqrtRatioX96_B high market price edge
     * @param liquidityIn Liquidity being added to the market
     * @return zTokenAmount zTokenAmount minted
     * @return aTokenAmount aTokenAmount minted
     **/
    function computeMint(
        uint160 currentSqrtRatioX96,
        uint160 edgeSqrtRatioX96_A,
        uint160 edgeSqrtRatioX96_B,
        uint160 liquidityIn
    ) internal pure returns (uint256 zTokenAmount, uint256 aTokenAmount) {
        zTokenAmount = SqrtPriceMath.getAmount0Delta(
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            liquidityIn,
            Math.Rounding.Floor
        );
        aTokenAmount = SqrtPriceMath.getAmount1Delta(
            edgeSqrtRatioX96_B,
            currentSqrtRatioX96,
            liquidityIn,
            Math.Rounding.Floor
        );
    }

    /**
     * @notice Computes liquidity out given exact zToken and aToken amounts
     * @dev - Estimates liquidity out, with higher error the bigger % of liquidity being redeemed given market size
     * @dev - Keeps nextSqrtRatioX96 within bounds
     * @param currentLiquidity The current liquidity
     * @param currentSqrtRatioX96 The current market price
     * @param edgeSqrtRatioX96_A low market price edge
     * @param edgeSqrtRatioX96_B high market price edge
     * @param zTokenAmtIn The exact amount of zToken specified for the redeem
     * @param zTokenAmtIn The exact amount of zToken specified for the redeem
     * @return liquidityOut The liquidity amount calculated for redeem
     * @return nextSqrtRatioX96 The next market price after swap
     */
    function computeRedeem(
        uint160 currentLiquidity,
        uint160 currentSqrtRatioX96,
        uint160 edgeSqrtRatioX96_A,
        uint160 edgeSqrtRatioX96_B,
        uint256 zTokenAmtIn,
        uint256 aTokenAmtIn
    ) internal pure returns (uint160 liquidityOut, uint160 nextSqrtRatioX96) {
        // Calculate current market dex amounts
        // @dev - given getMarketStateFromLiquidityAndDebt(),
        // calculated aDexAmount == actual aDexAmount in circulation
        // calculated zDexAmount <= actual zDexAmount in circulation
        // (given current market price)

        (uint256 zDexAmount, uint256 aDexAmount) = computeMint(
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            currentLiquidity
        );

        if (zTokenAmtIn >= zDexAmount && aTokenAmtIn >= aDexAmount) {
            //Full burn
            return (currentLiquidity, currentSqrtRatioX96);
        } else {
            // Calculate remaining zToken and aToken amounts after redeem (add 1 to overestimate)
            uint256 remZamt = (zTokenAmtIn < zDexAmount) ? zDexAmount - zTokenAmtIn + 1 : 0;
            uint256 remAamt = (aTokenAmtIn < aDexAmount) ? aDexAmount - aTokenAmtIn + 1 : 0;

            // Calculate remaining liquidity (add 1 to force rounding up)
            uint256 remLiq = (uint256(computeLiquidity(edgeSqrtRatioX96_A, edgeSqrtRatioX96_B, remZamt, remAamt)) + 1);

            // set max remLiq as currentLiquidity (no need to safeCast remLiq after this)
            if (remLiq > uint256(currentLiquidity)) remLiq = currentLiquidity;
            liquidityOut = currentLiquidity - uint160(remLiq);
            nextSqrtRatioX96 = (liquidityOut == 0)
                ? currentSqrtRatioX96
                : SqrtPriceMath.getNextSqrtPriceFromAmount0(
                    edgeSqrtRatioX96_A,
                    uint160(remLiq),
                    remZamt,
                    false,
                    Math.Rounding.Ceil
                );
            if (nextSqrtRatioX96 > edgeSqrtRatioX96_B) nextSqrtRatioX96 = edgeSqrtRatioX96_B;
            return (liquidityOut, nextSqrtRatioX96);
        }
    }

    /**
     * @notice Calculate the derivative of liquidity vs a given token (at tokenType), given all current balances.
     * @param currentSqrtRatioX96 The current sqrtRatio of the market
     * @param  edgeSqrtRatioX96_A low market price edge (price (token1/token0) when token0 = 0)
     * @param  edgeSqrtRatioX96_B high market price edge ( price (token1/token0) when token1 = 0)
     * @param tokenType the token balance we are calculating
     * @return ratioX96 The derivative (spot price) of token vs liquidity, with X96 precision
     * @dev the inverse derivatives are as follows
     * dX/dL = 1/sqrt(Pa) - 2/sqrt(P) + sqrt(Pb)/P
     * dY/dL = sqrt(Pb) - 2sqrt(P)+ P/sqrt(Pa)
     * where Pa and Pb are the edge prices, and P is the current market spot price.
     */
    function get_XvsL(
        uint160 currentSqrtRatioX96,
        uint160 edgeSqrtRatioX96_A,
        uint160 edgeSqrtRatioX96_B,
        AssetType tokenType
    ) internal pure returns (uint256 ratioX96) {
        if (tokenType == AssetType.DEBT) {
            // calculates inverse derivative with Q96 resolution
            ratioX96 =
                Math.mulDiv(edgeSqrtRatioX96_B, FixedPoint.Q192, currentSqrtRatioX96) /
                currentSqrtRatioX96 +
                FixedPoint.Q192 /
                uint256(edgeSqrtRatioX96_A) -
                (FixedPoint.Q192 << 1) /
                currentSqrtRatioX96;
        } else if (tokenType == AssetType.LEVERAGE) {
            ratioX96 =
                Math.mulDiv(currentSqrtRatioX96, currentSqrtRatioX96, edgeSqrtRatioX96_A) +
                uint256(edgeSqrtRatioX96_B) -
                (uint256(currentSqrtRatioX96) << 1);
        } else revert();
    }

    /**
     * @notice Functionality used in LatentSwapLEX to calculate aDexAmount + marketSqrt price given zDexAmount + market Liquidity
     * @dev - functionality isolated into this function for testing purposes, to ensure updateMarket + redeem functionality are aligned
     * @param edgeSqrtRatioX96_A low market price edge
     * @param edgeSqrtRatioX96_B high market price edge
     * @param liquidity The current market liquidity
     * @param zDexAmount The exact amount of zToken specified for the redeem
     * @return aDexAmount The derived aDexAmount
     * @return currentSqrtPriceX96 The derived marketSqrtPriceX96
     */
    function getMarketStateFromLiquidityAndDebt(
        uint160 edgeSqrtRatioX96_A,
        uint160 edgeSqrtRatioX96_B,
        uint160 liquidity,
        uint256 zDexAmount
    ) internal pure returns (uint256 aDexAmount, uint160 currentSqrtPriceX96) {
        // calculate market price given liquidity and zDexAmount
        // Round up current price (implicitly rounds up debt value, rounds down aDexAmount in next calculation)
        currentSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            edgeSqrtRatioX96_A,
            liquidity,
            zDexAmount,
            false,
            Math.Rounding.Ceil
        );

        // calculate aSynthAmount given current price and market liquidity
        // Round down aDexAmount
        aDexAmount = SqrtPriceMath.getAmount1Delta(
            edgeSqrtRatioX96_B,
            currentSqrtPriceX96,
            liquidity,
            Math.Rounding.Floor
        );
    }

    /**
     * @notice Calculates marginal value of L vs debt when market price == 1
     * @param edgeSqrtRatioX96_A low market price edge
     * @param edgeSqrtRatioX96_B high market price edge
     * @return targetXvsL XvsL when market on target (price == 1), with X96 precision
     */
    function targetXvsL(uint160 edgeSqrtRatioX96_A, uint160 edgeSqrtRatioX96_B) internal pure returns (uint256) {
        return get_XvsL(uint160(FixedPoint.Q96), edgeSqrtRatioX96_A, edgeSqrtRatioX96_B, AssetType.DEBT);
    }

    /**
     * @notice Calculates LTV given current market price and market edges.
     * @param edgeSqrtRatioX96_A low market price edge
     * @param edgeSqrtRatioX96_B high market price edge
     * @param currentSqrtRatioX96 current market price
     * @return LTV where 10000 = 100%
     */
    function computeLTV(
        uint160 edgeSqrtRatioX96_A,
        uint160 edgeSqrtRatioX96_B,
        uint160 currentSqrtRatioX96
    ) internal pure returns (uint256) {
        /**********************************************************************************************
        // At extremes, all X or all Y markets have equivalent value                                 //
        // (equal to value of collateral)                                                            //
        //                                                                                           //
        // All X coin Amount0 = Pb - Pa / Pb / Pa                                                    //
        // All Y coin Amount1 = Pb - Pa                                                              //
        //                                                                                           //
        // Where                                                                                     //
        // Pa = sqrt(price_0)                                                                        //
        // Pb = sqrt(price_1)                                                                        //
        // Pc = sqrt(price_current)                                                                  //
        //                                                                                           //
        //                                                                                           //
        // Thus, from a value perspective, if Vx = Amount0, then Vy = Amount1 * Pb * Pa              //
        //                                                                                           //
        // We define LTV = Vx / (Vy + Vx)                                                            //
        //               = Amount0 / (Amount0 + Amount1 * Pb * Pa)                                   //
        //                                                                                           //
        // Solving this (using Amount0 = 1 / Pc - 1 / Pa, and Amount 1 = Pb - Pc (see SqrtPriceMath) //
        //                                                                                           //
        // LTV = (Pc - Pa).Pb / [(Pc - Pa).Pb + (Pb - Pc).Pc]                                        //
        //                                                                                           //
        //                                                                                           //
        **********************************************************************************************/

        // @dev - does not revert for
        // edgeSqrtRatioX96_B <= (2^32) * FixedPoint.Q96
        // and 0 < edgeSqrtRatioX96_A <= currentSqrtRatioX96 <= edgeSqrtRatioX96_B
        // given edgeSqrtRatioX96_B ^ 2 <= 2^256
        uint256 calc1 = uint256(edgeSqrtRatioX96_B) * uint256(currentSqrtRatioX96 - edgeSqrtRatioX96_A);
        uint256 calc2 = uint256(currentSqrtRatioX96) * uint256(edgeSqrtRatioX96_B - currentSqrtRatioX96);

        return Math.mulDiv(FixedPoint.PERCENTAGE_FACTOR, calc1, calc1 + calc2);
    }

    /**
     * @notice Returns the maximum debt amount (in dex units) given liquidity and limit prices
     * @param edgeSqrtRatioX96_A low market price edge
     * @param edgeSqrtRatioX96_B high market price edge
     * @param liquidity current market liquidity
     * @return maxDebt The maximum debt amount
     */
    function computeMaxDebt(
        uint160 edgeSqrtRatioX96_A,
        uint160 edgeSqrtRatioX96_B,
        uint160 liquidity
    ) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(edgeSqrtRatioX96_B, edgeSqrtRatioX96_A, liquidity, Math.Rounding.Floor);
    }
}

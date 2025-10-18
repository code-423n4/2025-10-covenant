// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {LatentMath, AssetType} from "../../src/lex/latentswap/libraries/LatentMath.sol";

/// @notice wraps LatentMath functions as external calls (to catch reverts when testing)
contract MockLatentMath {
    constructor() {}

    function computeLiquidity(
        uint160 sqrtRatioX96_A,
        uint160 sqrtRatioX96_B,
        uint256 zTokenAmount,
        uint256 aTokenAmount
    ) external pure returns (uint160) {
        return LatentMath.computeLiquidity(sqrtRatioX96_A, sqrtRatioX96_B, zTokenAmount, aTokenAmount);
    }

    function computeSwap(
        uint160 currentLiquidity,
        uint160 currentSqrtRatioX96,
        AssetType tokenSpecified,
        uint256 amountSpecified,
        bool isExactIn
    ) external pure returns (uint256 amountCalculated, uint160 nextSqrtRatioX96) {
        return
            LatentMath.computeSwap(currentLiquidity, currentSqrtRatioX96, tokenSpecified, amountSpecified, isExactIn);
    }

    function computeMint(
        uint160 currentSqrtRatioX96,
        uint160 edgeSqrtRatioX96_A,
        uint160 edgeSqrtRatioX96_B,
        uint160 liquidityIn
    ) external pure returns (uint256 zTokenAmount, uint256 aTokenAmount) {
        return LatentMath.computeMint(currentSqrtRatioX96, edgeSqrtRatioX96_A, edgeSqrtRatioX96_B, liquidityIn);
    }

    function computeRedeem(
        uint160 currentLiquidity,
        uint160 currentSqrtRatioX96,
        uint160 edgeSqrtRatioX96_A,
        uint160 edgeSqrtRatioX96_B,
        uint256 zTokenAmtIn,
        uint256 aTokenAmtIn
    ) external pure returns (uint160 liquidityOut, uint160 nextSqrtRatioX96) {
        LatentMath.computeRedeem(
            currentLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            zTokenAmtIn,
            aTokenAmtIn
        );
    }
}

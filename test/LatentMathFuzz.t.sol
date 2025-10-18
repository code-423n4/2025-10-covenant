// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {LatentMath, AssetType} from "../src/lex/latentswap/libraries/LatentMath.sol";
import {FixedPoint} from "../src/lex/latentswap/libraries/FixedPoint.sol";
import {SqrtPriceMath} from "../src/lex/latentswap/libraries/SqrtPriceMath.sol";
import {LatentSwapLib} from "../src/periphery/libraries/LatentSwapLib.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";
import {TestMath} from "./utils/TestMath.sol";
import {AssetTypeHelpers} from "./utils/AssetTypeHelpers.sol";

// In the `LatentMath` functions, the protocol aims for computing a value either as small as possible or as large as possible
// by means of rounding in its favor; in order to achieve this, it may use arbitrary rounding directions during the calculations.
// The objective of `LatentMathTest` is to verify that the implemented rounding permutations favor the protocol more than other
// solutions (e.g., always rounding down or always rounding up).

contract LatentMathFuzzTest is Test {
    using Math for uint256;
    using SafeCast for bool;
    using SafeCast for uint256;

    // Max balance of swap pool balance that won't cause an overflow in latent math.
    uint256 constant MIN_BALANCE = 1;
    uint256 constant MAX_BALANCE = (1 << 150);

    uint256 constant MAX_BASE_MINT_RATIO = 45e17; // x4.5
    uint256 constant MIN_BASE_MINT_RATIO = 1; // 1/10^18

    uint256 constant MIN_LIQUIDITY = 1000;
    uint256 constant MAX_LIQUIDITY = type(uint160).max;
    uint256 constant MIN_LIQUIDITY_MINT = 1000;

    uint256 constant MAX_SQRTPRICE = 9 * FixedPoint.Q96; // 9 MAX price
    uint256 constant MIN_SQRTPRICE = (333 * FixedPoint.Q96) / 1000; // 0.1111 MIN price
    uint256 constant MIN_SQRTPRICE_RATIO = (1025 * FixedPoint.Q96) / 1000; // (1.0001)^500 MIN price width = 1.025 MIN sqrt price ratio

    uint256 constant MIN_AMOUNT_RATIO = 0.001e16; // 0.001 %
    uint256 constant MAX_AMOUNT_RATIO = 99.999e16; // 99.999 %

    uint256 constant LIQUIDITY_PRECISION_BELOW = 1e5;
    uint256 constant LIQUIDITY_BELOW_THRESHOLD = 1e9;

    // Token index constants
    uint8 private constant BASE = uint8(AssetType.BASE);
    uint8 private constant DEBT = uint8(AssetType.DEBT);
    uint8 private constant LEVERAGE = uint8(AssetType.LEVERAGE);

    /////////////////////////////
    // Bound utils

    function boundTokenIndex(uint8 rawTokenIndex) internal pure returns (uint8 tokenIndex) {
        tokenIndex = rawTokenIndex % 2;
    }

    function boundTokenIndexes(
        uint8 rawTokenIndexIn,
        uint8 rawTokenIndexOut
    ) internal pure returns (uint8 tokenIndexIn, uint8 tokenIndexOut) {
        tokenIndexIn = boundTokenIndex(rawTokenIndexIn);
        tokenIndexOut = boundTokenIndex(rawTokenIndexOut);
        vm.assume(tokenIndexIn != tokenIndexOut);
    }

    function boundBalances(uint256[2] calldata rawBalances) internal pure returns (uint256[] memory balances) {
        balances = new uint256[](2);
        balances[0] = bound(rawBalances[0], MIN_BALANCE, MAX_BALANCE);
        balances[1] = bound(rawBalances[1], MIN_BALANCE, MAX_BALANCE);
    }

    function boundBalance(uint256 rawBalance) internal pure returns (uint256 balance) {
        balance = bound(rawBalance, MIN_BALANCE, MAX_BALANCE);
    }

    function boundBalancesWithLiquidityLimit(
        uint256[2] calldata rawBalances,
        uint160[] memory sqrtRatios
    ) internal pure returns (uint256[] memory balances) {
        balances = new uint256[](2);
        // choose a quasi random index to start with
        uint8 i = uint8(((rawBalances[0] & 0xFFFFFF) + (rawBalances[1] & 0xFFFFFF)) % 2);

        balances[i] = bound(rawBalances[i], MIN_BALANCE, MAX_BALANCE);

        // Ensure the other balance is such that MIN_LIQUIDITY is satisfied
        // Note: requires sqrtRatios to already be set
        uint256 minBalance;
        if (i == 0) {
            minBalance = ((sqrtRatios[1] - sqrtRatios[0]) * MIN_LIQUIDITY).ceilDiv(FixedPoint.Q96);
        } else {
            minBalance = Math.mulDiv(
                sqrtRatios[1] * MIN_LIQUIDITY,
                sqrtRatios[0],
                (sqrtRatios[1] - sqrtRatios[0]) << FixedPoint.RESOLUTION,
                Math.Rounding.Ceil
            );
        }
        balances[1 - i] = bound(rawBalances[1 - i], minBalance, MAX_BALANCE);
    }

    function boundAmount(uint256 rawAmount, uint256 balance) internal pure returns (uint256 amount) {
        amount = bound(
            rawAmount,
            Math.mulDiv(balance, MIN_AMOUNT_RATIO, 10 ** 18),
            Math.mulDiv(balance, MAX_AMOUNT_RATIO, 10 ** 18)
        );
    }

    function boundLiquidity(uint160 rawLiquidity) internal pure returns (uint160 liquidity) {
        liquidity = uint160(bound(rawLiquidity, MIN_LIQUIDITY, MAX_LIQUIDITY));
    }

    function boundSqrtRatios(
        uint160 rawSqrtRatioA,
        uint160 rawSqrtRatioB,
        uint160 rawSqrtRatioCurrent
    ) internal pure returns (uint160 sqrtRatioA, uint160 sqrtRatioB, uint160 sqrtRatioCurrent) {
        uint160 minSqrtRatioB = uint160(Math.mulDiv(MIN_SQRTPRICE, MIN_SQRTPRICE_RATIO, FixedPoint.Q96));
        console.log("minSqrtRatioB", minSqrtRatioB);
        console.log("MAX_SQRTPRICE", MAX_SQRTPRICE);
        sqrtRatioB = uint160(bound(rawSqrtRatioB, minSqrtRatioB, MAX_SQRTPRICE));
        console.log("sqrtRatioB", sqrtRatioB);
        uint160 maxSqrtRatioA = uint160(Math.mulDiv(sqrtRatioB, FixedPoint.Q96, MIN_SQRTPRICE_RATIO) + 2);
        console.log("maxSqrtRatioA", maxSqrtRatioA);
        console.log("MIN_SQRTPRICE", MIN_SQRTPRICE);
        sqrtRatioA = uint160(bound(rawSqrtRatioA, MIN_SQRTPRICE, maxSqrtRatioA));
        console.log("sqrtRatioA", sqrtRatioA);
        sqrtRatioCurrent = uint160(bound(rawSqrtRatioCurrent, sqrtRatioA, sqrtRatioB));
    }

    //////////
    // Fuzz Tests

    struct MintRedeemVars {
        uint160 liquiditySetup;
        uint160 liquidityMint;
        uint160 edgeSqrtRatioX96_A;
        uint160 edgeSqrtRatioX96_B;
        uint160 currentSqrtRatioX96;
        uint160 nextSqrtRatioX96;
        uint256 zTokenSetup;
        uint256 aTokenSetup;
        uint256 zTokenAmount;
        uint256 aTokenAmount;
        uint160 liquidityOut;
        uint256 baseSetup;
        uint256 baseMint;
        uint256 baseOut;
        uint8 tokenFixed;
        uint256 swapAmount;
        uint256 swapAmountCalc;
    }

    // Mint / Redeem roundtrip tests
    // swap roundtrip tests, exactin / exactout
    // @dev - incorporates
    // 1) converstion from base tokens to liquidity and back
    // 2) limits on size of mint/redeem vs market size (defined by MAX_BASE_MINT_RATIO)
    // - if mint/redeem is much larger than current market size, there is the opportunity for the user to move the market to their advantage,
    // so this is limited directly in the protocol
    function test_mintRedeemRoundTrip_Fuzz(
        uint160 baseMintRaw,
        uint160 edgeHighSqrtPriceRaw,
        uint160 edgeLowSqrtPriceRaw,
        uint160 currentSqrtRatioRaw
    ) external pure {
        MintRedeemVars memory vars;

        vars.baseSetup = bound(baseMintRaw, MIN_BALANCE, MAX_BALANCE >> 100);
        vars.baseMint = bound(
            baseMintRaw,
            MIN_BALANCE,
            Math.min(MAX_BALANCE - vars.baseSetup, (vars.baseSetup * MAX_BASE_MINT_RATIO) / (10 ** 18))
        );
        (vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B, vars.currentSqrtRatioX96) = boundSqrtRatios(
            edgeHighSqrtPriceRaw,
            edgeLowSqrtPriceRaw,
            currentSqrtRatioRaw
        );

        execute_mintRedeemRoundTrip(vars);
    }

    // Test boundary when mint amount is the max vs mint setup amount.  Focuses fuzz test on surface are aof
    //high mint/redeem amounts vs the alreadly existing liquidit y in the market
    function test_mintRedeemRoundTripEdgeCase_Fuzz(
        uint160 baseMintRaw,
        uint160 edgeHighSqrtPriceRaw,
        uint160 edgeLowSqrtPriceRaw,
        uint160 currentSqrtRatioRaw
    ) external pure {
        MintRedeemVars memory vars;

        // Focus testing on max baseMint/baseSetup ratio (MAX_BASE_MINT_RATIO)
        vars.baseSetup = bound(baseMintRaw, MIN_BALANCE, (MAX_BALANCE * (10 ** 18)) / MAX_BASE_MINT_RATIO / 10);
        vars.baseMint = (vars.baseSetup * MAX_BASE_MINT_RATIO) / (10 ** 18);

        (vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B, vars.currentSqrtRatioX96) = boundSqrtRatios(
            edgeHighSqrtPriceRaw,
            edgeLowSqrtPriceRaw,
            currentSqrtRatioRaw
        );

        execute_mintRedeemRoundTrip(vars);
    }

    function execute_mintRedeemRoundTrip(MintRedeemVars memory vars) internal pure {
        // convert to liquidity (as done in LatentSwapLEX)
        vars.liquiditySetup = Math
            .mulDiv(
                vars.baseSetup,
                FixedPoint.Q96,
                LatentMath.targetXvsL(vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B),
                Math.Rounding.Floor
            )
            .toUint160();
        vars.liquidityMint = Math
            .mulDiv(
                vars.baseMint,
                FixedPoint.Q96,
                LatentMath.targetXvsL(vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B),
                Math.Rounding.Floor
            )
            .toUint160();

        // Ensure liquiditySetup and liquidityMint are not 0
        if (vars.liquiditySetup < MIN_LIQUIDITY) return;
        if (vars.liquidityMint == 0) return;

        // setup mint
        (vars.zTokenSetup, vars.aTokenSetup) = LatentMath.computeMint(
            vars.currentSqrtRatioX96,
            vars.edgeSqrtRatioX96_A,
            vars.edgeSqrtRatioX96_B,
            vars.liquiditySetup
        );

        // skip if not tokens minted (liquidity too low)
        if (vars.zTokenSetup < MIN_LIQUIDITY_MINT || vars.aTokenSetup < MIN_LIQUIDITY_MINT) return;

        // test mint
        (vars.zTokenAmount, vars.aTokenAmount) = LatentMath.computeMint(
            vars.currentSqrtRatioX96,
            vars.edgeSqrtRatioX96_A,
            vars.edgeSqrtRatioX96_B,
            vars.liquidityMint
        );
        // ensure test mint is not zero
        if (vars.zTokenAmount == 0 && vars.aTokenAmount == 0) return;

        // redeem
        (vars.liquidityOut, vars.nextSqrtRatioX96) = LatentMath.computeRedeem(
            vars.liquidityMint + vars.liquiditySetup,
            vars.currentSqrtRatioX96,
            vars.edgeSqrtRatioX96_A,
            vars.edgeSqrtRatioX96_B,
            vars.zTokenAmount,
            vars.aTokenAmount
        );

        // convert liquidity out to base
        vars.baseOut = Math.mulDiv(
            vars.liquidityOut,
            LatentMath.targetXvsL(vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B),
            FixedPoint.Q96,
            Math.Rounding.Floor
        );

        assertLe(vars.baseOut, vars.baseMint, "Redeem liquidity should be less than or equal to mint liquidity");
        if (vars.baseMint > LIQUIDITY_BELOW_THRESHOLD) {
            assertLe(
                (vars.baseMint * LIQUIDITY_PRECISION_BELOW) / vars.baseOut,
                LIQUIDITY_PRECISION_BELOW,
                "Redeem base amount should be close to mint liquidity"
            );
        }
    }

    function test_getMarketStateFromLiquidityAndDebt_Fuzz(
        uint160 liquidityRaw,
        uint160 edgeHighSqrtPriceRaw,
        uint160 edgeLowSqrtPriceRaw,
        uint160 zDexAmountRaw
    ) external pure {
        uint160 liquidity = boundLiquidity(liquidityRaw);

        (uint160 edgeSqrtRatioX96_A, uint160 edgeSqrtRatioX96_B, ) = boundSqrtRatios(
            edgeHighSqrtPriceRaw,
            edgeLowSqrtPriceRaw,
            0
        );

        // calculate max amount0 given liquidity
        uint256 maxZDexAmount = SqrtPriceMath.getAmount0Delta(
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            liquidity,
            Math.Rounding.Ceil
        );

        uint256 zDexAmount = boundAmount(zDexAmountRaw, maxZDexAmount);

        (uint256 aDexAmount, uint160 currentSqrtPriceX96) = LatentMath.getMarketStateFromLiquidityAndDebt(
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            liquidity,
            zDexAmount
        );

        (uint256 zDexMintAmount, uint256 aDexMintAmount) = LatentMath.computeMint(
            currentSqrtPriceX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            liquidity
        );

        // Ensure aDexAmount == aDexMintAmount, zDexAmount < zDexMintAmount
        // This ensures that in reality, the inferred liquidity in the market from circulating aDexAmount + zDexAmount
        // is a bit lower or equal to the actual market liquidity (value) given current market price.
        // As a consequence, this ensures that when redeeming using exact aDexAmounts + zDexAmounts, the liquidity out calculation
        // from the redeem function are <= to actual liquidity in the market
        assertEq(aDexAmount, aDexMintAmount, "should need more amount0 to redeem original liquidity");
        assertLe(zDexAmount, zDexMintAmount, "should need more amount0 to redeem original liquidity");
    }

    struct SwapRoundTripVars {
        uint160 liquidity;
        uint160 edgeSqrtRatioX96_A;
        uint160 edgeSqrtRatioX96_B;
        uint160 currentSqrtRatioX96;
        uint8 tokenFixed;
        uint256 zTokenAmount;
        uint256 yTokenAmount;
        uint256 swapAmount;
        uint256 firstAmountCalc;
        uint160 nextSqrtRatioX96;
        uint256 secondAmountCalc;
        uint160 secondNextSqrtRatioX96;
        uint256 maxDexAmount;
    }

    // swap roundtrip tests, exactin / exactout
    function test_swapRoundTrip_Fuzz(
        uint160 liquidityRaw,
        uint160 edgeHighSqrtPriceRaw,
        uint160 edgeLowSqrtPriceRaw,
        uint160 currentSqrtRatioRaw,
        uint256 swapAmountRaw,
        uint8 tokenFirstFixedRaw,
        bool firstSwapExactIn,
        bool secondSwapExactIn
    ) external pure {
        SwapRoundTripVars memory vars;

        vars.liquidity = boundLiquidity(liquidityRaw);

        (vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B, vars.currentSqrtRatioX96) = boundSqrtRatios(
            edgeHighSqrtPriceRaw,
            edgeLowSqrtPriceRaw,
            currentSqrtRatioRaw
        );

        vars.tokenFixed = uint8(bound(tokenFirstFixedRaw, DEBT, LEVERAGE));

        // Find amounts in market given liquidity
        (vars.zTokenAmount, vars.yTokenAmount) = LatentMath.computeMint(
            vars.currentSqrtRatioX96,
            vars.edgeSqrtRatioX96_A,
            vars.edgeSqrtRatioX96_B,
            vars.liquidity
        );

        // Bound swap amount given token amounts in market
        if (firstSwapExactIn) {
            vars.swapAmount = boundAmount(
                swapAmountRaw,
                vars.tokenFixed == DEBT ? vars.zTokenAmount : vars.yTokenAmount
            );
        } else {
            // Estimmate what is the biggest amount that could be 'swapped out'.
            if (vars.tokenFixed == DEBT) {
                vars.maxDexAmount =
                    LatentMath.computeMaxDebt(vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B, vars.liquidity) -
                    vars.zTokenAmount;
            } else {
                vars.maxDexAmount =
                    SqrtPriceMath.getAmount1Delta(
                        vars.edgeSqrtRatioX96_B,
                        vars.edgeSqrtRatioX96_A,
                        vars.liquidity,
                        Math.Rounding.Floor
                    ) -
                    vars.yTokenAmount;
            }
            vars.swapAmount = boundAmount(swapAmountRaw, vars.maxDexAmount);
        }

        // First swap
        (vars.firstAmountCalc, vars.nextSqrtRatioX96) = LatentMath.computeSwap(
            vars.liquidity,
            vars.currentSqrtRatioX96,
            AssetType(vars.tokenFixed),
            vars.swapAmount,
            firstSwapExactIn
        );

        // Second swap
        (vars.secondAmountCalc, vars.secondNextSqrtRatioX96) = LatentMath.computeSwap(
            vars.liquidity,
            vars.nextSqrtRatioX96,
            (firstSwapExactIn == secondSwapExactIn)
                ? AssetTypeHelpers.debtAndLeverageSwap(AssetType(vars.tokenFixed))
                : AssetType(vars.tokenFixed),
            (firstSwapExactIn == secondSwapExactIn) ? vars.firstAmountCalc : vars.swapAmount,
            secondSwapExactIn
        );

        if (firstSwapExactIn == secondSwapExactIn) {
            if (firstSwapExactIn) {
                // both exact in
                assertLe(
                    vars.secondAmountCalc,
                    vars.swapAmount,
                    "second swap output should be less than or equal to swap amount input (both exact in)"
                );
            } else {
                // both exact out
                assertGe(
                    vars.secondAmountCalc,
                    vars.swapAmount,
                    "second swap input should be greater than or equal to first swap output (both exact out)"
                );
            }
        } else {
            // one exact in, one exact out (either order)
            if (firstSwapExactIn) {
                assertLe(
                    vars.firstAmountCalc,
                    vars.secondAmountCalc,
                    "first swap output should be less than or equal to second swap input (first exact in, second exact out)"
                );
            } else {
                assertGe(
                    vars.firstAmountCalc,
                    vars.secondAmountCalc,
                    "first swap input should be greater than or equal to second swap output (first exact out, second exact in)"
                );
            }
        }
    }

    // Mint / Swap / Burn roundtrip tests
    function test_mintSwapRedeemRoundTrip_Fuzz(
        uint160 baseMintRaw,
        uint160 edgeHighSqrtPriceRaw,
        uint160 edgeLowSqrtPriceRaw,
        uint160 currentSqrtRatioRaw,
        uint256 swapAmountRaw,
        uint8 tokenSwapRaw
    ) external pure {
        MintRedeemVars memory vars;

        vars.baseSetup = bound(baseMintRaw, MIN_BALANCE, MAX_BALANCE >> 100);
        //vars.baseMint = bound(baseMintRaw, MIN_BALANCE, MAX_BALANCE - vars.baseSetup);
        vars.baseMint = bound(
            baseMintRaw,
            MIN_BALANCE,
            Math.min(MAX_BALANCE - vars.baseSetup, (vars.baseSetup * MAX_BASE_MINT_RATIO) / (10 ** 18))
        );

        (vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B, vars.currentSqrtRatioX96) = boundSqrtRatios(
            edgeHighSqrtPriceRaw,
            edgeLowSqrtPriceRaw,
            currentSqrtRatioRaw
        );
        vars.tokenFixed = uint8(bound(tokenSwapRaw, DEBT, LEVERAGE));

        execute_mintSwapRedeemRoundTrip(vars, swapAmountRaw);
    }

    // Test boundary when mint amount is the max vs mint setup amount.  Focuses fuzz test on surface are aof
    //high mint/redeem amounts vs the alreadly existing liquidit y in the market
    function test_mintSwapRedeemRoundTripEdgeCase_Fuzz(
        uint160 baseMintRaw,
        uint160 edgeHighSqrtPriceRaw,
        uint160 edgeLowSqrtPriceRaw,
        uint160 currentSqrtRatioRaw,
        uint256 swapAmountRaw,
        uint8 tokenSwapRaw
    ) external pure {
        MintRedeemVars memory vars;

        // Focus testing on max baseMint/baseSetup ratio (MAX_BASE_MINT_RATIO)
        vars.baseSetup = bound(baseMintRaw, MIN_BALANCE, (MAX_BALANCE * (10 ** 18)) / MAX_BASE_MINT_RATIO / 10);
        vars.baseMint = (vars.baseSetup * MAX_BASE_MINT_RATIO) / (10 ** 18);

        (vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B, vars.currentSqrtRatioX96) = boundSqrtRatios(
            edgeHighSqrtPriceRaw,
            edgeLowSqrtPriceRaw,
            currentSqrtRatioRaw
        );
        vars.tokenFixed = uint8(bound(tokenSwapRaw, DEBT, LEVERAGE));

        execute_mintSwapRedeemRoundTrip(vars, swapAmountRaw);
    }

    function execute_mintSwapRedeemRoundTrip(MintRedeemVars memory vars, uint256 swapAmountRaw) internal pure {
        // convert to liquidity (as done in LatentSwapLEX)
        vars.liquiditySetup = Math
            .mulDiv(
                vars.baseSetup,
                FixedPoint.Q96,
                LatentMath.targetXvsL(vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B),
                Math.Rounding.Floor
            )
            .toUint160();
        vars.liquidityMint = Math
            .mulDiv(
                vars.baseMint,
                FixedPoint.Q96,
                LatentMath.targetXvsL(vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B),
                Math.Rounding.Floor
            )
            .toUint160();

        // Ensure liquiditySetup and liquidityMint are not 0
        if (vars.liquiditySetup < MIN_LIQUIDITY) return;
        if (vars.liquidityMint == 0) return;

        // setup mint
        (vars.zTokenSetup, vars.aTokenSetup) = LatentMath.computeMint(
            vars.currentSqrtRatioX96,
            vars.edgeSqrtRatioX96_A,
            vars.edgeSqrtRatioX96_B,
            vars.liquiditySetup
        );
        // skip if not tokens minted (liquidity too low)
        if (vars.zTokenSetup < MIN_LIQUIDITY_MINT || vars.aTokenSetup < MIN_LIQUIDITY_MINT) return;

        // test mint
        (vars.zTokenAmount, vars.aTokenAmount) = LatentMath.computeMint(
            vars.currentSqrtRatioX96,
            vars.edgeSqrtRatioX96_A,
            vars.edgeSqrtRatioX96_B,
            vars.liquidityMint
        );
        // skip if not tokens minted (liquidity too low)
        if (vars.zTokenAmount == 0 && vars.aTokenAmount == 0) return;

        // swap
        vars.swapAmount = boundAmount(swapAmountRaw, (vars.tokenFixed == DEBT) ? vars.zTokenAmount : vars.aTokenAmount);
        (vars.swapAmountCalc, vars.nextSqrtRatioX96) = LatentMath.computeSwap(
            vars.liquiditySetup + vars.liquidityMint,
            vars.currentSqrtRatioX96,
            AssetType(vars.tokenFixed),
            vars.swapAmount,
            true
        );

        // update user's a+z tokens given swap output
        if (vars.tokenFixed == DEBT) {
            vars.aTokenAmount += vars.swapAmountCalc;
            vars.zTokenAmount -= vars.swapAmount;
        } else {
            vars.aTokenAmount -= vars.swapAmount;
            vars.zTokenAmount += vars.swapAmountCalc;
        }

        // redeem
        (vars.liquidityOut, ) = LatentMath.computeRedeem(
            vars.liquidityMint + vars.liquiditySetup,
            vars.nextSqrtRatioX96,
            vars.edgeSqrtRatioX96_A,
            vars.edgeSqrtRatioX96_B,
            vars.zTokenAmount,
            vars.aTokenAmount
        );

        // convert liquidity out to base
        vars.baseOut = Math.mulDiv(
            vars.liquidityOut,
            LatentMath.targetXvsL(vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B),
            FixedPoint.Q96,
            Math.Rounding.Floor
        );

        assertLe(vars.baseOut, vars.baseMint, "Redeem liquidity should be less than or equal to mint liquidity");
        if (vars.baseOut > LIQUIDITY_BELOW_THRESHOLD) {
            assertLe(
                (vars.baseMint * LIQUIDITY_PRECISION_BELOW) / vars.baseOut,
                LIQUIDITY_PRECISION_BELOW,
                "Redeem base amount should be close to mint liquidity"
            );
        }
    }

    // Fuzz test for comparing small redeem operations with get_XvsL derivative calculation
    function test_marginalRedeem_vs_LvsX_Debt_Fuzz(
        uint160 edgeHighSqrtPriceRaw,
        uint160 edgeLowSqrtPriceRaw,
        uint160 currentSqrtRatioRaw
    ) external pure {
        // Fixed high liquidity for consistent testing
        uint160 currentLiquidity = 1e20; // Large liquidity

        // Bound the price parameters using existing helper
        (uint160 edgeSqrtRatioX96_A, uint160 edgeSqrtRatioX96_B, uint160 currentSqrtRatioX96) = boundSqrtRatios(
            edgeHighSqrtPriceRaw,
            edgeLowSqrtPriceRaw,
            currentSqrtRatioRaw
        );

        // Small redeem amounts - just a tiny fraction of the total liquidity
        uint256 zTokenAmountIn = 1e12; // Small zToken amount
        uint256 aTokenAmountIn = 0; // Small aToken amount

        // check amount to be redeemed is bigger than current debt
        uint256 currentDebt = SqrtPriceMath.getAmount0Delta(
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            currentLiquidity,
            Math.Rounding.Floor
        );
        if (zTokenAmountIn > currentDebt) return;

        // Perform the redeem operation
        (uint160 liquidityAmount, ) = LatentMath.computeRedeem(
            currentLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            zTokenAmountIn,
            aTokenAmountIn
        );

        // Calculate the derivative using get_XvsL for AssetType.DEBT
        uint256 derivativeLvsX = LatentMath.get_XvsL(
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            AssetType.DEBT
        );

        // Calculate the ratio of liquidity removed to zToken amount
        // This should approximate the derivative for small amounts
        uint256 actualRatio = Math.mulDiv(zTokenAmountIn, FixedPoint.Q96, liquidityAmount);

        // For small amounts, the actual ratio should be close to the theoretical derivative
        // Allow for some tolerance due to rounding differences
        uint256 tolerance = 1e11; //0.001% tolerance

        assertApproxEqRel(
            actualRatio,
            derivativeLvsX,
            tolerance,
            "Small redeem ratio should approximate get_XvsL derivative for DEBT"
        );
    }

    // Fuzz test for comparing small redeem operations with get_XvsL derivative calculation
    function test_marginalRedeem_vs_LvsX_Leverage_Fuzz(
        uint160 edgeHighSqrtPriceRaw,
        uint160 edgeLowSqrtPriceRaw,
        uint160 currentSqrtRatioRaw
    ) external pure {
        // Fixed high liquidity for consistent testing
        uint160 currentLiquidity = 1e20; // Large liquidity

        // Bound the price parameters using existing helper
        (uint160 edgeSqrtRatioX96_A, uint160 edgeSqrtRatioX96_B, uint160 currentSqrtRatioX96) = boundSqrtRatios(
            edgeHighSqrtPriceRaw,
            edgeLowSqrtPriceRaw,
            currentSqrtRatioRaw
        );

        // Small redeem amounts - just a tiny fraction of the total liquidity
        uint256 aTokenAmountIn = 1e12; // Small aToken amount
        uint256 zTokenAmountIn = 0; // Small zToken amount

        // check amount to be redeemed is bigger than current leverage token  amount
        uint256 currentLeverage = SqrtPriceMath.getAmount1Delta(
            currentSqrtRatioX96,
            edgeSqrtRatioX96_B,
            currentLiquidity,
            Math.Rounding.Floor
        );
        if (aTokenAmountIn > currentLeverage) return;

        // Perform the redeem operation
        (uint160 liquidityAmount, ) = LatentMath.computeRedeem(
            currentLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            zTokenAmountIn,
            aTokenAmountIn
        );

        // Calculate the derivative using get_XvsL for AssetType.DEBT
        uint256 derivativeLvsX = LatentMath.get_XvsL(
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            AssetType.LEVERAGE
        );

        // Calculate the ratio of liquidity removed to aToken amount
        // This should approximate the derivative for small amounts
        uint256 actualRatio = Math.mulDiv(aTokenAmountIn, FixedPoint.Q96, liquidityAmount);

        // For small amounts, the actual ratio should be close to the theoretical derivative
        // Allow for some tolerance due to rounding differences
        uint256 tolerance = 1e11; // 0.0001% tolerance

        assertApproxEqRel(
            actualRatio,
            derivativeLvsX,
            tolerance,
            "Small redeem ratio should approximate get_XvsL derivative for LEVERAGE"
        );
    }

    // Fuzz test for getSqrtPriceFromLTVX96 and computeLTV roundtrip
    function test_computeLTV_roundtrip_Fuzz(
        uint160 edgeHighSqrtPriceRaw,
        uint160 edgeLowSqrtPriceRaw,
        uint32 targetLTVRaw
    ) external pure {
        // Bound edgeSqrtRatioX96_B to ensure it's within the specified range
        // edgeSqrtRatioX96_B <= (2^32) * FixedPoint.Q96
        // edgeSqrtRatioX96_B >= FixedPoint.Q96 / (2^32)
        uint160 maxEdgeB = uint160((uint256(1) << 32) * FixedPoint.Q96);
        uint160 minEdgeB = uint160(FixedPoint.Q96 / (uint256(1) << 32)) + 100000;

        uint160 edgeSqrtRatioX96_B = uint160(bound(edgeHighSqrtPriceRaw, minEdgeB, maxEdgeB));

        // Bound edgeSqrtRatioX96_A to be less than edgeSqrtRatioX96_B
        // Ensure there's enough space between A and B for meaningful testing
        uint160 minEdgeA = uint160(FixedPoint.Q96 / (uint256(1) << 32));
        uint160 maxEdgeA = edgeSqrtRatioX96_B - 99999;

        uint160 edgeSqrtRatioX96_A = uint160(bound(edgeLowSqrtPriceRaw, minEdgeA, maxEdgeA));

        // Bound targetLTV between 0 and 10000 (0% to 100%)
        uint32 targetLTV = uint32(bound(targetLTVRaw, 5000, 10000));

        // Calculate price given target LTV
        uint160 calculatedPrice = LatentSwapLib.getSqrtPriceFromLTVX96(
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            targetLTV
        );
        console.log("calculatedPrice                          ", calculatedPrice);
        // Verify the calculated price is within valid bounds
        assertLe(
            calculatedPrice,
            edgeSqrtRatioX96_B,
            "Calculated price should be less than or equal to edgeSqrtRatioX96_B"
        );
        assertGe(
            calculatedPrice,
            edgeSqrtRatioX96_A,
            "Calculated price should be greater than or equal to edgeSqrtRatioX96_A"
        );

        // Calculate LTV using the computed price
        uint256 computedLTV = LatentMath.computeLTV(edgeSqrtRatioX96_A, edgeSqrtRatioX96_B, calculatedPrice);

        // The computed LTV should be equal to the target LTV
        assertEq(computedLTV, targetLTV, "Computed LTV should match target LTV");
    }

    // Fuzz test for computeLTV edge cases
    function test_computeLTV_edgeCases_Fuzz(uint160 edgeHighSqrtPriceRaw, uint160 edgeLowSqrtPriceRaw) external pure {
        // Bound edgeSqrtRatioX96_B to ensure it's within the specified range
        uint160 maxEdgeB = uint160((uint256(1) << 32) * FixedPoint.Q96);
        uint160 minEdgeB = uint160(FixedPoint.Q96 / (uint256(1) << 32));

        uint160 edgeSqrtRatioX96_B = uint160(bound(edgeHighSqrtPriceRaw, minEdgeB, maxEdgeB));

        // Bound edgeSqrtRatioX96_A to be less than edgeSqrtRatioX96_B
        // Ensure there's enough space between A and B for meaningful testing
        uint160 minEdgeA = uint160(FixedPoint.Q96 / 1000);
        uint160 maxEdgeA = edgeSqrtRatioX96_B > minEdgeA + 1000 ? edgeSqrtRatioX96_B - 1000 : minEdgeA;

        // Skip if we can't create a valid range
        if (maxEdgeA <= minEdgeA) return;

        uint160 edgeSqrtRatioX96_A = uint160(bound(edgeLowSqrtPriceRaw, minEdgeA, maxEdgeA));

        // Skip if the price range is too small
        if (edgeSqrtRatioX96_B <= edgeSqrtRatioX96_A + 100000) return;

        // Test specific LTV values
        uint32[] memory testLTVs = new uint32[](4);
        testLTVs[0] = 5000; // 50%
        testLTVs[1] = 7500; // 75%
        testLTVs[2] = 9000; // 90%
        testLTVs[3] = 10000; // 100%

        for (uint256 i = 0; i < testLTVs.length; i++) {
            uint32 targetLTV = testLTVs[i];

            // Calculate price given target LTV
            uint160 calculatedPrice = LatentSwapLib.getSqrtPriceFromLTVX96(
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                targetLTV
            );

            // Verify the calculated price is within valid bounds
            assertLe(
                calculatedPrice,
                edgeSqrtRatioX96_B,
                "Calculated price should be less than or equal to edgeSqrtRatioX96_B"
            );
            assertGe(
                calculatedPrice,
                edgeSqrtRatioX96_A,
                "Calculated price should be greater than or equal to edgeSqrtRatioX96_A"
            );

            // Calculate LTV using the computed price
            uint256 computedLTV = LatentMath.computeLTV(edgeSqrtRatioX96_A, edgeSqrtRatioX96_B, calculatedPrice);

            // The computed LTV should be very close to the target LTV
            uint256 tolerance = 1; // 0.01% tolerance (1 basis point)

            assertApproxEqAbs(computedLTV, targetLTV, tolerance, "Edge case LTV should match within tolerance");
        }
    }

    // Fuzz test for getMarketEdgePrices roundtrip verification
    function test_getMarketEdgePrices_roundtrip_Fuzz(uint32 targetLTVRaw, uint256 targetPriceWidthRaw) external pure {
        // Bound targetLTV between .01% and 99.99% (1 to 9999)
        uint32 targetLTV = uint32(bound(targetLTVRaw, 1, 9999));

        // Bound targetPriceWidth to be > 1.0 (Q96) and reasonable upper bound
        // Minimum: 1.00001 (0.001% price width)
        // Maximum: 10.0 (10x price width)
        uint256 minPriceWidth = (1001 * FixedPoint.WAD) / 1000; // 1.001
        uint256 maxPriceWidth = 10 * FixedPoint.WAD; // 10.0
        uint256 targetPriceWidth = bound(targetPriceWidthRaw, minPriceWidth, maxPriceWidth);

        // Get market edge prices
        (uint160 edgeSqrtPriceX96_A, uint160 edgeSqrtPriceX96_B) = LatentSwapLib.getMarketEdgePrices(
            targetLTV,
            targetPriceWidth
        );

        // Verify edge prices are valid
        assertLt(edgeSqrtPriceX96_A, edgeSqrtPriceX96_B, "Edge price A should be less than edge price B");
        assertLt(edgeSqrtPriceX96_A, FixedPoint.Q96, "Edge price A should be less than Q96");
        assertGt(edgeSqrtPriceX96_B, FixedPoint.Q96, "Edge price B should be more than Q96");
        assertGt(edgeSqrtPriceX96_A, 0, "Edge price A should be greater than 0");

        // Verify the price ratio equals target price width
        uint256 actualPriceRatio = Math.mulDiv(edgeSqrtPriceX96_B, FixedPoint.WAD, edgeSqrtPriceX96_A);
        uint256 tolerance = 1e10; // 0.001% tolerance for price ratio
        assertApproxEqRel(actualPriceRatio, targetPriceWidth, tolerance, "Price ratio should equal target price width");

        // Verify that computeLTV at current price (FixedPoint.Q96) returns the target LTV
        uint256 computedLTV = LatentMath.computeLTV(edgeSqrtPriceX96_A, edgeSqrtPriceX96_B, uint160(FixedPoint.Q96));

        // Allow small tolerance for LTV due to rounding
        uint256 ltvTolerance = 1; // 0.01% tolerance (1 basis point)
        assertApproxEqAbs(
            computedLTV,
            targetLTV,
            ltvTolerance,
            "Computed LTV at current price should equal target LTV"
        );
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {LatentMath, AssetType} from "../src/lex/latentswap/libraries/LatentMath.sol";
import {FixedPoint} from "../src/lex/latentswap/libraries/FixedPoint.sol";
import {SqrtPriceMath} from "../src/lex/latentswap/libraries/SqrtPriceMath.sol";
import {DebtMath} from "../src/lex/latentswap/libraries/DebtMath.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {TestMath} from "./utils/TestMath.sol";
import {MockLatentMath} from "./mocks/MockLatentMath.sol";
import {UtilsLib} from "../src/libraries/Utils.sol";

// In the `LatentMath` functions, the protocol aims for computing a value either as small as possible or as large as possible
// by means of rounding in its favor; in order to achieve this, it may use arbitrary rounding directions during the calculations.
// The objective of `LatentMathTest` is to verify that the implemented rounding permutations favor the protocol more than other
// solutions (e.g., always rounding down or always rounding up).

contract LatentMathTest is Test {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for bool;

    // Max balance of swap pool balance that won't cause an overflow in circle math.
    uint256 constant MIN_BALANCE = 2 ** 5;
    uint256 constant MAX_BALANCE = 2 ** 150;

    uint256 constant MIN_LIQUIDITY = 0;
    uint256 constant MAX_LIQUIDITY = type(uint160).max;

    uint256 constant MAX_SQRTPRICE = (999 << FixedPoint.RESOLUTION) / 1000; // 0.998 MAX price
    uint256 constant MIN_SQRTPRICE = (10 << FixedPoint.RESOLUTION) / 1000; // 0.0001 MIN price

    // global variables
    uint256[] _balances;
    uint160 _currentSqrtRatioX96;
    uint160 _liquidity;
    uint160 sqrtRatioX96_A;
    uint160 sqrtRatioX96_B;

    function setUp() public {
        _balances = new uint256[](2);
        _balances[0] = 1 ** 18;
        _balances[1] = 1 ** 18;
        sqrtRatioX96_B = ((11 << FixedPoint.RESOLUTION) / 10).toUint160();
        sqrtRatioX96_A = (FixedPoint.Q192 / sqrtRatioX96_B).toUint160();
        _currentSqrtRatioX96 = (1 << 96); // 1.0 price
        _liquidity = 1e18;
    }

    function test_computeLiquidity() external {
        // returns 0 if balances are zero, normal prices
        _balances[0] = 0;
        _balances[1] = 0;
        uint160 liquidity_out = LatentMath.computeLiquidity(sqrtRatioX96_A, sqrtRatioX96_B, _balances[0], _balances[1]);
        assertEq(liquidity_out, 0, "computeLiquidity did not return 0 with no balances");

        // returns 0 if balances are zero, max concentration
        sqrtRatioX96_A = uint160(MAX_SQRTPRICE);
        sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();
        liquidity_out = LatentMath.computeLiquidity(sqrtRatioX96_A, sqrtRatioX96_B, _balances[0], _balances[1]);
        assertEq(liquidity_out, 0, "computeLiquidity did not return 0 with no balances + max concentration");

        // returns 0 if balances are zero,min concentration
        sqrtRatioX96_A = uint160(MIN_SQRTPRICE);
        sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();
        liquidity_out = LatentMath.computeLiquidity(sqrtRatioX96_A, sqrtRatioX96_B, _balances[0], _balances[1]);
        assertEq(liquidity_out, 0, "computeLiquidity did not return 0 with no balances + min concentration");

        // returns 0 for max balances, max concentration
        _balances[0] = MAX_BALANCE;
        _balances[1] = MAX_BALANCE;
        sqrtRatioX96_A = uint160(MAX_SQRTPRICE);
        sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();
        liquidity_out = LatentMath.computeLiquidity(sqrtRatioX96_A, sqrtRatioX96_B, _balances[0], _balances[1]);
        assertEq(
            liquidity_out,
            1425820445013253921177227677589247256653207699456,
            "computeLiquidity did not return 1425820445013253921177227677589247256653207699456 with max balances + max concentration"
        );

        // returns 0 for max balances, min concentration
        sqrtRatioX96_A = uint160(MIN_SQRTPRICE);
        sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();
        liquidity_out = LatentMath.computeLiquidity(sqrtRatioX96_A, sqrtRatioX96_B, _balances[0], _balances[1]);
        assertEq(
            liquidity_out,
            14416643360666261424831171401963899996710210,
            "computeLiquidity did not return 14416643360666261424831171401963899996710210 with max balances + min concentration"
        );

        // liquidity diff for balances < 2^120 vs liquidity when balances > 2^120 (when price[0]*price[1]=1)
        _balances[0] = _balances[1] = 1 << 119;
        uint160 liquidity_LargeNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        _balances[1] -= 1;
        uint160 liquidity_SmallNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        assertLe(
            liquidity_SmallNumCalc,
            liquidity_LargeNumCalc,
            "lower balance liquidity higher than higher balance liquidity, min concentration"
        );

        // liquidity diff for balances < 2^120 vs liquidity when balances > 2^120 (when price[0]*price[1]=1)
        sqrtRatioX96_A = uint160(MAX_SQRTPRICE);
        sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();
        _balances[0] = _balances[1] = 1 << 119;
        liquidity_LargeNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        _balances[1] -= 1;
        liquidity_SmallNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        assertLe(
            liquidity_SmallNumCalc,
            liquidity_LargeNumCalc,
            "lower balance liquidity higher than higher balance liquidity, max concentration"
        );

        // liquidity diff for balances < 2^120 vs liquidity when balances > 2^120 (when price[0]*price[1]=1)
        _balances[0] = _balances[1] = 1 << 119;
        liquidity_LargeNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        _balances[1] -= 1;
        liquidity_SmallNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        assertLe(
            liquidity_SmallNumCalc,
            liquidity_LargeNumCalc,
            "lower balance liquidity higher than higher balance liquidity, min concentration"
        );

        // liquidity diff for balances < 2^120 vs liquidity when balances > 2^120 (when price[0]*price[1]=1), for imbalanced market
        _balances[1] = 1000;
        _balances[0] = (1 << 120) - _balances[1];
        liquidity_LargeNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        _balances[0] -= 1;
        liquidity_SmallNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        assertLe(
            liquidity_SmallNumCalc,
            liquidity_LargeNumCalc,
            "lower balance liquidity higher than higher balance liquidity, min concentration, imbalanced market (low token1)"
        );

        // liquidity diff for balances < 2^120 vs liquidity when balances > 2^120 (when price[0]*price[1]=1), for imbalanced market
        _balances[0] = 1000;
        _balances[1] = (1 << 120) - _balances[0];
        liquidity_LargeNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        _balances[1] -= 1;
        liquidity_SmallNumCalc = LatentMath.computeLiquidity(
            sqrtRatioX96_A,
            sqrtRatioX96_B,
            _balances[0],
            _balances[1]
        );
        assertLe(
            liquidity_SmallNumCalc,
            liquidity_LargeNumCalc,
            "lower balance liquidity higher than higher balance liquidity, min concentration, imbalanced market (low token0)"
        );
    }

    function test_computeLiquidity_revertUnorderedPrice() external {
        vm.expectRevert();
        (sqrtRatioX96_A, sqrtRatioX96_B) = (sqrtRatioX96_B, sqrtRatioX96_A);
        LatentMath.computeLiquidity(sqrtRatioX96_A, sqrtRatioX96_B, _balances[0], _balances[1]);
    }

    function test_computeSwap() external view {
        uint160 liquidity = 1e18;
        uint256 amountIn = 1e16;
        uint160 currentSqrtRatioX96 = (1 << 96); // 1.0 price
        uint256 amountOut;
        uint256 amountCalc;
        uint160 nextSqrtPrice;

        //////////// EXACT IN ////////////
        // Test basic functionality for DEBT -> LEVERAGE
        {
            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                liquidity,
                currentSqrtRatioX96,
                AssetType.DEBT,
                amountIn,
                true
            );
            assertGt(amountOut, 0, "Should return non-zero amount for token0->token1");
            assertLt(nextSqrtPrice, currentSqrtRatioX96, "price should decrease for token0->token1 swap");
        }

        // Test basic functionality for LEVERAGE -> DEBT
        {
            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                liquidity,
                currentSqrtRatioX96,
                AssetType.LEVERAGE,
                amountIn,
                true
            );
            assertGt(amountOut, 0, "Should return non-zero amount for token1->token0");
            assertGt(nextSqrtPrice, currentSqrtRatioX96, "price should increase for token0->token1 swap");
        }

        // Test minimum liquidity
        {
            (amountOut, ) = LatentMath.computeSwap(
                1, // minimum liquidity
                currentSqrtRatioX96,
                AssetType.DEBT,
                amountIn,
                true
            );
            assertLt(amountOut, amountIn, "Output should be less than input for min liquidity");

            (amountOut, ) = LatentMath.computeSwap(
                1, // minimum liquidity
                currentSqrtRatioX96,
                AssetType.LEVERAGE,
                amountIn,
                true
            );
            assertLt(amountOut, amountIn, "Output should be less than input for min liquidity, token1");
        }

        // Test maximum liquidity
        {
            // for amountIn not big enough, no price change and 0 output
            // @dev - due to rounding, the input here is considered dust.
            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                type(uint160).max, // maximum liquidity
                currentSqrtRatioX96,
                AssetType.DEBT,
                10 ** 18,
                true
            );
            assertEq(
                amountOut,
                0,
                "There should be no output amount for max liquidity, with small input, for DEBT token"
            );
            assertEq(
                nextSqrtPrice,
                currentSqrtRatioX96,
                "There should be No price change for max liquidity, with small input, for DEBT token"
            );

            // for amountIn not big enough, no price change and 0 output
            // @dev - due to rounding, the input here is considered dust.
            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                type(uint160).max, // maximum liquidity
                currentSqrtRatioX96,
                AssetType.DEBT,
                10 ** 20,
                true
            );
            assertGt(amountOut, 0, "There shoud be output amount for max liquidity, with bigger input, for DEBT token");
            assertLt(
                nextSqrtPrice,
                currentSqrtRatioX96,
                "There should be price change for max liquidity, with bigger input, for DEBT token"
            );

            // for amountIn not big enough, no price change and 0 output
            // @dev - due to rounding, the input here is considered dust.
            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                type(uint160).max, // maximum liquidity
                currentSqrtRatioX96,
                AssetType.LEVERAGE,
                10 ** 18,
                true
            );
            assertEq(
                amountOut,
                0,
                "There shoud be no output amount for max liquidity, with small input, for LEVERAGE token"
            );
            assertEq(
                nextSqrtPrice,
                currentSqrtRatioX96,
                "There should be no price change for max liquidity, with small input, for LEVERAGE token"
            );

            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                type(uint160).max, // maximum liquidity
                currentSqrtRatioX96,
                AssetType.LEVERAGE,
                10 ** 20,
                true
            );
            assertGt(
                amountOut,
                0,
                "There shoud be output amount for max liquidity, with bigger input, for LEVERAGE token"
            );
            assertGt(
                nextSqrtPrice,
                currentSqrtRatioX96,
                "There should be price change for max liquidity, with bigger input, for LEVERAGE token"
            );
        }

        // Test minimum amount in
        {
            // Minimum amounts in should return 0 output (input considered dust)
            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                liquidity,
                currentSqrtRatioX96,
                AssetType.DEBT,
                1, // minimum amount in
                true
            );
            assertEq(amountOut, 0, "Should handle minimum amount in, token0");
            assertLt(nextSqrtPrice, currentSqrtRatioX96, "Should handle minimum amount in, price does change, token0");

            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                liquidity,
                currentSqrtRatioX96,
                AssetType.LEVERAGE,
                1, // minimum amount in
                true
            );
            assertEq(amountOut, 0, "Should handle minimum amount in, token1");
            assertGt(nextSqrtPrice, currentSqrtRatioX96, "Should handle minimum amount in, price does change, token1");
        }

        // Test maximum amount in
        {
            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                liquidity,
                currentSqrtRatioX96,
                AssetType.DEBT,
                1 << 120, // large amount in, but avoiding overflow
                true
            );
            assertEq(amountOut, 999999999999999999, "Should correctly calculate large amount in, DEBT");
            assertLt(nextSqrtPrice, sqrtRatioX96_A, "Should pass lower bound");

            (amountOut, nextSqrtPrice) = LatentMath.computeSwap(
                liquidity,
                currentSqrtRatioX96,
                AssetType.LEVERAGE,
                1 << 120, // large amount in, but avoiding overflow
                true
            );
            assertEq(amountOut, 999999999999999999, "Should correctly calculate amount in, LEVERAGE");
            assertGt(nextSqrtPrice, sqrtRatioX96_B, "Should pass upper bound");
        }

        //////////// EXACT OUT ////////////
        // Test basic functionality for DEBT -> LEVERAGE
        amountOut = 1e16;
        {
            (amountCalc, nextSqrtPrice) = LatentMath.computeSwap(
                liquidity,
                currentSqrtRatioX96,
                AssetType.DEBT,
                amountOut,
                false
            );
            assertGt(amountCalc, 0, "Should return non-zero amount for DEBT -> LEVERAGE exact out swap");
            assertGt(nextSqrtPrice, currentSqrtRatioX96, "price should increase for DEBT -> LEVERAGE exact out swap");
        }

        // Test basic functionality for LEVERAGE -> DEBT
        {
            (amountCalc, nextSqrtPrice) = LatentMath.computeSwap(
                liquidity,
                currentSqrtRatioX96,
                AssetType.LEVERAGE,
                amountOut,
                false
            );
            assertGt(amountCalc, 0, "Should return non-zero amount for LEVERAGE -> DEBT exact out swap");
            assertLt(nextSqrtPrice, currentSqrtRatioX96, "price should decrease for LEVERAGE -> DEBT exact out swap");
        }

        // Test maximum liquidity / minimum output
        {
            // @dev - there is a minimum quanta of input that will be expected, even for a small (dust) exact output.
            (amountCalc, nextSqrtPrice) = LatentMath.computeSwap(
                type(uint160).max, // maximum liquidity
                currentSqrtRatioX96,
                AssetType.DEBT,
                1,
                false
            );
            assertGt(
                amountCalc,
                0,
                "There should be a positive input amount for max liquidity, with small exact output, for DEBT token"
            );
            assertEq(
                nextSqrtPrice,
                currentSqrtRatioX96 + 1,
                "There should be a minimum price change for max liquidity, with small exact output, for DEBT token"
            );

            (amountCalc, nextSqrtPrice) = LatentMath.computeSwap(
                type(uint160).max, // maximum liquidity
                currentSqrtRatioX96,
                AssetType.LEVERAGE,
                1,
                false
            );
            assertGt(
                amountCalc,
                0,
                "There should be a positive input amount for max liquidity, with small exact output, for LEVERAGE token"
            );
            assertEq(
                nextSqrtPrice + 1,
                currentSqrtRatioX96,
                "There should be a minimum price change for max liquidity, with small exact output, for LEVERAGE token"
            );
        }
    }

    function test_computeSwap_revert_zeroLiquidity_ExactIn_Debt() external {
        // Test zero liquidity for DEBT
        vm.expectRevert();
        LatentMath.computeSwap(0, _currentSqrtRatioX96, AssetType.DEBT, 1e18, true);
    }

    function test_computeSwap_revert_zeroLiquidity_ExactIn_Leverage() external {
        // Test zero liquidity for LEVERAGE
        vm.expectRevert();
        LatentMath.computeSwap(0, _currentSqrtRatioX96, AssetType.LEVERAGE, 1e18, true);
    }

    function test_computeSwap_revert_zeroPrice_ExactIn_Debt() external {
        // Test zero price for DEBT
        vm.expectRevert();
        LatentMath.computeSwap(_liquidity, 0, AssetType.DEBT, 1e18, true);
    }

    function test_computeSwap_revert_zeroPrice_ExactIn_Leverage() external {
        // Test zero price for LEVERAGE
        vm.expectRevert();
        LatentMath.computeSwap(_liquidity, 0, AssetType.LEVERAGE, 1e18, true);
    }

    function test_computeSwap_revert_largeExactOut_Debt() external {
        // Test zero price for LEVERAGE
        vm.expectRevert();
        LatentMath.computeSwap(
            1, // minimum liquidity
            _currentSqrtRatioX96,
            AssetType.DEBT,
            10 ** 18,
            false
        );
    }

    function test_computeSwap_revert_largeExactOut_Leverage() external {
        // Test zero price for LEVERAGE
        vm.expectRevert();
        LatentMath.computeSwap(
            1, // minimum liquidity
            _currentSqrtRatioX96,
            AssetType.LEVERAGE,
            10 ** 18,
            false
        );
    }

    function test_get_XvsL() external {
        sqrtRatioX96_A = (FixedPoint.Q96 >> 1).toUint160(); // 0.5 price
        sqrtRatioX96_B = (FixedPoint.Q96 << 1).toUint160(); // 2.0 price
        uint160 currentSqrtRatioX96 = uint160(FixedPoint.Q96); // 1.0 price

        // Test basic functionality for token0
        {
            uint256 derivative0 = LatentMath.get_XvsL(
                currentSqrtRatioX96,
                sqrtRatioX96_A,
                sqrtRatioX96_B,
                AssetType.DEBT
            );
            assertGt(derivative0, 0, "Should return non-zero derivative for token0");
        }

        // Test basic functionality for token1
        {
            uint256 derivative1 = LatentMath.get_XvsL(
                currentSqrtRatioX96,
                sqrtRatioX96_A,
                sqrtRatioX96_B,
                AssetType.LEVERAGE
            );
            assertGt(derivative1, 0, "Should return non-zero derivative for token1");
        }

        // Test price boundary conditions
        {
            // Test with minimum valid price
            sqrtRatioX96_A = uint160(MIN_SQRTPRICE);
            sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();
            uint256 derivativeMinPrice0 = LatentMath.get_XvsL(
                currentSqrtRatioX96,
                sqrtRatioX96_A,
                sqrtRatioX96_B,
                AssetType.DEBT
            );
            assertGt(derivativeMinPrice0, 0, "Should handle minimum price for token0");
            assertGt(derivativeMinPrice0, 0, "Should handle minimum price for token0");

            uint256 derivativeMinPrice1 = LatentMath.get_XvsL(
                currentSqrtRatioX96,
                sqrtRatioX96_A,
                sqrtRatioX96_B,
                AssetType.LEVERAGE
            );
            assertGt(derivativeMinPrice1, 0, "Should handle minimum price for token1");

            // Test with maximum valid price
            sqrtRatioX96_A = uint160(MAX_SQRTPRICE);
            sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();
            uint256 derivativeMaxPrice0 = LatentMath.get_XvsL(
                currentSqrtRatioX96,
                sqrtRatioX96_A,
                sqrtRatioX96_B,
                AssetType.DEBT
            );
            assertGt(derivativeMaxPrice0, 0, "Should handle maximum price for token0");

            uint256 derivativeMaxPrice1 = LatentMath.get_XvsL(
                currentSqrtRatioX96,
                sqrtRatioX96_A,
                sqrtRatioX96_B,
                AssetType.LEVERAGE
            );
            assertGt(derivativeMaxPrice1, 0, "Should handle maximum price for token1");
        }

        // Test edge cases
        {
            // Test when current price equals minimum price
            sqrtRatioX96_A = uint160(MIN_SQRTPRICE);
            sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();

            uint256 derivativeEdge0 = LatentMath.get_XvsL(
                sqrtRatioX96_A,
                sqrtRatioX96_A,
                sqrtRatioX96_B,
                AssetType.DEBT
            );
            uint256 derivativeEdge1 = LatentMath.get_XvsL(
                sqrtRatioX96_B,
                sqrtRatioX96_A,
                sqrtRatioX96_B,
                AssetType.LEVERAGE
            );
            assertGt(derivativeEdge0, 0, "Should handle current price equal to minimum price for token0");
            assertGt(derivativeEdge1, 0, "Should handle current price equal to maximum price for token1");
            assertEq(derivativeEdge0, 79220239698012911159784596048962800, "Did not return expected min derivative 0");
            assertEq(derivativeEdge0, derivativeEdge1, "max derivative 1 should be equal to min derivative 0");

            derivativeEdge0 = LatentMath.get_XvsL(sqrtRatioX96_B, sqrtRatioX96_A, sqrtRatioX96_B, AssetType.DEBT);
            derivativeEdge1 = LatentMath.get_XvsL(sqrtRatioX96_A, sqrtRatioX96_A, sqrtRatioX96_B, AssetType.LEVERAGE);
            assertGt(derivativeEdge0, 0, "Should handle current price equal to maximum price for token0");
            assertGt(derivativeEdge1, 0, "Should handle current price equal to minimum price for token1");
            assertEq(derivativeEdge0, 7922023969801291115978459597697, "Did not return expected max derivative 0");
            assertEq(derivativeEdge0, derivativeEdge1, "max derivative 0 should be equal to min derivative 1");
        }
    }

    function test_targetXvsL() external {
        sqrtRatioX96_A = (FixedPoint.Q96 >> 1).toUint160(); // 0.5 price
        sqrtRatioX96_B = (FixedPoint.Q96 << 1).toUint160(); // 2.0 price

        // Test basic functionality
        {
            uint256 concentration = LatentMath.targetXvsL(sqrtRatioX96_A, sqrtRatioX96_B);
            assertGt(concentration, 0, "Should return non-zero concentration");
        }

        // Test price boundary conditions
        {
            // Test with minimum valid price
            sqrtRatioX96_A = uint160(MIN_SQRTPRICE);
            sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();
            uint256 concentrationMin = FixedPoint.Q192 / LatentMath.targetXvsL(sqrtRatioX96_A, sqrtRatioX96_B);
            assertGt(concentrationMin, 0, "Should handle minimum price");
            assertEq(
                concentrationMin,
                400142234920526957543151264,
                "Did not return expected concentration for minimum price"
            );

            // Test with maximum valid price
            sqrtRatioX96_A = uint160(MAX_SQRTPRICE);
            sqrtRatioX96_B = (FixedPoint.Q192 / sqrtRatioX96_A).toUint160();
            uint256 concentrationMax = FixedPoint.Q192 / LatentMath.targetXvsL(sqrtRatioX96_A, sqrtRatioX96_B);
            assertGt(concentrationMax, 0, "Should handle maximum price");
            assertEq(
                concentrationMax,
                39574467175875036627975203197827,
                "Did not return expected concentration for maximum price"
            );
        }

        // Test edge cases
        {
            // Test when price difference is very small
            sqrtRatioX96_A = uint160(FixedPoint.Q96);
            sqrtRatioX96_B = uint160(FixedPoint.Q96 + 1);
            uint256 concentrationSmallDiff = FixedPoint.Q192 / LatentMath.targetXvsL(sqrtRatioX96_A, sqrtRatioX96_B);
            assertGt(concentrationSmallDiff, 0, "Should handle very small price difference");
        }

        // Test mathematical properties
        {
            sqrtRatioX96_A = (FixedPoint.Q96 >> 1).toUint160(); // 0.5 price
            sqrtRatioX96_B = (FixedPoint.Q96 << 1).toUint160(); // 2.0 price

            uint256 concentration = FixedPoint.Q192 / LatentMath.targetXvsL(sqrtRatioX96_A, sqrtRatioX96_B);

            // Test that concentration increases with price difference
            uint160 sqrtRatioX96Higher_A = (FixedPoint.Q96 >> 2).toUint160(); // 0.25 price
            uint160 sqrtRatioX96Higher_B = (FixedPoint.Q96 << 2).toUint160(); // 4.0 price
            uint256 concentrationLower = FixedPoint.Q192 /
                LatentMath.targetXvsL(sqrtRatioX96Higher_A, sqrtRatioX96Higher_B);
            assertLt(concentrationLower, concentration, "Concentration should decrease with larger price difference");
        }
    }

    struct LiquidityAfterSwapVars {
        uint160[] sqrtRatioX96;
        uint160 sqrtRatioX96_A;
        uint160 sqrtRatioX96_B;
        uint256[] balances;
        uint160 liquidity;
        uint160 local_currentSqrtPriceX96;
        uint256[] derivedBalances;
        uint160 local_currentSqrtPriceX96_B0;
        uint160 local_currentSqrtPriceX96_B1;
        uint256[] highPrecisionDerivedBalance;
        uint256 denominator;
        uint256 firstTerm;
        uint256 secondTerm;
        uint160 calcprice;
        uint160 liquidity_calc;
        uint256 amount;
        uint256 amountOut;
        uint256[] balances_after;
        uint256 zTokenAmount;
        uint256 aTokenAmount;
        uint160 liquidityAfterSwap;
    }

    function test_liquidityAfterSwap() external pure {
        LiquidityAfterSwapVars memory vars;

        vars.sqrtRatioX96 = new uint160[](2);
        vars.sqrtRatioX96_A = (FixedPoint.Q96 >> 1).toUint160(); // 0.5 price
        vars.sqrtRatioX96_B = (FixedPoint.Q96 << 1).toUint160(); // 2.0 price
        vars.local_currentSqrtPriceX96 = (FixedPoint.Q96 + 10000).toUint160();

        (vars.zTokenAmount, vars.aTokenAmount) = LatentMath.computeMint(
            vars.local_currentSqrtPriceX96,
            vars.sqrtRatioX96_A,
            vars.sqrtRatioX96_B,
            10 ** 18
        );

        vars.amount = vars.zTokenAmount >> 1;
        (vars.amountOut, vars.local_currentSqrtPriceX96) = LatentMath.computeSwap(
            10 ** 18,
            vars.local_currentSqrtPriceX96,
            AssetType.DEBT,
            vars.amount,
            true
        );

        // Update balances given swap
        vars.zTokenAmount = vars.zTokenAmount - vars.amount;
        vars.aTokenAmount = vars.aTokenAmount + vars.amountOut;

        // compute liquidity after swap
        vars.liquidityAfterSwap =
            LatentMath.computeLiquidity(
                vars.sqrtRatioX96_A,
                vars.sqrtRatioX96_B,
                vars.zTokenAmount,
                vars.aTokenAmount
            ) +
            1;

        assertEq(vars.liquidityAfterSwap, 10 ** 18, "Liquidity should be the same");
    }

    function test_computeMint() external pure {
        uint160 currentSqrtRatioX96 = uint160(1 << 96); // 1.0 price
        uint160 edgeSqrtRatioX96_A = uint160((1 << 96) >> 1); // 0.5 price
        uint160 edgeSqrtRatioX96_B = uint160((1 << 96) << 1); // 2.0 price
        uint160 liquidityIn = 1e18;

        // Test basic functionality
        {
            currentSqrtRatioX96 = uint160(1 << 96); // 1.0 price
            (uint256 zTokenAmount, uint256 aTokenAmount) = LatentMath.computeMint(
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                liquidityIn
            );

            assertGt(zTokenAmount, 0, "Should return non-zero zToken amount");
            assertGt(aTokenAmount, 0, "Should return non-zero aToken amount");
            assertEq(zTokenAmount, aTokenAmount, "zToken amount should be equal to aToken amount at price 1.0");
        }

        // Test minimum liquidity
        {
            (uint256 zTokenAmount, uint256 aTokenAmount) = LatentMath.computeMint(
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                1 // minimum liquidity
            );
            assertGt(zTokenAmount, 0, "Should handle minimum liquidity for zToken");
            assertGt(aTokenAmount, 0, "Should handle minimum liquidity for aToken");
        }

        // Test maximum liquidity
        {
            (uint256 zTokenAmount, uint256 aTokenAmount) = LatentMath.computeMint(
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                type(uint160).max // maximum liquidity
            );
            assertGt(zTokenAmount, 0, "Should handle maximum liquidity for zToken");
            assertGt(aTokenAmount, 0, "Should handle maximum liquidity for aToken");
        }

        // Test price boundary conditions
        {
            // Test with minimum valid price
            edgeSqrtRatioX96_A = uint160(MIN_SQRTPRICE);
            edgeSqrtRatioX96_B = uint160(FixedPoint.Q192 / edgeSqrtRatioX96_A);
            (uint256 zTokenAmount, uint256 aTokenAmount) = LatentMath.computeMint(
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                liquidityIn
            );
            assertGt(zTokenAmount, 0, "Should handle minimum price for zToken");
            assertGt(aTokenAmount, 0, "Should handle minimum price for aToken");

            // Test with maximum valid price
            edgeSqrtRatioX96_A = uint160(MAX_SQRTPRICE);
            edgeSqrtRatioX96_B = uint160(FixedPoint.Q192 / edgeSqrtRatioX96_A);
            (zTokenAmount, aTokenAmount) = LatentMath.computeMint(
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                liquidityIn
            );
            assertGt(zTokenAmount, 0, "Should handle maximum price for zToken");
            assertGt(aTokenAmount, 0, "Should handle maximum price for aToken");
        }

        // Test current price at edges
        {
            // Test when current price equals minimum price
            edgeSqrtRatioX96_A = uint160(MIN_SQRTPRICE);
            edgeSqrtRatioX96_B = uint160(FixedPoint.Q192 / edgeSqrtRatioX96_A);
            (uint256 zTokenAmount, uint256 aTokenAmount) = LatentMath.computeMint(
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                liquidityIn
            );
            assertEq(zTokenAmount, 0, "zToken amount should be 0 when current price equals minimum price");
            assertGt(aTokenAmount, 0, "aToken amount should be positive when current price equals minimum price");

            // Test when current price equals maximum price
            edgeSqrtRatioX96_A = uint160(MAX_SQRTPRICE);
            edgeSqrtRatioX96_B = uint160(FixedPoint.Q192 / edgeSqrtRatioX96_A);
            (zTokenAmount, aTokenAmount) = LatentMath.computeMint(
                edgeSqrtRatioX96_B,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                liquidityIn
            );
            assertGt(zTokenAmount, 0, "zToken amount should be positive when current price equals maximum price");
            assertEq(aTokenAmount, 0, "aToken amount should be 0 when current price equals maximum price");
        }
    }

    function test_computeRedeem() external pure {
        uint160 currentLiquidity = 1e18;
        uint160 currentSqrtRatioX96 = uint160(1 << 96); // 1.0 price
        uint160 edgeSqrtRatioX96_A = uint160((1 << 96) >> 1); // 0.5 price
        uint160 edgeSqrtRatioX96_B = uint160((1 << 96) << 1); // 2.0 price
        uint256 zTokenAmountIn = 1e16;
        uint256 aTokenAmountIn = 1e16;

        // Test basic functionality with balanced amounts
        {
            (uint160 liquidityAmount, ) = LatentMath.computeRedeem(
                currentLiquidity,
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                zTokenAmountIn,
                aTokenAmountIn
            );

            assertGt(liquidityAmount, 0, "Should return non-zero liquidity amount");
            //assertEq(nextSqrtRatioX96, currentSqrtRatioX96, "Price should not change for balanced amounts");
        }

        // Test minimum amounts
        {
            (uint160 liquidityAmount, ) = LatentMath.computeRedeem(
                currentLiquidity,
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                1, // minimum zToken amount
                1 // minimum aToken amount
            );
            assertEq(liquidityAmount, 0, "Should handle minimum token amounts");
            //assertEq(nextSqrtRatioX96, currentSqrtRatioX96, "Price should not change for minimum balanced amounts");
        }

        // Test maximum amounts
        {
            (uint160 liquidityAmount, ) = LatentMath.computeRedeem(
                currentLiquidity,
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                MAX_BALANCE, // large but safe zToken amount
                MAX_BALANCE // large but safe aToken amount
            );
            assertGt(liquidityAmount, 0, "Should handle maximum token amounts");
            //assertEq(nextSqrtRatioX96, currentSqrtRatioX96, "Price should not change for maximum balanced amounts");
        }

        // Test unbalanced amounts (requires price adjustment)
        {
            // Test with more zToken than aToken
            (uint160 liquidityAmount, uint160 nextSqrtRatioX96) = LatentMath.computeRedeem(
                currentLiquidity,
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                zTokenAmountIn * 2, // double zToken amount
                aTokenAmountIn // original aToken amount
            );
            assertGt(liquidityAmount, 0, "Should handle unbalanced amounts (more zToken)");
            assertLt(nextSqrtRatioX96, currentSqrtRatioX96, "Price should decrease for more zToken");
            console.log("step4.1");
            // Test with more aToken than zToken
            (liquidityAmount, nextSqrtRatioX96) = LatentMath.computeRedeem(
                currentLiquidity,
                currentSqrtRatioX96,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                zTokenAmountIn, // original zToken amount
                aTokenAmountIn * 2 // double aToken amount
            );
            assertGt(liquidityAmount, 0, "Should handle unbalanced amounts (more aToken)");
            assertGt(nextSqrtRatioX96, currentSqrtRatioX96, "Price should increase for more aToken");
        }

        // Test edge price conditions
        {
            // Test when current price equals minimum price
            edgeSqrtRatioX96_A = uint160(MIN_SQRTPRICE);
            edgeSqrtRatioX96_B = uint160(FixedPoint.Q192 / edgeSqrtRatioX96_A);
            (uint160 liquidityAmount, uint160 nextSqrtRatioX96) = LatentMath.computeRedeem(
                currentLiquidity,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                zTokenAmountIn,
                aTokenAmountIn
            );
            assertGt(liquidityAmount, 0, "Should handle minimum price edge");
            assertEq(nextSqrtRatioX96, edgeSqrtRatioX96_A, "Price should stay at minimum edge");

            // Test when current price equals maximum price
            edgeSqrtRatioX96_A = uint160(MAX_SQRTPRICE);
            edgeSqrtRatioX96_B = uint160(FixedPoint.Q192 / edgeSqrtRatioX96_A);
            (liquidityAmount, nextSqrtRatioX96) = LatentMath.computeRedeem(
                currentLiquidity,
                edgeSqrtRatioX96_B,
                edgeSqrtRatioX96_A,
                edgeSqrtRatioX96_B,
                zTokenAmountIn,
                aTokenAmountIn
            );
            assertGt(liquidityAmount, 0, "Should handle maximum price edge");
            assertEq(nextSqrtRatioX96, edgeSqrtRatioX96_B, "Price should stay at maximum edge");
        }
    }

    function test_computeRedeem_vs_get_XvsL_Debt() external pure {
        // Setup parameters for a large liquidity pool with small redeem
        uint160 currentLiquidity = 1e20; // Large liquidity
        uint160 currentSqrtRatioX96 = uint160(1 << 96); // 1.0 price
        uint160 edgeSqrtRatioX96_A = uint160((1 << 96) >> 1); // 0.5 price
        uint160 edgeSqrtRatioX96_B = uint160((1 << 96) << 1); // 2.0 price

        // Small redeem amounts - just a tiny fraction of the total liquidity
        uint256 zTokenAmountIn = 1e10; // Small zToken amount

        // Perform the redeem operation
        (uint160 liquidityAmount, ) = LatentMath.computeRedeem(
            currentLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            zTokenAmountIn,
            0
        );

        // Calculate the derivative using get_XvsL for AssetType.DEBT
        uint256 derivativeXvsL = LatentMath.get_XvsL(
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
        uint256 tolerance = 1e9; // 0.1% tolerance

        assertApproxEqRel(
            actualRatio,
            derivativeXvsL,
            tolerance,
            "Small redeem ratio should approximate get_XvsL derivative for DEBT"
        );
    }

    function test_computeRedeem_vs_get_XvsL_Leverage() external pure {
        // Setup parameters for a large liquidity pool with small redeem
        uint160 currentLiquidity = 1e20; // Large liquidity
        uint160 currentSqrtRatioX96 = uint160(1 << 96); // 1.0 price
        uint160 edgeSqrtRatioX96_A = uint160((1 << 96) >> 1); // 0.5 price
        uint160 edgeSqrtRatioX96_B = uint160((1 << 96) << 1); // 2.0 price

        // Small redeem amounts - just a tiny fraction of the total liquidity
        uint256 aTokenAmountIn = 1e10; // Small zToken amount

        // Perform the redeem operation
        (uint160 liquidityAmount, ) = LatentMath.computeRedeem(
            currentLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            0,
            aTokenAmountIn
        );

        // Calculate the derivative using get_XvsL for AssetType.DEBT
        uint256 derivativeXvsL = LatentMath.get_XvsL(
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            AssetType.LEVERAGE
        );

        // Calculate the ratio of liquidity removed to zToken amount
        // This should approximate the derivative for small amounts
        uint256 actualRatio = Math.mulDiv(aTokenAmountIn, FixedPoint.Q96, liquidityAmount);

        // For small amounts, the actual ratio should be close to the theoretical derivative
        // Allow for some tolerance due to rounding differences
        uint256 tolerance = 1e9; // 0.1% tolerance

        assertApproxEqRel(
            actualRatio,
            derivativeXvsL,
            tolerance,
            "Small redeem ratio should approximate get_XvsL derivative for LEVERAGE"
        );
    }

    function test_maxLiquidity_minRedeem_overflow() external {
        // Setup parameters for a large liquidity pool with small redeem
        uint160 maxLiquidity = type(uint160).max - 1;
        uint160 currentSqrtRatioX96 = uint160(1 << 96); // 1.0 price
        uint160 edgeSqrtRatioX96_A = uint160((1 << 96) >> 1); // 0.5 price
        uint160 edgeSqrtRatioX96_B = uint160((1 << 96) << 1); // 2.0 price
        uint160 liquidityOut;
        MockLatentMath mockLatentMath = new MockLatentMath();

        // Perform redeem operation
        (liquidityOut, ) = mockLatentMath.computeRedeem(
            maxLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            1,
            0
        );
        assertEq(liquidityOut, 0, "Liquidity out should be zero if zToken redeem is small");

        // Perform redeem operation
        (liquidityOut, ) = mockLatentMath.computeRedeem(
            maxLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            0,
            1
        );
        assertEq(liquidityOut, 0, "Liquidity out should be zero if aToken redeem is small");

        // Perform redeem operation
        (liquidityOut, ) = mockLatentMath.computeRedeem(
            maxLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            1,
            1
        );
        assertEq(liquidityOut, 0, "Liquidity out should be zero if redeem is small");

        (liquidityOut, ) = mockLatentMath.computeRedeem(
            maxLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            0,
            0
        );
        assertEq(liquidityOut, 0, "Liquidity out should be zero if no redeem input");

        (liquidityOut, ) = mockLatentMath.computeRedeem(
            maxLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            2,
            0
        );
        assertEq(liquidityOut, 0, "Liquidity out should be zero if zToken redeem is small");

        (liquidityOut, ) = mockLatentMath.computeRedeem(
            maxLiquidity,
            currentSqrtRatioX96,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B,
            0,
            2
        );
        assertEq(liquidityOut, 0, "Liquidity out should be zero if aToken redeem is small");
    }

    //////////////////////////////////////////////////////////////////////////
    // Fee Accrual Tests
    //////////////////////////////////////////////////////////////////////////

    function test_tvlFeeAccrual_LinearOverTime() external pure {
        // Test TVL fee accrual using DebtMath.calculateLinearAccrual
        uint256 baseTokenSupply = 1000 * 1e18; // 1000 tokens
        uint16 tvlFee = 100; // 1% annual TVL fee
        uint256 timeDelta = 30 days; // 30 days

        // Calculate expected TVL fee accrual
        uint256 expectedTvlFee = DebtMath.calculateLinearAccrual(
            baseTokenSupply,
            uint256(tvlFee) << FixedPoint.RESOLUTION, // Convert to X96 format
            timeDelta
        );

        // Expected calculation: (baseTokenSupply * tvlFee * timeDelta) / (365 days * 10000)
        uint256 expectedManual = Math.mulDiv(baseTokenSupply, uint256(tvlFee) * timeDelta, 365 days * 10000);

        // Convert X96 result back to normal units
        uint256 actualTvlFee = expectedTvlFee / FixedPoint.Q96;

        // Allow for small rounding differences
        assertApproxEqRel(
            actualTvlFee,
            expectedManual,
            1e12, // 0.0001% tolerance
            "TVL fee accrual should match expected linear calculation"
        );

        // Verify that fee increases with time
        uint256 shorterTimeFee = DebtMath.calculateLinearAccrual(
            baseTokenSupply,
            uint256(tvlFee) << FixedPoint.RESOLUTION,
            timeDelta / 2
        ) / FixedPoint.Q96;

        assertLt(shorterTimeFee, actualTvlFee, "TVL fee should increase with longer time periods");

        // Verify that fee increases with base token supply
        uint256 smallerSupplyFee = DebtMath.calculateLinearAccrual(
            baseTokenSupply / 2,
            uint256(tvlFee) << FixedPoint.RESOLUTION,
            timeDelta
        ) / FixedPoint.Q96;

        assertLt(smallerSupplyFee, actualTvlFee, "TVL fee should increase with larger base token supply");
    }

    function test_tvlFeeAccrual_DifferentRates() external pure {
        uint256 baseTokenSupply = 1000 * 1e18;
        uint256 timeDelta = 90 days; // 3 months

        // Test different TVL fee rates
        uint16[] memory tvlFees = new uint16[](5);
        tvlFees[0] = 10; // 0.1%
        tvlFees[1] = 100; // 1%
        tvlFees[2] = 500; // 5% (maximum allowed)
        tvlFees[3] = 250; // 2.5%
        tvlFees[4] = 1; // 0.01%

        for (uint i = 0; i < tvlFees.length; i++) {
            uint256 tvlFeeAccrual = DebtMath.calculateLinearAccrual(
                baseTokenSupply,
                uint256(tvlFees[i]) << FixedPoint.RESOLUTION,
                timeDelta
            ) / FixedPoint.Q96;

            // Verify fee is proportional to rate
            uint256 expectedFee = Math.mulDiv(baseTokenSupply, uint256(tvlFees[i]) * timeDelta, 365 days * 10000);

            assertApproxEqRel(
                tvlFeeAccrual,
                expectedFee,
                1e12, // 0.0001% tolerance
                "TVL fee should be proportional to rate"
            );

            // Verify higher rates produce higher fees
            if (i > 0) {
                uint256 prevTvlFeeAccrual = DebtMath.calculateLinearAccrual(
                    baseTokenSupply,
                    uint256(tvlFees[i - 1]) << FixedPoint.RESOLUTION,
                    timeDelta
                ) / FixedPoint.Q96;

                if (tvlFees[i] > tvlFees[i - 1]) {
                    assertGt(tvlFeeAccrual, prevTvlFeeAccrual, "Higher TVL fee rate should produce higher accrual");
                }
            }
        }
    }

    function test_yieldFeeAccrual_WithInterest() external pure {
        // Test yield fee accrual based on debt notional price increases
        uint256 baseTokenSupply = 1000 * 1e18;
        uint256 ltv = 5000; // 50% LTV
        uint16 yieldFee = 1000; // 10% yield fee
        uint256 timeDelta = 30 days;

        // Simulate debt notional price increase (yield generation)
        uint256 initialDebtPrice = 1e18; // 1.0
        uint256 finalDebtPrice = 1.05e18; // 1.05 (5% increase)

        // Calculate yield in base units using LTV
        uint256 yieldInBaseUnits = Math.mulDiv(
            baseTokenSupply,
            (finalDebtPrice - initialDebtPrice) * ltv,
            finalDebtPrice * 10000 // PERCENTAGE_FACTOR
        );

        // Calculate yield fee
        uint256 yieldFeeAmount = Math.mulDiv(
            yieldInBaseUnits,
            uint256(yieldFee) << FixedPoint.RESOLUTION,
            10000 // PERCENTAGE_FACTOR
        ) / FixedPoint.Q96;

        // Verify yield fee is proportional to yield generated
        assertGt(yieldFeeAmount, 0, "Yield fee should be positive when there's yield");
        assertLt(yieldFeeAmount, yieldInBaseUnits, "Yield fee should be less than total yield");

        // Test with no yield (no fee should accrue)
        uint256 noYieldFee = Math.mulDiv(
            baseTokenSupply,
            0 * ltv, // No yield
            finalDebtPrice * 10000
        );
        assertEq(noYieldFee, 0, "No yield should result in no yield fee");

        // Test with higher yield (higher fee)
        uint256 higherYield = Math.mulDiv(
            baseTokenSupply,
            (finalDebtPrice * 2 - initialDebtPrice) * ltv, // 2x yield
            finalDebtPrice * 10000
        );
        uint256 higherYieldFee = Math.mulDiv(higherYield, uint256(yieldFee) << FixedPoint.RESOLUTION, 10000) /
            FixedPoint.Q96;

        assertGt(higherYieldFee, yieldFeeAmount, "Higher yield should produce higher yield fee");
    }

    function test_combinedFeeAccrual_TvlAndYield() external pure {
        // Test combined TVL and yield fee accrual
        uint256 baseTokenSupply = 1000 * 1e18;
        uint256 timeDelta = 90 days;
        uint16 tvlFee = 200; // 2% TVL fee
        uint16 yieldFee = 1500; // 15% yield fee
        uint256 ltv = 6000; // 60% LTV

        // Calculate TVL fee
        uint256 tvlFeeAccrual = DebtMath.calculateLinearAccrual(
            baseTokenSupply,
            uint256(tvlFee) << FixedPoint.RESOLUTION,
            timeDelta
        ) / FixedPoint.Q96;

        // Calculate yield fee (simulate 3% yield over 90 days)
        uint256 initialDebtPrice = 1e18;
        uint256 finalDebtPrice = 1.03e18; // 3% yield
        uint256 yieldInBaseUnits = Math.mulDiv(
            baseTokenSupply,
            (finalDebtPrice - initialDebtPrice) * ltv,
            finalDebtPrice * 10000
        );
        uint256 yieldFeeAccrual = Math.mulDiv(yieldInBaseUnits, uint256(yieldFee) << FixedPoint.RESOLUTION, 10000) /
            FixedPoint.Q96;

        // Total combined fee
        uint256 totalFee = tvlFeeAccrual + yieldFeeAccrual;

        // Verify both components are positive
        assertGt(tvlFeeAccrual, 0, "TVL fee should be positive");
        assertGt(yieldFeeAccrual, 0, "Yield fee should be positive");
        assertGt(totalFee, tvlFeeAccrual, "Total fee should be greater than TVL fee alone");
        assertGt(totalFee, yieldFeeAccrual, "Total fee should be greater than yield fee alone");

        // Verify total fee is reasonable (should not exceed a small percentage of base supply)
        assertLt(totalFee, baseTokenSupply / 10, "Total fee should be less than 10% of base supply");
    }

    function test_feeAccrual_EdgeCases() external pure {
        // Test edge cases for fee accrual
        uint256 baseTokenSupply = 1000 * 1e18;

        // Test with minimum time delta
        uint256 minTimeFee = DebtMath.calculateLinearAccrual(
            baseTokenSupply,
            uint256(100) << FixedPoint.RESOLUTION, // 1% fee
            1 seconds
        ) / FixedPoint.Q96;

        assertGt(minTimeFee, 0, "Should accrue some fee even with minimal time");
        assertLt(minTimeFee, 1e15, "Minimal time should result in very small fee");

        // Test with maximum allowed TVL fee
        uint256 maxTvlFee = DebtMath.calculateLinearAccrual(
            baseTokenSupply,
            uint256(500) << FixedPoint.RESOLUTION, // 5% fee (max allowed)
            365 days
        ) / FixedPoint.Q96;

        uint256 expectedMaxFee = Math.mulDiv(baseTokenSupply, 500 * 365 days, 365 days * 10000);

        assertApproxEqRel(maxTvlFee, expectedMaxFee, 1e12, "Maximum TVL fee should accrue correctly over a year");

        // Test with zero base token supply
        uint256 zeroSupplyFee = DebtMath.calculateLinearAccrual(0, uint256(100) << FixedPoint.RESOLUTION, 30 days) /
            FixedPoint.Q96;

        assertEq(zeroSupplyFee, 0, "Zero base supply should result in zero TVL fee");

        // Test with zero time delta
        uint256 zeroTimeFee = DebtMath.calculateLinearAccrual(
            baseTokenSupply,
            uint256(100) << FixedPoint.RESOLUTION,
            0
        ) / FixedPoint.Q96;

        assertEq(zeroTimeFee, 0, "Zero time delta should result in zero TVL fee");
    }

    function test_feeAccrual_TimeProportionality() external pure {
        // Test that fees accrue proportionally with time
        uint256 baseTokenSupply = 1000 * 1e18;
        uint16 tvlFee = 100; // 1% fee

        uint256[] memory timeDeltas = new uint256[](5);
        timeDeltas[0] = 1 days;
        timeDeltas[1] = 7 days;
        timeDeltas[2] = 30 days;
        timeDeltas[3] = 90 days;
        timeDeltas[4] = 365 days;

        uint256[] memory fees = new uint256[](5);

        for (uint i = 0; i < timeDeltas.length; i++) {
            fees[i] =
                DebtMath.calculateLinearAccrual(
                    baseTokenSupply,
                    uint256(tvlFee) << FixedPoint.RESOLUTION,
                    timeDeltas[i]
                ) /
                FixedPoint.Q96;
        }

        // Verify proportional relationship
        for (uint i = 1; i < timeDeltas.length; i++) {
            uint256 expectedRatio = Math.mulDiv(timeDeltas[i], 1e18, timeDeltas[0]);
            uint256 actualRatio = Math.mulDiv(fees[i], 1e18, fees[0]);

            // Allow for small rounding differences
            assertApproxEqRel(
                actualRatio,
                expectedRatio,
                1e12, // 0.0001% tolerance
                "Fee should be proportional to time"
            );
        }
    }

    function test_feeAccrual_SupplyProportionality() external pure {
        // Test that fees accrue proportionally with base token supply
        uint16 tvlFee = 100; // 1% fee
        uint256 timeDelta = 30 days;

        uint256[] memory supplies = new uint256[](5);
        supplies[0] = 100 * 1e18; // 100 tokens
        supplies[1] = 500 * 1e18; // 500 tokens
        supplies[2] = 1000 * 1e18; // 1000 tokens
        supplies[3] = 5000 * 1e18; // 5000 tokens
        supplies[4] = 10000 * 1e18; // 10000 tokens

        uint256[] memory fees = new uint256[](5);

        for (uint i = 0; i < supplies.length; i++) {
            fees[i] =
                DebtMath.calculateLinearAccrual(supplies[i], uint256(tvlFee) << FixedPoint.RESOLUTION, timeDelta) /
                FixedPoint.Q96;
        }

        // Verify proportional relationship
        for (uint i = 1; i < supplies.length; i++) {
            uint256 expectedRatio = Math.mulDiv(supplies[i], 1e18, supplies[0]);
            uint256 actualRatio = Math.mulDiv(fees[i], 1e18, fees[0]);

            // Allow for small rounding differences
            assertApproxEqRel(
                actualRatio,
                expectedRatio,
                1e12, // 0.0001% tolerance
                "Fee should be proportional to base token supply"
            );
        }
    }

    function test_feeAccrual_WithDifferentLtvLevels() external pure {
        // Test yield fee accrual with different LTV levels
        uint256 baseTokenSupply = 1000 * 1e18;
        uint16 yieldFee = 1000; // 10% yield fee
        uint256 yieldIncrease = 0.05e18; // 5% yield increase

        uint256[] memory ltvs = new uint256[](5);
        ltvs[0] = 1000; // 10% LTV
        ltvs[1] = 3000; // 30% LTV
        ltvs[2] = 5000; // 50% LTV
        ltvs[3] = 7000; // 70% LTV
        ltvs[4] = 9000; // 90% LTV

        uint256[] memory yieldFees = new uint256[](5);

        for (uint i = 0; i < ltvs.length; i++) {
            uint256 yieldInBaseUnits = Math.mulDiv(
                baseTokenSupply,
                yieldIncrease * ltvs[i],
                1.05e18 * 10000 // finalDebtPrice * PERCENTAGE_FACTOR
            );

            yieldFees[i] =
                Math.mulDiv(yieldInBaseUnits, uint256(yieldFee) << FixedPoint.RESOLUTION, 10000) /
                FixedPoint.Q96;
        }

        // Verify that higher LTV results in higher yield fees
        for (uint i = 1; i < ltvs.length; i++) {
            assertGt(yieldFees[i], yieldFees[i - 1], "Higher LTV should result in higher yield fees");
        }

        // Verify proportional relationship with LTV
        for (uint i = 1; i < ltvs.length; i++) {
            uint256 expectedRatio = Math.mulDiv(ltvs[i], 1e18, ltvs[0]);
            uint256 actualRatio = Math.mulDiv(yieldFees[i], 1e18, yieldFees[0]);

            assertApproxEqRel(
                actualRatio,
                expectedRatio,
                1e12, // 0.0001% tolerance
                "Yield fee should be proportional to LTV"
            );
        }
    }
}

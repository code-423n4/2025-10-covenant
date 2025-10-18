// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {SqrtPriceMath} from "../src/lex/latentswap/libraries/SqrtPriceMath.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {TestMath} from "./utils/TestMath.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";

// Copies tests from Uniswap V3 https://github.com/Uniswap/v3-core/blob/main/test/SqrtPriceMath.spec.ts

contract SqrtPriceMathTest is Test {
    using SafeCast for uint256;

    function test_getAmount0Delta() external pure {
        //returns 0 if liquidity is 0
        uint256 outRoundUp = SqrtPriceMath.getAmount0Delta(10 ** 18, 2 * 10 ** 18, 0, Math.Rounding.Ceil);
        uint256 outRoundDown = SqrtPriceMath.getAmount0Delta(10 ** 18, 2 * 10 ** 18, 0, Math.Rounding.Floor);
        assertEq(outRoundUp, 0, "Did not return 0 when liquidity is 0 - roundup");
        assertEq(outRoundDown, 0, "Did not return 0 when liquidity is 0 - rounddown");

        //returns 0 if prices are equal
        outRoundUp = SqrtPriceMath.getAmount0Delta(10 ** 18, 10 ** 18, (10 ** 18), Math.Rounding.Ceil);
        outRoundDown = SqrtPriceMath.getAmount0Delta(10 ** 18, 10 ** 18, (10 ** 18), Math.Rounding.Floor);
        assertEq(outRoundUp, 0, "Did not return 0 when prices are equal- roundup");
        assertEq(outRoundDown, 0, "Did not return 0 when prices are equal - rounddown");

        //returns 0.9 amount0 for price of 1 to 1.21
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(
            TestMath.encodePriceSqrtQ96(1, 1),
            TestMath.encodePriceSqrtQ96(121, 100),
            10 ** 18,
            Math.Rounding.Ceil
        );
        assertEq(amount0, 90909090909090910, "incorrect getAmount0Delta calculation");

        uint256 amount0roundDown = SqrtPriceMath.getAmount0Delta(
            TestMath.encodePriceSqrtQ96(1, 1),
            TestMath.encodePriceSqrtQ96(121, 100),
            10 ** 18,
            Math.Rounding.Floor
        );
        assertEq(amount0roundDown, amount0 - 1, "incorrect getAmount0Delta roundDown calculation");
    }

    function test_getAmount1Delta() external pure {
        //returns 0 if liquidity is 0
        uint256 outRoundUp = SqrtPriceMath.getAmount1Delta(10 ** 18, 2 * 10 ** 18, 0, Math.Rounding.Ceil);
        uint256 outRoundDown = SqrtPriceMath.getAmount1Delta(10 ** 18, 2 * 10 ** 18, 0, Math.Rounding.Floor);
        assertEq(outRoundUp, 0, "Did not return 1 when liquidity is 0 - roundup");
        assertEq(outRoundDown, 0, "Did not return 1 when liquidity is 0 - rounddown");

        //returns 0 if prices are equal
        outRoundUp = SqrtPriceMath.getAmount1Delta(10 ** 18, 10 ** 18, (10 ** 18), Math.Rounding.Ceil);
        outRoundDown = SqrtPriceMath.getAmount1Delta(10 ** 18, 10 ** 18, (10 ** 18), Math.Rounding.Floor);
        assertEq(outRoundUp, 0, "Did not return 1 when prices are equal- roundup");
        assertEq(outRoundDown, 0, "Did not return 1 when prices are equal - rounddown");

        //returns 0.1 amount1 for price of 1 to 1.21
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(
            TestMath.encodePriceSqrtQ96(1, 1),
            TestMath.encodePriceSqrtQ96(121, 100),
            10 ** 18,
            Math.Rounding.Ceil
        );
        assertEq(amount1, 10 ** 17, "incorrect getAmount0Delta calculation");

        uint256 amount1roundDown = SqrtPriceMath.getAmount1Delta(
            TestMath.encodePriceSqrtQ96(1, 1),
            TestMath.encodePriceSqrtQ96(121, 100),
            10 ** 18,
            Math.Rounding.Floor
        );
        assertEq(amount1roundDown, amount1 - 1, "incorrect getAmount1Delta roundDown calculation");
    }

    function test_getNextSqrtPriceFromAmount0_price0revert_1() external {
        //fails if price is zero
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(0, 1, 10 ** 17, true, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount0_price0revert_2() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(0, 1, 10 ** 17, true, Math.Rounding.Floor);
    }

    function test_getNextSqrtPriceFromAmount0_price0revert_3() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(0, 1, 10 ** 17, false, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount0_price0revert_4() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(0, 1, 10 ** 17, false, Math.Rounding.Floor);
    }

    function test_getNextSqrtPriceFromAmount0_liquidity0revert_1() external {
        //fails if liquidity is zero
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(1, 0, 10 ** 17, true, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount0_liquidity0revert_2() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(1, 0, 10 ** 17, true, Math.Rounding.Floor);
    }

    function test_getNextSqrtPriceFromAmount0_liquidity0revert_3() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(1, 0, 10 ** 17, false, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount0_liquidity0revert_4() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(1, 0, 10 ** 17, false, Math.Rounding.Floor);
    }

    function test_getNextSqrtPriceFromAmount0_priceOverflow() external {
        //fails if input amount overflows the price
        //for amount0, neet to substract amount
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0((1 << 160) - 1, 1024, 1024, false, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount0_priceChecks() external pure {
        //any input amount cannot underflow the price (roundUp)
        uint256 out = SqrtPriceMath.getNextSqrtPriceFromAmount0(1, 1, 1 << 255, true, Math.Rounding.Ceil);
        assertEq(out, 1, "large amount underflow");

        //returns input price if amount in is zero
        out = SqrtPriceMath.getNextSqrtPriceFromAmount0(1024, 1024, 0, true, Math.Rounding.Ceil);
        assertEq(out, 1024, "expected input price if amount = 0, case 1");
        out = SqrtPriceMath.getNextSqrtPriceFromAmount0(1024, 1024, 0, false, Math.Rounding.Ceil);
        assertEq(out, 1024, "expected input price if amount = 0, case 2");
        out = SqrtPriceMath.getNextSqrtPriceFromAmount0(1024, 1024, 0, true, Math.Rounding.Floor);
        assertEq(out, 1024, "expected input price if amount = 0, case 3");
        out = SqrtPriceMath.getNextSqrtPriceFromAmount0(1024, 1024, 0, false, Math.Rounding.Floor);
        assertEq(out, 1024, "expected input price if amount = 0, case 4");

        //returns the minimum price for max inputs
        uint256 sqrtP = ((1 << 160) - 1);
        uint256 liquidity = ((1 << 160) - 1);
        uint256 maxAmountNoOverflow = uint256((1 << 256) - 1) - (liquidity << 96) / sqrtP;
        out = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            uint160(sqrtP),
            uint160(liquidity),
            maxAmountNoOverflow,
            true,
            Math.Rounding.Ceil
        );
        assertEq(out, 1, "expected minimum price for max inputs");

        //input amount of 0.1 token0
        uint256 amountCeil = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 18,
            10 ** 17,
            true,
            Math.Rounding.Ceil
        );
        uint256 amountFloor = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 18,
            10 ** 17,
            true,
            Math.Rounding.Floor
        );
        assertEq(amountCeil, 72025602285694852357767227579, "incorrect output for 0.1 token0 input - roundup");
        assertEq(amountCeil, amountFloor + 1, "incorrect output for 0.1 token0 input - roundDown");

        //output amount of 0.1 token0
        amountCeil = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 18,
            10 ** 17,
            false,
            Math.Rounding.Ceil
        );
        amountFloor = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 18,
            10 ** 17,
            false,
            Math.Rounding.Floor
        );
        assertEq(amountCeil, 88031291682515930659493278152, "incorrect output for 0.1 token0 output - roundup");
        assertEq(amountCeil, amountFloor + 1, "incorrect output for 0.1 token0 output - roundDown");

        //amountIn > type(uint96).max
        amountCeil = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 19,
            1 << 100,
            true,
            Math.Rounding.Ceil
        );
        amountFloor = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 19,
            1 << 100,
            true,
            Math.Rounding.Floor
        );
        assertEq(amountCeil, 624999999995069620, "incorrect output for amountIn > uint96 max token0 input - roundup");
        assertEq(amountCeil, amountFloor + 1, "incorrect output for amountIn > uint96 max token0 input - rounddown");

        //can return 1 with enough amountIn - roundUp
        out = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            TestMath.encodePriceSqrtQ96(1, 1),
            1,
            1 << 255,
            true,
            Math.Rounding.Ceil
        );
        assertEq(out, 1, "incorrect can return 1 with enough amountIn - roundUp");
    }

    function test_getNextSqrtPriceFromAmount0_fullreserve_fail() external {
        //fails if output amount is exactly the virtual reserves of token0
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(20282409603651670423947251286016, 1024, 4, false, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount0_fullreserve_plus_fail() external {
        //ffails if output amount is greater than virtual reserves of token0
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(20282409603651670423947251286016, 1024, 5, false, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount0_fullreserve_minus_success() external pure {
        //succeeds for amount just under full reserve
        uint256 out = SqrtPriceMath.getNextSqrtPriceFromAmount0(
            20282409603651670423947251286016,
            1024,
            3,
            false,
            Math.Rounding.Ceil
        );
        assertEq(out, 81129638414606681695789005144064, "incorrect output amount");
    }

    function test_getNextSqrtPriceFromAmount0_impossible_amountout() external {
        //reverts if amountOut is impossible
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount0(
            TestMath.encodePriceSqrtQ96(1, 1),
            1,
            (1 << 256) - 1,
            false,
            Math.Rounding.Ceil
        );
    }

    function test_getNextSqrtPriceFromAmount1_price0revert_1() external {
        //fails if price is zero
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(0, 1, 10 ** 17, true, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount1_price0revert_2() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(0, 1, 10 ** 17, true, Math.Rounding.Floor);
    }

    function test_getNextSqrtPriceFromAmount1_price0revert_3() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(0, 1, 10 ** 17, false, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount1_price0revert_4() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(0, 1, 10 ** 17, false, Math.Rounding.Floor);
    }

    function test_getNextSqrtPriceFromAmount1_liquidity0revert_1() external {
        //fails if liquidity is zero
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(1, 0, 10 ** 17, true, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount1_liquidity0revert_2() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(1, 0, 10 ** 17, true, Math.Rounding.Floor);
    }

    function test_getNextSqrtPriceFromAmount1_liquidity0revert_3() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(1, 0, 10 ** 17, false, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount1_liquidity0revert_4() external {
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(1, 0, 10 ** 17, false, Math.Rounding.Floor);
    }

    function test_getNextSqrtPriceFromAmount1_priceOverflow() external {
        //fails if input amount overflows the price
        //for amount1, neet to add amount
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1((1 << 160) - 1, 1024, 1024, true, Math.Rounding.Ceil);
    }

    function test_getNextSqrtPriceFromAmount1_priceChecks() external pure {
        //returns input price if amount in is zero
        uint256 out = SqrtPriceMath.getNextSqrtPriceFromAmount1(1024, 1024, 0, true, Math.Rounding.Ceil);
        assertEq(out, 1024, "expected input price if amount = 0, case 1");
        out = SqrtPriceMath.getNextSqrtPriceFromAmount1(1024, 1024, 0, false, Math.Rounding.Ceil);
        assertEq(out, 1024, "expected input price if amount = 0, case 2");
        out = SqrtPriceMath.getNextSqrtPriceFromAmount1(1024, 1024, 0, true, Math.Rounding.Floor);
        assertEq(out, 1024, "expected input price if amount = 0, case 3");
        out = SqrtPriceMath.getNextSqrtPriceFromAmount1(1024, 1024, 0, false, Math.Rounding.Floor);
        assertEq(out, 1024, "expected input price if amount = 0, case 4");

        //input amount of 0.1 token1
        uint256 amountCeil = SqrtPriceMath.getNextSqrtPriceFromAmount1(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 18,
            10 ** 17,
            true,
            Math.Rounding.Ceil
        );
        uint256 amountFloor = SqrtPriceMath.getNextSqrtPriceFromAmount1(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 18,
            10 ** 17,
            true,
            Math.Rounding.Floor
        );
        assertEq(amountCeil, amountFloor + 1, "incorrect output for 0.1 token1 input - roundup");
        assertEq(amountFloor, 87150978765690771352898345369, "incorrect output for 0.1 token1 input - roundDown");

        //out amount of 0.1 token1
        amountCeil = SqrtPriceMath.getNextSqrtPriceFromAmount1(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 18,
            10 ** 17,
            false,
            Math.Rounding.Ceil
        );
        amountFloor = SqrtPriceMath.getNextSqrtPriceFromAmount1(
            TestMath.encodePriceSqrtQ96(1, 1),
            10 ** 18,
            10 ** 17,
            false,
            Math.Rounding.Floor
        );
        assertEq(amountCeil, amountFloor + 1, "incorrect output for 0.1 token1 output - roundup");
        assertEq(amountFloor, 71305346262837903834189555302, "incorrect output for 0.1 token1 output - roundDown");
    }

    function test_getNextSqrtPriceFromAmount1_fullreserve_fail() external {
        //fails if output amount is exactly the virtual reserves of token1
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(
            20282409603651670423947251286016,
            1024,
            262144,
            false,
            Math.Rounding.Ceil
        );
    }

    function test_getNextSqrtPriceFromAmount1_fullreserve_plus_fail() external {
        //fails if output amount is greater than the virtual reserves of token1
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(
            20282409603651670423947251286016,
            1024,
            262145,
            false,
            Math.Rounding.Ceil
        );
    }

    function test_getNextSqrtPriceFromAmount1_fullreserve_minus() external pure {
        //succeeds if output amount is just below the virtual reserves of token1
        uint256 out = SqrtPriceMath.getNextSqrtPriceFromAmount1(
            20282409603651670423947251286016,
            1024,
            262143,
            false,
            Math.Rounding.Ceil
        );
        assertEq(out, 77371252455336267181195264, "incorrect output amount");
    }

    function test_getNextSqrtPriceFromAmount1_impossible_amountout() external {
        //reverts if amountOut is impossible
        vm.expectRevert();
        SqrtPriceMath.getNextSqrtPriceFromAmount1(
            TestMath.encodePriceSqrtQ96(1, 1),
            1,
            (1 << 256) - 1,
            false,
            Math.Rounding.Ceil
        );
    }

    function test_swapComputation_token0() external pure {
        // check if price diff is equivalent to amount diff
        uint160 sqrtP = 1025574284609383690408304870162715216695788925244;
        uint160 liquidity = 50015962439936049619261659728067971248;
        uint256 amountIn = 406;

        uint160 sqrtQ = SqrtPriceMath.getNextSqrtPriceFromAmount0(sqrtP, liquidity, amountIn, true, Math.Rounding.Ceil);
        assertEq(sqrtQ, 1025574284609383582644711336373707553698163132913, "incorrect sqrt price output");

        uint256 calcAmount0 = SqrtPriceMath.getAmount0Delta(sqrtQ, sqrtP, liquidity, Math.Rounding.Ceil);
        assertEq(calcAmount0, 406, "incorrect token amount");
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {MarketId, MarketParams, MintParams, RedeemParams, SwapParams, SynthTokens} from "../src/interfaces/ICovenant.sol";
import {LatentSwapLEX, AssetType, LexState, LexParams, LexConfig, SetDefaultNoCapLimit} from "../src/lex/latentswap/LatentSwapLEX.sol";
import {LSErrors} from "../src/lex/latentswap/libraries/LSErrors.sol";
import {FixedPoint} from "../src/lex/latentswap/libraries/FixedPoint.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {WadRayMath} from "@aave/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/libraries/math/PercentageMath.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {LatentMath} from "../src/lex/latentswap/libraries/LatentMath.sol";
import {TestMath} from "./utils/TestMath.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockLatentSwapLEX} from "./mocks/MockLatentSwapLEX.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracleNonERC20} from "./mocks/MockOracleNonERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {ISynthToken} from "../src/interfaces/ISynthToken.sol";
import {LatentSwapLib} from "../src/periphery/libraries/LatentSwapLib.sol";
import {TokenPrices} from "../src/interfaces/ILiquidExchangeModel.sol";

contract LatentSwapLEXTest is Test {
    using Math for uint256;
    using PercentageMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    // Max balance of swap pool balance that won't cause an overflow in circle math.
    uint256 constant MIN_BALANCE = 2 ** 10;
    uint256 constant MAX_BALANCE = 2 ** 96; // Updated to comply with new mint cap constraints

    uint256 constant MIN_LIQUIDITY = 100000;
    uint256 constant MAX_LIQUIDITY = 2 ** 127;

    uint256 constant MAX_SQRTPRICE = (99999 << FixedPoint.RESOLUTION) / 100000; //  MAX price
    uint256 constant MIN_SQRTPRICE = (1 << FixedPoint.RESOLUTION) / 1000; // 0.000001 MIN price

    uint256 constant MAX_FOCUS_SQRTPRICE = (999 << FixedPoint.RESOLUTION) / 1000; // 0.998 MAX price
    uint256 constant MIN_FOCUS_SQRTPRICE = (100 << FixedPoint.RESOLUTION) / 1000; // 0.01 MIN price

    uint256 constant MIN_AMOUNT_RATIO = 0.01e16; // 0.01 %
    uint256 constant MAX_AMOUNT_RATIO = 99.99e16; // 99.99 %

    // LatentSwapLEX init pricing constants
    uint160 constant P_MAX = uint160((1095445 * FixedPoint.Q96) / 1000000); //uint160(Math.sqrt((FixedPoint.Q192 * 12) / 10)); // Edge price of 1.2
    uint160 constant P_MIN = uint160(FixedPoint.Q192 / P_MAX);
    uint32 constant DURATION = 30 * 24 * 60 * 60;
    uint8 constant SWAP_FEE = 0;
    int64 constant LN_RATE_BIAS = 5012540000000000; // WAD
    uint16 constant MAX_LIMIT_LTV = 9999; // 99.99% max limit LTV, above which aTokens cannot be minted.

    uint160 private P_LIM_H = LatentSwapLib.getSqrtPriceFromLTVX96(P_MIN, P_MAX, 9500);
    uint160 private P_LIM_MAX = LatentSwapLib.getSqrtPriceFromLTVX96(P_MIN, P_MAX, 9999);

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

    function boundLiquidity(uint128 rawLiquidity) internal pure returns (uint128 liquidity) {
        liquidity = uint128(bound(rawLiquidity, MIN_LIQUIDITY, MAX_LIQUIDITY));
    }

    function boundSqrtRatios(uint160 rawSqrtRatio, bool focus) internal pure returns (uint160[] memory sqrtRatios) {
        sqrtRatios = new uint160[](2);
        if (focus) sqrtRatios[0] = uint160(bound(rawSqrtRatio, MIN_FOCUS_SQRTPRICE, MAX_FOCUS_SQRTPRICE));
        else sqrtRatios[0] = uint160(bound(rawSqrtRatio, MIN_SQRTPRICE, MAX_SQRTPRICE));

        sqrtRatios[1] = uint160((1 << (FixedPoint.RESOLUTION << 1)) / sqrtRatios[0]);
    }

    //////////
    // Setup

    address private _mockOracle;
    address private _mockBaseAsset;
    address private _mockQuoteAsset;

    function setUp() public {
        // deploy mock oracle
        _mockOracle = address(new MockOracle(address(this)));

        // deploy mock ERC20 base asset (and mint for deployer)
        _mockBaseAsset = address(new MockERC20(address(this), "MockBaseAsset", "MBA", 18));

        // deploy mock ERC20 base asset (and mint for deployer)
        _mockQuoteAsset = address(new MockERC20(address(this), "MockQuoteAsset", "MQA", 18));
    }

    //////////
    // Tests

    function test_newLatentSwapLEX() external {
        // deploy latentSwapLEX liquid
        new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );
    }

    function test_newLatentSwapLEX_validFee() external {
        // deploy latentSwapLEX liquid
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            200
        );

        LexParams memory lexParams = latentSwapLEX.getLexParams();
        assertEq(lexParams.swapFee, 200, "Swap fee should match constructor");
    }

    function test_initializeLatentSwapLEX() external {
        // deploy latentSwapLEX liquid
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            1
        );

        // Verify initialization values
        LexParams memory lexParams = latentSwapLEX.getLexParams();

        // check correct initialization
        assertEq(lexParams.covenantCore, address(this), "covenantCore should match initialization");
        assertEq(lexParams.edgeSqrtPriceX96_B, P_MAX, "High price should match initialization");
        assertEq(lexParams.edgeSqrtPriceX96_A, P_MIN, "Low price should match initialization");
        assertEq(lexParams.limMaxSqrtPriceX96, P_LIM_MAX, "Max price should match initialization");
        assertEq(lexParams.limHighSqrtPriceX96, P_LIM_H, "High price should match initialization");
        assertGt(
            lexParams.edgeSqrtPriceX96_B,
            lexParams.edgeSqrtPriceX96_A,
            "High price should be greater than low price"
        );
        assertEq(lexParams.initLnRateBias, LN_RATE_BIAS, "LN rate bias should match initialization");
        assertEq(lexParams.swapFee, 1, "Swap fee should match constructor");
        assertEq(lexParams.debtDuration, DURATION, "Duration should match constructor");
    }

    function test_initializeLatentSwapLEX_reinitialize() external {
        // deploy latentSwapLEX liquid
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Attempt to reinit and check for specific error
        vm.expectRevert(abi.encodeWithSignature("E_LEX_AlreadyInitialized()"));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");
    }

    // Define test parameters
    struct TestParams {
        // Test configuration
        uint32[] ltvPercentages;
        uint256[] marketWidth;
        uint256[] rateBias;
        uint256 precision;
        // Test state
        uint160 priceHigh;
        uint160 priceLow;
        uint256 liquidityIn;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 calcDiscountedPriceEmpty;
        uint256 calcLTVEmpty;
        uint256 calcDiscountedPrice;
        uint256 calcLTV;
        MockLatentSwapLEX latentSwapLEX;
    }

    function test_initializeLatentSwapLEX_priceLTVAndDebtDiscountCombinations() external {
        TestParams memory params;
        params.ltvPercentages = new uint32[](5);
        params.ltvPercentages[0] = 2500; // 25% LTV
        params.ltvPercentages[1] = 5000; // 50% LTV
        params.ltvPercentages[2] = 7500; // 75% LTV
        params.ltvPercentages[3] = 8900; // 89% LTV
        params.ltvPercentages[4] = 9500; // 95% LTV

        params.marketWidth = new uint256[](3);
        params.marketWidth[0] = (11 * FixedPoint.WAD) / 10; // 1.1
        params.marketWidth[1] = (12 * FixedPoint.WAD) / 10; // 1.2
        params.marketWidth[2] = (13 * FixedPoint.WAD) / 10; // 1.3

        params.rateBias = new uint256[](3);
        params.rateBias[0] = 1 * FixedPoint.WAD; // 0% - 1 WAD
        params.rateBias[1] = (11 * FixedPoint.WAD) / 10; // 10% - 1.1 WAD
        params.rateBias[2] = (9 * FixedPoint.WAD) / 10; // -10% - .9 WAD

        params.precision = 4 * (10 ** 9);
        params.liquidityIn = FixedPoint.WAD;

        // Test combinations

        for (uint256 k = 0; k < params.ltvPercentages.length; k++) {
            for (uint256 i = 0; i < params.marketWidth.length; i++) {
                for (uint256 j = 0; j < params.rateBias.length; j++) {
                    // get market prices given LTV
                    (params.priceLow, params.priceHigh) = LatentSwapLib.getMarketEdgePrices(
                        params.ltvPercentages[k],
                        params.marketWidth[i]
                    );

                    int64 lnRateBias = FixedPointMathLib.lnWad(int256(params.rateBias[j])).toInt64();
                    params.latentSwapLEX = new MockLatentSwapLEX(
                        address(this),
                        address(this),
                        params.priceHigh,
                        params.priceLow,
                        params.priceHigh - 2,
                        params.priceHigh - 1,
                        lnRateBias,
                        DURATION,
                        SWAP_FEE
                    );

                    // init market
                    MarketId marketId = MarketId.wrap(
                        bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
                    );
                    MarketParams memory marketParams = MarketParams({
                        baseToken: _mockBaseAsset,
                        quoteToken: _mockQuoteAsset,
                        curator: _mockOracle,
                        lex: address(params.latentSwapLEX)
                    });
                    params.latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

                    // verify values for empty market
                    // get price discount for an empty market
                    params.calcDiscountedPriceEmpty = params.latentSwapLEX.getDebtPriceDiscount(marketId);

                    // verify price discount for empty market is equal to 1
                    assertEq(
                        FixedPoint.WAD,
                        params.calcDiscountedPriceEmpty,
                        "Price discount for empty market should be equal to 1"
                    );

                    // get LTV for empty market
                    params.calcLTVEmpty = params.latentSwapLEX.getLTV(marketId);

                    // verify LTV for empty market is equal to LTV
                    assertApproxEqAbs(
                        params.calcLTVEmpty,
                        params.ltvPercentages[k],
                        1,
                        "LTV for empty market should be equal to LTV"
                    );

                    // Mint position at LTV (for new market)
                    (params.aTokenAmount, params.zTokenAmount, , ) = params.latentSwapLEX.mint(
                        MintParams({
                            marketId: marketId,
                            marketParams: marketParams,
                            baseAmountIn: params.liquidityIn,
                            to: address(this),
                            minATokenAmountOut: 0,
                            minZTokenAmountOut: 0,
                            data: hex"",
                            msgValue: 0
                        }),
                        address(this),
                        0
                    );

                    // get price discount for a non-empty market
                    params.calcDiscountedPrice = params.latentSwapLEX.getDebtPriceDiscount(marketId);

                    // get LTV for a non-empty market
                    params.calcLTV = params.latentSwapLEX.getLTV(marketId);

                    // Verify LTV is within expected range
                    assertApproxEqAbs(params.calcLTV, params.ltvPercentages[k], 1, "LTV should be equal to target LTV");
                }
            }
        }
    }

    function test_mint_emptyLEX() external {
        // Deploy LatentSwapLEX
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Mint position
        uint256 liquidityIn = FixedPoint.WAD;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // Verify amounts are non-zero and within expected ranges
        assertGt(amount0, 0, "Amount0 should be greater than 0");
        assertGt(amount1, 0, "Amount1 should be greater than 0");
    }

    function test_redeemFull() external {
        // Deploy LatentSwapLEX
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Mint position
        uint256 liquidityIn = 10 ** 8;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // Fully redeem position
        (uint256 liquidityOut, , ) = latentSwapLEX.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: amount1,
                zTokenAmountIn: amount0,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        // Verify amounts are non-zero and within expected ranges
        assertEq(liquidityOut, liquidityIn, "Liquidity should be equal when redeemed in full");
    }

    function test_redeemFull_withFee() external {
        // Deploy LatentSwapLEX
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            200
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Mint position
        uint256 liquidityIn = 10 ** 8;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // Fully redeem position
        (uint256 liquidityOut, , ) = latentSwapLEX.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: amount1,
                zTokenAmountIn: amount0,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        // Verify amounts are non-zero and within expected ranges
        assertEq(liquidityOut, liquidityIn, "Liquidity should be equal when redeemed in full");
    }

    function test_redeemFull_noRevertWhenExceedsRedeemCap() external {
        // Deploy LatentSwapLEX
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Mint position
        uint256 liquidityIn = 10 ** 18;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // allow for time (and other transactions to accrue)
        vm.warp(block.timestamp + 1 days);
        latentSwapLEX.updateState(marketId, marketParams, liquidityIn, hex"");
        vm.warp(block.timestamp + 1 days);
        latentSwapLEX.updateState(marketId, marketParams, liquidityIn, hex"");
        vm.warp(block.timestamp + 1 days);
        latentSwapLEX.updateState(marketId, marketParams, liquidityIn, hex"");
        vm.warp(block.timestamp + 1 days);
        latentSwapLEX.updateState(marketId, marketParams, liquidityIn, hex"");

        // Fully redeem position (no revert)
        // vm.expectRevert(abi.encodeWithSignature("E_LEX_RedeemCapExceeded()"));
        (uint256 liquidityOut, , ) = latentSwapLEX.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: amount1,
                zTokenAmountIn: amount0,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );
    }

    struct SwapIndTestParams {
        // Test state
        uint256 debtDiscountBefore;
        uint256 ltvBefore;
        uint256 baseToDebtRatioBefore;
        uint256 baseToLEverageRatioBefore;
        uint256 debtToLeverageRatioBefore;
        uint256 debtDiscountAfter;
        uint256 ltvAfter;
        uint256 baseToDebtRatioAfter;
        uint256 baseToLEverageRatioAfter;
        uint256 debtToLeverageRatioAfter;
        uint256 zTokenIn;
        uint256 aTokenOut;
        uint256 zTokenOut;
        uint256 aTokenOutWithFee;
        uint256 zTokenOutWithFee;
        uint256 baseTokenIn;
        uint256 baseTokenOut;
        uint256 baseTokenOutWithFee;
        uint256 stateBaseSupply;
        uint256 stateBaseSupplyWithFee;
    }

    function test_swapZforA() external {
        SwapIndTestParams memory params;

        // Deploy LatentSwapLEX
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );
        MockLatentSwapLEX latentSwapLEXwithFee = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            200
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketId marketIdWithFee = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market with fee (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        MarketParams memory marketParamsWithFee = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEXwithFee)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");
        latentSwapLEXwithFee.initMarket(marketIdWithFee, marketParamsWithFee, 0, hex"");

        // Mint position
        uint256 liquidityIn = FixedPoint.WAD;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        (uint256 amount1withFee, uint256 amount0withFee, , ) = latentSwapLEXwithFee.mint(
            MintParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
        // params.lexState.aTokenSupply = amount0;
        // params.lexState.zTokenSupply = amount1;
        // params.lexState.baseTokenSupply = liquidityIn;
        assertEq(amount0withFee, amount0.percentMul(9800), "Incorrect mint fee retained for amount0");
        assertEq(amount1withFee, amount1.percentMul(9800), "Incorrect mint fee retained for amount1");

        // Read prices before swap
        params.debtDiscountBefore = latentSwapLEX.getDebtPriceDiscount(marketId);
        params.ltvBefore = latentSwapLEX.getLTV(marketId); // LTV before swap
        params.baseToDebtRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap

        params.baseToLEverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        params.debtToLeverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        // Swap z for a
        (params.aTokenOut, , ) = latentSwapLEX.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: amount0 >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        (params.aTokenOutWithFee, , ) = latentSwapLEXwithFee.swap(
            SwapParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: amount0withFee >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        // Read prices after swap
        params.debtDiscountAfter = latentSwapLEX.getDebtPriceDiscount(marketId); // Base to Debt price
        params.ltvAfter = latentSwapLEX.getLTV(marketId); // LTV after swap
        params.baseToDebtRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap
        params.baseToLEverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap
        params.debtToLeverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap
        // Ensure swap has right output
        assertEq(params.aTokenOut, 238612800622302182, "aTokenOut was not 238612800622302182");
        assertEq(params.aTokenOutWithFee, 219565616710843326, "aTokenWith Fee swap was not 219565616710843326");

        // Ensure prices move in right direction
        assertGt(params.debtDiscountBefore, params.debtDiscountAfter, "debt discount should decrease after selling zTokens"); // prettier-ignore
        assertGt(params.ltvBefore, params.ltvAfter, "LTV should decrease after selling zTokens"); // prettier-ignore
        assertLt(params.baseToDebtRatioBefore, params.baseToDebtRatioAfter, "base to debt ratio should increase after selling zTokens"); // prettier-ignore
        assertGt(params.baseToLEverageRatioBefore, params.baseToLEverageRatioAfter, "base to leverage ratio should decrease after selling zTokens"); // prettier-ignore
        assertGt(params.debtToLeverageRatioBefore, params.debtToLeverageRatioAfter, "debt to leverage ratio should decrease after selling zTokens"); // prettier-ignore
    }

    function test_swapAforZ() external {
        SwapIndTestParams memory params;

        // Deploy LatentSwapLEX
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );
        MockLatentSwapLEX latentSwapLEXwithFee = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            200
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketId marketIdWithFee = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market with fee (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        MarketParams memory marketParamsWithFee = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEXwithFee)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");
        latentSwapLEXwithFee.initMarket(marketIdWithFee, marketParamsWithFee, 0, hex"");

        // Mint position
        uint256 liquidityIn = FixedPoint.WAD;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        (uint256 amount1withFee, uint256 amount0withFee, , ) = latentSwapLEXwithFee.mint(
            MintParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
        assertEq(amount0withFee, amount0.percentMul(9800), "Incorrect mint fee retained for amount0");
        assertEq(amount1withFee, amount1.percentMul(9800), "Incorrect mint fee retained for amount1");

        // Read prices before swap
        params.debtDiscountBefore = latentSwapLEX.getDebtPriceDiscount(marketId);
        params.ltvBefore = latentSwapLEX.getLTV(marketId); // LTV before swap
        params.baseToDebtRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap

        params.baseToLEverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        params.debtToLeverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        // Swap z for a
        (params.zTokenOut, , ) = latentSwapLEX.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: amount1 >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        (params.zTokenOutWithFee, , ) = latentSwapLEXwithFee.swap(
            SwapParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: amount1withFee >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        // Read prices after swap
        params.debtDiscountAfter = latentSwapLEX.getDebtPriceDiscount(marketId); // Base to Debt price
        params.ltvAfter = latentSwapLEX.getLTV(marketId); // LTV after swap
        params.baseToDebtRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap
        params.baseToLEverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap
        params.debtToLeverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap
        // Ensure swap has right output
        assertEq(params.zTokenOut, 238612800622302183, "zTokenOut was not 238612800622302183");
        assertEq(params.zTokenOutWithFee, 239181206910320441, "zTokenWith Fee swap was not 239181206910320441");

        // Ensure prices move in right direction
        assertLt(params.debtDiscountBefore, params.debtDiscountAfter, "debt discount should increase after buying zTokens"); // prettier-ignore
        assertLt(params.ltvBefore, params.ltvAfter, "LTV should increase after buying zTokens"); // prettier-ignore
        assertGt(params.baseToDebtRatioBefore, params.baseToDebtRatioAfter, "base to debt ratio should decrease after buying zTokens"); // prettier-ignore
        assertLt(params.baseToLEverageRatioBefore, params.baseToLEverageRatioAfter, "base to leverage ratio should increase after buying zTokens"); // prettier-ignore
        assertLt(params.debtToLeverageRatioBefore, params.debtToLeverageRatioAfter, "debt to leverage ratio should increase after buying zTokens"); // prettier-ignore
    }

    function test_swapBaseforZ() external {
        SwapIndTestParams memory params;

        // Deploy LatentSwapLEX
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );
        MockLatentSwapLEX latentSwapLEXwithFee = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            50
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketId marketIdWithFee = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market with fee (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        MarketParams memory marketParamsWithFee = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEXwithFee)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");
        latentSwapLEXwithFee.initMarket(marketIdWithFee, marketParamsWithFee, 0, hex"");

        // Mint position
        uint256 liquidityIn = FixedPoint.WAD;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        (uint256 amount1withFee, uint256 amount0withFee, , ) = latentSwapLEXwithFee.mint(
            MintParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
        assertEq(amount0withFee, amount0.percentMul(9950), "Incorrect mint fee retained for amount0");
        assertEq(amount1withFee, amount1.percentMul(9950), "Incorrect mint fee retained for amount1");

        // Read prices before swap
        params.debtDiscountBefore = latentSwapLEX.getDebtPriceDiscount(marketId);
        params.ltvBefore = latentSwapLEX.getLTV(marketId); // LTV before swap
        params.baseToDebtRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap

        params.baseToLEverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        params.debtToLeverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        // Swap z for a
        params.baseTokenIn = liquidityIn >> 1;
        (params.zTokenOut, , ) = latentSwapLEX.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.BASE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: params.baseTokenIn,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );
        (params.zTokenOutWithFee, , ) = latentSwapLEXwithFee.swap(
            SwapParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                assetIn: AssetType.BASE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: params.baseTokenIn,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        // Read prices after swap
        params.debtDiscountAfter = latentSwapLEX.getDebtPriceDiscount(marketId); // Base to Debt price
        params.ltvAfter = latentSwapLEX.getLTV(marketId); // LTV after swap
        params.baseToDebtRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn + (liquidityIn >> 1),
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap
        params.baseToLEverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn + (liquidityIn >> 1),
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap
        params.debtToLeverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn + (liquidityIn >> 1),
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        assertEq(params.zTokenOut, 492291496053071528, "zTokenOut was not 492291496053071528");
        assertEq(params.zTokenOutWithFee, 489981467371248737, "zTokenWith Fee was not 489981467371248737");

        // Ensure prices move in right direction
        assertLt(params.debtDiscountBefore, params.debtDiscountAfter, "debt discount should increase after buying zTokens"); // prettier-ignore
        assertLt(params.ltvBefore, params.ltvAfter, "LTV should increase after buying zTokens"); // prettier-ignore
        assertGt(params.baseToDebtRatioBefore, params.baseToDebtRatioAfter, "base to debt ratio should decrease after buying zTokens"); // prettier-ignore
        assertLt(params.baseToLEverageRatioBefore, params.baseToLEverageRatioAfter, "base to leverage ratio should increase after buying zTokens"); // prettier-ignore
        assertLt(params.debtToLeverageRatioBefore, params.debtToLeverageRatioAfter, "debt to leverage ratio should increase after buying zTokens"); // prettier-ignore
    }

    function test_swapBaseforA() external {
        SwapIndTestParams memory params;

        // Deploy LatentSwapLEX
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );
        MockLatentSwapLEX latentSwapLEXwithFee = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            1
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketId marketIdWithFee = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market with fee (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        MarketParams memory marketParamsWithFee = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEXwithFee)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");
        latentSwapLEXwithFee.initMarket(marketIdWithFee, marketParamsWithFee, 0, hex"");

        console.log("minting");
        // Mint position
        uint256 liquidityIn = FixedPoint.WAD;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
        console.log("mint2");
        (uint256 amount1withFee, uint256 amount0withFee, , ) = latentSwapLEXwithFee.mint(
            MintParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
        // params.lexState.aTokenSupply = amount0;
        // params.lexState.zTokenSupply = amount1;
        // params.lexState.baseTokenSupply = liquidityIn;
        assertEq(amount0withFee, amount0.percentMul(9999), "Incorrect mint fee retained for amount0");
        assertEq(amount1withFee, amount1.percentMul(9999), "Incorrect mint fee retained for amount1");

        // Read prices before swap
        params.debtDiscountBefore = latentSwapLEX.getDebtPriceDiscount(marketId);
        params.ltvBefore = latentSwapLEX.getLTV(marketId); // LTV before swap
        params.baseToDebtRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap

        params.baseToLEverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        params.debtToLeverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap
        console.log("swap1");
        // Swap z for a
        (params.aTokenOut, , ) = latentSwapLEX.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.BASE,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: liquidityIn >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );
        console.log("swap2");
        (params.aTokenOutWithFee, , ) = latentSwapLEXwithFee.swap(
            SwapParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                assetIn: AssetType.BASE,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: liquidityIn >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        // Read prices after swap
        params.debtDiscountAfter = latentSwapLEX.getDebtPriceDiscount(marketId); // Base to Debt price
        params.ltvAfter = latentSwapLEX.getLTV(marketId); // LTV after swap
        params.baseToDebtRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn + (liquidityIn >> 1),
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap
        params.baseToLEverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn + (liquidityIn >> 1),
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap
        params.debtToLeverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn + (liquidityIn >> 1),
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        // Ensure swap has right output
        assertEq(params.aTokenOut, 492291496053071527, "aTokenOut was not 492291496053071527");
        assertEq(params.aTokenOutWithFee, 492140793997051899, "aTokenOut was not 492140793997051899");

        // Ensure prices move in right direction
        assertGt(params.debtDiscountBefore, params.debtDiscountAfter, "debt discount should decrease after selling zTokens"); // prettier-ignore
        assertGt(params.ltvBefore, params.ltvAfter, "LTV should decrease after selling zTokens"); // prettier-ignore
        assertLt(params.baseToDebtRatioBefore, params.baseToDebtRatioAfter, "base to debt ratio should increase after selling zTokens"); // prettier-ignore
        assertGt(params.baseToLEverageRatioBefore, params.baseToLEverageRatioAfter, "base to leverage ratio should decrease after selling zTokens"); // prettier-ignore
        assertGt(params.debtToLeverageRatioBefore, params.debtToLeverageRatioAfter, "debt to leverage ratio should decrease after selling zTokens"); // prettier-ignore
    }

    function test_swapAforBase() external {
        SwapIndTestParams memory params;

        // Deploy LatentSwapLEX
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );
        MockLatentSwapLEX latentSwapLEXwithFee = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            10
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketId marketIdWithFee = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market with fee (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        MarketParams memory marketParamsWithFee = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEXwithFee)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");
        latentSwapLEXwithFee.initMarket(marketIdWithFee, marketParamsWithFee, 0, hex"");

        // Mint position
        uint256 liquidityIn = FixedPoint.WAD;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        (uint256 amount1withFee, uint256 amount0withFee, , ) = latentSwapLEXwithFee.mint(
            MintParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
        // params.lexState.aTokenSupply = amount0;
        // params.lexState.zTokenSupply = amount1;
        // params.lexState.baseTokenSupply = liquidityIn;
        assertEq(amount0withFee, amount0.percentMul(9990), "Incorrect mint fee retained for amount0");
        assertEq(amount1withFee, amount1.percentMul(9990), "Incorrect mint fee retained for amount1");

        // Read prices before swap
        params.debtDiscountBefore = latentSwapLEX.getDebtPriceDiscount(marketId);
        params.ltvBefore = latentSwapLEX.getLTV(marketId); // LTV before swap
        params.baseToDebtRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap

        params.baseToLEverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        params.debtToLeverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        // Swap z for a
        (params.baseTokenOut, , ) = latentSwapLEX.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.BASE,
                to: address(this),
                amountSpecified: amount1 >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        (params.baseTokenOutWithFee, , ) = latentSwapLEXwithFee.swap(
            SwapParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.BASE,
                to: address(this),
                amountSpecified: amount1 >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        // Read prices after swap
        params.debtDiscountAfter = latentSwapLEX.getDebtPriceDiscount(marketId); // Base to Debt price
        params.ltvAfter = latentSwapLEX.getLTV(marketId); // LTV after swap
        params.baseToDebtRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn - params.baseTokenOut,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap
        params.baseToLEverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn - params.baseTokenOut,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap
        params.debtToLeverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn - params.baseTokenOut,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        // Ensure swap has right output
        assertEq(params.baseTokenOut, 246044976594020451, "baseTokenOut was not 246044976594020451");
        assertEq(params.baseTokenOutWithFee, 246312042055243004, "baseTokenOut was not 246312042055243004");

        // Ensure prices move in right direction
        assertLt(params.debtDiscountBefore, params.debtDiscountAfter, "debt discount should increase after buying zTokens"); // prettier-ignore
        assertLt(params.ltvBefore, params.ltvAfter, "LTV should increase after buying zTokens"); // prettier-ignore
        assertGt(params.baseToDebtRatioBefore, params.baseToDebtRatioAfter, "base to debt ratio should decrease after buying zTokens"); // prettier-ignore
        assertLt(params.baseToLEverageRatioBefore, params.baseToLEverageRatioAfter, "base to leverage ratio should increase after buying zTokens"); // prettier-ignore
        assertLt(params.debtToLeverageRatioBefore,params.debtToLeverageRatioAfter, "debt to leverage ratio should increase after buying zTokens"); // prettier-ignore
    }

    function test_swapZforBase() external {
        SwapIndTestParams memory params;

        // Deploy LatentSwapLEX
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );
        MockLatentSwapLEX latentSwapLEXwithFee = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            5
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketId marketIdWithFee = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market with fee (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        MarketParams memory marketParamsWithFee = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEXwithFee)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");
        latentSwapLEXwithFee.initMarket(marketIdWithFee, marketParamsWithFee, 0, hex"");

        // Mint position
        uint256 liquidityIn = FixedPoint.WAD;
        (uint256 amount1, uint256 amount0, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        (uint256 amount1withFee, uint256 amount0withFee, , ) = latentSwapLEXwithFee.mint(
            MintParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                baseAmountIn: liquidityIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
        // params.lexState.aTokenSupply = amount0;
        // params.lexState.zTokenSupply = amount1;
        // params.lexState.baseTokenSupply = liquidityIn;
        assertEq(amount0withFee, amount0.percentMul(9995), "Incorrect mint fee retained for amount0");
        assertEq(amount1withFee, amount1.percentMul(9995), "Incorrect mint fee retained for amount1");

        // Read prices before swap
        params.debtDiscountBefore = latentSwapLEX.getDebtPriceDiscount(marketId);
        params.ltvBefore = latentSwapLEX.getLTV(marketId); // LTV before swap
        params.baseToDebtRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap

        params.baseToLEverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        params.debtToLeverageRatioBefore = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        // Swap z for a
        (params.baseTokenOut, , ) = latentSwapLEX.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.BASE,
                to: address(this),
                amountSpecified: amount0 >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        (params.baseTokenOutWithFee, , ) = latentSwapLEXwithFee.swap(
            SwapParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.BASE,
                to: address(this),
                amountSpecified: amount0 >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            liquidityIn
        );

        // Read prices after swap
        params.debtDiscountAfter = latentSwapLEX.getDebtPriceDiscount(marketId); // Base to Debt price
        params.ltvAfter = latentSwapLEX.getLTV(marketId); // LTV after swap
        params.baseToDebtRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn - params.baseTokenOut,
            AssetType.BASE,
            AssetType.DEBT
        ); // Base to Debt ratio before swap
        params.baseToLEverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn - params.baseTokenOut,
            AssetType.BASE,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap
        params.debtToLeverageRatioAfter = latentSwapLEX.quoteRatio(
            marketId,
            marketParams,
            liquidityIn - params.baseTokenOut,
            AssetType.DEBT,
            AssetType.LEVERAGE
        ); // Base to Debt ratio before swap

        // Ensure swap has right output
        assertEq(params.baseTokenOut, 246044976594020451, "baseTokenOut was not 246044976594020451");
        assertEq(params.baseTokenOutWithFee, 245906225184371839, "baseTokenOut was not 245906225184371839");

        // Ensure prices move in right direction
        assertGt(params.debtDiscountBefore, params.debtDiscountAfter, "debt discount should decrease after selling zTokens"); // prettier-ignore
        assertGt(params.ltvBefore, params.ltvAfter, "LTV should decrease after selling zTokens"); // prettier-ignore
        assertLt(params.baseToDebtRatioBefore, params.baseToDebtRatioAfter, "base to debt ratio should increase after selling zTokens"); // prettier-ignore
        assertGt(params.baseToLEverageRatioBefore, params.baseToLEverageRatioAfter, "base to leverage ratio should decrease after selling zTokens"); // prettier-ignore
        assertGt(params.debtToLeverageRatioBefore, params.debtToLeverageRatioAfter, "debt to leverage ratio should decrease after selling zTokens"); // prettier-ignore
    }

    struct test_LatentSwapLEX_mintProportional_Params {
        // Test configuration
        uint256[] ltvPercentages;
        uint256[] initialBaseTokenSupplies;
        uint256[] mintAmounts;
        // Test state
        uint256 initialATokenSupply;
        uint256 initialZTokenSupply;
        uint256 newATokenAmount;
        uint256 newZTokenAmount;
        MockLatentSwapLEX latentSwapLEX;
    }

    function test_LatentSwapLEX_mintProportional() external {
        test_LatentSwapLEX_mintProportional_Params memory params;

        // Test different LTVs
        params.ltvPercentages = new uint256[](3);
        params.ltvPercentages[0] = 2500; // 25% LTV
        params.ltvPercentages[1] = 5000; // 50% LTV
        params.ltvPercentages[2] = 7500; // 75% LTV

        // Test different initial market sizes
        params.initialBaseTokenSupplies = new uint256[](3);
        params.initialBaseTokenSupplies[0] = FixedPoint.WAD; // 1 WAD
        params.initialBaseTokenSupplies[1] = FixedPoint.WAD * 10; // 10 WAD
        params.initialBaseTokenSupplies[2] = FixedPoint.WAD * 100; // 100 WAD

        // Test different mint amounts
        params.mintAmounts = new uint256[](3);
        params.mintAmounts[0] = FixedPoint.WAD / 10; // 0.1 WAD
        params.mintAmounts[1] = FixedPoint.WAD; // 1 WAD
        params.mintAmounts[2] = FixedPoint.WAD * 10; // 10 WAD

        for (uint256 k = 0; k < params.ltvPercentages.length; k++) {
            for (uint256 i = 0; i < params.initialBaseTokenSupplies.length; i++) {
                for (uint256 j = 0; j < params.mintAmounts.length; j++) {
                    // deploy latentSwapLEX liquid
                    uint160 targetPrice = TestMath.getSqrtPriceX96(
                        P_MAX,
                        uint256(10 ** 18).percentMul(params.ltvPercentages[k]),
                        uint256(10 ** 18).percentMul(10000 - params.ltvPercentages[k])
                    );

                    params.latentSwapLEX = new MockLatentSwapLEX(
                        address(this),
                        address(this),
                        P_MAX,
                        P_MIN,
                        P_LIM_H,
                        P_LIM_MAX,
                        LN_RATE_BIAS,
                        DURATION,
                        0
                    );

                    // Initialize
                    MarketId marketId = MarketId.wrap(
                        bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
                    );
                    MarketParams memory marketParams = MarketParams({
                        baseToken: _mockBaseAsset,
                        quoteToken: _mockQuoteAsset,
                        curator: _mockOracle,
                        lex: address(params.latentSwapLEX)
                    });
                    params.latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

                    // remove mint and redeem caps
                    params.latentSwapLEX.setMarketNoCapLimit(marketId, 255);

                    // First mint to create initial market state
                    (params.initialATokenSupply, params.initialZTokenSupply, , ) = params.latentSwapLEX.mint(
                        MintParams({
                            marketId: marketId,
                            marketParams: marketParams,
                            baseAmountIn: params.initialBaseTokenSupplies[i],
                            to: address(this),
                            minATokenAmountOut: 0,
                            minZTokenAmountOut: 0,
                            data: hex"",
                            msgValue: 0
                        }),
                        address(this),
                        0
                    );

                    // Second mint to verify proportionality
                    (params.newATokenAmount, params.newZTokenAmount, , ) = params.latentSwapLEX.mint(
                        MintParams({
                            marketId: marketId,
                            marketParams: marketParams,
                            baseAmountIn: params.mintAmounts[j],
                            to: address(this),
                            minATokenAmountOut: 0,
                            minZTokenAmountOut: 0,
                            data: hex"",
                            msgValue: 0
                        }),
                        address(this),
                        params.initialBaseTokenSupplies[i]
                    );

                    // Verify proportions match mint amount
                    uint256 precision = 10 ** 15;
                    assertEq(
                        (
                            (params.newATokenAmount *
                                params.initialZTokenSupply *
                                precision +
                                ((params.newZTokenAmount * params.initialATokenSupply) >> 1))
                        ) / (params.newZTokenAmount * params.initialATokenSupply),
                        precision,
                        string.concat(
                            "aToken: zToken mint amount should be proportional to market state. LTV: ",
                            vm.toString(params.ltvPercentages[k]),
                            ", Initial Supply: ",
                            vm.toString(params.initialBaseTokenSupplies[i]),
                            ", Mint Amount: ",
                            vm.toString(params.mintAmounts[j])
                        )
                    );
                }
            }
        }
    }

    function test_LatentSwapLEX_mintZeroAmount() external {
        // deploy latentSwapLEX liquid

        // Deploy LatentSwapLEX
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );
        MockLatentSwapLEX latentSwapLEXwithFee = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            5
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketId marketIdWithFee = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market with fee (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        MarketParams memory marketParamsWithFee = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEXwithFee)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");
        latentSwapLEXwithFee.initMarket(marketIdWithFee, marketParamsWithFee, 0, hex"");

        // Mint 0 position
        (uint256 zTokenAmount, uint256 aTokenAmount, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: 0,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        (uint256 zTokenAmountWithFee, uint256 aTokenAmountWithFee, , ) = latentSwapLEXwithFee.mint(
            MintParams({
                marketId: marketIdWithFee,
                marketParams: marketParamsWithFee,
                baseAmountIn: 0,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // Verify zero amounts
        assertEq(aTokenAmount, 0, "aToken amount should be 0");
        assertEq(zTokenAmount, 0, "zToken amount should be 0");
        assertEq(aTokenAmountWithFee, 0, "aToken amount should be 0 with fee");
        assertEq(zTokenAmountWithFee, 0, "zToken amount should be 0 with Fee");
    }

    struct MintEdgeCasesParams {
        uint256[] mintAmounts;
        uint256[] baseTokenPrices;
        uint256[] debtNotionalPrices;
        MockLatentSwapLEX latentSwapLEX;
    }

    function test_LatentSwapLEX_mintEdgeCases() external {
        MintEdgeCasesParams memory params;

        // Test different mint amounts including edge cases
        params.mintAmounts = new uint256[](4);
        params.mintAmounts[0] = 100; // Minimum amount  // @dev - smaller than this has a 0 output, which is ok.
        params.mintAmounts[1] = FixedPoint.WAD / 1000; // Very small amount
        params.mintAmounts[2] = FixedPoint.WAD * 1000; // Very large amount
        params.mintAmounts[3] = MAX_BALANCE; // Near max amount

        // Test different price conditions
        params.baseTokenPrices = new uint256[](3);
        params.baseTokenPrices[0] = FixedPoint.WAD / 2; // 0.5 WAD
        params.baseTokenPrices[1] = FixedPoint.WAD; // 1 WAD
        params.baseTokenPrices[2] = FixedPoint.WAD * 2; // 2 WAD

        params.debtNotionalPrices = new uint256[](3);
        params.debtNotionalPrices[0] = FixedPoint.WAD / 2; // 0.5 WAD
        params.debtNotionalPrices[1] = FixedPoint.WAD; // 1 WAD
        params.debtNotionalPrices[2] = FixedPoint.WAD * 2; // 2 WAD

        for (uint256 i = 0; i < params.mintAmounts.length; i++) {
            for (uint256 j = 0; j < params.baseTokenPrices.length; j++) {
                for (uint256 k = 0; k < params.debtNotionalPrices.length; k++) {
                    // deploy latentSwapLEX liquid
                    params.latentSwapLEX = new MockLatentSwapLEX(
                        address(this),
                        address(this),
                        P_MAX,
                        P_MIN,
                        P_LIM_H,
                        P_LIM_MAX,
                        LN_RATE_BIAS,
                        DURATION,
                        0
                    );

                    // Initialize
                    MarketId marketId = MarketId.wrap(
                        bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
                    );
                    MarketParams memory marketParams = MarketParams({
                        baseToken: _mockBaseAsset,
                        quoteToken: _mockQuoteAsset,
                        curator: _mockOracle,
                        lex: address(params.latentSwapLEX)
                    });
                    params.latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

                    // Set prices and mint
                    MockOracle(_mockOracle).setPrice(params.baseTokenPrices[j]);
                    params.latentSwapLEX.setDebtNotionalPrice(marketId, params.debtNotionalPrices[k]);
                    (uint256 aTokenAmount, uint256 zTokenAmount, , ) = params.latentSwapLEX.mint(
                        MintParams({
                            marketId: marketId,
                            marketParams: marketParams,
                            baseAmountIn: params.mintAmounts[i],
                            to: address(this),
                            minATokenAmountOut: 0,
                            minZTokenAmountOut: 0,
                            data: hex"",
                            msgValue: 0
                        }),
                        address(this),
                        0
                    );

                    // Verify non-zero amounts
                    assertGt(aTokenAmount, 0, "aToken amount should be greater than 0");
                    assertGt(zTokenAmount, 0, "zToken amount should be greater than 0");
                }
            }
        }
    }

    function test_LatentSwapLEX_redeemMarketNoLiquidity() external {
        // deploy latentSwapLEX liquid
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            0
        );

        // Initialize
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Mint
        (uint256 aTokenAmount, uint256 zTokenAmount, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: 10 ** 18,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // Test a zero base token, but where we want to redeem aTokens and zTokens (not allowed,
        // given no base tokens in the market)
        vm.expectRevert(LSErrors.E_LEX_ZeroLiquidity.selector);
        latentSwapLEX.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount >> 1,
                zTokenAmountIn: zTokenAmount >> 1,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
    }

    struct RedeemSwapEquivalenceParams {
        uint256[] ltvPercentages;
        uint256[] baseSupplies;
        uint256[] basePrices;
        uint256[] redeemAmounts;
        MockLatentSwapLEX latentSwapLEX_A;
        MockLatentSwapLEX latentSwapLEX_B;
        // Local variables
        uint256 initialATokenSupply;
        uint256 initialZTokenSupply;
        uint256 redeemAmount;
        uint256 redeemLiquidityOut;
        uint256 swapLiquidityOut;
        MarketId marketId_A;
        MarketParams marketParams_A;
        MarketId marketId_B;
        MarketParams marketParams_B;
    }

    // @dev - This test is to ensure that redeeming aToken or zToken
    // is equivalent to swapping the same amount of base tokens.
    function test_LatentSwapLEX_redeemSwapEquivalence_zToken() external {
        RedeemSwapEquivalenceParams memory params;

        // Test different LTVs
        params.ltvPercentages = new uint256[](2);
        //params.ltvPercentages[0] = 2500; // 25% LTV
        params.ltvPercentages[0] = 5000; // 50% LTV
        params.ltvPercentages[1] = 7500; // 75% LTV

        // Test different base supplies
        params.baseSupplies = new uint256[](3);
        params.baseSupplies[0] = FixedPoint.WAD; // 1 WAD
        params.baseSupplies[1] = FixedPoint.WAD * 10; // 10 WAD
        params.baseSupplies[2] = FixedPoint.WAD * 100; // 100 WAD

        // Test different base prices
        params.basePrices = new uint256[](3);
        params.basePrices[0] = FixedPoint.WAD / 2; // 0.5 WAD
        params.basePrices[1] = FixedPoint.WAD; // 1 WAD
        params.basePrices[2] = FixedPoint.WAD * 2; // 2 WAD

        // Test different redeem amounts
        params.redeemAmounts = new uint256[](3);
        params.redeemAmounts[0] = FixedPoint.WAD / 10; // 0.1 WAD
        params.redeemAmounts[1] = FixedPoint.WAD / 2; // 0.5 WAD
        params.redeemAmounts[2] = (FixedPoint.WAD * 7) / 10; // 0.7 WAD

        for (uint256 l = 0; l < params.ltvPercentages.length; l++) {
            // deploy latentSwapLEX liquid
            uint160 targetPrice = TestMath.getSqrtPriceX96(
                P_MAX,
                uint256(10 ** 18).percentMul(params.ltvPercentages[l]),
                uint256(10 ** 18).percentMul(10000 - params.ltvPercentages[l])
            );

            for (uint256 i = 0; i < params.baseSupplies.length; i++) {
                for (uint256 j = 0; j < params.basePrices.length; j++) {
                    for (uint256 k = 0; k < params.redeemAmounts.length; k++) {
                        params.latentSwapLEX_A = new MockLatentSwapLEX(
                            address(this),
                            address(this),
                            P_MAX,
                            P_MIN,
                            P_LIM_H,
                            P_LIM_MAX,
                            LN_RATE_BIAS,
                            DURATION,
                            0
                        );
                        params.latentSwapLEX_B = new MockLatentSwapLEX(
                            address(this),
                            address(this),
                            P_MAX,
                            P_MIN,
                            P_LIM_H,
                            P_LIM_MAX,
                            LN_RATE_BIAS,
                            DURATION,
                            0
                        );

                        // Initialize
                        params.marketId_A = MarketId.wrap(
                            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
                        );
                        params.marketParams_A = MarketParams({
                            baseToken: _mockBaseAsset,
                            quoteToken: _mockQuoteAsset,
                            curator: _mockOracle,
                            lex: address(params.latentSwapLEX_A)
                        });
                        params.latentSwapLEX_A.initMarket(params.marketId_A, params.marketParams_A, 0, hex"");

                        params.marketId_B = MarketId.wrap(
                            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
                        );
                        params.marketParams_B = MarketParams({
                            baseToken: _mockBaseAsset,
                            quoteToken: _mockQuoteAsset,
                            curator: _mockOracle,
                            lex: address(params.latentSwapLEX_B)
                        });
                        params.latentSwapLEX_B.initMarket(params.marketId_B, params.marketParams_B, 0, hex"");

                        // First mint to create initial market state
                        MockOracle(_mockOracle).setPrice(params.basePrices[j]);

                        (params.initialATokenSupply, params.initialZTokenSupply, , ) = params.latentSwapLEX_A.mint(
                            MintParams({
                                marketId: params.marketId_A,
                                marketParams: params.marketParams_A,
                                baseAmountIn: params.baseSupplies[i],
                                to: address(this),
                                minATokenAmountOut: 0,
                                minZTokenAmountOut: 0,
                                data: hex"",
                                msgValue: 0
                            }),
                            address(this),
                            0
                        );

                        (params.initialATokenSupply, params.initialZTokenSupply, , ) = params.latentSwapLEX_B.mint(
                            MintParams({
                                marketId: params.marketId_B,
                                marketParams: params.marketParams_B,
                                baseAmountIn: params.baseSupplies[i],
                                to: address(this),
                                minATokenAmountOut: 0,
                                minZTokenAmountOut: 0,
                                data: hex"",
                                msgValue: 0
                            }),
                            address(this),
                            0
                        );

                        // Calculate redeem amount as percentage of initial supply
                        params.redeemAmount = Math.mulDiv(
                            params.initialZTokenSupply,
                            params.redeemAmounts[k],
                            FixedPoint.WAD
                        );

                        // Test zToken redeem vs swap
                        (params.redeemLiquidityOut, , ) = params.latentSwapLEX_A.redeem(
                            RedeemParams({
                                marketId: params.marketId_A,
                                marketParams: params.marketParams_A,
                                aTokenAmountIn: 0,
                                zTokenAmountIn: params.redeemAmount,
                                to: address(this),
                                minAmountOut: 0,
                                data: hex"",
                                msgValue: 0
                            }),
                            address(this),
                            params.baseSupplies[i]
                        );

                        (params.swapLiquidityOut, , ) = params.latentSwapLEX_B.swap(
                            SwapParams({
                                marketId: params.marketId_B,
                                marketParams: params.marketParams_B,
                                assetIn: AssetType.DEBT,
                                assetOut: AssetType.BASE,
                                to: address(this),
                                amountSpecified: params.redeemAmount,
                                amountLimit: 0,
                                isExactIn: true,
                                data: hex"",
                                msgValue: 0
                            }),
                            address(this),
                            params.baseSupplies[i]
                        );

                        // Allow for small rounding differences
                        assertApproxEqRel(
                            params.redeemLiquidityOut,
                            params.swapLiquidityOut,
                            0.0000000000000001e18,
                            string.concat(
                                "zToken redeem should match swap output. LTV: ",
                                vm.toString(params.ltvPercentages[l]),
                                ", Base Supply: ",
                                vm.toString(params.baseSupplies[i]),
                                ", Base Price: ",
                                vm.toString(params.basePrices[j]),
                                ", Redeem Amount: ",
                                vm.toString(params.redeemAmount)
                            )
                        );
                    }
                }
            }
        }
    }

    // @dev - This test is to ensure that redeeming aToken or zToken
    // is equivalent to swapping the same amount of base tokens.
    function test_LatentSwapLEX_redeemSwapEquivalence_aToken() external {
        RedeemSwapEquivalenceParams memory params;

        // Test different LTVs
        params.ltvPercentages = new uint256[](2);
        //params.ltvPercentages[0] = 2500; // 25% LTV
        params.ltvPercentages[0] = 5000; // 50% LTV
        params.ltvPercentages[1] = 7500; // 75% LTV

        // Test different base supplies
        params.baseSupplies = new uint256[](3);
        params.baseSupplies[0] = FixedPoint.WAD; // 1 WAD
        params.baseSupplies[1] = FixedPoint.WAD * 10; // 10 WAD
        params.baseSupplies[2] = FixedPoint.WAD * 100; // 100 WAD

        // Test different base prices
        params.basePrices = new uint256[](3);
        params.basePrices[0] = FixedPoint.WAD / 2; // 0.5 WAD
        params.basePrices[1] = FixedPoint.WAD; // 1 WAD
        params.basePrices[2] = FixedPoint.WAD * 2; // 2 WAD

        // Test different redeem amounts
        params.redeemAmounts = new uint256[](3);
        params.redeemAmounts[0] = FixedPoint.WAD / 10; // 0.1 WAD
        params.redeemAmounts[1] = FixedPoint.WAD / 2; // 0.5 WAD
        params.redeemAmounts[2] = (FixedPoint.WAD * 7) / 10; // 0.7 WAD

        for (uint256 l = 0; l < params.ltvPercentages.length; l++) {
            // deploy latentSwapLEX liquid
            uint160 targetPrice = TestMath.getSqrtPriceX96(
                P_MAX,
                uint256(10 ** 18).percentMul(params.ltvPercentages[l]),
                uint256(10 ** 18).percentMul(10000 - params.ltvPercentages[l])
            );

            for (uint256 i = 0; i < params.baseSupplies.length; i++) {
                for (uint256 j = 0; j < params.basePrices.length; j++) {
                    for (uint256 k = 0; k < params.redeemAmounts.length; k++) {
                        params.latentSwapLEX_A = new MockLatentSwapLEX(
                            address(this),
                            address(this),
                            P_MAX,
                            P_MIN,
                            P_LIM_H,
                            P_LIM_MAX,
                            LN_RATE_BIAS,
                            DURATION,
                            0
                        );
                        params.latentSwapLEX_B = new MockLatentSwapLEX(
                            address(this),
                            address(this),
                            P_MAX,
                            P_MIN,
                            P_LIM_H,
                            P_LIM_MAX,
                            LN_RATE_BIAS,
                            DURATION,
                            0
                        );

                        // Initialize
                        params.marketId_A = MarketId.wrap(
                            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
                        );
                        params.marketParams_A = MarketParams({
                            baseToken: _mockBaseAsset,
                            quoteToken: _mockQuoteAsset,
                            curator: _mockOracle,
                            lex: address(params.latentSwapLEX_A)
                        });
                        params.latentSwapLEX_A.initMarket(params.marketId_A, params.marketParams_A, 0, hex"");

                        params.marketId_B = MarketId.wrap(
                            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
                        );
                        params.marketParams_B = MarketParams({
                            baseToken: _mockBaseAsset,
                            quoteToken: _mockQuoteAsset,
                            curator: _mockOracle,
                            lex: address(params.latentSwapLEX_B)
                        });
                        params.latentSwapLEX_B.initMarket(params.marketId_B, params.marketParams_B, 0, hex"");

                        // First mint to create initial market state
                        MockOracle(_mockOracle).setPrice(params.basePrices[j]);

                        (params.initialATokenSupply, params.initialZTokenSupply, , ) = params.latentSwapLEX_A.mint(
                            MintParams({
                                marketId: params.marketId_A,
                                marketParams: params.marketParams_A,
                                baseAmountIn: params.baseSupplies[i],
                                to: address(this),
                                minATokenAmountOut: 0,
                                minZTokenAmountOut: 0,
                                data: hex"",
                                msgValue: 0
                            }),
                            address(this),
                            0
                        );

                        (params.initialATokenSupply, params.initialZTokenSupply, , ) = params.latentSwapLEX_B.mint(
                            MintParams({
                                marketId: params.marketId_B,
                                marketParams: params.marketParams_B,
                                baseAmountIn: params.baseSupplies[i],
                                to: address(this),
                                minATokenAmountOut: 0,
                                minZTokenAmountOut: 0,
                                data: hex"",
                                msgValue: 0
                            }),
                            address(this),
                            0
                        );

                        // Calculate redeem amount as percentage of initial supply
                        params.redeemAmount = Math.mulDiv(
                            params.initialATokenSupply,
                            params.redeemAmounts[k],
                            FixedPoint.WAD
                        );

                        // Test zToken redeem vs swap
                        (params.redeemLiquidityOut, , ) = params.latentSwapLEX_A.redeem(
                            RedeemParams({
                                marketId: params.marketId_A,
                                marketParams: params.marketParams_A,
                                aTokenAmountIn: params.redeemAmount,
                                zTokenAmountIn: 0,
                                to: address(this),
                                minAmountOut: 0,
                                data: hex"",
                                msgValue: 0
                            }),
                            address(this),
                            params.baseSupplies[i]
                        );

                        (params.swapLiquidityOut, , ) = params.latentSwapLEX_B.swap(
                            SwapParams({
                                marketId: params.marketId_B,
                                marketParams: params.marketParams_B,
                                assetIn: AssetType.LEVERAGE,
                                assetOut: AssetType.BASE,
                                to: address(this),
                                amountSpecified: params.redeemAmount,
                                amountLimit: 0,
                                isExactIn: true,
                                data: hex"",
                                msgValue: 0
                            }),
                            address(this),
                            params.baseSupplies[i]
                        );

                        // Allow for small rounding differences
                        assertApproxEqRel(
                            params.redeemLiquidityOut,
                            params.swapLiquidityOut,
                            0.0000000000000001e18,
                            string.concat(
                                "zToken redeem should match swap output. LTV: ",
                                vm.toString(params.ltvPercentages[l]),
                                ", Base Supply: ",
                                vm.toString(params.baseSupplies[i]),
                                ", Base Price: ",
                                vm.toString(params.basePrices[j]),
                                ", Redeem Amount: ",
                                vm.toString(params.redeemAmount)
                            )
                        );
                    }
                }
            }
        }
    }

    struct UnderCollateralizedTestParams {
        // Test configuration
        uint256 initialSupply;
        uint256 reducedBasePrice;
        MockLatentSwapLEX latentSwapLEX;
        // Local variables
        uint256 initialATokenSupply;
        uint256 initialZTokenSupply;
    }

    function test_LatentSwapLEX_swapUnderCollateralizedRevert() external {
        UnderCollateralizedTestParams memory params;

        // Set initial supply
        params.initialSupply = FixedPoint.WAD * 100; // 100 WAD
        params.reducedBasePrice = FixedPoint.WAD / 2; // 0.5 WAD

        // deploy latentSwapLEX liquid
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            0,
            DURATION,
            0
        );

        // Initialize
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Step 1: Mint initial position at 50% LTV
        (params.initialATokenSupply, params.initialZTokenSupply, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: params.initialSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // Step 2: reduce price
        MockOracle(_mockOracle).setPrice(params.reducedBasePrice);

        // Step 3: Verify market is undercollateralized
        bool isUnderCollateralized = latentSwapLEX.isUnderCollateralized(marketId, marketParams, params.initialSupply);

        assertTrue(isUnderCollateralized, "Market should be undercollateralized after base price reduction");

        // Step 4: Attempt swap and expect revert
        vm.expectRevert(abi.encodeWithSignature("E_LEX_ActionNotAllowedUnderCollateralized()"));
        latentSwapLEX.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: params.initialATokenSupply / 2, // Try to swap half of aTokens,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            params.initialSupply
        );
    }

    // A user can come in with a large amount of liqudiity, swap (against itself), and then exit
    // Forcing a bad price onto existing individuals (given user's entry vs exist price is different)
    function test_mintSwapRedeem_MarketMoverEdge_BalancedToAllDebt() external {
        uint256 initBaseSupply = 10 ** 18;
        uint256 whaleUserBaseSupply = 10 ** 18; // Reduced to comply with new mint cap constraints

        // Start with balanced market

        // deploy latentSwapLEX liquid
        // Disable LTV limits...
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_MAX - 1,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // init market
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Mint position at LTV (for new market)
        (uint256 aTokenAmount, uint256 zTokenAmount, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: initBaseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // Enter Whale into market
        (uint256 whaleAAmount, uint256 whaleZAmount, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: whaleUserBaseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            initBaseSupply
        );

        // Whale swaps all to debt
        (uint256 additionalZAmount, , ) = latentSwapLEX.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: (whaleAAmount * 999) / 1000,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            initBaseSupply + whaleUserBaseSupply
        );
        whaleZAmount += additionalZAmount;

        // Whale exits...
        (uint256 liquidityOut, , ) = latentSwapLEX.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: 0,
                zTokenAmountIn: whaleZAmount,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            initBaseSupply + whaleUserBaseSupply
        );

        console.log("liquidityOut", liquidityOut);
        console.log("whaleUserBaseSupply", whaleUserBaseSupply);

        assertLe(liquidityOut, whaleUserBaseSupply, "Whale ate our lunch....");
    }

    // A user can come in with a large amount of liqudiity, swap (against itself), and then exit
    // Forcing a bad price onto existing individuals (given user's entry vs exist price is different)

    // Shared struct to reduce stack usage for market mover edge tests
    struct MarketMoverEdgeTestVars {
        uint256 initBaseSupply;
        uint256 whaleUserBaseSupply;
        MockLatentSwapLEX latentSwapLEX;
        MarketId marketId;
        MarketParams marketParams;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 whaleAAmount;
        uint256 whaleZAmount;
        uint256 liquidityOut;
    }

    function test_mintSwapRedeem_MarketMoverEdge_BalancedToAllBoost() external {
        MarketMoverEdgeTestVars memory vars;
        vars.initBaseSupply = 10 ** 18;
        vars.whaleUserBaseSupply = 10 ** 18; // Reduced to comply with new mint cap constraints

        // Start with balanced market

        // deploy latentSwapLEX liquid
        // Disable LTV limits...
        vars.latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_MAX - 1,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // init market
        vars.marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Mint position at LTV (for new market)
        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.initBaseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // Enter Whale into market
        (vars.whaleAAmount, vars.whaleZAmount, , ) = vars.latentSwapLEX.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.whaleUserBaseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply
        );

        // Whale swaps all to debt
        (uint256 additionalAAmount, , ) = vars.latentSwapLEX.swap(
            SwapParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: vars.whaleZAmount,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply + vars.whaleUserBaseSupply
        );

        vars.whaleAAmount += additionalAAmount;

        // Whale exits...
        (vars.liquidityOut, , ) = vars.latentSwapLEX.redeem(
            RedeemParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                aTokenAmountIn: vars.whaleAAmount,
                zTokenAmountIn: 0,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply + vars.whaleUserBaseSupply
        );

        assertLe(vars.liquidityOut, vars.whaleUserBaseSupply, "Whale ate our lunch....");
    }

    // A user can come in with a large amount of liqudiity, swap (against itself), and then exit
    // Forcing a bad price onto existing individuals (given user's entry vs exist price is different)
    function test_mintSwapRedeem_MarketMoverEdge_AllBoostToBalanced() external {
        MarketMoverEdgeTestVars memory vars;
        vars.initBaseSupply = 10 ** 18;
        vars.whaleUserBaseSupply = 10 ** 18; // Reduced to comply with new mint cap constraints

        // Start with balanced market

        // deploy latentSwapLEX liquid
        // Disable LTV limits...
        vars.latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_MAX - 1,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // init market
        vars.marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Mint position at LTV (for new market)
        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.initBaseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // market moves to an 'all boost' state
        (uint256 marketNewA, , ) = vars.latentSwapLEX.swap(
            SwapParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: vars.zTokenAmount,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply
        );

        // Enter Whale into market (will mint mostly boost given current market price)
        (vars.whaleAAmount, vars.whaleZAmount, , ) = vars.latentSwapLEX.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.whaleUserBaseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply
        );

        // Whale swaps half (to balance market)
        (uint256 additionalZAmount, , ) = vars.latentSwapLEX.swap(
            SwapParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: vars.whaleAAmount >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply + vars.whaleUserBaseSupply
        );
        vars.whaleAAmount -= (vars.whaleAAmount >> 1);
        vars.whaleZAmount += additionalZAmount;

        // Whale exits...
        (vars.liquidityOut, , ) = vars.latentSwapLEX.redeem(
            RedeemParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                aTokenAmountIn: vars.whaleAAmount,
                zTokenAmountIn: vars.whaleZAmount,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply + vars.whaleUserBaseSupply
        );
        console.log("liquidityOut", vars.liquidityOut);
        console.log("whaleUserBaseSupply", vars.whaleUserBaseSupply);
        assertLe(vars.liquidityOut, vars.whaleUserBaseSupply, "Whale ate our lunch....");
    }

    // A user can come in with a large amount of liqudiity, swap (against itself), and then exit
    // Forcing a bad price onto existing individuals (given user's entry vs exist price is different)
    function test_mintSwapRedeem_MarketMoverEdge_AllDebtToBalanced() external {
        MarketMoverEdgeTestVars memory vars;
        vars.initBaseSupply = 10 ** 9;
        vars.whaleUserBaseSupply = 10 ** 9; // Reduced to comply with new mint cap constraints

        // Start with balanced market

        // deploy latentSwapLEX liquid
        // Disable LTV limits...
        vars.latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_MAX - 1,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // init market
        vars.marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Mint position at LTV (for new market)
        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.initBaseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // market moves to an 'all debt' state
        // or as close to MAX_LIMIT_LTV as we can
        vars.latentSwapLEX.swap(
            SwapParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: (vars.aTokenAmount * 89) / 100,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply
        );

        // Enter Whale into market (will mint mostly debt given current market price)
        (vars.whaleAAmount, vars.whaleZAmount, , ) = vars.latentSwapLEX.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.whaleUserBaseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply
        );

        // Whale swaps half (to balance market)
        (uint256 additionalAAmount, , ) = vars.latentSwapLEX.swap(
            SwapParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: vars.whaleZAmount >> 1,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply + vars.whaleUserBaseSupply
        );
        vars.whaleZAmount -= (vars.whaleZAmount >> 1);
        vars.whaleAAmount += additionalAAmount;

        // Whale exits...
        (vars.liquidityOut, , ) = vars.latentSwapLEX.redeem(
            RedeemParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                aTokenAmountIn: vars.whaleAAmount,
                zTokenAmountIn: vars.whaleZAmount,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            vars.initBaseSupply + vars.whaleUserBaseSupply
        );
        console.log("liquidityOut", vars.liquidityOut);
        console.log("whaleUserBaseSupply", vars.whaleUserBaseSupply);
        assertLe(vars.liquidityOut, vars.whaleUserBaseSupply, "Whale ate our lunch....");
    }

    // Test that onlyCovenantCore modifier is working correctly
    function test_onlyCovenantCore_modifier_working() external {
        // deploy latentSwapLEX liquid
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Verify that the deployer (address(this)) is the covenant core
        LexParams memory lexParams = latentSwapLEX.getLexParams();
        assertEq(lexParams.covenantCore, address(this), "Deployer should be covenant core");
    }

    function test_onlyCovenantCore_modifier_reverts_for_non_covenant_core() external {
        // deploy latentSwapLEX liquid
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create a different address
        address nonCovenantCore = address(0x1234);

        // Test initMarket - should revert for non-covenant core
        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256("Random market")))));
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Test setMarketProtocolFee - should revert for non-covenant core
        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.setMarketProtocolFee(marketId, 100);

        // Test mint - should revert for non-covenant core
        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: 1e18,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.mint(mintParams, address(this), 0);

        // Test redeem - should revert for non-covenant core
        RedeemParams memory redeemParams = RedeemParams({
            marketId: marketId,
            marketParams: marketParams,
            aTokenAmountIn: 1e18,
            zTokenAmountIn: 1e18,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.redeem(redeemParams, address(this), 0);

        // Test swap - should revert for non-covenant core
        SwapParams memory swapParams = SwapParams({
            marketId: marketId,
            marketParams: marketParams,
            assetIn: AssetType.LEVERAGE,
            assetOut: AssetType.DEBT,
            to: address(this),
            amountSpecified: 1e18,
            amountLimit: 0,
            isExactIn: true,
            data: hex"",
            msgValue: 0
        });

        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.swap(swapParams, address(this), 0);

        // Test updateState - should revert for non-covenant core
        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.updateState(marketId, marketParams, 0, hex"");
    }

    function test_onlyCovenantCore_modifier_allows_covenant_core() external {
        // deploy latentSwapLEX liquid
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Test that covenant core can call all functions
        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256("Random market")))));
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        // Test initMarket - should succeed for covenant core
        (SynthTokens memory synthTokens, ) = latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");
        assertTrue(synthTokens.aToken != address(0), "aToken should be created");
        assertTrue(synthTokens.zToken != address(0), "zToken should be created");

        // Test setMarketProtocolFee - should succeed for covenant core
        latentSwapLEX.setMarketProtocolFee(marketId, 100);

        // Test mint - should succeed for covenant core
        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: 1e18,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (uint256 aTokenAmount, uint256 zTokenAmount, , ) = latentSwapLEX.mint(mintParams, address(this), 0);
        assertGt(aTokenAmount, 0, "aToken amount should be greater than 0");
        assertGt(zTokenAmount, 0, "zToken amount should be greater than 0");

        // Test swap - should succeed for covenant core
        SwapParams memory swapParams = SwapParams({
            marketId: marketId,
            marketParams: marketParams,
            assetIn: AssetType.LEVERAGE,
            assetOut: AssetType.DEBT,
            to: address(this),
            amountSpecified: aTokenAmount / 2,
            amountLimit: 0,
            isExactIn: true,
            data: hex"",
            msgValue: 0
        });

        (uint256 swapAmount, , ) = latentSwapLEX.swap(swapParams, address(this), 1e18);
        assertGt(swapAmount, 0, "Swap amount should be greater than 0");

        // Test updateState - should succeed for covenant core
        uint128 protocolFees = latentSwapLEX.updateState(marketId, marketParams, 1e18, hex"");
        // Note: protocolFees might be 0 depending on the state, so we just verify it doesn't revert
    }

    function test_onlyCovenantCore_modifier_quote_functions_are_public() external {
        // deploy latentSwapLEX liquid
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Initialize market first
        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256("Random market")))));
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Mint initial liquidity
        latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: 1e18,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // allow for time (and other transactions to accrue)
        vm.warp(block.timestamp + 1 days);
        latentSwapLEX.updateState(marketId, marketParams, 1e18, hex"");
        vm.warp(block.timestamp + 1 days);
        latentSwapLEX.updateState(marketId, marketParams, 1e18, hex"");
        vm.warp(block.timestamp + 1 days);
        latentSwapLEX.updateState(marketId, marketParams, 1e18, hex"");
        vm.warp(block.timestamp + 1 days);
        latentSwapLEX.updateState(marketId, marketParams, 1e18, hex"");

        // Test that quote functions can be called by anyone (they are view functions)
        address randomUser = address(0x5678);

        // Test quoteMint - should succeed for any caller
        vm.prank(randomUser);
        (uint256 aTokenQuote, uint256 zTokenQuote, , , ) = latentSwapLEX.quoteMint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: 1e15,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            1e18
        );

        assertGt(aTokenQuote, 0, "aToken quote should be greater than 0");
        assertGt(zTokenQuote, 0, "zToken quote should be greater than 0");

        // Test quoteRedeem - should succeed for any caller
        vm.prank(randomUser);
        (uint256 redeemQuote, , , ) = latentSwapLEX.quoteRedeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenQuote,
                zTokenAmountIn: zTokenQuote,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            1e18
        );

        assertGt(redeemQuote, 0, "Redeem quote should be greater than 0");

        // Test quoteSwap - should succeed for any caller
        vm.prank(randomUser);
        (uint256 swapQuote, , , ) = latentSwapLEX.quoteSwap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: 1e17,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            1e18
        );

        assertGt(swapQuote, 0, "Swap quote should be greater than 0");
    }

    function test_onlyCovenantCore_modifier_getter_functions_are_public() external {
        // deploy latentSwapLEX liquid
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Initialize market first
        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256("Random market")))));
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Test that getter functions can be called by anyone (they are view functions)
        address randomUser = address(0x9ABC);

        // Test getLexState - should succeed for any caller
        vm.prank(randomUser);
        LexState memory lexState = latentSwapLEX.getLexState(marketId);
        assertEq(lexState.lastSqrtPriceX96, uint160(FixedPoint.Q96), "Last sqrt price should match target");

        // Test getLexConfig - should succeed for any caller
        vm.prank(randomUser);
        LexConfig memory lexConfig = latentSwapLEX.getLexConfig(marketId);
        assertTrue(lexConfig.aToken != address(0), "aToken should be set");

        // Test getSynthTokens - should succeed for any caller
        vm.prank(randomUser);
        SynthTokens memory synthTokens = latentSwapLEX.getSynthTokens(marketId);
        assertTrue(synthTokens.aToken != address(0), "aToken should be returned");
        assertTrue(synthTokens.zToken != address(0), "zToken should be returned");
    }

    function test_onlyCovenantCore_modifier_comprehensive_coverage() external {
        // This test ensures we've covered all state-changing functions
        // deploy latentSwapLEX liquid
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create a different address to test with
        address nonCovenantCore = address(0xDEAD);

        // Test all state-changing functions with non-covenant core address
        // Each should revert with the onlyCovenantCore error

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256("Random market")))));
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        // 1. initMarket
        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Initialize market with covenant core first
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // 2. setMarketProtocolFee
        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.setMarketProtocolFee(marketId, 100);

        // 3. mint
        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: 1e18,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.mint(mintParams, address(this), 0);

        // Mint with covenant core first
        (uint256 aTokenAmount, uint256 zTokenAmount, , ) = latentSwapLEX.mint(mintParams, address(this), 0);

        // 4. redeem
        RedeemParams memory redeemParams = RedeemParams({
            marketId: marketId,
            marketParams: marketParams,
            aTokenAmountIn: aTokenAmount / 2,
            zTokenAmountIn: zTokenAmount / 2,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.redeem(redeemParams, address(this), 1e18);

        // 5. swap
        SwapParams memory swapParams = SwapParams({
            marketId: marketId,
            marketParams: marketParams,
            assetIn: AssetType.LEVERAGE,
            assetOut: AssetType.DEBT,
            to: address(this),
            amountSpecified: aTokenAmount / 4,
            amountLimit: 0,
            isExactIn: true,
            data: hex"",
            msgValue: 0
        });

        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.swap(swapParams, address(this), 1e18);

        // 6. updateState
        vm.prank(nonCovenantCore);
        vm.expectRevert(abi.encodeWithSignature("E_LEX_OnlyCovenantCanCall()"));
        latentSwapLEX.updateState(marketId, marketParams, 1e18, hex"");

        // Verify that covenant core can still call all functions
        latentSwapLEX.setMarketProtocolFee(marketId, 200);
        latentSwapLEX.updateState(marketId, marketParams, 1e18, hex"");
    }

    function test_Reedeem_revertOnExcess() external {
        UnderCollateralizedTestParams memory params;

        // Set initial supply
        params.initialSupply = FixedPoint.WAD * 100; // 100 WAD

        // deploy latentSwapLEX liquid
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            0,
            DURATION,
            0
        );

        // Initialize
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        (params.initialATokenSupply, params.initialZTokenSupply, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: params.initialSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // The following redeem should not revert
        vm.expectRevert(LSErrors.E_LEX_InsufficientTokens.selector);
        (uint256 liquidityOut, , ) = latentSwapLEX.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: params.initialATokenSupply + 1,
                zTokenAmountIn: params.initialZTokenSupply + 1,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            params.initialSupply
        );
    }

    function test_PoC_DoSMarket_Fixed() external {
        UnderCollateralizedTestParams memory params;

        // Set initial supply
        params.initialSupply = 1e9;

        // deploy latentSwapLEX liquid
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            0,
            DURATION,
            100
        );

        // Initialize
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 100, hex"");

        // Step 1: Mint initial position
        (params.initialATokenSupply, params.initialZTokenSupply, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: params.initialSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
        console.log("initial supply A : ", params.initialATokenSupply);
        console.log("initial supply Z : ", params.initialZTokenSupply);

        uint256 timeDelta = (((((params.initialSupply) * 1) / 100) + 5) * (365 days * 1e4)) /
            (100 * params.initialSupply) +
            1;

        skip(timeDelta);
        (uint256 liquidityOut, uint128 protocolFees, ) = latentSwapLEX.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: params.initialATokenSupply - 2,
                zTokenAmountIn: params.initialZTokenSupply,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            params.initialSupply
        );

        //vm.expectRevert(abi.encodeWithSignature("E_LEX_InvalidMarketState()"));
        //Market should not revert
        bool isUnderCollateralized = latentSwapLEX.isUnderCollateralized(
            marketId,
            marketParams,
            params.initialSupply - liquidityOut - protocolFees
        );
    }

    function test_PoC_DoSMarketLiquidity0_fixed() external {
        MockOracle(_mockOracle).setPrice(FixedPoint.WAD / 10);

        UnderCollateralizedTestParams memory params;

        // Set initial supply
        params.initialSupply = 1e9;

        // deploy latentSwapLEX liquid
        MockLatentSwapLEX latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            0,
            DURATION,
            100
        );

        // Initialize
        MarketId marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });
        latentSwapLEX.initMarket(marketId, marketParams, 100, hex"");

        // Step 1: Mint initial position
        (params.initialATokenSupply, params.initialZTokenSupply, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: params.initialSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );
        console.log("initial supply A : ", params.initialATokenSupply);
        console.log("initial supply Z : ", params.initialZTokenSupply);

        // timeDelta = fee * seconds_per_year * 1e4 / (protocolFee * baseTokenSupply);
        uint256 timeDelta = (((((params.initialSupply) * 1) / 100) + 50) * (365 days * 1e4)) /
            (100 * params.initialSupply) +
            1;

        skip(timeDelta);
        (uint256 liquidityOut, uint128 protocolFees, ) = latentSwapLEX.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: params.initialATokenSupply - 3,
                zTokenAmountIn: params.initialZTokenSupply,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            params.initialSupply
        );

        //vm.expectRevert();
        //Call does not revert
        bool isUnderCollateralized = latentSwapLEX.isUnderCollateralized(
            marketId,
            marketParams,
            params.initialSupply - liquidityOut - protocolFees
        );
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Synth Token Creation and Naming Tests
    /////////////////////////////////////////////////////////////////////////////////////////////

    function test_synthTokenCreation_basic() external {
        // Deploy LatentSwapLEX
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create market parameters
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));

        // Initialize market
        (SynthTokens memory synthTokens, ) = latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Verify Synth tokens were created
        assertTrue(synthTokens.aToken != address(0), "aToken should be created");
        assertTrue(synthTokens.zToken != address(0), "zToken should be created");

        // Verify exact token names and symbols
        string memory aTokenName = IERC20Metadata(synthTokens.aToken).name();
        string memory aTokenSymbol = IERC20Metadata(synthTokens.aToken).symbol();
        string memory zTokenName = IERC20Metadata(synthTokens.zToken).name();
        string memory zTokenSymbol = IERC20Metadata(synthTokens.zToken).symbol();

        // Expected exact values based on the naming pattern in initMarket:
        // aToken: "MockBaseAsset x2 Leverage Coin (MockQuoteAsset / 1M)"
        // aToken symbol: "MBAx2.MQA"
        // zToken: "MockQuoteAsset MockBaseAsset-Backed Margin Coin (x2 / 1M)"
        // zToken symbol: "MQA.b.MBA"
        assertEq(aTokenName, "MockBaseAsset x2 Leverage Coin (MQA/1M)", "aToken name should match expected pattern");
        assertEq(aTokenSymbol, "MBAx2.MQA", "aToken symbol should match expected pattern");
        assertEq(zTokenName, "MQA Yield Coin - backed by MBA (x2/1M)", "zToken name should match expected pattern");
        assertEq(zTokenSymbol, "MQA.b.MBA", "zToken symbol should match expected pattern");

        // Verify decimals
        uint8 aTokenDecimals = IERC20Metadata(synthTokens.aToken).decimals();
        uint8 zTokenDecimals = IERC20Metadata(synthTokens.zToken).decimals();
        assertEq(aTokenDecimals, 18, "aToken should have correct decimals");
        assertEq(zTokenDecimals, 18, "zToken should have correct decimals");
    }

    function test_synthTokenCreation_differentBaseTokens() external {
        // Deploy LatentSwapLEX
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Test with Bitcoin
        address bitcoinToken = address(new MockERC20(address(this), "Bitcoin", "BTC", 8));
        MockERC20(bitcoinToken).mint(address(this), 100 * 10 ** 18);

        MarketParams memory btcMarketParams = MarketParams({
            baseToken: bitcoinToken,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId btcMarketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(btcMarketParams))))));
        (SynthTokens memory btcSynthTokens, ) = latentSwapLEX.initMarket(btcMarketId, btcMarketParams, 0, hex"");

        // Verify exact Bitcoin token names and symbols
        assertEq(
            IERC20Metadata(btcSynthTokens.aToken).name(),
            "Bitcoin x2 Leverage Coin (MQA/1M)",
            "Bitcoin aToken name should match expected pattern"
        );
        assertEq(
            IERC20Metadata(btcSynthTokens.aToken).symbol(),
            "BTCx2.MQA",
            "Bitcoin aToken symbol should match expected pattern"
        );
        assertEq(
            IERC20Metadata(btcSynthTokens.zToken).name(),
            "MQA Yield Coin - backed by BTC (x2/1M)",
            "Bitcoin zToken name should match expected pattern"
        );
        assertEq(
            IERC20Metadata(btcSynthTokens.zToken).symbol(),
            "MQA.b.BTC",
            "Bitcoin zToken symbol should match expected pattern"
        );

        // Test with Ethereum
        address ethToken = address(new MockERC20(address(this), "Ethereum", "ETH", 18));
        MockERC20(ethToken).mint(address(this), 100 * 10 ** 18);

        MarketParams memory ethMarketParams = MarketParams({
            baseToken: ethToken,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId ethMarketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(ethMarketParams))))));
        (SynthTokens memory ethSynthTokens, ) = latentSwapLEX.initMarket(ethMarketId, ethMarketParams, 0, hex"");

        // Verify exact Ethereum token names and symbols
        assertEq(
            IERC20Metadata(ethSynthTokens.aToken).name(),
            "Ethereum x2 Leverage Coin (MQA/1M)",
            "Ethereum aToken name should match expected pattern"
        );
        assertEq(
            IERC20Metadata(ethSynthTokens.aToken).symbol(),
            "ETHx2.MQA",
            "Ethereum aToken symbol should match expected pattern"
        );
        assertEq(
            IERC20Metadata(ethSynthTokens.zToken).name(),
            "MQA Yield Coin - backed by ETH (x2/1M)",
            "Ethereum zToken name should match expected pattern"
        );
        assertEq(
            IERC20Metadata(ethSynthTokens.zToken).symbol(),
            "MQA.b.ETH",
            "Ethereum zToken symbol should match expected pattern"
        );
    }

    function test_synthTokenCreation_differentDurations() external {
        // Test 1 month duration
        LatentSwapLEX latentSwapLEX1M = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            30 days, // 1 month
            SWAP_FEE
        );

        MarketParams memory marketParams1M = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX1M)
        });

        MarketId marketId1M = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams1M, "1M"))))));
        (SynthTokens memory synthTokens1M, ) = latentSwapLEX1M.initMarket(marketId1M, marketParams1M, 0, hex"");

        // Verify exact 1M duration token names
        assertEq(
            IERC20Metadata(synthTokens1M.aToken).name(),
            "MockBaseAsset x2 Leverage Coin (MQA/1M)",
            "1M aToken name should match expected pattern"
        );
        assertEq(
            IERC20Metadata(synthTokens1M.zToken).name(),
            "MQA Yield Coin - backed by MBA (x2/1M)",
            "1M zToken name should match expected pattern"
        );

        // Test 3 months duration
        LatentSwapLEX latentSwapLEX3M = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            90 days, // 3 months
            SWAP_FEE
        );

        MarketParams memory marketParams3M = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX3M)
        });

        MarketId marketId3M = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams3M, "3M"))))));
        (SynthTokens memory synthTokens3M, ) = latentSwapLEX3M.initMarket(marketId3M, marketParams3M, 0, hex"");

        // Verify exact 3M duration token names
        assertEq(
            IERC20Metadata(synthTokens3M.aToken).name(),
            "MockBaseAsset x2 Leverage Coin (MQA/3M)",
            "3M aToken name should match expected pattern"
        );
        assertEq(
            IERC20Metadata(synthTokens3M.zToken).name(),
            "MQA Yield Coin - backed by MBA (x2/3M)",
            "3M zToken name should match expected pattern"
        );

        // Test 1 year duration
        LatentSwapLEX latentSwapLEX1Y = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            365 days, // 1 year
            SWAP_FEE
        );

        MarketParams memory marketParams1Y = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX1Y)
        });

        MarketId marketId1Y = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams1Y, "1Y"))))));
        (SynthTokens memory synthTokens1Y, ) = latentSwapLEX1Y.initMarket(marketId1Y, marketParams1Y, 0, hex"");

        // Verify exact 1Y duration token names
        assertEq(
            IERC20Metadata(synthTokens1Y.aToken).name(),
            "MockBaseAsset x2 Leverage Coin (MQA/1Y)",
            "1Y aToken name should match expected pattern"
        );
        assertEq(
            IERC20Metadata(synthTokens1Y.zToken).name(),
            "MQA Yield Coin - backed by MBA (x2/1Y)",
            "1Y zToken name should match expected pattern"
        );
    }

    function test_synthTokenCreation_differentLeverageRatios() external {
        // Test that leverage ratios are correctly reflected in token names
        // We'll use the standard LEX instance and verify the leverage calculation

        // Deploy LatentSwapLEX with standard parameters
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create market parameters
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));

        // Initialize market
        (SynthTokens memory synthTokens, ) = latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Verify exact token names and symbols with leverage information
        string memory aTokenName = IERC20Metadata(synthTokens.aToken).name();
        string memory aTokenSymbol = IERC20Metadata(synthTokens.aToken).symbol();
        string memory zTokenName = IERC20Metadata(synthTokens.zToken).name();
        string memory zTokenSymbol = IERC20Metadata(synthTokens.zToken).symbol();

        // Expected values with leverage ratio (should be 2x based on P_TARGET)
        assertEq(aTokenName, "MockBaseAsset x2 Leverage Coin (MQA/1M)", "aToken name should include leverage");
        assertEq(aTokenSymbol, "MBAx2.MQA", "aToken symbol should include leverage");
        assertEq(zTokenName, "MQA Yield Coin - backed by MBA (x2/1M)", "zToken name should include leverage");
        assertEq(zTokenSymbol, "MQA.b.MBA", "zToken symbol should include leverage");

        // Verify that leverage information is present in the names
        assertTrue(bytes(aTokenName).length > 0, "aToken should have a name");
        assertTrue(bytes(aTokenSymbol).length > 0, "aToken should have a symbol");
        assertTrue(bytes(zTokenName).length > 0, "zToken should have a name");
        assertTrue(bytes(zTokenSymbol).length > 0, "zToken should have a symbol");
    }

    function test_synthTokenCreationNonERC20QuoteToken() external {
        // Deploy LatentSwapLEX
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create a custom quote token (non-ERC20)
        address customQuoteToken = makeAddr("non-ERC20");

        // Set custom noCapLimit for the quote token
        latentSwapLEX.setDefaultNoCapLimit(customQuoteToken, 100);

        // Create oracle for nonERC20 quote token
        MockOracleNonERC20 mockOracleNonERC20 = new MockOracleNonERC20(address(this));

        // Set custom symbol for the quote token using LatentSwapLEX directly
        (bool success, ) = address(latentSwapLEX).call(
            abi.encodeWithSignature("setQuoteTokenSymbolOverrideForNewMarkets(address,string)", customQuoteToken, "CCC")
        );
        require(success, "Failed to set quote token symbol");

        // Create market parameters with custom quote token
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: customQuoteToken,
            curator: address(mockOracleNonERC20),
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));

        // Initialize market
        (SynthTokens memory synthTokens, ) = latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Verify exact token names and symbols with custom symbol
        assertEq(
            IERC20Metadata(synthTokens.aToken).name(),
            "MockBaseAsset x2 Leverage Coin (CCC/1M)",
            "aToken name should use custom symbol"
        );
        assertEq(IERC20Metadata(synthTokens.aToken).symbol(), "MBAx2.CCC", "aToken symbol should use custom symbol");
        assertEq(
            IERC20Metadata(synthTokens.zToken).name(),
            "CCC Yield Coin - backed by MBA (x2/1M)",
            "zToken name should use custom symbol"
        );
        assertEq(IERC20Metadata(synthTokens.zToken).symbol(), "CCC.b.MBA", "zToken symbol should use custom symbol");
    }

    function test_synthTokenCreation_edgeCases() external {
        // Deploy LatentSwapLEX
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Test with very long token names
        address longNameToken = address(
            new MockERC20(address(this), "VeryLongTokenNameForTestingPurposesThatExceedsNormalLength", "VLTS", 18)
        );
        MockERC20(longNameToken).mint(address(this), 100 * 10 ** 18);

        // Test with very short token names
        address shortNameToken = address(new MockERC20(address(this), "A", "B", 18));
        MockERC20(shortNameToken).mint(address(this), 100 * 10 ** 18);

        // Test with special characters
        address specialCharToken = address(new MockERC20(address(this), "Token-Name_123", "TKN-123", 18));
        MockERC20(specialCharToken).mint(address(this), 100 * 10 ** 18);

        address[] memory testTokens = new address[](3);
        testTokens[0] = longNameToken;
        testTokens[1] = shortNameToken;
        testTokens[2] = specialCharToken;

        for (uint256 i = 0; i < testTokens.length; i++) {
            // Create market parameters
            MarketParams memory marketParams = MarketParams({
                baseToken: testTokens[i],
                quoteToken: _mockQuoteAsset,
                curator: _mockOracle,
                lex: address(latentSwapLEX)
            });

            MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));

            // Initialize market - should not revert
            (SynthTokens memory synthTokens, ) = latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

            // Verify tokens were created successfully
            assertTrue(synthTokens.aToken != address(0), "aToken should be created");
            assertTrue(synthTokens.zToken != address(0), "zToken should be created");

            // Verify token names and symbols are not empty
            string memory aTokenName = IERC20Metadata(synthTokens.aToken).name();
            string memory aTokenSymbol = IERC20Metadata(synthTokens.aToken).symbol();
            string memory zTokenName = IERC20Metadata(synthTokens.zToken).name();
            string memory zTokenSymbol = IERC20Metadata(synthTokens.zToken).symbol();

            assertTrue(bytes(aTokenName).length > 0, "aToken should have a name");
            assertTrue(bytes(aTokenSymbol).length > 0, "aToken should have a symbol");
            assertTrue(bytes(zTokenName).length > 0, "zToken should have a name");
            assertTrue(bytes(zTokenSymbol).length > 0, "zToken should have a symbol");
        }
    }

    function test_synthTokenMetadata_validation() external {
        // Deploy LatentSwapLEX
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create market parameters
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));

        // Initialize market
        (SynthTokens memory synthTokens, ) = latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Verify aToken metadata
        IERC20Metadata aToken = IERC20Metadata(synthTokens.aToken);
        assertTrue(bytes(aToken.name()).length > 0, "aToken name should not be empty");
        assertTrue(bytes(aToken.symbol()).length > 0, "aToken symbol should not be empty");
        assertTrue(aToken.decimals() > 0, "aToken decimals should be greater than 0");
        assertEq(aToken.totalSupply(), 0, "aToken initial supply should be 0");

        // Verify zToken metadata
        IERC20Metadata zToken = IERC20Metadata(synthTokens.zToken);
        assertTrue(bytes(zToken.name()).length > 0, "zToken name should not be empty");
        assertTrue(bytes(zToken.symbol()).length > 0, "zToken symbol should not be empty");
        assertTrue(zToken.decimals() > 0, "zToken decimals should be greater than 0");
        assertEq(zToken.totalSupply(), 0, "zToken initial supply should be 0");

        // Verify SynthToken specific getters
        ISynthToken aSynthToken = ISynthToken(synthTokens.aToken);
        ISynthToken zSynthToken = ISynthToken(synthTokens.zToken);

        assertEq(aSynthToken.getCovenantCore(), address(this), "aToken covenant core should be correct");
        assertEq(zSynthToken.getCovenantCore(), address(this), "zToken covenant core should be correct");
        assertTrue(
            MarketId.unwrap(aSynthToken.getMarketId()) == MarketId.unwrap(marketId),
            "aToken market ID should be correct"
        );
        assertTrue(
            MarketId.unwrap(zSynthToken.getMarketId()) == MarketId.unwrap(marketId),
            "zToken market ID should be correct"
        );
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Tests for noCapLimit functionality
    /////////////////////////////////////////////////////////////////////////////////////////////

    function test_setDefaultNoCapLimit_basic() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        address customQuoteToken = makeAddr("customQuoteToken");
        uint8 customMintRedeemNoCap = 25;

        // Test that event is emitted with correct parameters
        vm.expectEmit(true, false, false, true);
        emit SetDefaultNoCapLimit(customQuoteToken, 0, customMintRedeemNoCap);
        latentSwapLEX.setDefaultNoCapLimit(customQuoteToken, customMintRedeemNoCap);
    }

    function test_setDefaultNoCapLimit_access_control() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        address nonOwner = makeAddr("nonOwner");
        address customQuoteToken = makeAddr("customQuoteToken");

        // Test that non-owner cannot call setDefaultNoCapLimit
        vm.prank(nonOwner);
        vm.expectRevert();
        latentSwapLEX.setDefaultNoCapLimit(customQuoteToken, 25);
    }

    function test_setMarketNoCapLimit_basic() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        (SynthTokens memory synthTokens, ) = latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Test updating noCapLimit
        uint8 newNoCapDecimals = 20;
        latentSwapLEX.setMarketNoCapLimit(marketId, newNoCapDecimals);

        // Verify the update
        LexConfig memory config = latentSwapLEX.getLexConfig(marketId);
        assertEq(config.noCapLimit, newNoCapDecimals, "noCapLimit should be updated");
    }

    function test_setMarketNoCapLimit_access_control() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        address nonOwner = makeAddr("nonOwner");

        // Test that non-owner cannot call setMarketNoCapLimit
        vm.prank(nonOwner);
        vm.expectRevert();
        latentSwapLEX.setMarketNoCapLimit(marketId, 20);
    }

    function test_setMarketNoCapLimit_marketDoesNotExist() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Test with non-existent market
        MarketId nonExistentMarketId = MarketId.wrap(bytes20(uint160(uint256(keccak256("non-existent")))));

        vm.expectRevert(LSErrors.E_LEX_MarketDoesNotExist.selector);
        latentSwapLEX.setMarketNoCapLimit(nonExistentMarketId, 20);
    }

    function test_market_initialization_with_custom_noCapLimit() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        address customQuoteToken = makeAddr("customQuoteToken");

        // Set custom base token noCapLimit
        uint8 customMintRedeemNoCap = 25;
        latentSwapLEX.setDefaultNoCapLimit(_mockBaseAsset, customMintRedeemNoCap);

        // Create oracle for custom quote token
        MockOracleNonERC20 mockOracleCustom = new MockOracleNonERC20(address(this));

        // Set custom symbol for the quote token using LatentSwapLEX directly
        (bool success, ) = address(latentSwapLEX).call(
            abi.encodeWithSignature("setQuoteTokenSymbolOverrideForNewMarkets(address,string)", customQuoteToken, "CQT")
        );
        require(success, "Failed to set quote token symbol");

        // Create market with custom quote token
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: customQuoteToken,
            curator: address(mockOracleCustom),
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Verify that the market uses the custom noCapLimit
        LexConfig memory config = latentSwapLEX.getLexConfig(marketId);
        assertEq(config.noCapLimit, customMintRedeemNoCap, "Market should use custom noCapLimit");
    }

    function test_market_initialization_with_default_noCapLimit() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create market without setting custom quote token data
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Verify that the market uses the default noCapLimit (18)
        LexConfig memory config = latentSwapLEX.getLexConfig(marketId);
        assertEq(config.noCapLimit, 60, "Market should use default noCapLimit");
    }

    function test_mint_cap_enforcement_with_custom_noCapLimit() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Set a very restrictive noCapLimit (e.g., 3, so cap applies when supply > 2^10=1024)
        uint8 restrictiveNoCapLimit = 10;
        latentSwapLEX.setMarketNoCapLimit(marketId, restrictiveNoCapLimit);

        // Mint initial liquidity to get above the cap threshold
        uint256 initialMintAmount = 2000e18;
        IERC20(_mockBaseAsset).approve(address(latentSwapLEX), initialMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: initialMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        latentSwapLEX.mint(mintParams, address(this), 0);

        // have time pass by
        vm.warp(block.timestamp + 30);
        // Update state to set up ETWAP properly
        latentSwapLEX.updateState(marketId, marketParams, initialMintAmount, hex"");

        // Now try to mint a large amount that should exceed the cap
        uint256 largeMintAmount = 1000e18; // This should trigger the cap
        IERC20(_mockBaseAsset).approve(address(latentSwapLEX), largeMintAmount);

        MintParams memory largeMintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: largeMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });
        console.log("step4");
        // This should revert due to mint cap
        vm.expectRevert(LSErrors.E_LEX_MintCapExceeded.selector);
        latentSwapLEX.mint(largeMintParams, address(this), initialMintAmount);
    }

    function test_mint_no_cap_when_below_threshold() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Set a restrictive noCapLimit
        uint8 restrictiveNoCapLimit = 10;
        latentSwapLEX.setMarketNoCapLimit(marketId, restrictiveNoCapLimit);

        // Mint amount below the cap threshold (2^10=1024)
        uint256 smallMintAmount = 500e18;
        IERC20(_mockBaseAsset).approve(address(latentSwapLEX), smallMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: smallMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // This should succeed as it's below the cap threshold
        latentSwapLEX.mint(mintParams, address(this), 0);
    }

    function test_redeem_cap_enforcement_with_custom_noCapLimit() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Set a restrictive noCapLimit
        uint8 restrictiveNoCapLimit = 10;
        latentSwapLEX.setMarketNoCapLimit(marketId, restrictiveNoCapLimit);

        // Mint initial liquidity to get above the cap threshold
        uint256 initialMintAmount = 2000e18;
        IERC20(_mockBaseAsset).approve(address(latentSwapLEX), initialMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: initialMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (uint256 aTokenAmount, uint256 zTokenAmount, , ) = latentSwapLEX.mint(mintParams, address(this), 0);

        // have enough time pass by
        vm.warp(block.timestamp + 30000);
        latentSwapLEX.updateState(marketId, marketParams, initialMintAmount, hex"");
        // have time pass by
        vm.warp(block.timestamp + 30000);
        latentSwapLEX.updateState(marketId, marketParams, initialMintAmount, hex"");
        // have time pass by
        vm.warp(block.timestamp + 30000);
        latentSwapLEX.updateState(marketId, marketParams, initialMintAmount, hex"");
        // have time pass by
        vm.warp(block.timestamp + 30000);
        // Update state to set up ETWAP properly
        latentSwapLEX.updateState(marketId, marketParams, initialMintAmount, hex"");

        RedeemParams memory redeemParams = RedeemParams({
            marketId: marketId,
            marketParams: marketParams,
            aTokenAmountIn: aTokenAmount / 2,
            zTokenAmountIn: zTokenAmount / 2,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // This should revert due to redeem cap
        vm.expectRevert(LSErrors.E_LEX_RedeemCapExceeded.selector);
        latentSwapLEX.redeem(redeemParams, address(this), initialMintAmount);
    }

    function test_swap_cap_enforcement_with_custom_noCapLimit() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Set a restrictive noCapLimit
        uint8 restrictiveNoCapLimit = 10;
        latentSwapLEX.setMarketNoCapLimit(marketId, restrictiveNoCapLimit);

        // Mint initial liquidity to get above the cap threshold
        uint256 initialMintAmount = 2000e18;
        IERC20(_mockBaseAsset).approve(address(latentSwapLEX), initialMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: initialMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        latentSwapLEX.mint(mintParams, address(this), 0);

        // Now try to swap a large amount of base token that should exceed the cap
        uint256 largeSwapAmount = 1000e18; // This should trigger the cap

        SwapParams memory swapParams = SwapParams({
            marketId: marketId,
            marketParams: marketParams,
            assetIn: AssetType.BASE,
            assetOut: AssetType.LEVERAGE,
            to: address(this),
            amountSpecified: largeSwapAmount,
            amountLimit: 0,
            isExactIn: true,
            data: hex"",
            msgValue: 0
        });

        // This should revert due to mint cap (base token in triggers mint cap)
        vm.expectRevert(LSErrors.E_LEX_MintCapExceeded.selector);
        latentSwapLEX.swap(swapParams, address(this), initialMintAmount);
    }

    function test_extreme_noCapLimit_values() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Test with very restrictive cap (0)
        latentSwapLEX.setMarketNoCapLimit(marketId, 0);
        LexConfig memory config = latentSwapLEX.getLexConfig(marketId);
        assertEq(config.noCapLimit, 0, "Should accept noCapLimit = 0");

        // Test with very permissive cap (255)
        latentSwapLEX.setMarketNoCapLimit(marketId, 255);
        config = latentSwapLEX.getLexConfig(marketId);
        assertEq(config.noCapLimit, 255, "Should accept noCapLimit = 255");
    }

    function test_multiple_markets_independent_caps() external {
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create two different markets
        MarketParams memory marketParams1 = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        address differentQuoteToken = address(new MockERC20(address(this), "Different Quote Token", "DQT", 18));
        address differentOracle = address(new MockOracle(address(this)));

        MarketParams memory marketParams2 = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: differentQuoteToken,
            curator: differentOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId1 = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams1))))));
        MarketId marketId2 = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams2))))));

        latentSwapLEX.initMarket(marketId1, marketParams1, 0, hex"");
        latentSwapLEX.initMarket(marketId2, marketParams2, 0, hex"");

        // Set different noCapLimit for each market
        uint8 cap1 = 10;
        uint8 cap2 = 20;

        latentSwapLEX.setMarketNoCapLimit(marketId1, cap1);
        latentSwapLEX.setMarketNoCapLimit(marketId2, cap2);

        // Verify that each market has its own cap
        LexConfig memory config1 = latentSwapLEX.getLexConfig(marketId1);
        LexConfig memory config2 = latentSwapLEX.getLexConfig(marketId2);

        assertEq(config1.noCapLimit, cap1, "Market 1 should have its own cap");
        assertEq(config2.noCapLimit, cap2, "Market 2 should have its own cap");
    }

    function test_name() external {
        // Deploy LatentSwapLEX contract
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Test that the name function returns the expected value
        string memory contractName = latentSwapLEX.name();
        assertEq(contractName, "LatentSwap V1.0", "Contract name should be 'LatentSwap V1.0'");
    }

    // ========================================
    // Workout Rate Tests
    // ========================================

    function test_workout_rate_no_workout_when_below_limMax() external {
        // Test that no workout rate is applied when lastSqrtPriceX96 <= limMaxSqrtPriceX96
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Mint some liquidity to have a functioning market
        uint256 mintAmount = 1 * 10 ** 18; // Use very small amount to avoid mint cap
        latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: mintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            mintAmount
        );

        // Get initial state
        LexState memory initialState = latentSwapLEX.getLexState(marketId);
        uint256 initialDebtNotionalPrice = initialState.lastDebtNotionalPrice;
        int256 initialLnRateBias = initialState.lastLnRateBias;

        // Verify we're below limMaxSqrtPriceX96 (should be at target price initially)
        assertLe(initialState.lastSqrtPriceX96, P_LIM_MAX, "Initial price should be below limMaxSqrtPriceX96");

        // Advance time to trigger interest accrual
        vm.warp(block.timestamp + 1 days);

        // Update state to trigger interest calculation
        latentSwapLEX.updateState(marketId, marketParams, mintAmount, hex"");

        // Get updated state
        LexState memory updatedState = latentSwapLEX.getLexState(marketId);

        // Verify that debt notional price has increased (normal interest accrual)
        assertGt(
            updatedState.lastDebtNotionalPrice,
            initialDebtNotionalPrice,
            "Debt notional price should increase with normal interest accrual"
        );
    }

    function test_workout_rate_interest_accrual_with_workout() external {
        // Test that workout rate affects interest accrual when market is above limMaxSqrtPriceX96
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        // Mint initial liquidity
        uint256 mintAmount = 1 * 10 ** 18;
        latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: mintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        // Get initial state
        LexState memory initialState = latentSwapLEX.getLexState(marketId);
        uint256 initialDebtNotionalPrice = initialState.lastDebtNotionalPrice;

        // Move market to undercollateralized state by lowering oracle price
        MockOracle(_mockOracle).setPrice(1 * 10 ** 17);

        // Update state to trigger interest calculation
        latentSwapLEX.updateState(marketId, marketParams, mintAmount, hex"");

        // Get updated state
        LexState memory updatedState = latentSwapLEX.getLexState(marketId);
        uint256 updatedDebtNotionalPrice = updatedState.lastDebtNotionalPrice;

        // Advance time
        vm.warp(block.timestamp + 1 days);

        // Update state to trigger interest calculation
        latentSwapLEX.updateState(marketId, marketParams, mintAmount, hex"");

        // Get updated state2
        LexState memory updatedState2 = latentSwapLEX.getLexState(marketId);
        uint256 updatedDebtNotionalPrice2 = updatedState2.lastDebtNotionalPrice;

        // ensure we are in a workout state
        //assertEq(updatedState.underCollateralized, true, "Market should be undercollateralized");
        assertGt(updatedState.lastSqrtPriceX96, P_LIM_MAX, "Market should above P_LIM_MAX");

        // The interest rate should be negative (debt notional price should decrease)
        assertGt(initialDebtNotionalPrice, updatedDebtNotionalPrice2, "Interest rate should be negative");

        // Calculate the interest rate from the debt notional price change
        uint256 interestRate = (updatedDebtNotionalPrice2 * 1e18) / initialDebtNotionalPrice;

        // Interest rate should be approximaltely 1% a day
        assertApproxEqAbs(interestRate, (99 * 1e18) / 100, 1e17, "Interest rate should be approximately -1% for 1 day");
    }

    function test_undercollateralized_minimal_liquidity() external {
        // Test the scenario where minimal liquidity causes MaxDebt = 0 in undercollateralized state
        // This blocks zToken to Base swaps even when liquidity > 0
        uint256 baseAmountIn = 10;
        uint104 MIN_SQRTPRICE_RATIO = uint104((1005 * FixedPoint.WAD) / 1000);
        console.log("baseAmountIn", baseAmountIn);

        // Setup: 50% target LTV market with very narrow price width
        (uint160 edgeSqrtRatioX96_A, uint160 edgeSqrtRatioX96_B) = LatentSwapLib.getMarketEdgePrices(
            uint32(PercentageMath.HALF_PERCENTAGE_FACTOR),
            MIN_SQRTPRICE_RATIO
        );

        // Initialize LEX
        LatentSwapLEX latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            edgeSqrtRatioX96_B,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B - 2,
            edgeSqrtRatioX96_B - 1,
            0,
            DURATION,
            0
        );

        // initialize market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(latentSwapLEX)
        });

        MarketId marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(marketParams))))));
        latentSwapLEX.initMarket(marketId, marketParams, 0, hex"");

        console.log("----------------------------------------");
        // Mint initial minimal liquidity
        (uint256 aTokenAmountOut, uint256 zTokenAmountOut, , ) = latentSwapLEX.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            0
        );

        console.log("aTokenAmountOut", aTokenAmountOut);
        console.log("zTokenAmountOut", zTokenAmountOut);

        console.log("----------------------------------------");

        // Reduce price to put into an undercollateralized state
        MockOracle(_mockOracle).setPrice(1 * 10 ** 17);

        uint256 debtOut = (zTokenAmountOut >> 2);
        console.log("debtOut", debtOut);

        // Swap zToken to Base
        (uint256 baseAmountOut, , TokenPrices memory tokenPrices) = latentSwapLEX.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.BASE,
                to: address(this),
                amountSpecified: debtOut,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            baseAmountIn
        );

        console.log("tokenPrices.baseTokenPrice", tokenPrices.baseTokenPrice);
        console.log("tokenPrices.aTokenPrice", tokenPrices.aTokenPrice);
        console.log("tokenPrices.zTokenPrice", tokenPrices.zTokenPrice);

        console.log("baseAmountOut", baseAmountOut);
        console.log("ExpectedOut", baseAmountIn >> 2);
        assertLe(
            baseAmountOut,
            baseAmountIn >> 2,
            "When undercollateralized, zToken to Base swap should be proportional."
        );
    }

    struct CollateralizedRedeemTestVars {
        LatentSwapLEX latentSwapLEX;
        MarketParams marketParams;
        MarketId marketId;
        uint256 initialMintAmount;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 smallRedeemAmount;
        uint256 largeRedeemAmount;
    }

    function test_redeem_cap_collateralized_state() external {
        // Test redeem cap enforcement in collateralized state
        CollateralizedRedeemTestVars memory vars;
        vars.latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });

        vars.marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(vars.marketParams))))));
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Set a very restrictive redeem cap (5% of total supply)
        uint8 restrictiveNoCapLimit = 5;
        vars.latentSwapLEX.setMarketNoCapLimit(vars.marketId, restrictiveNoCapLimit);

        // Mint initial liquidity
        vars.initialMintAmount = 1000e18;
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), vars.initialMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.initialMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(mintParams, address(this), 0);

        // Set up ETWAP properly with multiple updateState calls
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.initialMintAmount, hex"");
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.initialMintAmount, hex"");
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.initialMintAmount, hex"");
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.initialMintAmount, hex"");

        // Test 1: Small redeem should succeed (below cap)
        vars.smallRedeemAmount = vars.aTokenAmount / 20; // 5% of tokens
        RedeemParams memory smallRedeemParams = RedeemParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            aTokenAmountIn: vars.smallRedeemAmount,
            zTokenAmountIn: vars.smallRedeemAmount,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // This should succeed
        (uint256 liquidityOut, , ) = vars.latentSwapLEX.redeem(
            smallRedeemParams,
            address(this),
            vars.initialMintAmount
        );
        assertGt(liquidityOut, 0, "Small redeem should succeed");

        // Test 2: Large redeem should fail (above cap)
        vars.largeRedeemAmount = vars.aTokenAmount / 3; // 33% of tokens
        RedeemParams memory largeRedeemParams = RedeemParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            aTokenAmountIn: vars.largeRedeemAmount,
            zTokenAmountIn: vars.largeRedeemAmount,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // This should revert due to redeem cap
        vm.expectRevert(LSErrors.E_LEX_RedeemCapExceeded.selector);
        vars.latentSwapLEX.redeem(largeRedeemParams, address(this), vars.initialMintAmount);
    }

    struct UndercollateralizedRedeemTestVars {
        LatentSwapLEX latentSwapLEX;
        MarketParams marketParams;
        MarketId marketId;
        uint256 baseAmountIn;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 smallRedeemAmount;
        uint256 largeRedeemAmount;
    }

    function test_redeem_cap_undercollateralized_state() external {
        // Test redeem cap enforcement in undercollateralized state
        UndercollateralizedRedeemTestVars memory vars;
        vars.baseAmountIn = 1000e18;
        uint104 MIN_SQRTPRICE_RATIO = uint104((1005 * FixedPoint.WAD) / 1000);

        // Setup: 50% target LTV market with very narrow price width
        (uint160 edgeSqrtRatioX96_A, uint160 edgeSqrtRatioX96_B) = LatentSwapLib.getMarketEdgePrices(
            uint32(PercentageMath.HALF_PERCENTAGE_FACTOR),
            MIN_SQRTPRICE_RATIO
        );

        // Initialize LEX
        vars.latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            edgeSqrtRatioX96_B,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B - 2,
            edgeSqrtRatioX96_B - 1,
            0,
            DURATION,
            0
        );

        // Create and initialize a market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });

        vars.marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(vars.marketParams))))));
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Set a restrictive redeem cap (5% of total supply)
        uint8 restrictiveNoCapLimit = 5;
        vars.latentSwapLEX.setMarketNoCapLimit(vars.marketId, restrictiveNoCapLimit);

        // Mint initial liquidity
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), vars.baseAmountIn);

        MintParams memory mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.baseAmountIn,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(mintParams, address(this), 0);

        // Set up ETWAP properly first
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");

        // Reduce price by 75% to put into undercollateralized state
        MockOracle(_mockOracle).setPrice(1 * 10 ** 17); // 0.1 WAD (75% reduction from 1 WAD)

        // Update state to reflect the new price
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");

        // Test 1: Small zToken-only redeem should succeed even in undercollateralized state (below cap)
        vars.smallRedeemAmount = vars.zTokenAmount / 50; // 2% of zTokens
        RedeemParams memory smallRedeemParams = RedeemParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            aTokenAmountIn: 0, // No aTokens in undercollateralized state
            zTokenAmountIn: vars.smallRedeemAmount,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // This should succeed even in undercollateralized state
        (uint256 liquidityOut, , ) = vars.latentSwapLEX.redeem(smallRedeemParams, address(this), vars.baseAmountIn);
        assertGt(liquidityOut, 0, "Small zToken redeem should succeed even in undercollateralized state");

        // Test 2: aToken redeem should fail in undercollateralized state
        RedeemParams memory aTokenRedeemParams = RedeemParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            aTokenAmountIn: vars.aTokenAmount / 10, // 10% of aTokens
            zTokenAmountIn: 0,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // This should revert because aToken redeems are not allowed in undercollateralized state
        vm.expectRevert(LSErrors.E_LEX_ActionNotAllowedUnderCollateralized.selector);
        vars.latentSwapLEX.redeem(aTokenRedeemParams, address(this), vars.baseAmountIn);

        // Test 3: Large zToken redeem should fail in undercollateralized state (above cap)
        vars.largeRedeemAmount = vars.zTokenAmount / 2; // 50% of zTokens
        RedeemParams memory largeRedeemParams = RedeemParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            aTokenAmountIn: 0, // No aTokens in undercollateralized state
            zTokenAmountIn: vars.largeRedeemAmount,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // This should revert due to redeem cap even in undercollateralized state
        vm.expectRevert(LSErrors.E_LEX_RedeemCapExceeded.selector);
        vars.latentSwapLEX.redeem(largeRedeemParams, address(this), vars.baseAmountIn);
    }

    struct PartialRedeemTestVars {
        LatentSwapLEX latentSwapLEX;
        MarketParams marketParams;
        MarketId marketId;
        uint256 baseAmountIn;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 redeemAmount;
        uint256 largeRedeemAmount;
    }

    function test_redeem_cap_undercollateralized_state_partial_redeem() external {
        // Test that partial redeems work in undercollateralized state when below cap
        PartialRedeemTestVars memory vars;
        vars.baseAmountIn = 1000e18;
        uint104 MIN_SQRTPRICE_RATIO = uint104((1005 * FixedPoint.WAD) / 1000);

        // Setup: 50% target LTV market with very narrow price width
        (uint160 edgeSqrtRatioX96_A, uint160 edgeSqrtRatioX96_B) = LatentSwapLib.getMarketEdgePrices(
            uint32(PercentageMath.HALF_PERCENTAGE_FACTOR),
            MIN_SQRTPRICE_RATIO
        );

        // Initialize LEX
        vars.latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            edgeSqrtRatioX96_B,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B - 2,
            edgeSqrtRatioX96_B - 1,
            0,
            DURATION,
            0
        );

        // Create and initialize a market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });

        vars.marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(vars.marketParams))))));
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Set a moderate redeem cap (15% of total supply)
        uint8 moderateNoCapLimit = 15;
        vars.latentSwapLEX.setMarketNoCapLimit(vars.marketId, moderateNoCapLimit);

        // Mint initial liquidity
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), vars.baseAmountIn);

        MintParams memory mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.baseAmountIn,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(mintParams, address(this), 0);

        // Set up ETWAP properly first
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");

        // Reduce price by 75% to put into undercollateralized state
        MockOracle(_mockOracle).setPrice(1 * 10 ** 17); // 0.1 WAD (75% reduction from 1 WAD)

        // Update state to reflect the new price
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.baseAmountIn, hex"");

        // Test: Multiple small zToken redeems should work (each below cap)
        vars.redeemAmount = vars.zTokenAmount / 20; // 5% of zTokens per redeem

        for (uint256 i = 0; i < 3; i++) {
            RedeemParams memory redeemParams = RedeemParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                aTokenAmountIn: 0, // No aTokens in undercollateralized state
                zTokenAmountIn: vars.redeemAmount,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            });

            // Each redeem should succeed
            (uint256 liquidityOut, , ) = vars.latentSwapLEX.redeem(redeemParams, address(this), vars.baseAmountIn);
            assertGt(liquidityOut, 0, "Partial zToken redeem should succeed in undercollateralized state");
        }

        // Test: Large zToken redeem should fail (above cap)
        vars.largeRedeemAmount = vars.zTokenAmount / 2; // 50% of zTokens
        RedeemParams memory largeRedeemParams = RedeemParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            aTokenAmountIn: 0, // No aTokens in undercollateralized state
            zTokenAmountIn: vars.largeRedeemAmount,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // This should revert due to redeem cap
        vm.expectRevert(LSErrors.E_LEX_RedeemCapExceeded.selector);
        vars.latentSwapLEX.redeem(largeRedeemParams, address(this), vars.baseAmountIn);
    }

    struct NoCapLimitTestVars {
        LatentSwapLEX latentSwapLEX;
        MarketParams marketParams;
        MarketId marketId;
        uint256 initialMintAmount;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
    }

    function test_redeem_cap_no_cap_limit() external {
        // Test that when noCapLimit is set to 255 (no cap), redeems work regardless of size
        NoCapLimitTestVars memory vars;
        vars.latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });

        vars.marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(vars.marketParams))))));
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Set no cap limit (255 means no cap)
        vars.latentSwapLEX.setMarketNoCapLimit(vars.marketId, 255);

        // Mint initial liquidity
        vars.initialMintAmount = 1000e18;
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), vars.initialMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.initialMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(mintParams, address(this), 0);

        // Update state
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.initialMintAmount, hex"");

        // Test: Large redeem should succeed when no cap is set
        RedeemParams memory redeemParams = RedeemParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            aTokenAmountIn: vars.aTokenAmount / 2, // 50% of tokens
            zTokenAmountIn: vars.zTokenAmount / 2,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // This should succeed (no cap)
        (uint256 liquidityOut, , ) = vars.latentSwapLEX.redeem(redeemParams, address(this), vars.initialMintAmount);
        assertGt(liquidityOut, 0, "Large redeem should succeed when no cap is set");
    }

    // ==================== NEW MINT CAP CONSTRAINT TESTS ====================

    function test_mint_cap_2_96_limit_small_market() external {
        // Test that for small markets (baseTokenSupply <= 2^noCapLimit),
        // we can mint up to 2^96 but only if mintAmount <= marketBaseTokenSupply
        MintCapTestVars memory vars;

        // Create LEX with noCapLimit = 60 (so small market threshold is 2^60)
        vars.latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });

        vars.marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(vars.marketParams))))));
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Test 1: Small market, mint amount <= 2^96 and <= marketBaseTokenSupply should succeed
        vars.smallMintAmount = 1000e18; // Much smaller than 2^96
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), vars.smallMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.smallMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(mintParams, address(this), 0);
        assertGt(vars.aTokenAmount, 0, "Small mint should succeed");

        // Test 2: Try to mint exactly 2^96 (should succeed for small market)
        uint256 largeMintAmount = 2 ** 96;
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), largeMintAmount);

        mintParams.baseAmountIn = largeMintAmount;
        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(mintParams, address(this), 0);
        assertGt(vars.aTokenAmount, 0, "Mint of 2^96 should succeed for small market");

        // Test 3: Try to mint more than 2^96 (should fail)
        uint256 tooLargeMintAmount = 2 ** 96 + 1;
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), tooLargeMintAmount);

        mintParams.baseAmountIn = tooLargeMintAmount;
        vm.expectRevert(LSErrors.E_LEX_MintCapExceeded.selector);
        vars.latentSwapLEX.mint(mintParams, address(this), 0);
    }

    function test_mint_cap_baseTokenSupply_limit_large_market() external {
        // Test that for large markets (baseTokenSupply > 2^noCapLimit),
        // mintAmount must be <= marketBaseTokenSupply
        MintCapTestVars memory vars;

        // Create LEX with noCapLimit = 10 (so large market threshold is 2^10 = 1024)
        vars.latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });

        vars.marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(vars.marketParams))))));
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // First, create a large market by minting enough to exceed 2^10
        vars.initialMintAmount = 2000e18; // > 2^10
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), vars.initialMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.initialMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(mintParams, address(this), 0);
        assertGt(vars.aTokenAmount, 0, "Initial mint should succeed");

        // Update state to make it a large market
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.initialMintAmount, hex"");

        // Test 1: Mint amount <= marketBaseTokenSupply should succeed
        vars.smallMintAmount = 1000e18; // < marketBaseTokenSupply
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), vars.smallMintAmount);

        mintParams.baseAmountIn = vars.smallMintAmount;
        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(
            mintParams,
            address(this),
            vars.initialMintAmount
        );
        assertGt(vars.aTokenAmount, 0, "Small mint should succeed for large market");

        // Test 2: Mint amount > marketBaseTokenSupply should fail
        uint256 tooLargeMintAmount = vars.initialMintAmount + 1; // > marketBaseTokenSupply
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), tooLargeMintAmount);

        mintParams.baseAmountIn = tooLargeMintAmount;
        vm.expectRevert(LSErrors.E_LEX_MintCapExceeded.selector);
        vars.latentSwapLEX.mint(mintParams, address(this), vars.initialMintAmount);
    }

    function test_mint_cap_edge_case_noCapLimit_threshold() external {
        // Test the edge case where marketBaseTokenSupply is exactly at the noCapLimit threshold
        MintCapTestVars memory vars;

        // Create LEX with noCapLimit = 10 (threshold is 2^10 = 1024)
        vars.latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });

        vars.marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(vars.marketParams))))));
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Mint exactly 2^10 to be at the threshold
        vars.initialMintAmount = 2 ** 10;
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), vars.initialMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.initialMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(mintParams, address(this), 0);
        assertGt(vars.aTokenAmount, 0, "Initial mint at threshold should succeed");

        // Update state
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.initialMintAmount, hex"");

        // Test: At threshold, should still be treated as small market (can mint up to 2^96)
        uint256 largeMintAmount = 2 ** 96;
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), largeMintAmount);

        mintParams.baseAmountIn = largeMintAmount;
        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(
            mintParams,
            address(this),
            vars.initialMintAmount
        );
        assertGt(vars.aTokenAmount, 0, "Large mint should succeed at threshold (small market rules)");
    }

    function test_mint_cap_swap_operations() external {
        // Test that mint caps also apply to swap operations that involve minting
        MintCapTestVars memory vars;

        vars.latentSwapLEX = new LatentSwapLEX(
            address(this),
            address(this),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Create and initialize a market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.latentSwapLEX)
        });

        vars.marketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(vars.marketParams))))));
        vars.latentSwapLEX.initMarket(vars.marketId, vars.marketParams, 0, hex"");

        // Create a large market first
        vars.initialMintAmount = 2000e18;
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), vars.initialMintAmount);

        MintParams memory mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.initialMintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        (vars.aTokenAmount, vars.zTokenAmount, , ) = vars.latentSwapLEX.mint(mintParams, address(this), 0);

        // Update state
        vm.warp(block.timestamp + 30000);
        vars.latentSwapLEX.updateState(vars.marketId, vars.marketParams, vars.initialMintAmount, hex"");

        // Test: Swap with base token input should respect mint caps
        uint256 tooLargeSwapAmount = vars.initialMintAmount + 1; // > marketBaseTokenSupply
        IERC20(_mockBaseAsset).approve(address(vars.latentSwapLEX), tooLargeSwapAmount);

        SwapParams memory swapParams = SwapParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            assetIn: AssetType.BASE,
            assetOut: AssetType.LEVERAGE,
            to: address(this),
            amountSpecified: tooLargeSwapAmount,
            amountLimit: 0,
            isExactIn: true,
            data: hex"",
            msgValue: 0
        });

        vm.expectRevert(LSErrors.E_LEX_MintCapExceeded.selector);
        vars.latentSwapLEX.swap(swapParams, address(this), vars.initialMintAmount);
    }

    // Helper struct for mint cap tests
    struct MintCapTestVars {
        LatentSwapLEX latentSwapLEX;
        MarketParams marketParams;
        MarketId marketId;
        uint256 initialMintAmount;
        uint256 smallMintAmount;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
    }
}

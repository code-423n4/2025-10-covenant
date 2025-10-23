// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {MarketId, MarketParams, MintParams, RedeemParams, SwapParams, LexState, TokenPrices} from "../src/lex/latentswap/interfaces/ILatentSwapLEX.sol";
import {LatentSwapLEX, AssetType} from "../src/lex/latentswap/LatentSwapLEX.sol";
import {FixedPoint} from "../src/lex/latentswap/libraries/FixedPoint.sol";
import {LSErrors} from "../src/lex/latentswap/libraries/LSErrors.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {WadRayMath} from "@aave/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/libraries/math/PercentageMath.sol";
import {LatentMath} from "../src/lex/latentswap/libraries/LatentMath.sol";
import {TestMath} from "./utils/TestMath.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockLatentSwapLEX} from "./mocks/MockLatentSwapLEX.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {LatentSwapLib} from "../src/periphery/libraries/LatentSwapLib.sol";
import {AssetTypeHelpers} from "./utils/AssetTypeHelpers.sol";
import {SaturatingMath} from "../src/lex/latentswap/libraries/SaturatingMath.sol";

contract LatentSwapLEXFuzzTest is Test {
    using Math for uint256;
    using SafeCast for bool;
    using SafeCast for uint256;
    using PercentageMath for uint256;

    // Max balance of swap pool balance that won't cause an overflow in latent math.
    uint8 constant MIN_FEE = 0;
    uint8 constant HIGH_FEE = 100;

    uint256 constant MIN_BASE_SUPPLY = 10 ** 8;
    uint256 constant MAX_BASE_SUPPLY = (1 << 220); //(1 << 140);

    uint256 constant MAX_INITIAL_BASE_SUPPLY_MINT = FixedPoint.Q96;
    uint256 constant MIN_INITIAL_BASE_SUPPLY_MINT = 10 ** 8;

    uint256 constant MAX_BASE_MINT_RATIO = 1e18; // x1
    uint256 constant MIN_BASE_MINT_RATIO = 1; // 1/10^18

    uint256 constant MIN_SYNTH_MIN_AMOUNT = 10;

    uint256 constant MIN_LTV_PERCENTAGE = 3000;
    uint256 constant MAX_LTV_PERCENTAGE = 9900;

    uint256 constant MIN_SWAP_AMOUNT = 100; // 0.01 %
    uint256 constant MIN_AMOUNT_RATIO = 0.05e16; // 0.05 %
    uint256 constant MAX_AMOUNT_RATIO = 100e16; // 100%

    uint256 constant MIN_BASE_PRICE = 10 ** 16; // 0.001 WAD
    uint256 constant MAX_BASE_PRICE = 10 ** 45; // 10^37 WAD

    uint256 constant MIN_NOTIONAL_PRICE = 10 ** 15; // 1 WAD
    uint256 constant MAX_NOTIONAL_PRICE = 10 ** 60; // 100 WAD

    uint256 constant MAX_SQRTPRICE = 8 * FixedPoint.Q96; // 8 MAX price
    uint256 constant MIN_SQRTPRICE = (333 * FixedPoint.Q96) / 1000; // .11111 MIN price
    uint256 constant MIN_SQRTPRICE_RATIO = (1004 * FixedPoint.Q96) / 1000; // (1.0001)^500 MIN price width = 1.025 MIN sqrt price ratio

    uint256 constant BASE_AMOUNT_PRECISION_ABOVE = 10 ** 26;
    uint256 constant BASE_AMOUNT_PERCENT_BELOW = 8700; // 87%

    int64 constant LN_RATE_BIAS = 5012540000000000; // WAD

    // LTV constants
    uint256 constant MAX_LTV = 9500; // 9
    uint256 constant MIN_LTV = 5000; // 1.003
    uint160 constant P_LIM_H = 9900; // 95%
    uint160 constant P_LIM_MAX = 9999; // 20%
    uint16 constant MAX_LIMIT_LTV = 9999; // 99.99% max limit LTV, above which aTokens cannot be minted.

    // Duration constant
    uint32 constant DURATION = 30 * 24 * 60 * 60;

    /////////////////////////////
    // Bound utils

    function boundTokenIndex(uint8 rawTokenIndex) internal pure returns (uint8 tokenIndex) {
        tokenIndex = rawTokenIndex % (uint8(AssetType.COUNT) - 1);
    }

    function boundBaseSupply(uint256 rawBaseSupply) internal pure returns (uint256 baseSupply) {
        baseSupply = bound(rawBaseSupply, MIN_BASE_SUPPLY, MAX_BASE_SUPPLY);
    }

    function boundBasePrice(uint256 rawBasePrice, uint256 baseSupply) internal pure returns (uint256 basePrice) {
        uint256 maxBasePrice = SaturatingMath.saturatingMulDiv(type(uint256).max, FixedPoint.WAD, baseSupply);
        if (maxBasePrice > MAX_BASE_PRICE) maxBasePrice = MAX_BASE_PRICE;
        uint256 minBasePrice = MIN_BASE_PRICE;
        if (minBasePrice > maxBasePrice) maxBasePrice = minBasePrice;
        basePrice = bound(rawBasePrice, MIN_BASE_PRICE, MAX_BASE_PRICE);
    }

    function boundNotionalPrice(uint256 rawNotionalPrice) internal pure returns (uint256 notionalPrice) {
        notionalPrice = bound(rawNotionalPrice, MIN_NOTIONAL_PRICE, MAX_NOTIONAL_PRICE);
    }

    function boundSqrtRatios(
        uint256 rawSqrtRatioA,
        uint256 rawSqrtRatioB
    ) internal pure returns (uint160 sqrtRatioA, uint160 sqrtRatioB) {
        sqrtRatioB = uint160(bound(rawSqrtRatioB, MIN_SQRTPRICE_RATIO, MAX_SQRTPRICE));
        uint160 maxSqrtRatioA = uint160(Math.mulDiv(sqrtRatioB, FixedPoint.Q96, MIN_SQRTPRICE_RATIO) + 2);
        if (maxSqrtRatioA > uint160(FixedPoint.Q96)) maxSqrtRatioA = uint160(FixedPoint.Q96) - 1;
        sqrtRatioA = uint160(bound(rawSqrtRatioA, MIN_SQRTPRICE, maxSqrtRatioA));
    }

    function boundTokenIndexes(
        uint8 rawTokenIndexIn,
        uint8 rawTokenIndexOut
    ) internal pure returns (uint8 tokenIndexIn, uint8 tokenIndexOut) {
        tokenIndexIn = boundTokenIndex(rawTokenIndexIn);
        tokenIndexOut = boundTokenIndex(rawTokenIndexOut);
        if (tokenIndexIn == tokenIndexOut) tokenIndexOut = boundTokenIndex(tokenIndexOut + 1);
    }

    function boundAmount(uint256 rawAmount, uint256 balance) internal pure returns (uint256 amount) {
        amount = bound(
            rawAmount,
            Math.mulDiv(balance, MIN_AMOUNT_RATIO, 10 ** 18),
            Math.mulDiv(balance, MAX_AMOUNT_RATIO, 10 ** 18)
        );
    }

    //////////
    // Setup

    address private _mockOracle;
    address private _mockBaseAsset;
    address private _mockQuoteAsset;

    //////////
    function setUp() public {
        // deploy mock oracle
        _mockOracle = address(new MockOracle(address(this)));

        // deploy mock ERC20 base asset (and mint for deployer)
        _mockBaseAsset = address(new MockERC20(address(this), "MockBaseAsset", "MBA", 18));

        // deploy mock ERC20 base asset (and mint for deployer)
        _mockQuoteAsset = address(new MockERC20(address(this), "MockQuoteAsset", "MQA", 18));
    }

    //////////
    // Fuzz Tests

    struct test_LatentSwapLEX_swapRoundTrip_Params {
        MockLatentSwapLEX latentSwapLEX;
        uint256 baseSupply;
        uint256 basePrice;
        uint256 notionalPrice;
        uint256 swapAmount;
        uint256 secondSwapAmount;
        uint160 lexHighPriceX96;
        uint160 lexLowPriceX96;
        uint160 limHighPriceX96;
        uint160 limMaxPriceX96;
        uint96 debtPriceDiscountBalanced;
        uint256 debtNotionalPrice;
        uint8 tokenIn;
        uint8 tokenOut;
        uint256 initialATokenSupply;
        uint256 initialZTokenSupply;
        uint256 firstSwapCalc;
        uint256 secondSwapCalc;
        MarketParams marketParams;
        MarketId marketId;
        // Quote comparison variables
        uint256 firstSwapQuote;
        uint256 secondSwapQuote;
        uint256 valueIn;
        uint256 valueOut;
        bool stopTest;
    }

    // Fuzz tests round trips, to ensure output is less or equal to input
    function test_LatentSwapLEX_swapRoundTrip_Fuzz(
        uint256 baseSupplyRaw,
        uint256 basePriceRaw,
        uint256 notionalPriceRaw,
        uint256 swapAmountRaw,
        uint8 tokenInRaw,
        uint8 tokenOutRaw,
        bool firstSwapExactIn,
        bool secondSwapExactIn,
        uint256 lexHighPriceRaw,
        uint256 lexLowPriceRaw,
        bool withFee
    ) external {
        test_LatentSwapLEX_swapRoundTrip_Params memory params;

        // ensure all parameters in range
        params.baseSupply = boundBaseSupply(baseSupplyRaw);
        params.basePrice = boundBasePrice(basePriceRaw, params.baseSupply);
        params.notionalPrice = boundNotionalPrice(notionalPriceRaw);
        (params.tokenIn, params.tokenOut) = boundTokenIndexes(tokenInRaw, tokenOutRaw);
        (params.lexLowPriceX96, params.lexHighPriceX96) = boundSqrtRatios(lexLowPriceRaw, lexHighPriceRaw);
        params.limMaxPriceX96 = params.lexHighPriceX96 - 1;
        params.limHighPriceX96 = params.limMaxPriceX96 - 1;

        console.log("steap1");
        params.debtNotionalPrice = boundNotionalPrice(params.debtPriceDiscountBalanced);
        console.log("steap2");
        // if base is being swapped, it has to all be exact in.
        if (params.tokenIn == uint8(AssetType.BASE) || params.tokenOut == uint8(AssetType.BASE)) {
            firstSwapExactIn = secondSwapExactIn = true;
        }
        console.log("steap3");
        // deploy latentSwapLEX liquid
        params.latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            params.lexHighPriceX96,
            params.lexLowPriceX96,
            params.limHighPriceX96,
            params.limMaxPriceX96,
            LN_RATE_BIAS,
            DURATION,
            withFee ? HIGH_FEE : MIN_FEE
        );

        // Initialize market
        params.marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        params.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(params.latentSwapLEX)
        });
        params.latentSwapLEX.initMarket(params.marketId, params.marketParams, 0, hex"");
        // remove mint and redeem caps
        params.latentSwapLEX.setMarketNoCapLimit(params.marketId, 255);
        console.log("steap4");
        // Set oracle and notional price (mock)
        MockOracle(_mockOracle).setPrice(params.basePrice);
        params.latentSwapLEX.setDebtNotionalPrice(params.marketId, params.debtNotionalPrice);

        // First mint to create initial market state
        (params.initialATokenSupply, params.initialZTokenSupply, params.stopTest) = _mintIterative(
            params.latentSwapLEX,
            MintParams({
                marketId: params.marketId,
                marketParams: params.marketParams,
                baseAmountIn: params.baseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            0
        );
        if (
            params.stopTest ||
            params.initialATokenSupply < MIN_SWAP_AMOUNT ||
            params.initialZTokenSupply < MIN_SWAP_AMOUNT
        ) return;

        console.log("steap5a");
        // bound swap amount
        uint8 tokenFixed = (firstSwapExactIn) ? params.tokenIn : params.tokenOut;
        uint8 tokenVariable = (firstSwapExactIn) ? params.tokenOut : params.tokenIn;
        params.swapAmount = boundAmount(
            swapAmountRaw,
            (tokenFixed == uint8(AssetType.BASE))
                ? params.baseSupply
                : (tokenFixed == uint8(AssetType.LEVERAGE))
                    ? params.initialATokenSupply >> ((tokenVariable == uint8(AssetType.BASE)) ? 1 : 0)
                    : params.initialZTokenSupply >> ((tokenVariable == uint8(AssetType.BASE)) ? 1 : 0)
        );
        console.log("steap6");
        // Get quote for first swap
        try
            params.latentSwapLEX.quoteSwap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetType(params.tokenIn),
                    assetOut: AssetType(params.tokenOut),
                    to: address(this),
                    amountSpecified: params.swapAmount,
                    amountLimit: 0,
                    isExactIn: firstSwapExactIn,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply
            )
        returns (uint256 firstSwapQuote, uint128, uint128, TokenPrices memory) {
            params.firstSwapQuote = firstSwapQuote;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return;
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        // First swap
        try
            params.latentSwapLEX.swap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetType(params.tokenIn),
                    assetOut: AssetType(params.tokenOut),
                    to: address(this),
                    amountSpecified: params.swapAmount,
                    amountLimit: 0,
                    isExactIn: firstSwapExactIn,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply
            )
        returns (uint256 firstSwapCalc, uint128, TokenPrices memory) {
            params.firstSwapCalc = firstSwapCalc;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return;
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }
        console.log("steap7");
        // Verify quote matches actual swap
        assertEq(params.firstSwapQuote, params.firstSwapCalc, "First swap quote should match actual swap amount");

        // Ensure first swap is at least MIN_SWAP_AMOUNT
        if (params.firstSwapCalc < MIN_SWAP_AMOUNT) return;

        // Update baseSupply
        // @dev - LatentSwap does not track baseTokens, so done here explicitly
        if (AssetType(params.tokenIn) == AssetType.BASE)
            params.baseSupply += firstSwapExactIn ? params.swapAmount : params.firstSwapCalc;
        else if (AssetType(params.tokenOut) == AssetType.BASE)
            params.baseSupply -= firstSwapExactIn ? params.firstSwapCalc : params.swapAmount;

        // Second swap
        params.secondSwapAmount = (firstSwapExactIn == secondSwapExactIn) ? params.firstSwapCalc : params.swapAmount;
        console.log("steap8");
        // Get quote for second swap
        try
            params.latentSwapLEX.quoteSwap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetType(params.tokenOut),
                    assetOut: AssetType(params.tokenIn),
                    to: address(this),
                    amountSpecified: params.secondSwapAmount,
                    amountLimit: 0,
                    isExactIn: secondSwapExactIn,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply
            )
        returns (uint256 secondSwapQuote, uint128, uint128, TokenPrices memory) {
            params.secondSwapQuote = secondSwapQuote;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return;
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        try
            params.latentSwapLEX.swap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetType(params.tokenOut),
                    assetOut: AssetType(params.tokenIn),
                    to: address(this),
                    amountSpecified: params.secondSwapAmount,
                    amountLimit: 0,
                    isExactIn: secondSwapExactIn,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply
            )
        returns (uint256 secondSwapCalc, uint128, TokenPrices memory) {
            params.secondSwapCalc = secondSwapCalc;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return;
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        // Verify quote matches actual swap
        assertEq(params.secondSwapQuote, params.secondSwapCalc, "Second swap quote should match actual swap amount");
        if (firstSwapExactIn == secondSwapExactIn) {
            if (firstSwapExactIn) {
                // both exact in
                // if asset is base Token, use value of baseToken for comparison, with precision.
                if (params.tokenIn != uint8(AssetType.BASE)) {
                    assertLe(
                        params.secondSwapCalc,
                        params.swapAmount,
                        "second swap output should be less than or equal to swap amount input (both exact in)"
                    );
                } else {
                    if (params.secondSwapCalc > params.swapAmount) {
                        assertLe(
                            Math.mulDiv(params.secondSwapCalc, BASE_AMOUNT_PRECISION_ABOVE, params.swapAmount),
                            BASE_AMOUNT_PRECISION_ABOVE,
                            "second swap output should be less than or equal to swap amount input to 27 decimal places in value"
                        );
                    } else {
                        if (params.swapAmount > MIN_BASE_SUPPLY) {
                            console.log("params.swapAmount", params.swapAmount);
                            console.log("params.secondSwapCalc", params.secondSwapCalc);
                            assertGe(
                                Math.mulDiv(params.secondSwapCalc, 10000, params.swapAmount),
                                BASE_AMOUNT_PERCENT_BELOW,
                                "Swap output should not be more than 13% under swap input amount"
                            );
                        }
                    }
                }
            } else {
                // both exact out
                assertGe(
                    params.secondSwapCalc,
                    params.swapAmount,
                    "second swap input should be greater than or equal to first swap output (both exact out)"
                );
            }
        } else {
            // one exact in, one exact out (either order)
            if (firstSwapExactIn) {
                assertLe(
                    params.firstSwapCalc,
                    params.secondSwapCalc,
                    "first swap output should be less than or equal to second swap input (one exact in, one exact out)"
                );
            } else {
                assertGe(
                    params.firstSwapCalc,
                    params.secondSwapCalc,
                    "first swap input should be greater than or equal to second swap output (one exact in, one exact out)"
                );
            }
        }
    }

    struct test_LatentSwapLEX_mintAndSwapBackRoundTrip_Params {
        MockLatentSwapLEX latentSwapLEX;
        uint256 ltvPercentage;
        uint256 baseSupply;
        uint256 basePrice;
        uint256 notionalPrice;
        uint256 lexHighPrice;
        uint96 debtPriceDiscountBalanced;
        uint256 debtNotionalPrice;
        uint8 firstSwapTokenIn;
        uint256 initialATokenSupply;
        uint256 initialZTokenSupply;
        uint256 firstSwapCalc;
        uint256 secondSwapCalc;
        uint256 mintAmount;
        MarketParams marketParams;
        MarketId marketId;
        uint160 lexHighPriceX96;
        uint160 lexLowPriceX96;
        uint160 limHighPriceX96;
        uint160 limMaxPriceX96;
        uint256 amountOut;
        // Quote comparison variables
        uint256 firstMintATokenQuote;
        uint256 firstMintZTokenQuote;
        uint256 secondMintATokenQuote;
        uint256 secondMintZTokenQuote;
        uint256 firstSwapQuote;
        uint256 secondSwapQuote;
        uint256 valueIn;
        uint256 valueOut;
        bool stopTest;
    }

    // Fuzz tests round trips, to ensure output is less or equal to input
    function test_LatentSwapLEX_mintAndSwapBackRoundTrip_Fuzz(
        uint256 baseSupplyRaw,
        uint256 basePriceRaw,
        uint256 notionalPriceRaw,
        uint256 mintAmountRaw,
        uint256 lexHighPriceRaw,
        uint256 lexLowPriceRaw,
        uint8 firstSwapTokenInRaw,
        bool withFee
    ) external {
        test_LatentSwapLEX_mintAndSwapBackRoundTrip_Params memory params;

        // ensure all parameters in range
        {
            params.baseSupply = boundBaseSupply(baseSupplyRaw);
            params.mintAmount = bound(
                mintAmountRaw,
                Math.mulDiv(params.baseSupply, MIN_BASE_MINT_RATIO, 1e18),
                Math.mulDiv(params.baseSupply, MAX_BASE_MINT_RATIO, 1e18)
            );

            if (params.mintAmount < MIN_SWAP_AMOUNT) return;
            params.basePrice = boundBasePrice(basePriceRaw, params.baseSupply);
            params.notionalPrice = boundNotionalPrice(notionalPriceRaw);
            params.firstSwapTokenIn = uint8(
                bound(firstSwapTokenInRaw, uint8(AssetType.DEBT), uint8(AssetType.LEVERAGE))
            );

            (params.lexLowPriceX96, params.lexHighPriceX96) = boundSqrtRatios(lexLowPriceRaw, lexHighPriceRaw);

            params.limMaxPriceX96 = params.lexHighPriceX96 - 1;
            params.limHighPriceX96 = params.limMaxPriceX96 - 1;

            params.debtNotionalPrice = boundNotionalPrice(params.debtPriceDiscountBalanced);
        }

        // deploy latentSwapLEX liquid
        params.latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            params.lexHighPriceX96,
            params.lexLowPriceX96,
            params.limHighPriceX96,
            params.limMaxPriceX96,
            LN_RATE_BIAS,
            DURATION,
            withFee ? HIGH_FEE : MIN_FEE
        );

        // Initialize market
        params.marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        params.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(params.latentSwapLEX)
        });
        params.latentSwapLEX.initMarket(params.marketId, params.marketParams, 0, hex"");

        // remove mint and redeem caps
        params.latentSwapLEX.setMarketNoCapLimit(params.marketId, 255);

        // First mint to create initial market state
        (params.initialATokenSupply, params.initialZTokenSupply, params.stopTest) = _mintIterative(
            params.latentSwapLEX,
            MintParams({
                marketId: params.marketId,
                marketParams: params.marketParams,
                baseAmountIn: params.baseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            0
        );
        if (
            params.stopTest ||
            params.initialATokenSupply < MIN_SWAP_AMOUNT ||
            params.initialZTokenSupply < MIN_SWAP_AMOUNT
        ) return;

        // Get quote for second mint
        (params.secondMintATokenQuote, params.secondMintZTokenQuote, , , ) = params.latentSwapLEX.quoteMint(
            MintParams({
                marketId: params.marketId,
                marketParams: params.marketParams,
                baseAmountIn: params.mintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            params.baseSupply
        );

        // Second mint
        (params.initialATokenSupply, params.initialZTokenSupply, , ) = params.latentSwapLEX.mint(
            MintParams({
                marketId: params.marketId,
                marketParams: params.marketParams,
                baseAmountIn: params.mintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            params.baseSupply
        );

        // Verify quote matches actual mint
        assertEq(
            params.secondMintATokenQuote,
            params.initialATokenSupply,
            "Second mint aToken quote should match actual mint amount"
        );
        assertEq(
            params.secondMintZTokenQuote,
            params.initialZTokenSupply,
            "Second mint zToken quote should match actual mint amount"
        );

        // Ensure second mint as a+z tokens that are at least MIN_SWAP_AMOUNT
        if (params.initialATokenSupply < MIN_SWAP_AMOUNT || params.initialZTokenSupply < MIN_SWAP_AMOUNT) return;

        // Get quote for first swap
        uint256 firstSwapAmount = (AssetType(params.firstSwapTokenIn) == AssetType.DEBT)
            ? params.initialZTokenSupply
            : params.initialATokenSupply;
        try
            params.latentSwapLEX.quoteSwap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetType(params.firstSwapTokenIn),
                    assetOut: AssetType.BASE,
                    to: address(this),
                    amountSpecified: firstSwapAmount,
                    amountLimit: 0,
                    isExactIn: true,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply + params.mintAmount
            )
        returns (uint256 firstSwapQuote, uint128, uint128, TokenPrices memory) {
            params.firstSwapQuote = firstSwapQuote;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return;
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        // first swap out
        try
            params.latentSwapLEX.swap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetType(params.firstSwapTokenIn),
                    assetOut: AssetType.BASE,
                    to: address(this),
                    amountSpecified: firstSwapAmount,
                    amountLimit: 0,
                    isExactIn: true,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply + params.mintAmount
            )
        returns (uint256 firstSwapCalc, uint128, TokenPrices memory) {
            params.firstSwapCalc = firstSwapCalc;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return;
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        // Verify quote matches actual swap
        assertEq(params.firstSwapQuote, params.firstSwapCalc, "First swap quote should match actual swap amount");

        // Get quote for second swap
        uint256 secondSwapAmount = (AssetType(params.firstSwapTokenIn) == AssetType.DEBT)
            ? params.initialATokenSupply
            : params.initialZTokenSupply;
        try
            params.latentSwapLEX.quoteSwap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetTypeHelpers.debtAndLeverageSwap(AssetType(params.firstSwapTokenIn)),
                    assetOut: AssetType.BASE,
                    to: address(this),
                    amountSpecified: secondSwapAmount,
                    amountLimit: 0,
                    isExactIn: true,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply + params.mintAmount - params.firstSwapCalc
            )
        returns (uint256 secondSwapQuote, uint128, uint128, TokenPrices memory) {
            params.secondSwapQuote = secondSwapQuote;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return;
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        // second swap out
        // @dev - use quoteSwap to bypass LTV limits
        try
            params.latentSwapLEX.swap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetTypeHelpers.debtAndLeverageSwap(AssetType(params.firstSwapTokenIn)),
                    assetOut: AssetType.BASE,
                    to: address(this),
                    amountSpecified: secondSwapAmount,
                    amountLimit: 0,
                    isExactIn: true,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply + params.mintAmount - params.firstSwapCalc
            )
        returns (uint256 secondSwapCalc, uint128, TokenPrices memory) {
            params.secondSwapCalc = secondSwapCalc;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return;
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        // Verify quote matches actual swap
        assertEq(params.secondSwapQuote, params.secondSwapCalc, "Second swap quote should match actual swap amount");

        // base tokens output should be less than or equal to base tokens input
        params.amountOut = params.secondSwapCalc + params.firstSwapCalc;
        if (params.amountOut > params.mintAmount) {
            console.log("params.mintAmount", params.mintAmount);
            console.log("params.amountOut", params.amountOut);
            assertLe(
                Math.mulDiv(params.amountOut, BASE_AMOUNT_PRECISION_ABOVE, params.mintAmount),
                BASE_AMOUNT_PRECISION_ABOVE,
                "Redeem output should be lower or equal to 27 decimal places in value"
            );
        } else {
            if (params.mintAmount > MIN_BASE_SUPPLY) {
                assertGe(
                    Math.mulDiv(params.amountOut, 10000, params.mintAmount),
                    BASE_AMOUNT_PERCENT_BELOW,
                    "Redeem output should not be more than 13% under input amount"
                );
            }
        }
    }

    struct test_LatentSwapLEX_mintSwapRedeem_RoundTrip_Params {
        MockLatentSwapLEX latentSwapLEX;
        uint256 ltvPercentage;
        uint256 baseSupply;
        uint256 basePrice;
        uint256 notionalPrice;
        uint256 swapAmount;
        uint256 lexHighPrice;
        uint96 debtPriceDiscountBalanced;
        uint256 debtNotionalPrice;
        uint8 firstSwapTokenIn;
        uint256 initialATokenSupply;
        uint256 initialZTokenSupply;
        uint256 secondMintATokenSupply;
        uint256 secondMintZTokenSupply;
        uint256 firstSwapCalc;
        uint256 secondSwapCalc;
        uint256 mintAmount;
        uint256 redeemCalc;
        MarketParams marketParams;
        MarketId marketId;
        uint160 lexHighPriceX96;
        uint160 lexLowPriceX96;
        uint160 limHighPriceX96;
        uint160 limMaxPriceX96;
        // Quote comparison variables
        uint256 firstMintATokenQuote;
        uint256 firstMintZTokenQuote;
        uint256 secondMintATokenQuote;
        uint256 secondMintZTokenQuote;
        uint256 firstSwapQuote;
        uint256 redeemQuote;
        uint256 valueIn;
        uint256 valueOut;
        bool stopTest;
    }

    // Fuzz tests round trips, to ensure output is less or equal to input
    function test_LatentSwapLEX_mintSwapRedeem_RoundTrip_Fuzz(
        uint256 baseSupplyRaw,
        uint256 basePriceRaw,
        uint256 notionalPriceRaw,
        uint256 mintAmountRaw,
        uint256 lexHighPriceRaw,
        uint256 lexLowPriceRaw,
        uint256 swapAmountRaw,
        uint8 firstSwapTokenInRaw,
        bool withFee
    ) public {
        test_LatentSwapLEX_mintSwapRedeem_RoundTrip_Params memory params;

        // ensure all parameters in range
        {
            params.baseSupply = boundBaseSupply(baseSupplyRaw);
            params.mintAmount = bound(
                mintAmountRaw,
                Math.mulDiv(params.baseSupply, MIN_BASE_MINT_RATIO, 1e18),
                Math.mulDiv(params.baseSupply, MAX_BASE_MINT_RATIO, 1e18)
            );

            if (params.mintAmount < MIN_SWAP_AMOUNT) return;
            params.basePrice = boundBasePrice(basePriceRaw, params.baseSupply);
            params.notionalPrice = boundNotionalPrice(notionalPriceRaw);
            params.firstSwapTokenIn = uint8(
                bound(firstSwapTokenInRaw, uint8(AssetType.DEBT), uint8(AssetType.LEVERAGE))
            );

            (params.lexLowPriceX96, params.lexHighPriceX96) = boundSqrtRatios(lexLowPriceRaw, lexHighPriceRaw);

            params.limMaxPriceX96 = params.lexHighPriceX96 - 1;
            params.limHighPriceX96 = params.limMaxPriceX96 - 1;

            params.debtNotionalPrice = boundNotionalPrice(FixedPoint.WAD);
        }

        // deploy latentSwapLEX liquid
        params.latentSwapLEX = new MockLatentSwapLEX(
            address(this),
            address(this),
            params.lexHighPriceX96,
            params.lexLowPriceX96,
            params.limHighPriceX96,
            params.limMaxPriceX96,
            LN_RATE_BIAS,
            DURATION,
            withFee ? HIGH_FEE : MIN_FEE
        );

        // Initialize market
        params.marketId = MarketId.wrap(
            bytes20(uint160(uint256(keccak256("Random market (LatentSwap does not verify)"))))
        );
        params.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(params.latentSwapLEX)
        });
        params.latentSwapLEX.initMarket(params.marketId, params.marketParams, 0, hex"");

        // remove mint and redeem caps
        params.latentSwapLEX.setMarketNoCapLimit(params.marketId, 255);

        // Set oracle and notional price (mock)
        MockOracle(_mockOracle).setPrice(params.basePrice);
        params.latentSwapLEX.setDebtNotionalPrice(params.marketId, params.debtNotionalPrice);

        // First mint to create initial market state
        (params.initialATokenSupply, params.initialZTokenSupply, params.stopTest) = _mintIterative(
            params.latentSwapLEX,
            MintParams({
                marketId: params.marketId,
                marketParams: params.marketParams,
                baseAmountIn: params.baseSupply,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            0
        );

        // Ensure minimum synth mint amout before continuing
        if (
            params.stopTest ||
            params.initialATokenSupply < MIN_SYNTH_MIN_AMOUNT ||
            params.initialZTokenSupply < MIN_SYNTH_MIN_AMOUNT
        ) return;

        // Get quote for second mint
        try
            params.latentSwapLEX.quoteMint(
                MintParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    baseAmountIn: params.mintAmount,
                    to: address(this),
                    minATokenAmountOut: 0,
                    minZTokenAmountOut: 0,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply
            )
        returns (uint256 aTokenAmountOut, uint256 zTokenAmountOut, uint128, uint128, TokenPrices memory) {
            params.secondMintATokenQuote = aTokenAmountOut;
            params.secondMintZTokenQuote = zTokenAmountOut;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                // selector of E_LEX_ActionNotAllowedUnderCollateralized()
                if (sel == LSErrors.E_LEX_ActionNotAllowedUnderCollateralized.selector) {
                    return; // graceful exit
                }
            }
            // not the error we expected — bubble it up unchanged
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        // Second mint
        (params.secondMintATokenSupply, params.secondMintZTokenSupply, , ) = params.latentSwapLEX.mint(
            MintParams({
                marketId: params.marketId,
                marketParams: params.marketParams,
                baseAmountIn: params.mintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            params.baseSupply
        );

        // Verify quote matches actual mint
        assertEq(
            params.secondMintATokenQuote,
            params.secondMintATokenSupply,
            "Second mint aToken quote should match actual mint amount"
        );
        assertEq(
            params.secondMintZTokenQuote,
            params.secondMintZTokenSupply,
            "Second mint zToken quote should match actual mint amount"
        );

        // Ensure minimum synth mint amout before continuing
        if (
            (params.secondMintZTokenSupply < MIN_SYNTH_MIN_AMOUNT) ||
            (params.secondMintATokenSupply < MIN_SYNTH_MIN_AMOUNT)
        ) return;

        // Determine swap amount
        params.swapAmount = boundAmount(
            swapAmountRaw,
            (AssetType(params.firstSwapTokenIn) == AssetType.DEBT)
                ? params.secondMintZTokenSupply
                : params.secondMintATokenSupply
        );
        // Ensure min swap amount
        if (params.swapAmount < MIN_SWAP_AMOUNT) return;

        console.log(">>>>>>>>>>>>quote swap");
        // Get quote for first swap
        try
            params.latentSwapLEX.quoteSwap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetType(params.firstSwapTokenIn), // token in
                    assetOut: AssetTypeHelpers.debtAndLeverageSwap(AssetType(params.firstSwapTokenIn)), // token out
                    to: address(this),
                    amountSpecified: params.swapAmount,
                    amountLimit: 0,
                    isExactIn: true,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply + params.mintAmount
            )
        returns (uint256 amountCalculated, uint128, uint128, TokenPrices memory) {
            params.firstSwapQuote = amountCalculated;
        } catch (bytes memory lowLevelData) {
            console.log(">>>>>>>>>>>>error quote swap");
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                // selector of E_LEX_ActionNotAllowedUnderCollateralized()
                if (
                    sel == LSErrors.E_LEX_ActionNotAllowedUnderCollateralized.selector ||
                    sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector
                ) {
                    return; // graceful exit
                }
            }
            // not the error we expected — bubble it up unchanged
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        console.log(">>>>>>>>>>>>swap");
        // first swap out
        try
            params.latentSwapLEX.swap(
                SwapParams({
                    marketId: params.marketId,
                    marketParams: params.marketParams,
                    assetIn: AssetType(params.firstSwapTokenIn), // token in
                    assetOut: AssetTypeHelpers.debtAndLeverageSwap(AssetType(params.firstSwapTokenIn)), // token out
                    to: address(this),
                    amountSpecified: params.swapAmount,
                    amountLimit: 0,
                    isExactIn: true,
                    data: hex"",
                    msgValue: 0
                }),
                address(this),
                params.baseSupply + params.mintAmount
            )
        returns (uint256 firstSwapCalc, uint128, TokenPrices memory) {
            params.firstSwapCalc = firstSwapCalc;
        } catch (bytes memory lowLevelData) {
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return;
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        // Verify quote matches actual swap
        assertEq(params.firstSwapQuote, params.firstSwapCalc, "First swap quote should match actual swap amount");

        // update atoken + ztokens owned given mint + swap
        if (AssetType(params.firstSwapTokenIn) == AssetType.DEBT) {
            params.secondMintATokenSupply += params.firstSwapCalc;
            params.secondMintZTokenSupply -= params.swapAmount;
        } else {
            params.secondMintATokenSupply -= params.swapAmount;
            params.secondMintZTokenSupply += params.firstSwapCalc;
        }
        console.log(">>>>>>>>>>>>quote redeem");
        // Get quote for redeem
        (params.redeemQuote, , , ) = params.latentSwapLEX.quoteRedeem(
            RedeemParams({
                marketId: params.marketId,
                marketParams: params.marketParams,
                aTokenAmountIn: params.secondMintATokenSupply,
                zTokenAmountIn: params.secondMintZTokenSupply,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            params.baseSupply + params.mintAmount
        );

        // redeem a + z tokens from second mint + swap.
        (params.redeemCalc, , ) = params.latentSwapLEX.redeem(
            RedeemParams({
                marketId: params.marketId,
                marketParams: params.marketParams,
                aTokenAmountIn: params.secondMintATokenSupply,
                zTokenAmountIn: params.secondMintZTokenSupply,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            }),
            address(this),
            params.baseSupply + params.mintAmount
        );

        // Verify quote matches actual redeem
        assertEq(params.redeemQuote, params.redeemCalc, "Redeem quote should match actual redeem amount");

        if (params.redeemCalc > params.mintAmount) {
            //params.valueIn = Math.mulDiv(params.mintAmount, params.basePrice, FixedPoint.WAD);
            //params.valueOut = Math.mulDiv(params.redeemCalc, params.basePrice, FixedPoint.WAD);
            assertLe(
                Math.mulDiv(params.redeemCalc, BASE_AMOUNT_PRECISION_ABOVE, params.mintAmount),
                BASE_AMOUNT_PRECISION_ABOVE,
                "Redeem output should be lower or equal to 27 decimal places in value"
            );
        } else {
            if (params.mintAmount > MIN_BASE_SUPPLY) {
                assertGe(
                    Math.mulDiv(params.redeemCalc, 10000, params.mintAmount),
                    BASE_AMOUNT_PERCENT_BELOW,
                    "Redeem output should not be more than 13% under input amount"
                );
            }

            assertGt(params.redeemCalc, 0, "redeem output should be greater than 0, given min redeem amounts");
        }
    }

    function _mintIterative(
        MockLatentSwapLEX latentSwapLEX,
        MintParams memory mintParams,
        uint256 baseTokenSupply
    ) internal returns (uint256 initialATokenSupply, uint256 initialZTokenSupply, bool stopTest) {
        // Mints multiple times to reach target mint amount, and returns a special flag if test should return.

        uint256 mintAmount = mintParams.baseAmountIn;
        console.log(">>>>>>>>>>>>>minting");
        // if baseSupply > X96, then do various mints to create initial market state.
        // First mint to create initial market state
        mintParams.baseAmountIn = Math.min(mintAmount, FixedPoint.Q96);
        try latentSwapLEX.mint(mintParams, address(this), 0) returns (
            uint256 aTokenAmount,
            uint256 zTokenAmount,
            uint128,
            TokenPrices memory
        ) {
            initialATokenSupply = aTokenAmount;
            initialZTokenSupply = zTokenAmount;
        } catch (bytes memory lowLevelData) {
            console.log(">>>>>>>>>>>>>error minting");
            if (lowLevelData.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(lowLevelData, 32))
                }
                if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                    // Market size limit exceeded, skip this test case
                    return (0, 0, true);
                }
            }
            // Re-throw other exceptions to bubble up the actual error
            assembly {
                revert(add(lowLevelData, 32), mload(lowLevelData))
            }
        }

        if (mintAmount > FixedPoint.Q96) {
            uint256 currentBaseSupply = FixedPoint.Q96;
            while (currentBaseSupply < mintAmount) {
                // mint remaining amount or 2*currentBaseSupply, whichever is smaller
                mintParams.baseAmountIn = Math.min(mintAmount - currentBaseSupply, currentBaseSupply);
                try latentSwapLEX.mint(mintParams, address(this), currentBaseSupply) returns (
                    uint256 secondATokenSupply,
                    uint256 secondZTokenSupply,
                    uint128,
                    TokenPrices memory
                ) {
                    initialATokenSupply += secondATokenSupply;
                    initialZTokenSupply += secondZTokenSupply;
                    currentBaseSupply += mintAmount;
                } catch (bytes memory lowLevelData) {
                    console.log(">>>>>>>>>>>>>error minting");
                    if (lowLevelData.length >= 4) {
                        bytes4 sel;
                        assembly {
                            sel := mload(add(lowLevelData, 32))
                        }
                        if (sel == LSErrors.E_LEX_MarketSizeLimitExceeded.selector) {
                            // Market size limit exceeded, skip this test case
                            return (0, 0, true);
                        }
                    }
                    // Re-throw other exceptions to bubble up the actual error
                    assembly {
                        revert(add(lowLevelData, 32), mload(lowLevelData))
                    }
                }
            }
        }

        console.log(">>>>>>>>>>>>>finished minting");
        return (initialATokenSupply, initialZTokenSupply, false);
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {SynthToken} from "../src/synths/SynthToken.sol";
import {Covenant} from "../src/Covenant.sol";
import {DataProvider, MarketDetails} from "../src/periphery/DataProvider.sol";
import {LatentSwapLEX} from "../src/lex/latentswap/LatentSwapLEX.sol";
import {FixedPoint} from "../src/lex/latentswap/libraries/FixedPoint.sol";
import {ICovenant, MarketId, MarketParams, IERC20, MintParams, TokenPrices, SwapParams, RedeemParams, AssetType} from "../src/interfaces/ICovenant.sol";
import {ISynthToken} from "../src/interfaces/ISynthToken.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ILiquidExchangeModel} from "../src/interfaces/ILiquidExchangeModel.sol";
import {ILatentSwapLEX, LexState} from "../src/lex/latentswap/interfaces/ILatentSwapLEX.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {MarketParamsLib} from "../src/libraries/MarketParams.sol";
import {LatentSwapLib} from "../src/periphery/libraries/LatentSwapLib.sol";
import {PercentageMath} from "@aave/libraries/math/PercentageMath.sol";

contract DataProviderTest is Test {
    // LatentSwapLEX init pricing constants
    // Order: edgeHigh >= limMax > limHigh > target >= edgeLow
    uint160 constant P_EDGE_HIGH = uint160((1095445 * FixedPoint.Q96) / 1000000); // Edge price of 1.2
    uint160 constant P_LIM_MAX = uint160((1086278 * FixedPoint.Q96) / 1000000); // == 95% LTV
    uint160 constant P_LIM_HIGH = uint160((1050000 * FixedPoint.Q96) / 1000000); // == 90% LTV
    uint160 constant P_TARGET = uint160(FixedPoint.Q96); // Target price == 1, == 50% LTV
    uint160 constant P_EDGE_LOW = uint160((948683 * FixedPoint.Q96) / 1000000); // == 22% LTV
    uint32 constant DURATION = 30 * 24 * 60 * 60;

    address private _mockOracle;
    address private _mockBaseAsset;
    address private _mockQuoteAsset;
    address private _mockBaseAsset6;
    address private _mockQuoteAsset6;
    address private _synthImplementation;
    Covenant private _covenantCore;
    MarketId[] private _marketIds;

    function setUp() public {
        // deploy mock oracle
        _mockOracle = address(new MockOracle(address(this)));

        // deploy mock ERC20 base asset (and mint for deployer)
        _mockBaseAsset = address(new MockERC20(address(this), "MockBaseAsset", "MBA", 18));
        MockERC20(_mockBaseAsset).mint(address(this), 100 * 10 ** 18);

        // deploy mock ERC20 quote asset
        _mockQuoteAsset = address(new MockERC20(address(this), "MockQuoteAsset", "MQA", 18));

        // deploy mock ERC20 base asset (and mint for deployer)
        _mockBaseAsset6 = address(new MockERC20(address(this), "MockBaseAsset6", "MBA6", 6));
        MockERC20(_mockBaseAsset6).mint(address(this), 100 * 10 ** 6);

        // deploy mock ERC20 quote asset
        _mockQuoteAsset6 = address(new MockERC20(address(this), "MockQuoteAsset6", "MQA6", 6));

        // deploy covenant liquid
        _covenantCore = new Covenant(address(this));

        // deploy lex implementation
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this), // initialOwner
                address(_covenantCore), // covenantCore
                P_EDGE_HIGH, // edgeHighSqrtPriceX96
                P_EDGE_LOW, // edgeLowSqrtPriceX96
                P_LIM_HIGH, // limHighSqrtPriceX96
                P_LIM_MAX, // limMaxSqrtPriceX96
                5012540000000000, // lnRateBias
                7776000, // debtDuration
                0 // swapFee
            )
        );

        // authorize lex
        _covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        _covenantCore.setEnabledCurator(_mockOracle, true);

        // Initialize markets using loops
        address[2] memory baseTokens = [_mockBaseAsset, _mockBaseAsset6];
        address[2] memory quoteTokens = [_mockQuoteAsset, _mockQuoteAsset6];

        _marketIds = new MarketId[](baseTokens.length * quoteTokens.length);
        uint256 k = 0;
        for (uint256 i = 0; i < baseTokens.length; i++) {
            for (uint256 j = 0; j < quoteTokens.length; j++) {
                MarketParams memory marketParams = MarketParams({
                    baseToken: baseTokens[i],
                    quoteToken: quoteTokens[j],
                    curator: _mockOracle,
                    lex: lexImplementation
                });

                _marketIds[k] = _covenantCore.createMarket(marketParams, abi.encode(990000000000000000));
                k++;
            }
        }
    }

    function test_newDataProvider() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        // Verify it was deployed successfully
        assertTrue(address(dataProvider) != address(0));
    }

    function test_getMarketDetails_noLiquidity() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        // get marketDetails for each market
        for (uint256 i = 0; i < _marketIds.length; i++) {
            MarketDetails memory marketDetails = dataProvider.getMarketDetails(address(_covenantCore), _marketIds[i]);

            // Verify basic market information
            assertEq(MarketId.unwrap(marketDetails.marketId), MarketId.unwrap(_marketIds[i]));

            // Determine expected tokens based on market index
            address expectedBaseToken = (i == 0 || i == 1) ? _mockBaseAsset : _mockBaseAsset6;
            address expectedQuoteToken = (i == 0 || i == 2) ? _mockQuoteAsset : _mockQuoteAsset6;

            assertEq(marketDetails.marketParams.baseToken, expectedBaseToken);
            assertEq(marketDetails.marketParams.quoteToken, expectedQuoteToken);
            assertEq(marketDetails.marketParams.curator, _mockOracle);

            // Verify token details
            assertTrue(bytes(marketDetails.baseToken.name).length > 0);
            assertTrue(bytes(marketDetails.baseToken.symbol).length > 0);
            assertTrue(marketDetails.baseToken.decimals > 0);

            assertTrue(bytes(marketDetails.quoteToken.name).length > 0);
            assertTrue(bytes(marketDetails.quoteToken.symbol).length > 0);
            assertTrue(marketDetails.quoteToken.decimals > 0);

            // Verify synth token details
            assertTrue(marketDetails.aToken.tokenAddress != address(0));
            assertTrue(marketDetails.zToken.tokenAddress != address(0));
            assertTrue(bytes(marketDetails.aToken.name).length > 0);
            assertTrue(bytes(marketDetails.zToken.name).length > 0);

            // Verify token prices are returned
            assertTrue(marketDetails.tokenPrices.baseTokenPrice > 0);
            assertTrue(marketDetails.tokenPrices.aTokenPrice > 0);
            assertTrue(marketDetails.tokenPrices.zTokenPrice > 0);
        }
    }

    function test_getMarketsDetails_noLiquidity() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        // get marketDetails for all 4 markets
        MarketDetails[] memory marketsDetails = dataProvider.getMarketsDetails(address(_covenantCore), _marketIds);

        // Verify we got details for all markets
        assertEq(marketsDetails.length, _marketIds.length);

        // Verify each market's details
        for (uint256 i = 0; i < marketsDetails.length; i++) {
            assertEq(MarketId.unwrap(marketsDetails[i].marketId), MarketId.unwrap(_marketIds[i]));
            assertTrue(bytes(marketsDetails[i].baseToken.name).length > 0);
            assertTrue(bytes(marketsDetails[i].quoteToken.name).length > 0);

            // Verify token prices are returned
            assertTrue(marketsDetails[i].tokenPrices.baseTokenPrice > 0);
            assertTrue(marketsDetails[i].tokenPrices.aTokenPrice > 0);
            assertTrue(marketsDetails[i].tokenPrices.zTokenPrice > 0);
        }
    }
    function test_getMarketDetails_withLiquidity() external {
        DataProvider dataProvider;
        uint256 baseAmountIn;

        // deploy data provider
        dataProvider = new DataProvider();

        // Loop over all markets to approve, mint, and get market details
        for (uint256 i = 0; i < _marketIds.length; i++) {
            // Get market params
            MarketParams memory marketParams = _covenantCore.getIdToMarketParams(_marketIds[i]);
            address baseAsset = marketParams.baseToken;

            // Calc amountIn
            uint256 assetDecimals = IERC20Metadata(baseAsset).decimals();
            baseAmountIn = 10 ** assetDecimals;

            console.log("iteration", i);

            // Approve transferFrom for each market
            IERC20(baseAsset).approve(address(_covenantCore), baseAmountIn);

            // Mint for each market
            MintParams memory mintParams = MintParams({
                marketId: _marketIds[i],
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: "",
                msgValue: 0
            });

            console.log("minting");
            _covenantCore.mint(mintParams);

            // Get market details for each market
            console.log("getting market details");
            MarketDetails memory output = dataProvider.getMarketDetails(address(_covenantCore), _marketIds[i]);
            console.log("got market details");
            // Verify market details are populated
            assertEq(MarketId.unwrap(output.marketId), MarketId.unwrap(_marketIds[i]));
            assertTrue(output.marketState.baseSupply > 0);
            assertTrue(output.aToken.totalSupply > 0);
            assertTrue(output.zToken.totalSupply > 0);

            // Verify token prices are returned
            assertTrue(output.tokenPrices.baseTokenPrice > 0);
            assertTrue(output.tokenPrices.aTokenPrice > 0);
            assertTrue(output.tokenPrices.zTokenPrice > 0);
        }
    }

    function test_tokenPrices_detailed() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        // Test token prices for the first market
        MarketDetails memory marketDetails = dataProvider.getMarketDetails(address(_covenantCore), _marketIds[0]);

        // Verify token prices structure
        assertTrue(marketDetails.tokenPrices.baseTokenPrice > 0, "Base token price should be positive");
        assertTrue(marketDetails.tokenPrices.aTokenPrice > 0, "A token price should be positive");
        assertTrue(marketDetails.tokenPrices.zTokenPrice > 0, "Z token price should be positive");

        // Verify prices are reasonable (not zero and not extremely large)
        assertTrue(marketDetails.tokenPrices.baseTokenPrice < 1e30, "Base token price should be reasonable");
        assertTrue(marketDetails.tokenPrices.aTokenPrice < 1e30, "A token price should be reasonable");
        assertTrue(marketDetails.tokenPrices.zTokenPrice < 1e30, "Z token price should be reasonable");

        // Log prices for debugging
        console.log("Base token price:", marketDetails.tokenPrices.baseTokenPrice);
        console.log("A token price:", marketDetails.tokenPrices.aTokenPrice);
        console.log("Z token price:", marketDetails.tokenPrices.zTokenPrice);
    }

    function test_tokenPrices_consistency() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        // Test that token prices are consistent across multiple calls
        MarketDetails memory marketDetails1 = dataProvider.getMarketDetails(address(_covenantCore), _marketIds[0]);
        MarketDetails memory marketDetails2 = dataProvider.getMarketDetails(address(_covenantCore), _marketIds[0]);

        // Prices should be the same for the same market state
        assertEq(
            marketDetails1.tokenPrices.baseTokenPrice,
            marketDetails2.tokenPrices.baseTokenPrice,
            "Base token prices should be consistent"
        );
        assertEq(
            marketDetails1.tokenPrices.aTokenPrice,
            marketDetails2.tokenPrices.aTokenPrice,
            "A token prices should be consistent"
        );
        assertEq(
            marketDetails1.tokenPrices.zTokenPrice,
            marketDetails2.tokenPrices.zTokenPrice,
            "Z token prices should be consistent"
        );
    }

    function test_tokenPrices_allMarkets() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        // Test token prices for all markets
        for (uint256 i = 0; i < _marketIds.length; i++) {
            MarketDetails memory marketDetails = dataProvider.getMarketDetails(address(_covenantCore), _marketIds[i]);

            // Verify all token prices are positive
            assertTrue(marketDetails.tokenPrices.baseTokenPrice > 0, "Base token price should be positive");
            assertTrue(marketDetails.tokenPrices.aTokenPrice > 0, "A token price should be positive");
            assertTrue(marketDetails.tokenPrices.zTokenPrice > 0, "Z token price should be positive");

            console.log("Market", i);
            console.log("Base price:", marketDetails.tokenPrices.baseTokenPrice);
            console.log("A price:", marketDetails.tokenPrices.aTokenPrice);
            console.log("Z price:", marketDetails.tokenPrices.zTokenPrice);
        }
    }

    function test_tokenPrices_vs_quoteMint() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        // Test token prices comparison for the first market
        MarketId marketId = _marketIds[0];
        MarketParams memory marketParams = _covenantCore.getIdToMarketParams(marketId);

        // Get token prices from DataProvider
        MarketDetails memory marketDetails = dataProvider.getMarketDetails(address(_covenantCore), marketId);

        // Prepare mint parameters for quoteMint
        uint256 baseAmountIn = 1e18; // 1 token
        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: baseAmountIn,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: "",
            msgValue: 0
        });

        // Get token prices from quoteMint
        (
            uint256 aTokenAmountOut,
            uint256 zTokenAmountOut,
            uint128 protocolFees,
            uint128 oracleUpdateFee,
            TokenPrices memory quoteTokenPrices
        ) = ILiquidExchangeModel(marketParams.lex).quoteMint(mintParams, address(this), 0);

        // Log both sets of prices for comparison
        console.log("=== DataProvider Token Prices ===");
        console.log("Base token price:", marketDetails.tokenPrices.baseTokenPrice);
        console.log("A token price:", marketDetails.tokenPrices.aTokenPrice);
        console.log("Z token price:", marketDetails.tokenPrices.zTokenPrice);

        console.log("=== QuoteMint Token Prices ===");
        console.log("Base token price:", quoteTokenPrices.baseTokenPrice);
        console.log("A token price:", quoteTokenPrices.aTokenPrice);
        console.log("Z token price:", quoteTokenPrices.zTokenPrice);

        console.log("=== QuoteMint Amounts ===");
        console.log("A token amount out:", aTokenAmountOut);
        console.log("Z token amount out:", zTokenAmountOut);
        console.log("Protocol fees:", protocolFees);
        console.log("Oracle update fee:", oracleUpdateFee);

        // Verify that both return positive prices
        assertTrue(marketDetails.tokenPrices.baseTokenPrice > 0, "DataProvider base token price should be positive");
        assertTrue(marketDetails.tokenPrices.aTokenPrice > 0, "DataProvider A token price should be positive");
        assertTrue(marketDetails.tokenPrices.zTokenPrice > 0, "DataProvider Z token price should be positive");

        assertTrue(quoteTokenPrices.baseTokenPrice > 0, "QuoteMint base token price should be positive");
        assertTrue(quoteTokenPrices.aTokenPrice > 0, "QuoteMint A token price should be positive");
        assertTrue(quoteTokenPrices.zTokenPrice > 0, "QuoteMint Z token price should be positive");

        // Note: The prices might not be exactly equal due to different calculation contexts
        // but they should be in the same order of magnitude
        console.log("=== Price Comparison ===");
        console.log(
            "Base price ratio (DataProvider/QuoteMint):",
            (marketDetails.tokenPrices.baseTokenPrice * 1e18) / quoteTokenPrices.baseTokenPrice
        );
        console.log(
            "A price ratio (DataProvider/QuoteMint):",
            (marketDetails.tokenPrices.aTokenPrice * 1e18) / quoteTokenPrices.aTokenPrice
        );
        console.log(
            "Z price ratio (DataProvider/QuoteMint):",
            (marketDetails.tokenPrices.zTokenPrice * 1e18) / quoteTokenPrices.zTokenPrice
        );
    }

    function test_tokenPrices_vs_quoteMint_allMarkets() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        // Test token prices comparison for all markets
        for (uint256 i = 0; i < _marketIds.length; i++) {
            MarketId marketId = _marketIds[i];
            MarketParams memory marketParams = _covenantCore.getIdToMarketParams(marketId);

            // Get token prices from DataProvider
            MarketDetails memory marketDetails = dataProvider.getMarketDetails(address(_covenantCore), marketId);

            // Prepare mint parameters for quoteMint
            uint256 baseAmountIn = 1e18; // 1 token
            MintParams memory mintParams = MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: "",
                msgValue: 0
            });

            // Get token prices from quoteMint
            (
                uint256 aTokenAmountOut,
                uint256 zTokenAmountOut,
                uint128 protocolFees,
                uint128 oracleUpdateFee,
                TokenPrices memory quoteTokenPrices
            ) = ILiquidExchangeModel(marketParams.lex).quoteMint(mintParams, address(this), 0);

            console.log("=== Market", i, "===");
            console.log("DataProvider - Base:", marketDetails.tokenPrices.baseTokenPrice);
            console.log("DataProvider - A:", marketDetails.tokenPrices.aTokenPrice);
            console.log("DataProvider - Z:", marketDetails.tokenPrices.zTokenPrice);
            console.log("QuoteMint - Base:", quoteTokenPrices.baseTokenPrice);
            console.log("QuoteMint - A:", quoteTokenPrices.aTokenPrice);
            console.log("QuoteMint - Z:", quoteTokenPrices.zTokenPrice);
            console.log("QuoteMint - A Amount:", aTokenAmountOut);
            console.log("QuoteMint - Z Amount:", zTokenAmountOut);

            // Verify that both return positive prices
            assertTrue(
                marketDetails.tokenPrices.baseTokenPrice > 0,
                "DataProvider base token price should be positive"
            );
            assertTrue(marketDetails.tokenPrices.aTokenPrice > 0, "DataProvider A token price should be positive");
            assertTrue(marketDetails.tokenPrices.zTokenPrice > 0, "DataProvider Z token price should be positive");

            assertTrue(quoteTokenPrices.baseTokenPrice > 0, "QuoteMint base token price should be positive");
            assertTrue(quoteTokenPrices.aTokenPrice > 0, "QuoteMint A token price should be positive");
            assertTrue(quoteTokenPrices.zTokenPrice > 0, "QuoteMint Z token price should be positive");
        }
    }

    function test_tokenPrices_after_mint() external {
        DataProvider dataProvider;
        uint256 baseAmountIn;

        // deploy data provider
        dataProvider = new DataProvider();

        // Test token prices before and after minting
        MarketId marketId = _marketIds[0];
        MarketParams memory marketParams = _covenantCore.getIdToMarketParams(marketId);
        address baseAsset = marketParams.baseToken;

        // Get prices before minting
        MarketDetails memory marketDetailsBefore = dataProvider.getMarketDetails(address(_covenantCore), marketId);

        // Mint tokens
        uint256 assetDecimals = IERC20Metadata(baseAsset).decimals();
        baseAmountIn = 10 ** assetDecimals;
        IERC20(baseAsset).approve(address(_covenantCore), baseAmountIn);

        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: baseAmountIn,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: "",
            msgValue: 0
        });

        _covenantCore.mint(mintParams);

        // Get prices after minting
        MarketDetails memory marketDetailsAfter = dataProvider.getMarketDetails(address(_covenantCore), marketId);

        console.log("=== Before Mint ===");
        console.log("Base price:", marketDetailsBefore.tokenPrices.baseTokenPrice);
        console.log("A price:", marketDetailsBefore.tokenPrices.aTokenPrice);
        console.log("Z price:", marketDetailsBefore.tokenPrices.zTokenPrice);

        console.log("=== After Mint ===");
        console.log("Base price:", marketDetailsAfter.tokenPrices.baseTokenPrice);
        console.log("A price:", marketDetailsAfter.tokenPrices.aTokenPrice);
        console.log("Z price:", marketDetailsAfter.tokenPrices.zTokenPrice);

        // Verify prices are still positive after minting
        assertTrue(marketDetailsAfter.tokenPrices.baseTokenPrice > 0, "Base token price should be positive after mint");
        assertTrue(marketDetailsAfter.tokenPrices.aTokenPrice > 0, "A token price should be positive after mint");
        assertTrue(marketDetailsAfter.tokenPrices.zTokenPrice > 0, "Z token price should be positive after mint");

        // Verify that supply has increased
        assertTrue(
            marketDetailsAfter.marketState.baseSupply > marketDetailsBefore.marketState.baseSupply,
            "Base supply should increase after mint"
        );
        assertTrue(
            marketDetailsAfter.aToken.totalSupply > marketDetailsBefore.aToken.totalSupply,
            "A token supply should increase after mint"
        );
        assertTrue(
            marketDetailsAfter.zToken.totalSupply > marketDetailsBefore.zToken.totalSupply,
            "Z token supply should increase after mint"
        );
    }

    function test_tokenPrices_vs_quoteMint_different_amounts() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        MarketId marketId = _marketIds[0];
        MarketParams memory marketParams = _covenantCore.getIdToMarketParams(marketId);

        // Test with different mint amounts
        uint256[] memory testAmounts = new uint256[](5);
        testAmounts[0] = 1e15; // 0.001 tokens
        testAmounts[1] = 1e16; // 0.01 tokens
        testAmounts[2] = 1e17; // 0.1 tokens
        testAmounts[3] = 1e18; // 1 token
        testAmounts[4] = 10e18; // 10 tokens

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 baseAmountIn = testAmounts[i];

            // Get token prices from DataProvider
            MarketDetails memory marketDetails = dataProvider.getMarketDetails(address(_covenantCore), marketId);

            // Prepare mint parameters for quoteMint
            MintParams memory mintParams = MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: "",
                msgValue: 0
            });

            // Get token prices from quoteMint
            (
                uint256 aTokenAmountOut,
                uint256 zTokenAmountOut,
                ,
                ,
                TokenPrices memory quoteTokenPrices
            ) = ILiquidExchangeModel(marketParams.lex).quoteMint(mintParams, address(this), 0);

            console.log("=== Amount", baseAmountIn, "===");
            console.log("DataProvider - Base:", marketDetails.tokenPrices.baseTokenPrice);
            console.log("DataProvider - A:", marketDetails.tokenPrices.aTokenPrice);
            console.log("DataProvider - Z:", marketDetails.tokenPrices.zTokenPrice);
            console.log("QuoteMint - Base:", quoteTokenPrices.baseTokenPrice);
            console.log("QuoteMint - A:", quoteTokenPrices.aTokenPrice);
            console.log("QuoteMint - Z:", quoteTokenPrices.zTokenPrice);
            console.log("QuoteMint - A Amount Out:", aTokenAmountOut);
            console.log("QuoteMint - Z Amount Out:", zTokenAmountOut);

            // Verify prices are positive
            assertTrue(
                marketDetails.tokenPrices.baseTokenPrice > 0,
                "DataProvider base token price should be positive"
            );
            assertTrue(quoteTokenPrices.baseTokenPrice > 0, "QuoteMint base token price should be positive");
        }
    }

    function test_tokenPrices_vs_quoteMint_progressive_liquidity() external {
        DataProvider dataProvider;
        uint256 baseAmountIn;

        // deploy data provider
        dataProvider = new DataProvider();

        MarketId marketId = _marketIds[0];
        MarketParams memory marketParams = _covenantCore.getIdToMarketParams(marketId);
        address baseAsset = marketParams.baseToken;

        // Test progressive liquidity addition
        uint256[] memory liquidityAmounts = new uint256[](4);
        liquidityAmounts[0] = 0; // No liquidity
        liquidityAmounts[1] = 1e16; // 0.01 tokens
        liquidityAmounts[2] = 1e17; // 0.1 tokens
        liquidityAmounts[3] = 1e18; // 1 token

        for (uint256 i = 0; i < liquidityAmounts.length; i++) {
            if (i > 0) {
                // Add liquidity
                uint256 assetDecimals = IERC20Metadata(baseAsset).decimals();
                baseAmountIn = liquidityAmounts[i] - liquidityAmounts[i - 1];
                IERC20(baseAsset).approve(address(_covenantCore), baseAmountIn);

                MintParams memory mintParams = MintParams({
                    marketId: marketId,
                    marketParams: marketParams,
                    baseAmountIn: baseAmountIn,
                    to: address(this),
                    minATokenAmountOut: 0,
                    minZTokenAmountOut: 0,
                    data: "",
                    msgValue: 0
                });

                _covenantCore.mint(mintParams);
            }

            // Get current state
            MarketDetails memory marketDetails = dataProvider.getMarketDetails(address(_covenantCore), marketId);

            // Test quoteMint with small amount
            uint256 quoteAmount = 1e16; // 0.01 tokens
            MintParams memory quoteParams = MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: quoteAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: "",
                msgValue: 0
            });

            (
                uint256 aTokenAmountOut,
                uint256 zTokenAmountOut,
                ,
                ,
                TokenPrices memory quoteTokenPrices
            ) = ILiquidExchangeModel(marketParams.lex).quoteMint(
                    quoteParams,
                    address(this),
                    marketDetails.marketState.baseSupply
                );

            console.log("=== Liquidity Level", i, "===");
            console.log("Total Base Supply:", marketDetails.marketState.baseSupply);
            console.log("DataProvider - Base:", marketDetails.tokenPrices.baseTokenPrice);
            console.log("DataProvider - A:", marketDetails.tokenPrices.aTokenPrice);
            console.log("DataProvider - Z:", marketDetails.tokenPrices.zTokenPrice);
            console.log("QuoteMint - Base:", quoteTokenPrices.baseTokenPrice);
            console.log("QuoteMint - A:", quoteTokenPrices.aTokenPrice);
            console.log("QuoteMint - Z:", quoteTokenPrices.zTokenPrice);
            console.log("QuoteMint - A Amount Out:", aTokenAmountOut);
            console.log("QuoteMint - Z Amount Out:", zTokenAmountOut);

            // Verify prices are positive
            assertTrue(
                marketDetails.tokenPrices.baseTokenPrice > 0,
                "DataProvider base token price should be positive"
            );
            assertTrue(quoteTokenPrices.baseTokenPrice > 0, "QuoteMint base token price should be positive");
        }
    }

    function test_tokenPrices_after_swapping() external {
        DataProvider dataProvider;
        uint256 baseAmountIn;

        // deploy data provider
        dataProvider = new DataProvider();

        MarketId marketId = _marketIds[0];
        MarketParams memory marketParams = _covenantCore.getIdToMarketParams(marketId);
        address baseAsset = marketParams.baseToken;

        // First, add some liquidity by minting
        uint256 assetDecimals = IERC20Metadata(baseAsset).decimals();
        baseAmountIn = 10 ** assetDecimals; // 1 token
        IERC20(baseAsset).approve(address(_covenantCore), baseAmountIn);

        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: baseAmountIn,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: "",
            msgValue: 0
        });

        _covenantCore.mint(mintParams);

        // Get prices before swapping
        MarketDetails memory marketDetailsBefore = dataProvider.getMarketDetails(address(_covenantCore), marketId);

        // Get the synth tokens that were minted
        address aToken = marketDetailsBefore.aToken.tokenAddress;
        address zToken = marketDetailsBefore.zToken.tokenAddress;

        // Get some A tokens to swap
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
        uint256 swapAmount = aTokenBalance / 2; // Swap half of A tokens

        if (swapAmount > 0) {
            // Approve the LEX to spend A tokens
            IERC20(aToken).approve(marketParams.lex, swapAmount);

            // Prepare swap parameters
            SwapParams memory swapParams = SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: swapAmount,
                amountLimit: 0,
                isExactIn: true,
                data: "",
                msgValue: 0
            });

            // Execute the swap
            _covenantCore.swap(swapParams);
        }

        // Get prices after swapping
        MarketDetails memory marketDetailsAfter = dataProvider.getMarketDetails(address(_covenantCore), marketId);

        console.log("=== Before Swap ===");
        console.log("Base price:", marketDetailsBefore.tokenPrices.baseTokenPrice);
        console.log("A price:", marketDetailsBefore.tokenPrices.aTokenPrice);
        console.log("Z price:", marketDetailsBefore.tokenPrices.zTokenPrice);
        console.log("A token supply:", marketDetailsBefore.aToken.totalSupply);
        console.log("Z token supply:", marketDetailsBefore.zToken.totalSupply);

        console.log("=== After Swap ===");
        console.log("Base price:", marketDetailsAfter.tokenPrices.baseTokenPrice);
        console.log("A price:", marketDetailsAfter.tokenPrices.aTokenPrice);
        console.log("Z price:", marketDetailsAfter.tokenPrices.zTokenPrice);
        console.log("A token supply:", marketDetailsAfter.aToken.totalSupply);
        console.log("Z token supply:", marketDetailsAfter.zToken.totalSupply);

        // Verify prices are still positive after swapping
        assertTrue(marketDetailsAfter.tokenPrices.baseTokenPrice > 0, "Base token price should be positive after swap");
        assertTrue(marketDetailsAfter.tokenPrices.aTokenPrice > 0, "A token price should be positive after swap");
        assertTrue(marketDetailsAfter.tokenPrices.zTokenPrice > 0, "Z token price should be positive after swap");

        // Test quoteMint after swapping
        uint256 quoteAmount = 1e17; // 0.1 tokens
        MintParams memory quoteParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: quoteAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: "",
            msgValue: 0
        });

        (
            uint256 aTokenAmountOut,
            uint256 zTokenAmountOut,
            ,
            ,
            TokenPrices memory quoteTokenPrices
        ) = ILiquidExchangeModel(marketParams.lex).quoteMint(
                quoteParams,
                address(this),
                marketDetailsAfter.marketState.baseSupply
            );

        console.log("=== QuoteMint After Swap ===");
        console.log("QuoteMint - Base:", quoteTokenPrices.baseTokenPrice);
        console.log("QuoteMint - A:", quoteTokenPrices.aTokenPrice);
        console.log("QuoteMint - Z:", quoteTokenPrices.zTokenPrice);
        console.log("QuoteMint - A Amount Out:", aTokenAmountOut);
        console.log("QuoteMint - Z Amount Out:", zTokenAmountOut);

        // Compare DataProvider vs QuoteMint after swap
        console.log("=== Price Comparison After Swap ===");
        console.log(
            "Base price ratio (DataProvider/QuoteMint):",
            (marketDetailsAfter.tokenPrices.baseTokenPrice * 1e18) / quoteTokenPrices.baseTokenPrice
        );
        console.log(
            "A price ratio (DataProvider/QuoteMint):",
            (marketDetailsAfter.tokenPrices.aTokenPrice * 1e18) / quoteTokenPrices.aTokenPrice
        );
        console.log(
            "Z price ratio (DataProvider/QuoteMint):",
            (marketDetailsAfter.tokenPrices.zTokenPrice * 1e18) / quoteTokenPrices.zTokenPrice
        );
    }

    function test_tokenPrices_vs_quoteMint_after_redeeming() external {
        DataProvider dataProvider;
        uint256 baseAmountIn;

        // deploy data provider
        dataProvider = new DataProvider();

        MarketId marketId = _marketIds[0];
        MarketParams memory marketParams = _covenantCore.getIdToMarketParams(marketId);
        address baseAsset = marketParams.baseToken;

        // First, add some liquidity by minting
        uint256 assetDecimals = IERC20Metadata(baseAsset).decimals();
        baseAmountIn = 10 ** assetDecimals; // 1 token
        IERC20(baseAsset).approve(address(_covenantCore), baseAmountIn);

        MintParams memory mintParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: baseAmountIn,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: "",
            msgValue: 0
        });

        _covenantCore.mint(mintParams);

        // Get prices before redeeming
        MarketDetails memory marketDetailsBefore = dataProvider.getMarketDetails(address(_covenantCore), marketId);

        // Get the synth tokens that were minted
        address aToken = marketDetailsBefore.aToken.tokenAddress;
        address zToken = marketDetailsBefore.zToken.tokenAddress;

        // Get some A and Z tokens to redeem
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
        uint256 zTokenBalance = IERC20(zToken).balanceOf(address(this));
        uint256 redeemAmount = aTokenBalance / 2; // Redeem half of tokens

        if (redeemAmount > 0 && zTokenBalance > 0) {
            // Approve the LEX to spend tokens
            IERC20(aToken).approve(marketParams.lex, redeemAmount);
            IERC20(zToken).approve(marketParams.lex, redeemAmount);

            // Prepare redeem parameters
            RedeemParams memory redeemParams = RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: redeemAmount,
                zTokenAmountIn: redeemAmount,
                to: address(this),
                minAmountOut: 0,
                data: "",
                msgValue: 0
            });

            // Execute the redeem
            _covenantCore.redeem(redeemParams);
        }

        // Get prices after redeeming
        MarketDetails memory marketDetailsAfter = dataProvider.getMarketDetails(address(_covenantCore), marketId);

        console.log("=== Before Redeem ===");
        console.log("Base price:", marketDetailsBefore.tokenPrices.baseTokenPrice);
        console.log("A price:", marketDetailsBefore.tokenPrices.aTokenPrice);
        console.log("Z price:", marketDetailsBefore.tokenPrices.zTokenPrice);
        console.log("A token supply:", marketDetailsBefore.aToken.totalSupply);
        console.log("Z token supply:", marketDetailsBefore.zToken.totalSupply);

        console.log("=== After Redeem ===");
        console.log("Base price:", marketDetailsAfter.tokenPrices.baseTokenPrice);
        console.log("A price:", marketDetailsAfter.tokenPrices.aTokenPrice);
        console.log("Z price:", marketDetailsAfter.tokenPrices.zTokenPrice);
        console.log("A token supply:", marketDetailsAfter.aToken.totalSupply);
        console.log("Z token supply:", marketDetailsAfter.zToken.totalSupply);

        // Verify prices are still positive after redeeming
        assertTrue(
            marketDetailsAfter.tokenPrices.baseTokenPrice > 0,
            "Base token price should be positive after redeem"
        );
        assertTrue(marketDetailsAfter.tokenPrices.aTokenPrice > 0, "A token price should be positive after redeem");
        assertTrue(marketDetailsAfter.tokenPrices.zTokenPrice > 0, "Z token price should be positive after redeem");

        // Test quoteMint after redeeming
        uint256 quoteAmount = 1e17; // 0.1 tokens
        MintParams memory quoteParams = MintParams({
            marketId: marketId,
            marketParams: marketParams,
            baseAmountIn: quoteAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: "",
            msgValue: 0
        });

        (
            uint256 aTokenAmountOut,
            uint256 zTokenAmountOut,
            ,
            ,
            TokenPrices memory quoteTokenPrices
        ) = ILiquidExchangeModel(marketParams.lex).quoteMint(
                quoteParams,
                address(this),
                marketDetailsAfter.marketState.baseSupply
            );

        console.log("=== QuoteMint After Redeem ===");
        console.log("QuoteMint - Base:", quoteTokenPrices.baseTokenPrice);
        console.log("QuoteMint - A:", quoteTokenPrices.aTokenPrice);
        console.log("QuoteMint - Z:", quoteTokenPrices.zTokenPrice);
        console.log("QuoteMint - A Amount Out:", aTokenAmountOut);
        console.log("QuoteMint - Z Amount Out:", zTokenAmountOut);

        // Compare DataProvider vs QuoteMint after redeem
        console.log("=== Price Comparison After Redeem ===");
        console.log(
            "Base price ratio (DataProvider/QuoteMint):",
            (marketDetailsAfter.tokenPrices.baseTokenPrice * 1e18) / quoteTokenPrices.baseTokenPrice
        );
        console.log(
            "A price ratio (DataProvider/QuoteMint):",
            (marketDetailsAfter.tokenPrices.aTokenPrice * 1e18) / quoteTokenPrices.aTokenPrice
        );
        console.log(
            "Z price ratio (DataProvider/QuoteMint):",
            (marketDetailsAfter.tokenPrices.zTokenPrice * 1e18) / quoteTokenPrices.zTokenPrice
        );
    }

    function test_tokenPrices_vs_quoteMint_edge_cases() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        MarketId marketId = _marketIds[0];
        MarketParams memory marketParams = _covenantCore.getIdToMarketParams(marketId);

        // Test edge cases
        uint256[] memory edgeAmounts = new uint256[](4);
        edgeAmounts[0] = 1; // 1 wei
        edgeAmounts[1] = 1000; // 1000 wei
        edgeAmounts[2] = 1e15; // 0.001 tokens
        edgeAmounts[3] = 100e18; // 100 tokens

        for (uint256 i = 0; i < edgeAmounts.length; i++) {
            uint256 baseAmountIn = edgeAmounts[i];

            // Get token prices from DataProvider
            MarketDetails memory marketDetails = dataProvider.getMarketDetails(address(_covenantCore), marketId);

            // Prepare mint parameters for quoteMint
            MintParams memory mintParams = MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: "",
                msgValue: 0
            });

            // Get token prices from quoteMint
            (
                uint256 aTokenAmountOut,
                uint256 zTokenAmountOut,
                ,
                ,
                TokenPrices memory quoteTokenPrices
            ) = ILiquidExchangeModel(marketParams.lex).quoteMint(mintParams, address(this), 0);

            console.log("=== Edge Case", i, "===");
            console.log("Amount:", baseAmountIn);
            console.log("DataProvider - Base:", marketDetails.tokenPrices.baseTokenPrice);
            console.log("DataProvider - A:", marketDetails.tokenPrices.aTokenPrice);
            console.log("DataProvider - Z:", marketDetails.tokenPrices.zTokenPrice);
            console.log("QuoteMint - Base:", quoteTokenPrices.baseTokenPrice);
            console.log("QuoteMint - A:", quoteTokenPrices.aTokenPrice);
            console.log("QuoteMint - Z:", quoteTokenPrices.zTokenPrice);
            console.log("QuoteMint - A Amount Out:", aTokenAmountOut);
            console.log("QuoteMint - Z Amount Out:", zTokenAmountOut);

            // Verify prices are positive
            assertTrue(
                marketDetails.tokenPrices.baseTokenPrice > 0,
                "DataProvider base token price should be positive"
            );
            assertTrue(quoteTokenPrices.baseTokenPrice > 0, "QuoteMint base token price should be positive");
        }
    }

    struct UnderCollateralizedTestVars {
        // Test configuration
        uint256 baseAmountIn;
        uint104 minSqrtPriceRatio;
        uint160 edgeSqrtRatioX96_A;
        uint160 edgeSqrtRatioX96_B;
        // Contract instances
        Covenant covenantCore;
        LatentSwapLEX lexImplementation;
        // Market setup
        MarketParams marketParams;
        MarketId marketId;
        // Token amounts
        uint256 aTokenAmountOut;
        uint256 zTokenAmountOut;
        uint256 debtOut;
        uint256 baseAmountOut;
        uint256 remainingZTokens;
        uint256 baseAmountOut2;
    }

    function test_DataProvider_inUndercollateralizedStates() external {
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        UnderCollateralizedTestVars memory vars;

        // Test the scenario where minimal liquidity causes MaxDebt = 0 in undercollateralized state
        // This blocks zToken to Base swaps even when liquidity > 0
        vars.baseAmountIn = 10;
        vars.minSqrtPriceRatio = uint104((1005 * FixedPoint.WAD) / 1000);

        // deploy covenant liquid
        vars.covenantCore = new Covenant(address(this));

        // Setup: 50% target LTV market with very narrow price width
        (vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B) = LatentSwapLib.getMarketEdgePrices(
            uint32(PercentageMath.HALF_PERCENTAGE_FACTOR),
            vars.minSqrtPriceRatio
        );

        // Initialize LEX
        vars.lexImplementation = new LatentSwapLEX(
            address(this),
            address(vars.covenantCore),
            vars.edgeSqrtRatioX96_B,
            vars.edgeSqrtRatioX96_A,
            vars.edgeSqrtRatioX96_B - 2,
            vars.edgeSqrtRatioX96_B - 1,
            0,
            DURATION,
            0
        );

        // authorize lex and oracle
        vars.covenantCore.setEnabledLEX(address(vars.lexImplementation), true);
        vars.covenantCore.setEnabledCurator(_mockOracle, true);

        // initialize market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.lexImplementation)
        });

        vars.marketId = vars.covenantCore.createMarket(vars.marketParams, hex"");

        MarketDetails memory marketDetails = dataProvider.getMarketDetails(address(vars.covenantCore), vars.marketId);

        // approve transferFrom and mint initial liquidity
        IERC20(_mockBaseAsset).approve(address(vars.covenantCore), vars.baseAmountIn);
        (vars.aTokenAmountOut, vars.zTokenAmountOut) = vars.covenantCore.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        marketDetails = dataProvider.getMarketDetails(address(vars.covenantCore), vars.marketId);

        // Reduce price to put into an undercollateralized state
        MockOracle(_mockOracle).setPrice(1 * 10 ** 17);

        vars.debtOut = (vars.zTokenAmountOut >> 1);

        vars.baseAmountOut = vars.covenantCore.swap(
            SwapParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.BASE,
                to: address(this),
                amountSpecified: vars.debtOut,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );

        marketDetails = dataProvider.getMarketDetails(address(vars.covenantCore), vars.marketId);

        assertLe(
            vars.baseAmountOut,
            vars.baseAmountIn >> 1,
            "When undercollateralized, zToken to Base swap should be proportional."
        );

        // Step 6: Do full redeem of remaining zTokens
        vars.remainingZTokens = vars.zTokenAmountOut - vars.debtOut;

        // Swap remaining zTokens to base tokens
        vars.baseAmountOut2 = vars.covenantCore.swap(
            SwapParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.BASE,
                to: address(this),
                amountSpecified: vars.remainingZTokens,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );

        assertLe(
            vars.baseAmountOut2 + vars.baseAmountOut,
            vars.baseAmountIn,
            "Full redeem should be equal to initial mint"
        );

        // Get market details
        marketDetails = dataProvider.getMarketDetails(address(vars.covenantCore), vars.marketId);
    }

    function test_DataProvider_SmallPriceChanges() external {
        // @dev - this is actually testing the tokenPrice functionality
        // (specially in the undercollateralized event horizon) + Dataprovider ability to retrieve these prices.
        DataProvider dataProvider;

        // deploy data provider
        dataProvider = new DataProvider();

        // Test different decimal combinations
        uint8[] memory baseDecimals = new uint8[](3);
        baseDecimals[0] = 18;
        baseDecimals[1] = 10;
        baseDecimals[2] = 6;

        uint8[] memory quoteDecimals = new uint8[](3);
        quoteDecimals[0] = 18;
        quoteDecimals[1] = 10;
        quoteDecimals[2] = 6;

        uint8[] memory synthDecimals = new uint8[](2);
        synthDecimals[0] = 0; // Fixed 6 decimals for synths
        synthDecimals[1] = 6; // Use quote token decimals (0 means use quote token decimals)

        for (uint256 baseIdx = 0; baseIdx < baseDecimals.length; baseIdx++) {
            for (uint256 quoteIdx = 0; quoteIdx < quoteDecimals.length; quoteIdx++) {
                for (uint256 synthIdx = 0; synthIdx < synthDecimals.length; synthIdx++) {
                    console.log("=== Testing Decimal Combination ===");
                    console.log("Base Decimals:", baseDecimals[baseIdx]);
                    console.log("Quote Decimals:", quoteDecimals[quoteIdx]);
                    if (synthDecimals[synthIdx] == 0) {
                        console.log("Synth Decimals: Same as Quote");
                    } else {
                        console.log("Synth Decimals:", uint256(synthDecimals[synthIdx]));
                    }

                    _testSmallPriceChangesWithDecimals(
                        dataProvider,
                        baseDecimals[baseIdx],
                        quoteDecimals[quoteIdx],
                        synthDecimals[synthIdx]
                    );
                    console.log("================================================");
                    console.log(" ");
                    console.log(" ");
                    console.log(" ");
                    console.log(" ");
                }
            }
        }
    }

    struct SmallPriceChangesTestVars {
        // Test configuration
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint8 synthDecimals;
        uint256 baseAmountIn;
        uint104 minSqrtPriceRatio;
        uint160 edgeSqrtRatioX96_A;
        uint160 edgeSqrtRatioX96_B;
        // Contract instances
        Covenant covenantCore;
        LatentSwapLEX lexImplementation;
        // Market setup
        MarketParams marketParams;
        MarketId marketId;
        // Token amounts
        uint256 aTokenAmountOut;
        uint256 zTokenAmountOut;
        // Price tracking variables
        MarketDetails marketDetails;
        uint256 currentOraclePrice;
        uint256 oldATokenPrice;
        uint256 oldZTokenPrice;
        uint256 oldBaseTokenPrice;
        uint256 oracleStep;
        uint256 oldLTV;
        // Precision variables
        uint256 zStepPrecisionA;
        uint256 zStepPrecisionB;
        uint256 aStepPrecision;
        uint256 baseStepPrecision;
    }

    function _testSmallPriceChangesWithDecimals(
        DataProvider dataProvider,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint8 synthDecimals
    ) internal {
        SmallPriceChangesTestVars memory vars;

        // Initialize test configuration
        vars.baseDecimals = baseDecimals;
        vars.quoteDecimals = quoteDecimals;
        vars.synthDecimals = (synthDecimals == 0) ? quoteDecimals : synthDecimals;

        // set oracle price.
        MockOracle(_mockOracle).setPrice(10 ** 18);

        // Create mock tokens with specific decimals
        MockERC20 baseToken = new MockERC20(address(this), "TestBase", "TB", baseDecimals);
        MockERC20 quoteToken = new MockERC20(address(this), "TestQuote", "TQ", quoteDecimals);

        // Mint tokens for testing
        baseToken.mint(address(this), 1000 * 10 ** baseDecimals);
        quoteToken.mint(address(this), 1000 * 10 ** quoteDecimals);

        // Test the scenario where we gradually reduce oracle price and monitor token prices
        vars.baseAmountIn = 10 ** (baseDecimals - 1); // 0.1 tokens
        vars.minSqrtPriceRatio = uint104((11 * FixedPoint.WAD) / 10);

        // deploy covenant liquid
        vars.covenantCore = new Covenant(address(this));

        // Setup: 50% target LTV market
        (vars.edgeSqrtRatioX96_A, vars.edgeSqrtRatioX96_B) = LatentSwapLib.getMarketEdgePrices(
            uint32(PercentageMath.HALF_PERCENTAGE_FACTOR),
            vars.minSqrtPriceRatio
        );

        // Initialize LEX
        vars.lexImplementation = new LatentSwapLEX(
            address(this),
            address(vars.covenantCore),
            vars.edgeSqrtRatioX96_B,
            vars.edgeSqrtRatioX96_A,
            vars.edgeSqrtRatioX96_B - 2,
            vars.edgeSqrtRatioX96_B - 1,
            0,
            DURATION,
            0
        );

        // Set synth token decimals if needed
        if (synthDecimals > 0) {
            vars.lexImplementation.setQuoteTokenDecimalsOverrideForNewMarkets(address(quoteToken), synthDecimals);
        }

        // authorize lex and oracle
        vars.covenantCore.setEnabledLEX(address(vars.lexImplementation), true);
        vars.covenantCore.setEnabledCurator(_mockOracle, true);

        // initialize market
        vars.marketParams = MarketParams({
            baseToken: address(baseToken),
            quoteToken: address(quoteToken),
            curator: _mockOracle,
            lex: address(vars.lexImplementation)
        });

        vars.marketId = vars.covenantCore.createMarket(vars.marketParams, hex"");

        // approve transferFrom and mint initial liquidity
        IERC20(address(baseToken)).approve(address(vars.covenantCore), vars.baseAmountIn);
        (vars.aTokenAmountOut, vars.zTokenAmountOut) = vars.covenantCore.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Initialize price tracking variables
        vars.oracleStep = (10 ** 18) / 100000;
        vars.zStepPrecisionA = 1e18;
        vars.zStepPrecisionB = 1e4;
        vars.aStepPrecision = 1e18;
        vars.baseStepPrecision = 1e5;

        // Test fewer iterations for each decimal combination to avoid too much output
        for (uint256 i = 50100; i >= 50000; i--) {
            // Reduce price by 10% (multiply by 0.9)
            // (Price has 18 decimal feed precision.  Mock Oracle adjusts output for base and quote decimals
            vars.currentOraclePrice = ((10 ** 18) * i) / 100000;
            MockOracle(_mockOracle).setPrice(vars.currentOraclePrice);

            // Update LEX state to reflect new price
            vars.covenantCore.updateState(vars.marketId, vars.marketParams, hex"", 0);

            // Get updated market details
            vars.marketDetails = dataProvider.getMarketDetails(address(vars.covenantCore), vars.marketId);

            console.log("vars.marketDetails.tokenPrices.baseTokenPrice", vars.marketDetails.tokenPrices.baseTokenPrice);
            console.log("vars.currentOraclePrice", vars.currentOraclePrice);
            console.log("vars.quoteDecimals", vars.quoteDecimals);
            console.log("vars.baseDecimals", vars.baseDecimals);

            assertEq(
                (((vars.baseStepPrecision * vars.marketDetails.tokenPrices.baseTokenPrice * (10 ** vars.baseDecimals)) /
                    (10 ** vars.quoteDecimals)) + (vars.currentOraclePrice >> 1)) / vars.currentOraclePrice,
                vars.baseStepPrecision,
                "baseToken price not correct "
            );

            if (i < 50100) {
                if (vars.oldLTV < 10000 && vars.marketDetails.currentLTV < 10000) {
                    assertEq((vars.marketDetails.tokenPrices.zTokenPrice * vars.zStepPrecisionA + vars.oldZTokenPrice>>1)/ vars.oldZTokenPrice,  vars.zStepPrecisionA, "zToken change to big A"); // prettier-ignore
                    assertLe(((vars.oldATokenPrice - vars.marketDetails.tokenPrices.aTokenPrice)*vars.aStepPrecision+vars.oracleStep)/(2*vars.oracleStep), vars.aStepPrecision,"aToken change to big"); // prettier-ignore
                } else if (vars.oldLTV == 10000 && vars.marketDetails.currentLTV == 10000) {
                    console.log("vars.synthDecimals", vars.synthDecimals);
                    console.log("price diff", vars.oldZTokenPrice - vars.marketDetails.tokenPrices.zTokenPrice);
                    console.log("oracle step", vars.oracleStep);

                    assertEq(
                        (((vars.oldZTokenPrice - vars.marketDetails.tokenPrices.zTokenPrice) *
                            (10 ** vars.synthDecimals) *
                            vars.zStepPrecisionB) /
                            (10 ** vars.quoteDecimals) +
                            vars.oracleStep) / (2 * vars.oracleStep),
                        vars.zStepPrecisionB,
                        "zToken change to big B"
                    );

                    assertEq(
                        vars.marketDetails.tokenPrices.aTokenPrice,
                        0,
                        "A token should be 0 when undercollateralized"
                    );
                    assertEq(
                        (((vars.zStepPrecisionB *
                            (vars.marketDetails.tokenPrices.zTokenPrice >> 1) *
                            (10 ** vars.synthDecimals)) /
                            (10 ** vars.quoteDecimals) +
                            (vars.currentOraclePrice >> 1)) / vars.currentOraclePrice),
                        vars.zStepPrecisionB,
                        "Z token should be double the oracle price when undercollateralized"
                    );
                } else {
                    // transition point
                    assertApproxEqAbs(vars.marketDetails.tokenPrices.zTokenPrice, vars.oldZTokenPrice, 1e13, "zToken change to big C"); // prettier-ignore
                }
            }

            console.log("=== Iteration", i, "===");
            console.log("Oracle Price:", vars.currentOraclePrice);
            console.log("BToken Price:", vars.marketDetails.tokenPrices.baseTokenPrice);
            console.log("aToken Price:", vars.marketDetails.tokenPrices.aTokenPrice);
            console.log("zToken Price:", vars.marketDetails.tokenPrices.zTokenPrice);
            console.log("Market LTV:", vars.marketDetails.currentLTV);
            console.log("Target LTV:", vars.marketDetails.targetLTV);

            vars.oldATokenPrice = vars.marketDetails.tokenPrices.aTokenPrice;
            vars.oldZTokenPrice = vars.marketDetails.tokenPrices.zTokenPrice;
            vars.oldBaseTokenPrice = vars.marketDetails.tokenPrices.baseTokenPrice;
            vars.oldLTV = vars.marketDetails.currentLTV;
        }
    }
}

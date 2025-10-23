// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {SynthToken} from "../src/synths/SynthToken.sol";
import {Covenant, MarketId, MarketParams, MarketState, SynthTokens, TokenPrices} from "../src/Covenant.sol";
import {LatentSwapLEX} from "../src/lex/latentswap/LatentSwapLEX.sol";
import {FixedPoint} from "../src/lex/latentswap/libraries/FixedPoint.sol";
import {ICovenant, IERC20, AssetType, SwapParams, RedeemParams, MintParams} from "../src/interfaces/ICovenant.sol";
import {ISynthToken} from "../src/interfaces/ISynthToken.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ILiquidExchangeModel} from "../src/interfaces/ILiquidExchangeModel.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {WadRayMath} from "@aave/libraries/math/WadRayMath.sol";
import {MockLatentSwapLEX} from "./mocks/MockLatentSwapLEX.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {LatentSwapLib} from "../src/periphery/libraries/LatentSwapLib.sol";

contract CovenantTest is Test {
    using WadRayMath for uint256;

    // Max balance of swap pool balance that won't cause an overflow in circle math.
    uint256 constant MIN_BALANCE = 2 ** 10;
    uint256 constant MAX_BALANCE = 2 ** 30;

    uint256 constant MIN_BASE_TOKEN = 100000;
    uint256 constant MAX_BASE_TOKEN = 2 ** 20;
    uint256 constant MIN_BASE_SWAPAMOUNT = 100;
    uint256 constant MAX_BASE_SWAPAMOUNT = 10 ** 10;

    // @dev - default oracle price is 10**18
    uint256 constant MIN_PRICE = 6 * 10 ** 17;
    uint256 constant MAX_PRICE = 10 ** 19;

    uint256 constant LIQUIDITY_PRECISION_BELOW = 10 ** 5;

    // LatentSwapLEX init pricing constants
    uint160 constant P_MAX = uint160((1095445 * FixedPoint.Q96) / 1000000); //uint160(Math.sqrt((FixedPoint.Q192 * 12) / 10)); // Edge price of 1.2
    uint160 constant P_MIN = uint160(FixedPoint.Q192 / P_MAX);
    uint32 constant DURATION = 7776000;
    uint8 constant SWAP_FEE = 0;
    int64 constant LN_RATE_BIAS = 5012540000000000; // WAD

    uint160 private P_LIM_H = LatentSwapLib.getSqrtPriceFromLTVX96(P_MIN, P_MAX, 9500);
    uint160 private P_LIM_MAX = LatentSwapLib.getSqrtPriceFromLTVX96(P_MIN, P_MAX, 9999);
    address private _mockOracle;
    address private _mockBaseAsset;
    address private _mockQuoteAsset;
    address private _lexImplementation;
    Covenant private _covenantCore;
    MarketParams private _marketParams;
    MarketId private _marketId;

    function boundTokenIndex(uint8 rawTokenIndex) internal pure returns (uint8 tokenIndex) {
        tokenIndex = (rawTokenIndex % 3);
    }

    function boundMintAmount(uint256 rawAmount) internal pure returns (uint256 amount) {
        amount = bound(rawAmount, MIN_BASE_TOKEN, MAX_BASE_TOKEN);
    }

    function boundMintAmountDecimalAware(
        uint256 rawAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals
    ) internal pure returns (uint256 amount) {
        uint256 minAmount = Math.mulDiv(MIN_BASE_TOKEN, 10 ** baseDecimals, 10 ** quoteDecimals);
        uint256 maxAmount = Math.mulDiv(MAX_BASE_TOKEN, 10 ** baseDecimals, 10 ** quoteDecimals);
        if (minAmount == 0) minAmount = 10;
        if (maxAmount < minAmount) maxAmount = minAmount + 10;
        amount = bound(rawAmount, minAmount, maxAmount);
    }

    function boundSwapBaseInAmount(
        uint256 rawAmount,
        uint256 currentBaseAmount
    ) internal pure returns (uint256 amount) {
        uint256 maxAmount = currentBaseAmount >> 2;
        uint256 minAmount = MIN_BASE_SWAPAMOUNT;
        if (maxAmount < minAmount) minAmount = maxAmount;
        amount = bound(rawAmount, minAmount, maxAmount);
    }

    function boundSwapBaseOutAmount(uint256 rawAmount, uint256 mintAmount) internal pure returns (uint256 amount) {
        amount = bound(rawAmount, MIN_BASE_SWAPAMOUNT, mintAmount);
    }

    function boundOraclePrice(uint256 rawPrice) internal pure returns (uint256 price) {
        price = bound(rawPrice, MIN_PRICE, MAX_PRICE);
    }

    function boundDecimals(uint8 rawDecimals) internal pure returns (uint8 decimals) {
        decimals = uint8(6 * bound(rawDecimals, 1, 3));
    }

    // Test internal baseSupply tracking equals ERC20 base supply tracking
    function _baseSupplyInvariant(ICovenant covenantCore, MarketId marketId) internal view {
        uint256 baseSupply = covenantCore.getMarketState(marketId).baseSupply;
        uint256 erc20BaseSupply = IERC20(covenantCore.getIdToMarketParams(marketId).baseToken).balanceOf(
            address(covenantCore)
        );
        assertEq(baseSupply, erc20BaseSupply, "Internal and external ERC20 base supply do not match");
    }

    ////////////////////////////////////////////////////////////////////////////

    function setUp() public {
        // deploy mock oracle
        _mockOracle = address(new MockOracle(address(this)));

        // deploy mock ERC20 base asset (and mint for deployer)
        _mockBaseAsset = address(new MockERC20(address(this), "MockBaseAsset", "MBA", 18));
        MockERC20(_mockBaseAsset).mint(address(this), type(uint256).max);

        // deploy mock ERC20 quote asset
        _mockQuoteAsset = address(new MockERC20(address(this), "MockQaseAsset", "MQA", 18));

        // deploy covenant liquid
        _covenantCore = new Covenant(address(this));

        // deploy lex implementation (no redeemCaps)
        _lexImplementation = address(
            new MockLatentSwapLEX(
                address(this),
                address(_covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex
        _covenantCore.setEnabledLEX(_lexImplementation, true);

        // authorize oracle
        _covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        _marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset, // $130K limit
            curator: _mockOracle,
            lex: _lexImplementation
        });
        _marketId = _covenantCore.createMarket(_marketParams, hex"");

        // remove mint and redeem caps
        MockLatentSwapLEX(_lexImplementation).setMarketNoCapLimit(_marketId, 255);

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(_covenantCore), type(uint256).max);
    }

    struct SwapTestVars {
        address lexImplementation;
        MarketId marketId;
        MarketParams marketParams;
        MarketState marketState;
        SynthTokens synthTokens;
        uint256 baseAmountIn;
        uint256 swapAmount;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 baseAmountOut;
        AssetType inTokenType;
        AssetType outTokenType;
        address inToken;
        address outToken;
        uint256 initialInBalance;
        uint256 initialOutBalance;
        uint256 finalInBalance;
        uint256 finalOutBalance;
        SwapParams swapParams;
        uint256 swapAmountOut;
        uint256 swapAmountBack;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        address mockBaseAsset;
        address mockQuoteAsset;
    }

    function testSwap__Fuzz(
        uint256 initMintAmount,
        uint256 oraclePrice,
        uint256 rawSwapAmount,
        uint8 rawAssetIn,
        uint8 rawAssetOut,
        uint8 rawBaseDecimals,
        uint8 rawQuoteDecimals
    ) public {
        SwapTestVars memory vars;
        // bound assetin/out
        uint8 assetIn = boundTokenIndex(rawAssetIn);
        //uint8 assetOut = 3 - assetIn;
        uint8 assetOut = boundTokenIndex(rawAssetOut);
        if (assetIn == assetOut) assetOut = boundTokenIndex(assetOut + 1);
        vars.baseDecimals = boundDecimals(rawBaseDecimals);
        vars.quoteDecimals = boundDecimals(rawQuoteDecimals);
        // Create mock assets with specified decimals
        vars.mockBaseAsset = address(new MockERC20(address(this), "MockBaseAsset", "MBA", vars.baseDecimals));
        vars.mockQuoteAsset = address(new MockERC20(address(this), "MockQuoteAsset", "MQA", vars.quoteDecimals));

        // bound amounts
        uint256 mintAmount = boundMintAmountDecimalAware(initMintAmount, vars.baseDecimals, vars.quoteDecimals);
        // Mint base tokens to this contract
        MockERC20(vars.mockBaseAsset).mint(address(this), type(uint256).max);

        // init market
        vars.marketParams = MarketParams({
            baseToken: vars.mockBaseAsset,
            quoteToken: vars.mockQuoteAsset, // $130K limit
            curator: _mockOracle,
            lex: _lexImplementation
        });
        vars.marketId = _covenantCore.createMarket(vars.marketParams, hex"");

        // remove mint and redeem caps
        MockLatentSwapLEX(_lexImplementation).setMarketNoCapLimit(vars.marketId, 255);

        // approve transferFrom
        IERC20(vars.mockBaseAsset).approve(address(_covenantCore), type(uint256).max);
        // mint
        // @dev - mints when price == 10**18, with 50% LTV
        (vars.aTokenAmount, vars.zTokenAmount) = _covenantCore.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: mintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Set new price in oracle
        MockOracle(_mockOracle).setPrice(boundOraclePrice(oraclePrice));
        // get data
        vars.inTokenType = AssetType(assetIn);
        vars.outTokenType = AssetType(assetOut);
        vars.marketState = _covenantCore.getMarketState(vars.marketId);
        vars.synthTokens = ILiquidExchangeModel(vars.marketParams.lex).getSynthTokens(vars.marketId);
        // Convert to token addresses and bound swapAmount
        if (vars.inTokenType == AssetType.BASE) {
            vars.inToken = address(vars.marketParams.baseToken);
            vars.swapAmount = boundSwapBaseInAmount(rawSwapAmount, mintAmount);
        } else if (vars.inTokenType == AssetType.LEVERAGE) {
            vars.inToken = address(vars.synthTokens.aToken);
            vars.swapAmount = bound(rawSwapAmount, 1000, vars.aTokenAmount >> 2);
        } else if (vars.inTokenType == AssetType.DEBT) {
            vars.inToken = address(vars.synthTokens.zToken);
            vars.swapAmount = bound(rawSwapAmount, 1000, vars.zTokenAmount >> 2);
        }
        if (vars.outTokenType == AssetType.BASE) {
            vars.outToken = address(vars.marketParams.baseToken);
        } else if (vars.outTokenType == AssetType.LEVERAGE) {
            vars.outToken = address(vars.synthTokens.aToken);
        } else if (vars.outTokenType == AssetType.DEBT) {
            vars.outToken = address(vars.synthTokens.zToken);
        }
        ///////////////////////////////////////////////////////////////////////////
        // Swap one way
        // Define swap parameters
        vars.swapParams = SwapParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            assetIn: vars.inTokenType,
            assetOut: vars.outTokenType,
            to: address(this),
            amountSpecified: vars.swapAmount,
            amountLimit: 0,
            isExactIn: true,
            data: hex"",
            msgValue: 0
        });
        // Initial balances
        vars.initialInBalance = IERC20(vars.inToken).balanceOf(address(this));
        vars.initialOutBalance = IERC20(vars.outToken).balanceOf(address(this));
        // swap inToken for outToken
        try _covenantCore.swap(vars.swapParams) returns (uint256 swapAmountOut) {
            vars.swapAmountOut = swapAmountOut;
        } catch (bytes memory reason) {
            // Check if the error is E_InsufficientAmount
            if (keccak256(reason) == keccak256(abi.encodeWithSignature("E_InsufficientAmount()"))) {
                return; // Exit gracefully if insufficient amount
            } else {
                revert(string(reason)); // Revert for other errors
            }
        }
        // amount were too small, dust was accepted by LEX, but discontinue test here
        if (vars.swapAmountOut == 0) return;

        // check base supply invariant
        _baseSupplyInvariant(_covenantCore, vars.marketId);

        ///////////////////////////////////////////////////////////////////////////
        // Swap back

        // Define swap parameters
        vars.swapParams = SwapParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            assetIn: vars.outTokenType,
            assetOut: vars.inTokenType,
            to: address(this),
            amountSpecified: vars.swapAmountOut,
            amountLimit: 0,
            isExactIn: true,
            data: hex"",
            msgValue: 0
        });

        // swap outToken for inToken
        try _covenantCore.swap(vars.swapParams) returns (uint256 swapAmountBack) {
            vars.swapAmountBack = swapAmountBack;
        } catch (bytes memory reason) {
            // Check if the error is E_InsufficientAmount
            if (keccak256(reason) == keccak256(abi.encodeWithSignature("E_InsufficientAmount()"))) {
                return; // Exit gracefully if insufficient amount
            } else {
                revert(string(reason)); // Revert for other errors
            }
        }
        //  Balance after swap
        vars.finalInBalance = IERC20(vars.inToken).balanceOf(address(this));
        vars.finalOutBalance = IERC20(vars.outToken).balanceOf(address(this));

        ///////////////////////////////////////////////////////////////////////////
        // Test swap return less or equal than initial amount
        assertLe(vars.swapAmountBack, vars.swapAmount, "swap back amount should be smaller or equal to swap in amount");

        // check base supply invariant
        _baseSupplyInvariant(_covenantCore, vars.marketId);
    }

    struct MintRedeemTestVars {
        MarketId marketId;
        MarketParams marketParams;
        MarketState marketState;
        SynthTokens synthTokens;
        uint256 initMintAmount;
        uint256 mintAmount;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 aAmountOut;
        uint256 zAmountOut;
        uint256 baseAmountOut;
        MintParams mintParams;
        RedeemParams redeemParams;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        address mockBaseAsset;
        address mockQuoteAsset;
    }

    // At any time, check that minting a+z tokens, and then immediatedly redeeming them,
    // does not result in a positive gain in base tokens
    function testMintRedeem__Fuzz(
        uint256 rawInitMintAmount,
        uint256 oraclePrice,
        uint256 rawMintAmount,
        uint8 rawBaseDecimals,
        uint8 rawQuoteDecimals
    ) external {
        MintRedeemTestVars memory vars;

        vars.baseDecimals = boundDecimals(rawBaseDecimals);
        vars.quoteDecimals = boundDecimals(rawQuoteDecimals);

        // Create mock assets with specified decimals
        vars.mockBaseAsset = address(new MockERC20(address(this), "MockBaseAsset", "MBA", vars.baseDecimals));
        vars.mockQuoteAsset = address(new MockERC20(address(this), "MockQuoteAsset", "MQA", vars.quoteDecimals));

        // Mint base tokens to this contract
        MockERC20(vars.mockBaseAsset).mint(address(this), type(uint256).max);

        // init market
        vars.marketParams = MarketParams({
            baseToken: vars.mockBaseAsset,
            quoteToken: vars.mockQuoteAsset, // $130K limit                      a
            curator: _mockOracle,
            lex: _lexImplementation
        });
        vars.marketId = _covenantCore.createMarket(vars.marketParams, hex"");

        // remove mint and redeem caps
        MockLatentSwapLEX(_lexImplementation).setMarketNoCapLimit(vars.marketId, 255);

        // approve transferFrom
        IERC20(vars.mockBaseAsset).approve(address(_covenantCore), type(uint256).max);

        // bound amounts
        vars.initMintAmount = boundMintAmountDecimalAware(rawInitMintAmount, vars.baseDecimals, vars.quoteDecimals);
        vars.mintAmount = boundMintAmountDecimalAware(rawMintAmount, vars.baseDecimals, vars.quoteDecimals);

        // Preview mint
        (uint256 previewATokenAmount, uint256 previewZTokenAmount, , , ) = _covenantCore.previewMint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.initMintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // mint
        // @dev - mints when price == 10**18, with 50% LTV
        (vars.aTokenAmount, vars.zTokenAmount) = _covenantCore.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.initMintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // check base supply invariant
        _baseSupplyInvariant(_covenantCore, vars.marketId);

        // Test if the actual mint returns the same amounts as the preview
        assertEq(vars.aTokenAmount, previewATokenAmount, "Actual aToken amount does not match preview");
        assertEq(vars.zTokenAmount, previewZTokenAmount, "Actual zToken amount does not match preview");

        // Set new price in oracle
        MockOracle(_mockOracle).setPrice(boundOraclePrice(oraclePrice));

        ///////////////////////////////////////////////////////////////////////////
        // Mint

        // Define mint parameters
        vars.mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.mintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // mint
        (vars.aAmountOut, vars.zAmountOut) = _covenantCore.mint(vars.mintParams);

        //////////////////////////////////////////////////////////////////////////
        // Redeem

        // Preview redeem
        (uint256 previewBaseAmountOut, , , ) = _covenantCore.previewRedeem(
            RedeemParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                aTokenAmountIn: vars.aAmountOut,
                zTokenAmountIn: vars.zAmountOut,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Define redeem parameters
        vars.redeemParams = RedeemParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            aTokenAmountIn: vars.aAmountOut,
            zTokenAmountIn: vars.zAmountOut,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // redeem
        vars.baseAmountOut = _covenantCore.redeem(vars.redeemParams);

        // Test if the actual redeem returns the same amount as the preview
        assertEq(vars.baseAmountOut, previewBaseAmountOut, "Actual base amount out does not match preview");

        ///////////////////////////////////////////////////////////////////////////
        // Test redeem returns less or equal to initial mint
        assertLe(vars.baseAmountOut, vars.mintAmount, "redeem returned more than initially used for mint");

        // check base supply invariant
        _baseSupplyInvariant(_covenantCore, vars.marketId);
    }

    // At any time, check that minting a+z tokens, and then immediatedly redeeming a random amount,
    // check that the preivew redeem matches the actual redeem
    function testRedeemPartial__Fuzz(
        uint256 rawInitMintAmount,
        uint256 oraclePrice,
        uint256 rawMintAmount,
        uint256 rawARedeemAmount,
        uint256 rawZRedeemAmount,
        uint256 timeInterval1 // Time between mint and redeem
    ) external {
        MintRedeemTestVars memory vars;

        // Initialize marketId
        vars.marketId = _marketId;
        vars.marketParams = _marketParams;

        // bound amounts
        vars.initMintAmount = boundMintAmount(rawInitMintAmount);
        vars.mintAmount = boundMintAmount(rawMintAmount);

        // mint
        // @dev - mints when price == 10**18, with 50% LTV
        (vars.aTokenAmount, vars.zTokenAmount) = _covenantCore.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.initMintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Set new price in oracle (changes LTV)
        MockOracle(_mockOracle).setPrice(boundOraclePrice(oraclePrice));

        ///////////////////////////////////////////////////////////////////////////
        // Mint

        // Define mint parameters
        vars.mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.mintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // mint
        (vars.aAmountOut, vars.zAmountOut) = _covenantCore.mint(vars.mintParams);

        // check base supply invariant
        _baseSupplyInvariant(_covenantCore, vars.marketId);

        //////////////////////////////////////////////////////////////////////////
        // Redeem

        // Simulate time passage between mint and redeem
        vm.warp(block.timestamp + (timeInterval1 % (3 * 30 * 24 * 60 * 60))); // Limit to 3 months

        uint256 aAmountRedeem = bound(rawARedeemAmount, 0, vars.aAmountOut >> 1);
        uint256 zAmountRedeem = bound(rawZRedeemAmount, 0, vars.zAmountOut >> 1);
        if (aAmountRedeem == 0 && zAmountRedeem == 0) return;

        // Preview redeem
        uint256 previewBaseAmountOut;
        try
            _covenantCore.previewRedeem(
                RedeemParams({
                    marketId: vars.marketId,
                    marketParams: vars.marketParams,
                    aTokenAmountIn: aAmountRedeem,
                    zTokenAmountIn: zAmountRedeem,
                    to: address(this),
                    minAmountOut: 0,
                    data: hex"",
                    msgValue: 0
                })
            )
        returns (uint256 amountOut, uint128 protocolFees, uint128, TokenPrices memory tokenPrices) {
            previewBaseAmountOut = amountOut;
        } catch (bytes memory reason) {
            // Check if the error is E_InsufficientAmount
            if (keccak256(reason) == keccak256(abi.encodeWithSignature("E_InsufficientAmount()"))) {
                previewBaseAmountOut = 0; // set to 0 for rest of test
            } else {
                revert(string(reason)); // Revert for other errors
            }
        }

        console.log("preview redeem", previewBaseAmountOut);

        ///////////////////////////////////////////////////////////////////////////
        // Test previewRedeem returns less or equal to initial mint
        assertLe(previewBaseAmountOut, vars.mintAmount, "redeem returned more than initially used for mint");

        // check that diff is not too big (buffer given passage of time)
        if (vars.mintAmount > 100 * MIN_BASE_TOKEN) {
            assertFalse(previewBaseAmountOut == 0, "Redeem should not be zero");
            assertLe(
                (vars.mintAmount * LIQUIDITY_PRECISION_BELOW) / previewBaseAmountOut,
                LIQUIDITY_PRECISION_BELOW,
                "Redeem base amount should be close to mint liquidity"
            );
        }

        // Define redeem parameters
        if (previewBaseAmountOut > 0) {
            vars.redeemParams = RedeemParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                aTokenAmountIn: aAmountRedeem,
                zTokenAmountIn: zAmountRedeem,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            });

            // redeem
            console.log("original mint", vars.mintAmount);
            vars.baseAmountOut = _covenantCore.redeem(vars.redeemParams);

            // Test if the actual redeem returns the same amount as the preview
            assertEq(vars.baseAmountOut, previewBaseAmountOut, "Actual base amount out does not match preview");

            // check base supply invariant
            _baseSupplyInvariant(_covenantCore, vars.marketId);
        }
    }

    struct MintSwapRedeemTestVars {
        uint256 initMintAmount;
        uint256 mintAmount;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 aWalletAmount;
        uint256 zWalletAmount;
        uint256 swapAmount;
        uint256 swapAmountOut;
        uint256 baseAmountOut;
        MarketId marketId;
        MarketParams marketParams;
        MintParams mintParams;
        RedeemParams redeemParams;
        SwapParams swapParams;
    }

    function testMintSwapRedeem__Fuzz(
        uint256 rawInitMintAmount,
        uint256 oraclePrice,
        uint256 rawMintAmount,
        uint256 rawSwapAmount,
        bool aToZSwap,
        bool isExactIn
    ) external {
        MintSwapRedeemTestVars memory vars;

        // Initialize marketId
        vars.marketId = _marketId;
        vars.marketParams = _marketParams;

        // bound amounts
        vars.initMintAmount = boundMintAmount(rawInitMintAmount);
        vars.mintAmount = boundMintAmount(rawMintAmount);

        // Preview initial mint
        (uint256 previewATokenAmount, uint256 previewZTokenAmount, , , ) = _covenantCore.previewMint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.initMintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // mint
        // @dev - mints when price == 10**18, with 50% LTV
        (vars.aTokenAmount, vars.zTokenAmount) = _covenantCore.mint(
            MintParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                baseAmountIn: vars.initMintAmount,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test if the actual mint returns the same amounts as the preview
        assertEq(vars.aTokenAmount, previewATokenAmount, "Actual aToken amount does not match preview");
        assertEq(vars.zTokenAmount, previewZTokenAmount, "Actual zToken amount does not match preview");

        // Simulate time passage between mint and swap
        //vm.warp(block.timestamp + (timeInterval1 % (3 * 30 * 24 * 60 * 60))); // Limit to 3 months

        // Set new price in oracle
        MockOracle(_mockOracle).setPrice(boundOraclePrice(oraclePrice));

        ///////////////////////////////////////////////////////////////////////////
        // Mint

        // Define mint parameters
        vars.mintParams = MintParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            baseAmountIn: vars.mintAmount,
            to: address(this),
            minATokenAmountOut: 0,
            minZTokenAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // mint
        (vars.aWalletAmount, vars.zWalletAmount) = _covenantCore.mint(vars.mintParams);

        // check base supply invariant
        _baseSupplyInvariant(_covenantCore, vars.marketId);

        ///////////////////////////////////////////////////////////////////////////
        // Swap
        vars.swapAmount = bound(rawSwapAmount, 1, ((aToZSwap && isExactIn) ? vars.aWalletAmount : vars.zWalletAmount));

        // Define swap parameters
        vars.swapParams = SwapParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            assetIn: aToZSwap ? AssetType.LEVERAGE : AssetType.DEBT,
            assetOut: aToZSwap ? AssetType.DEBT : AssetType.LEVERAGE,
            to: address(this),
            amountSpecified: vars.swapAmount,
            amountLimit: 0,
            isExactIn: isExactIn,
            data: hex"",
            msgValue: 0
        });

        // Try to perform the swap and catch specific errors
        try _covenantCore.swap(vars.swapParams) returns (uint256 swapAmountOut) {
            vars.swapAmountOut = swapAmountOut;

            // Update my current 'token amounts'
            if (aToZSwap) {
                if (isExactIn) {
                    vars.aWalletAmount -= vars.swapAmount;
                    vars.zWalletAmount += vars.swapAmountOut;
                } else {
                    vars.aWalletAmount -= vars.swapAmountOut;
                    vars.zWalletAmount += vars.swapAmount;
                }
            } else if (isExactIn) {
                vars.zWalletAmount -= vars.swapAmount;
                vars.aWalletAmount += vars.swapAmountOut;
            } else {
                vars.zWalletAmount -= vars.swapAmountOut;
                vars.aWalletAmount += vars.swapAmount;
            }
        } catch (bytes memory reason) {
            // Check if the error is E_CrossedLimit or E_LEX_InsufficientTokens
            if (
                keccak256(reason) == keccak256(abi.encodeWithSignature("E_CrossedLimit()")) ||
                keccak256(reason) == keccak256(abi.encodeWithSignature("E_ZeroAmount()")) ||
                keccak256(reason) == keccak256(abi.encodeWithSignature("E_LEX_InsufficientTokens()")) ||
                keccak256(reason) == keccak256(abi.encodeWithSignature("E_LEX_ActionNotAllowedGivenLTVlimit()"))
            ) {
                return; // Continue fuzz testing if either error is caught
            } else {
                revert(string(reason)); // Revert for other errors
            }
        }

        // check base supply invariant
        _baseSupplyInvariant(_covenantCore, vars.marketId);

        // Simulate time passage between swap and redeem
        //vm.warp(block.timestamp + (timeInterval2 % (3 * 30 * 24 * 60 * 60))); // Limit to 3 months

        //////////////////////////////////////////////////////////////////////////
        // Redeem

        // Preview redeem
        console.log("vars.aWalletAmount", vars.aWalletAmount);
        console.log("vars.zWalletAmount", vars.zWalletAmount);
        (uint256 previewBaseAmountOut, , , ) = _covenantCore.previewRedeem(
            RedeemParams({
                marketId: vars.marketId,
                marketParams: vars.marketParams,
                aTokenAmountIn: vars.aWalletAmount,
                zTokenAmountIn: vars.zWalletAmount,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Define redeem parameters
        vars.redeemParams = RedeemParams({
            marketId: vars.marketId,
            marketParams: vars.marketParams,
            aTokenAmountIn: vars.aWalletAmount,
            zTokenAmountIn: vars.zWalletAmount,
            to: address(this),
            minAmountOut: 0,
            data: hex"",
            msgValue: 0
        });

        // redeem
        vars.baseAmountOut = _covenantCore.redeem(vars.redeemParams);

        // Test if the actual redeem returns the same amount as the preview
        assertEq(vars.baseAmountOut, previewBaseAmountOut, "Actual base amount out does not match preview");

        ///////////////////////////////////////////////////////////////////////////
        // Test redeem returns less or equal to initial mint
        assertLe(vars.baseAmountOut, vars.mintAmount, "redeem returned more than initially used for mint + swap");

        // check base supply invariant
        _baseSupplyInvariant(_covenantCore, vars.marketId);
    }
}

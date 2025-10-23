// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {SynthToken} from "../src/synths/SynthToken.sol";
import {Covenant, MarketId, MarketParams, MarketState, SynthTokens} from "../src/Covenant.sol";
import {LatentSwapLEX} from "../src/lex/latentswap/LatentSwapLEX.sol";
import {LSErrors} from "../src/lex/latentswap/libraries/LSErrors.sol";
import {FixedPoint} from "../src/lex/latentswap/libraries/FixedPoint.sol";
import {DebtMath} from "../src/lex/latentswap/libraries/DebtMath.sol";
import {ICovenant, IERC20, AssetType, SwapParams, RedeemParams, MintParams} from "../src/interfaces/ICovenant.sol";
import {ISynthToken} from "../src/interfaces/ISynthToken.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ILiquidExchangeModel} from "../src/interfaces/ILiquidExchangeModel.sol";
import {ILatentSwapLEX, LexState} from "../src/lex/latentswap/interfaces/ILatentSwapLEX.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {WadRayMath} from "@aave/libraries/math/WadRayMath.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {UtilsLib} from "../src/libraries/Utils.sol";
import {TestMath} from "./utils/TestMath.sol";
import {Events} from "../src/libraries/Events.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {LatentSwapLib} from "../src/periphery/libraries/LatentSwapLib.sol";
import {PercentageMath} from "@aave/libraries/math/PercentageMath.sol";

// Helper contract to test delegate calls
contract DelegateCallTester {
    function helpDelegateCall(address target, bytes calldata data) external {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        if (!success) {
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }
    }
}

contract CovenantTest is Test {
    using WadRayMath for uint256;

    // LatentSwapLEX init pricing constants
    uint160 constant P_MAX = uint160((1095445 * FixedPoint.Q96) / 1000000); //uint160(Math.sqrt((FixedPoint.Q192 * 12) / 10)); // Edge price of 1.2
    uint160 constant P_MIN = uint160(FixedPoint.Q192 / P_MAX);
    uint32 constant DURATION = 30 * 24 * 60 * 60;
    uint8 constant SWAP_FEE = 0;
    int64 constant LN_RATE_BIAS = 5012540000000000; // WAD

    address private _mockOracle;
    address private _mockBaseAsset;
    address private _mockQuoteAsset;
    uint160 private P_LIM_H = LatentSwapLib.getSqrtPriceFromLTVX96(P_MIN, P_MAX, 9500);
    uint160 private P_LIM_MAX = LatentSwapLib.getSqrtPriceFromLTVX96(P_MIN, P_MAX, 9999);

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
        MockERC20(_mockBaseAsset).mint(address(this), 100 * 10 ** 18);

        // deploy mock ERC20 quote asset
        _mockQuoteAsset = address(new MockERC20(address(this), "MockQaseAsset", "MQA", 18));
    }

    function test_newCovenant() external {
        Covenant covenantCore;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));
    }

    function test_setLEX() external {
        Covenant covenantCore;
        address lexImplementation;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
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
            )
        );

        // authorize lex
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);
    }

    function test_mint() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // Preview mint using only necessary parameters
        (uint256 previewATokenAmount, uint256 previewZTokenAmount, , , ) = covenantCore.previewMint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // mint
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test if the actual mint returns the same amounts as the preview
        assertEq(aTokenAmount, previewATokenAmount, "Actual aToken amount does not match preview");
        assertEq(zTokenAmount, previewZTokenAmount, "Actual zToken amount does not match preview");

        // check base supply invariant
        _baseSupplyInvariant(covenantCore, marketId);
    }

    function test_redeemFull() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 10 ** 9;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 baseAmountOut;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // mint
        (aTokenAmount, zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Preview redeem
        (uint256 previewBaseAmountOut, , , ) = covenantCore.previewRedeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount,
                zTokenAmountIn: zTokenAmount,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // redeem
        baseAmountOut = covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount,
                zTokenAmountIn: zTokenAmount,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test if the actual redeem returns the same amount as the preview
        assertEq(baseAmountOut, previewBaseAmountOut, "Actual base amount out does not match preview");

        // check full base amount redeemed
        assertEq(baseAmountIn, baseAmountOut);

        // check base supply is 0 after full redemption
        MarketState memory currentMarketState = covenantCore.getMarketState(marketId);
        assertEq(currentMarketState.baseSupply, 0, "Base supply should be 0 after full redemption");

        // check baseToken balance is 0 after full redemption
        assertEq(
            IERC20(_mockBaseAsset).balanceOf(address(covenantCore)),
            0,
            "Base token balance should be 0 after full redemption"
        );

        // check base supply invariant
        _baseSupplyInvariant(covenantCore, marketId);
    }

    function test_redeemPartial() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 baseAmountOut;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // mint
        (aTokenAmount, zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Preview redeem
        (uint256 previewBaseAmountOut, , , ) = covenantCore.previewRedeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount >> 8,
                zTokenAmountIn: zTokenAmount >> 8,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // redeem
        baseAmountOut = covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount >> 8,
                zTokenAmountIn: zTokenAmount >> 8,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test if the actual redeem returns the same amount as the preview
        assertEq(baseAmountOut, previewBaseAmountOut, "Actual base amount out does not match preview");

        // check base supply invariant
        _baseSupplyInvariant(covenantCore, marketId);
    }

    struct SwapTestVars {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        MarketParams marketParams;
        uint256 baseAmountIn;
        uint256 swapAmount;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 baseAmountOut;
        SynthTokens synthTokens;
        uint256 zTokenPriceBefore;
        uint256 aTokenPriceBefore;
        uint256 zTokenPriceAfterAtoZ;
        uint256 aTokenPriceAfterAtoZ;
        AssetType inTokenType;
        AssetType outTokenType;
        address inToken;
        address outToken;
        uint256 initialInBalance;
        uint256 initialOutBalance;
        uint256 finalInBalance;
        uint256 finalOutBalance;
        uint256 inPriceBefore;
        uint256 outPriceBefore;
        uint256 inPriceAfter;
        uint256 outPriceAfter;
        SwapParams swapParams;
        uint256 swapAmountOut;
        uint256 previewAmount;
    }

    function test_swap() external {
        SwapTestVars memory vars;

        vars.baseAmountIn = 10 ** 18;
        vars.swapAmount = 10 ** 16;

        // deploy covenant liquid
        vars.covenantCore = new Covenant(address(this));

        // deploy lex implementation
        vars.lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(vars.covenantCore),
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
        vars.covenantCore.setEnabledLEX(vars.lexImplementation, true);

        // authorize oracle
        vars.covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: vars.lexImplementation
        });
        vars.marketId = vars.covenantCore.createMarket(vars.marketParams, hex"");

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(vars.covenantCore), vars.baseAmountIn << 10);

        // mint
        (vars.aTokenAmount, vars.zTokenAmount) = vars.covenantCore.mint(
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

        // allow for time (to reset mint cap)
        vm.warp(block.timestamp + 1 days);
        vars.covenantCore.updateState(vars.marketId, vars.marketParams, hex"", 0);

        // Get market info
        vars.synthTokens = ILiquidExchangeModel(vars.marketParams.lex).getSynthTokens(vars.marketId);

        // Loop over all possible swaps
        for (uint8 inType = 0; inType < 3; inType++) {
            for (uint8 outType = 0; outType < 3; outType++) {
                for (uint8 exactIn = 0; exactIn < 2; exactIn++) {
                    if (inType == outType) continue; // Skip if inType and outType are the same
                    if (inType == uint8(AssetType.BASE) && exactIn == 1) continue; // Skip if inType is BASE and swap is EXACT_out
                    if (outType == uint8(AssetType.BASE) && exactIn == 1) continue; // Skip if outType is BASE and swap is EXACT_out

                    //Update State - after 30 min
                    vm.warp(block.timestamp + 3600);
                    vars.covenantCore.updateState(vars.marketId, vars.marketParams, hex"", 0);

                    vars.inTokenType = AssetType(inType);
                    vars.outTokenType = AssetType(outType);

                    // Convert to token addresses
                    if (vars.inTokenType == AssetType.BASE) {
                        vars.inToken = address(vars.marketParams.baseToken);
                    } else if (vars.inTokenType == AssetType.LEVERAGE) {
                        vars.inToken = address(vars.synthTokens.aToken);
                    } else if (vars.inTokenType == AssetType.DEBT) {
                        vars.inToken = address(vars.synthTokens.zToken);
                    }
                    if (vars.outTokenType == AssetType.BASE) {
                        vars.outToken = address(vars.marketParams.baseToken);
                    } else if (vars.outTokenType == AssetType.LEVERAGE) {
                        vars.outToken = address(vars.synthTokens.aToken);
                    } else if (vars.outTokenType == AssetType.DEBT) {
                        vars.outToken = address(vars.synthTokens.zToken);
                    }

                    // Define swap parameters
                    vars.swapParams = SwapParams({
                        marketId: vars.marketId,
                        marketParams: vars.marketParams,
                        assetIn: vars.inTokenType,
                        assetOut: vars.outTokenType,
                        to: address(this),
                        amountSpecified: vars.swapAmount,
                        amountLimit: exactIn == 0 ? 0 : type(uint256).max,
                        isExactIn: exactIn == 0,
                        data: hex"",
                        msgValue: 0
                    });

                    // Initial balances
                    vars.initialInBalance = IERC20(vars.inToken).balanceOf(address(this));
                    vars.initialOutBalance = IERC20(vars.outToken).balanceOf(address(this));

                    // get initial values
                    (vars.previewAmount, , , ) = vars.covenantCore.previewSwap(vars.swapParams);
                    vars.inPriceBefore = (vars.swapParams.isExactIn)
                        ? (vars.previewAmount * 10 ** 18) / vars.swapAmount
                        : (vars.swapAmount * 10 ** 18) / vars.previewAmount;

                    // swap inToken for outToken
                    vars.swapAmountOut = vars.covenantCore.swap(vars.swapParams);

                    // Balance after swap
                    vars.finalInBalance = IERC20(vars.inToken).balanceOf(address(this));
                    vars.finalOutBalance = IERC20(vars.outToken).balanceOf(address(this));

                    // Assert balances
                    assertEq(
                        vars.finalInBalance,
                        vars.initialInBalance - (vars.swapParams.isExactIn ? vars.swapAmount : vars.swapAmountOut),
                        "Incorrect inToken balance after swap"
                    );
                    assertEq(
                        vars.finalOutBalance,
                        vars.initialOutBalance + (vars.swapParams.isExactIn ? vars.swapAmountOut : vars.swapAmount),
                        "Incorrect outToken balance after swap"
                    );

                    // Assert preview
                    assertEq(vars.previewAmount, vars.swapAmountOut, "Incorrect preview and swap amount");

                    // prices after swap
                    (vars.previewAmount, , , ) = vars.covenantCore.previewSwap(
                        SwapParams({
                            marketId: vars.marketId,
                            marketParams: vars.marketParams,
                            assetIn: vars.inTokenType,
                            assetOut: vars.outTokenType,
                            to: address(this),
                            amountSpecified: vars.swapAmount,
                            amountLimit: vars.swapParams.isExactIn ? 0 : type(uint256).max,
                            isExactIn: vars.swapParams.isExactIn,
                            data: hex"",
                            msgValue: 0
                        })
                    );
                    vars.inPriceAfter = (vars.swapParams.isExactIn)
                        ? (vars.previewAmount * 10 ** 18) / vars.swapAmount
                        : (vars.swapAmount * 10 ** 18) / vars.previewAmount;

                    // Assert price changes after swap
                    assertGt(vars.inPriceBefore, vars.inPriceAfter, "price should increase after swap");

                    // check base supply invariant
                    _baseSupplyInvariant(vars.covenantCore, vars.marketId);
                }
            }
        }
    }

    struct NotionalPriceTestVars {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        MarketParams marketParams;
        LexState initialState;
        uint256 initialBaseSupply;
        uint256 baseAmountIn;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        LexState afterMintState;
        uint256 afterMintBaseSupply;
        LexState updatedState;
        uint256 updatedBaseSupply;
        uint256 additionalBaseAmount;
        uint256 additionalATokenAmount;
        uint256 additionalZTokenAmount;
        LexState finalState;
    }

    function test_NotionalPriceIncreasesOverTime() public {
        NotionalPriceTestVars memory vars;

        // deploy covenant liquid
        vars.covenantCore = new Covenant(address(this));

        // deploy lex implementation
        vars.lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(vars.covenantCore),
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
        vars.covenantCore.setEnabledLEX(vars.lexImplementation, true);

        // authorize oracle
        vars.covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: vars.lexImplementation
        });
        vars.marketId = vars.covenantCore.createMarket(vars.marketParams, hex"");

        // Get initial market state
        vars.initialState = ILatentSwapLEX(vars.marketParams.lex).getLexState(vars.marketId);

        // Fast forward time by 1 day
        vm.warp(block.timestamp + 1 days);

        // update state
        vars.covenantCore.updateState(vars.marketId, vars.marketParams, hex"", 0);

        // Get updated market state
        vars.updatedState = ILatentSwapLEX(vars.marketParams.lex).getLexState(vars.marketId);

        // Verify that notional price has increased
        assertGt(
            vars.updatedState.lastDebtNotionalPrice,
            vars.initialState.lastDebtNotionalPrice,
            "Notional price should increase over time with positive interest rate"
        );

        // verify that timestamp increased
        assertGt(
            vars.updatedState.lastUpdateTimestamp,
            vars.initialState.lastUpdateTimestamp,
            "timestamp should increase over time "
        );

        // Calculate expected increase based on interest rate
        uint256 elapsedTime = vars.updatedState.lastUpdateTimestamp - vars.initialState.lastUpdateTimestamp;
        uint256 spotPriceDiscount = TestMath.getDebtDiscount(vars.initialState.lastSqrtPriceX96, P_MIN, P_MAX);
        uint256 expectedNotionalPrice = DebtMath.accrueInterest(
            vars.initialState.lastDebtNotionalPrice,
            DURATION,
            spotPriceDiscount,
            elapsedTime,
            LN_RATE_BIAS
        );

        // Verify that the increase matches expected calculation
        assertEq(
            vars.updatedState.lastDebtNotionalPrice,
            expectedNotionalPrice,
            "Notional price increase should match expected calculation"
        );
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Fee Management Tests
    /////////////////////////////////////////////////////////////////////////////////////////////

    function test_setDefaultFee() external {
        Covenant covenantCore;
        uint32 newFee = 50; // 0.5%

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // Test 1: Only owner can call setDefaultFee
        address nonOwner = address(0x123);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        covenantCore.setDefaultFee(newFee);

        // Test 2: Owner can successfully set default fee
        covenantCore.setDefaultFee(newFee);

        // Test 3: Verify the fee was set correctly by checking a new market gets the new default fee
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Test 4: Verify event was emitted with correct parameters
        vm.expectEmit(true, true, false, true);
        emit Events.UpdateDefaultProtocolFee(newFee, newFee + 10);
        covenantCore.setDefaultFee(newFee + 10); // Call again to trigger event
    }

    function test_setMarketFee() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint32 newFee = 75; // 0.75%

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test 1: Only owner can call setMarketFee
        address nonOwner = address(0x123);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, newFee);

        // Test 2: Owner can successfully set market fee
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, newFee);

        // Note: The new interface doesn't have getMarketConfig, so we'll just verify the fee was set
        // by checking that we can call the function without reverting

        // Test 3: Verify event was emitted with correct parameters
        vm.expectEmit(true, true, false, true);
        emit Events.UpdateMarketProtocolFee(marketId, newFee, newFee + 10);
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, newFee + 10); // Call again to trigger event

        // Test 4: Cannot set fee for non-existent market
        vm.expectRevert(Errors.E_MarketNonExistent.selector);
        covenantCore.setMarketProtocolFee(
            MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(999)))))),
            marketParams,
            hex"",
            0,
            newFee
        );
    }

    function test_collectProtocol_noFees() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        address recipient = address(0x456);
        uint128 amountRequested = 1 * 10 ** 16; // 0.01 tokens

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test 1: Only owner can call collectProtocol
        address nonOwner = address(0x123);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        covenantCore.collectProtocolFee(marketId, recipient, amountRequested);

        // Test 2: Cannot collect from non-existent market
        vm.expectRevert(Errors.E_MarketNonExistent.selector);
        covenantCore.collectProtocolFee(
            MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(999)))))),
            recipient,
            amountRequested
        );

        // Test 3: Initially no fees to collect
        uint256 initialRecipientBalance = IERC20(_mockBaseAsset).balanceOf(recipient);
        covenantCore.collectProtocolFee(marketId, recipient, amountRequested);
        uint256 finalRecipientBalance = IERC20(_mockBaseAsset).balanceOf(recipient);
        assertEq(initialRecipientBalance, finalRecipientBalance, "Should not collect fees when none available");

        // Test 4: Mint initial liquidity
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);
        covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Fast forward time to allow fee accrual
        vm.warp(block.timestamp + 90 days);

        // Update state
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        // Test 5: Collect protocol fees (should not revert when 0 fees)
        initialRecipientBalance = IERC20(_mockBaseAsset).balanceOf(recipient);
        covenantCore.collectProtocolFee(marketId, recipient, amountRequested);
        finalRecipientBalance = IERC20(_mockBaseAsset).balanceOf(recipient);

        // Should not transfer anything given no fees available
        assertEq(initialRecipientBalance, finalRecipientBalance, "Should not transfer when no fees available");

        // Test 6: Verify event emission of 0 amount
        vm.expectEmit(true, true, false, true);
        emit Events.CollectProtocolFee(marketId, recipient, address(_mockBaseAsset), 0);
        covenantCore.collectProtocolFee(marketId, recipient, amountRequested);

        // Test 7: Test with a different recipient
        address newRecipient = address(0x789);
        uint256 newRecipientInitialBalance = IERC20(_mockBaseAsset).balanceOf(newRecipient);
        covenantCore.collectProtocolFee(marketId, newRecipient, amountRequested);
        uint256 newRecipientFinalBalance = IERC20(_mockBaseAsset).balanceOf(newRecipient);
        assertEq(
            newRecipientInitialBalance,
            newRecipientFinalBalance,
            "New recipient should not receive fees when none available"
        );
    }

    function test_collectProtocol_withFees() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        address recipient = address(0x456);
        uint32 defaultFee = 100; // 1% fee for testing

        // deploy covenant liquid with a non-zero default fee
        covenantCore = new Covenant(address(this));
        covenantCore.setDefaultFee(defaultFee); // 1% fee for testing

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Get initial balances
        uint256 initialRecipientBalance = IERC20(_mockBaseAsset).balanceOf(recipient);

        //  Mint initial liquidity
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn * 2);
        covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Fast forward time to allow fee accrual
        vm.warp(block.timestamp + 90 days);

        // Update state
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        // Test collected protocol fees close to expected amount
        uint128 amountExpected = uint128(baseAmountIn * defaultFee * (90 days)) / 10000 / (365 days); // 0.01 tokens
        MarketState memory currentState = covenantCore.getMarketState(marketId);
        assertApproxEqAbs(
            amountExpected,
            currentState.protocolFeeGrowth,
            5000000000000,
            "Accrued fees should be close to expected amount"
        );

        // Request half of expected amount
        uint128 amountRequested = amountExpected / 2;
        vm.expectEmit(true, true, false, true);
        emit Events.CollectProtocolFee(marketId, recipient, address(_mockBaseAsset), amountRequested);
        covenantCore.collectProtocolFee(marketId, recipient, amountRequested);

        // Verify recipient received tokens
        uint256 finalRecipientBalance = IERC20(_mockBaseAsset).balanceOf(recipient);

        // The actual amount transferred should be the minimum of amountRequested and available fees
        uint128 actualAmountTransferred = uint128(finalRecipientBalance - initialRecipientBalance);
        assertEq(actualAmountTransferred, amountRequested, "Should transfer amount requested");

        // Test only remaining fees are collected even if more is requested
        currentState = covenantCore.getMarketState(marketId);
        uint128 remainingFees = currentState.protocolFeeGrowth;
        uint128 amountRequested2 = remainingFees * 100; // request more than remaining fees
        vm.expectEmit(true, true, false, true);
        emit Events.CollectProtocolFee(marketId, recipient, address(_mockBaseAsset), remainingFees);
        covenantCore.collectProtocolFee(marketId, recipient, amountRequested2);

        // Verify recipient received tokens
        uint256 finalRecipientBalance2 = IERC20(_mockBaseAsset).balanceOf(recipient);
        assertEq(finalRecipientBalance2, finalRecipientBalance + remainingFees, "Should transfer remaining fees");
    }

    function test_feePermissions() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test that non-owner cannot call any fee functions
        address nonOwner = address(0x123);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        covenantCore.setDefaultFee(50);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, 50);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        covenantCore.collectProtocolFee(marketId, address(0x456), 1000);

        // Test that owner can call all fee functions
        covenantCore.setDefaultFee(50);
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, 75);
        covenantCore.collectProtocolFee(marketId, address(0x456), 1000);
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Valid LEX, Oracle, and Duration Tests
    /////////////////////////////////////////////////////////////////////////////////////////////

    function test_setEnabledLEX() external {
        Covenant covenantCore;
        address lexImplementation;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // Test 1: Only owner can call setEnabledLEX
        address nonOwner = address(0x123);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        covenantCore.setEnabledLEX(lexImplementation, true);

        // Test 2: Owner can set LEX as valid
        vm.expectEmit(true, true, false, true);
        emit Events.UpdateEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledLEX(lexImplementation, true);

        // Test 3: Owner can set LEX as invalid
        vm.expectEmit(true, true, false, true);
        emit Events.UpdateEnabledLEX(lexImplementation, false);
        covenantCore.setEnabledLEX(lexImplementation, false);

        // Test 4: Owner can set LEX as valid again
        vm.expectEmit(true, true, false, true);
        emit Events.UpdateEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledLEX(lexImplementation, true);
    }

    function test_setEnabledOracle() external {
        Covenant covenantCore;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // Test 1: Only owner can call setEnabledCurator
        address nonOwner = address(0x123);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test 2: Owner can set oracle as valid
        vm.expectEmit(true, true, false, true);
        emit Events.UpdateEnabledOracle(_mockOracle, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test 3: Owner can set oracle as invalid
        vm.expectEmit(true, true, false, true);
        emit Events.UpdateEnabledOracle(_mockOracle, false);
        covenantCore.setEnabledCurator(_mockOracle, false);

        // Test 4: Owner can set oracle as valid again
        vm.expectEmit(true, true, false, true);
        emit Events.UpdateEnabledOracle(_mockOracle, true);
        covenantCore.setEnabledCurator(_mockOracle, true);
    }

    function test_marketInitWithInvalidLEX() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize oracle and duration
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test: Cannot initialize market with invalid LEX
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        vm.expectRevert(Errors.E_LEXimplementationNotAuthorized.selector);
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Now authorize the LEX
        covenantCore.setEnabledLEX(lexImplementation, true);

        // Test: Can initialize market with valid LEX
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Verify market was created successfully
        MarketParams memory marketParamsFromCovenant = covenantCore.getIdToMarketParams(marketId);
        // Note: The LEX address in the market is the proxy address, not the implementation address
        assertEq(marketParamsFromCovenant.lex, lexImplementation, "Market should have a LEX proxy");
    }

    function test_marketInitWithInvalidOracle() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize LEX and duration
        covenantCore.setEnabledLEX(lexImplementation, true);

        // Test: Cannot initialize market with invalid oracle
        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        vm.expectRevert(Errors.E_CuratorNotAuthorized.selector);
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Now authorize the oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test: Can initialize market with valid oracle
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Verify market was created successfully
        MarketParams memory marketParamsFromCovenant = covenantCore.getIdToMarketParams(marketId);
        assertEq(marketParamsFromCovenant.curator, _mockOracle, "Market should have correct oracle");
    }

    function test_marketWorksAfterEnabledFlagsSetToFalse() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize everything
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Now set all valid flags to false
        covenantCore.setEnabledLEX(lexImplementation, false);
        covenantCore.setEnabledCurator(_mockOracle, false);

        // Test: Market should still work for operations
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // Test mint operation still works
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Verify mint was successful
        assertGt(aTokenAmount, 0, "Mint should succeed even after valid flags set to false");
        assertGt(zTokenAmount, 0, "Mint should succeed even after valid flags set to false");

        // Test redeem operation still works (redeem half of what we minted)
        uint256 baseAmountOut = covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount / 10,
                zTokenAmountIn: zTokenAmount / 10,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Verify redeem was successful
        assertGt(baseAmountOut, 0, "Redeem should succeed even after valid flags set to false");

        // Test getMarketConfig still works
        MarketParams memory marketParamsGet = covenantCore.getIdToMarketParams(marketId);
        assertEq(marketParamsGet.lex, lexImplementation, "Market config should still be accessible");

        // Test getMarketState still works
        MarketState memory marketState = covenantCore.getMarketState(marketId);
        assertGt(marketState.baseSupply, 0, "Market state should still be accessible");
    }

    function test_multipleValidLEXs() external {
        Covenant covenantCore;
        address lexImplementation1;
        address lexImplementation2;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy two lex implementations
        lexImplementation1 = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        lexImplementation2 = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE + 10
            )
        );

        // authorize both LEXs
        covenantCore.setEnabledLEX(lexImplementation1, true);
        covenantCore.setEnabledLEX(lexImplementation2, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test: Can initialize market with first LEX
        MarketParams memory marketParams1 = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation1
        });
        MarketId marketId1 = covenantCore.createMarket(marketParams1, hex"");

        // Test: Can initialize market with second LEX
        MarketParams memory marketParams2 = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation2
        });
        MarketId marketId2 = covenantCore.createMarket(marketParams2, hex"");

        // Verify both markets were created successfully
        MarketParams memory MarketParamsGet1 = covenantCore.getIdToMarketParams(marketId1);
        MarketParams memory MarketParamsGet2 = covenantCore.getIdToMarketParams(marketId2);
        // Note: The LEX addresses in the markets are proxy addresses, not the implementation addresses
        assertEq(MarketParamsGet1.lex, lexImplementation1, "First market should have a LEX proxy");
        assertEq(MarketParamsGet2.lex, lexImplementation2, "Second market should have a LEX proxy");
        assertTrue(MarketParamsGet1.lex != MarketParamsGet2.lex, "Markets should have different LEX proxies");
    }

    function test_multipleValidOracles() external {
        Covenant covenantCore;
        address lexImplementation;
        address mockOracle1;
        address mockOracle2;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // deploy two mock oracles
        mockOracle1 = address(new MockOracle(address(this)));
        mockOracle2 = address(new MockOracle(address(this)));

        // authorize LEX and both oracles
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(mockOracle1, true);
        covenantCore.setEnabledCurator(mockOracle2, true);

        // Test: Can initialize market with first LEX
        MarketParams memory marketParams1 = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: mockOracle1,
            lex: lexImplementation
        });
        MarketId marketId1 = covenantCore.createMarket(marketParams1, hex"");

        // Test: Can initialize market with second LEX
        MarketParams memory marketParams2 = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: mockOracle2,
            lex: lexImplementation
        });
        MarketId marketId2 = covenantCore.createMarket(marketParams2, hex"");

        // Verify both markets were created successfully
        MarketParams memory MarketParamsGet1 = covenantCore.getIdToMarketParams(marketId1);
        MarketParams memory MarketParamsGet2 = covenantCore.getIdToMarketParams(marketId2);
        assertEq(MarketParamsGet1.curator, mockOracle1, "First market should have first oracle");
        assertEq(MarketParamsGet2.curator, mockOracle2, "Second market should have second oracle");
    }

    // /////////////////////////////////////////////////////////////////////////////////////////////
    // // Constructor and Initialization Tests
    // /////////////////////////////////////////////////////////////////////////////////////////////

    function test_constructor_validation() external {
        // Test 1: Constructor should revert with zero owner
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new Covenant(address(0));

        // Test 2: Constructor should work with valid parameters
        Covenant covenantCore = new Covenant(address(this));

        // Test 3: Verify owner is set correctly
        assertEq(covenantCore.owner(), address(this), "Owner should be set correctly");
    }

    // TODO: Test that when marketParameters change, we get a different MarketId.
    // TODO: Test we cannot start the same market with same parameters twice.

    // /////////////////////////////////////////////////////////////////////////////////////////////
    // // Event Emission Tests
    // /////////////////////////////////////////////////////////////////////////////////////////////

    // // function test_NewMarket_event_emission() external {
    // //     Covenant covenantCore = new Covenant(address(this));
    // //     address lexImplementation = address(
    // //         new LatentSwapLEX(address(this),address(covenantCore), P_MAX, P_MIN,  P_LIM_H, P_LIM_MAX, 0)
    // //     );
    // //     covenantCore.setEnabledLEX(lexImplementation, true);
    // //     covenantCore.setEnabledCurator(_mockOracle, true);
    // //

    // //     // Test NewMarket event emission
    // //     // We can't predict the exact values, so we'll just verify the event is emitted without checking parameters
    // //     covenantCore.initMarket(
    // //         InitMarketParams({
    // //             baseToken: IERC20(_mockBaseAsset),
    // //             quoteToken: IERC20(_mockQuoteAsset),
    // //             curator:IPriceOracle(_mockOracle),
    // //             debtDuration: 7776000,
    // //             lex: ILiquidExchangeModel(lexImplementation),
    // //             lexInitParams: abi.encode(LatentSwapLEX_InitParams({debtPriceDiscountBalanced: 990000000000000000}))
    // //         })
    // //     );
    // // }

    // // function test_Mint_event_emission() external {
    // //     Covenant covenantCore = new Covenant(address(this));
    // //     address lexImplementation = address(
    // //         new LatentSwapLEX(address(this),address(covenantCore), P_MAX, P_MIN,  P_LIM_H, P_LIM_MAX, 0)
    // //     );
    // //     covenantCore.setEnabledLEX(lexImplementation, true);
    // //     covenantCore.setEnabledCurator(_mockOracle, true);
    // //

    // //     bytes32 marketId = covenantCore.initMarket(
    // //         InitMarketParams({
    // //             baseToken: IERC20(_mockBaseAsset),
    // //             quoteToken: IERC20(_mockQuoteAsset),
    // //             curator:IPriceOracle(_mockOracle),
    // //             debtDuration: 7776000,
    // //             lex: ILiquidExchangeModel(lexImplementation),
    // //             lexInitParams: abi.encode(LatentSwapLEX_InitParams({debtPriceDiscountBalanced: 990000000000000000}))
    // //         })
    // //     );

    // //     uint256 baseAmountIn = 1 * 10 ** 18;
    // //     IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

    // //     // Calculate expected aToken and zToken amounts from mint
    // //     (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.quoteMint(
    // //         MintParams({
    // //             marketId: marketId,
    // //             baseAmountIn: baseAmountIn,
    // //
    // //             to: address(this),
    // //             minATokenAmountOut: 0,
    // //             minZTokenAmountOut: 0
    // //         })
    // //     );

    // //     // Test Mint event emission
    // //     vm.expectEmit(true, true, true, true);
    // //     emit Mint(marketId, address(this), address(this), aTokenAmount, zTokenAmount);
    // //     covenantCore.mint(
    // //         MintParams({
    // //             marketId: marketId,
    // //             baseAmountIn: baseAmountIn,
    // //
    // //             to: address(this),
    // //             minATokenAmountOut: 0,
    // //             minZTokenAmountOut: 0
    // //         })
    // //     );
    // // }

    // // function test_Redeem_event_emission() external {
    // //     Covenant covenantCore = new Covenant(address(this));
    // //     address lexImplementation = address(
    // //         new LatentSwapLEX(address(this),address(covenantCore), P_MAX, P_MIN,  P_LIM_H, P_LIM_MAX, 0)
    // //     );
    // //     covenantCore.setEnabledLEX(lexImplementation, true);
    // //     covenantCore.setEnabledCurator(_mockOracle, true);
    // //

    // //     bytes32 marketId = covenantCore.initMarket(
    // //         InitMarketParams({
    // //             baseToken: IERC20(_mockBaseAsset),
    // //             quoteToken: IERC20(_mockQuoteAsset),
    // //             curator:IPriceOracle(_mockOracle),
    // //             debtDuration: 7776000,
    // //             lex: ILiquidExchangeModel(lexImplementation),
    // //             lexInitParams: abi.encode(LatentSwapLEX_InitParams({debtPriceDiscountBalanced: 990000000000000000}))
    // //         })
    // //     );

    // //     uint256 baseAmountIn = 1 * 10 ** 14; // Use very small amount to avoid redeem cap
    // //     IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

    // //     (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
    // //         MintParams({
    // //             marketId: marketId,
    // //             baseAmountIn: baseAmountIn,
    // //
    // //             to: address(this),
    // //             minATokenAmountOut: 0,
    // //             minZTokenAmountOut: 0
    // //         })
    // //     );

    // //     // Calculate expected redeem amount
    // //     (uint256 baseAmountOut, uint256 aTokenAmountOut, uint256 zTokenAmountOut) = covenantCore.quoteRedeem(
    // //         RedeemParams({
    // //             marketId: marketId,
    // //             aTokenAmountIn: aTokenAmount / 2,
    // //             zTokenAmountIn: zTokenAmount / 2,
    // //
    // //             to: address(this),
    // //             minAmountOut: 0
    // //         })
    // //     );

    // //     // Test Redeem event emission with partial redemption
    // //     vm.expectEmit(true, true, true, true);
    // //     emit Redeem(marketId, address(this), address(this), baseAmountOut, aTokenAmountOut, zTokenAmountOut);
    // //     covenantCore.redeem(
    // //         RedeemParams({
    // //             marketId: marketId,
    // //             aTokenAmountIn: aTokenAmount / 2,
    // //             zTokenAmountIn: zTokenAmount / 2,
    // //
    // //             to: address(this),
    // //             minAmountOut: 0
    // //         })
    // //     );
    // // }

    // // function test_Swap_event_emission() external {
    // //     Covenant covenantCore = new Covenant(address(this));
    // //     address lexImplementation = address(
    // //         new LatentSwapLEX(address(this),address(covenantCore), P_MAX, P_MIN,  P_LIM_H, P_LIM_MAX, 0)
    // //     );
    // //     covenantCore.setEnabledLEX(lexImplementation, true);
    // //     covenantCore.setEnabledCurator(_mockOracle, true);
    // //

    // //     bytes32 marketId = covenantCore.initMarket(
    // //         InitMarketParams({
    // //             baseToken: IERC20(_mockBaseAsset),
    // //             quoteToken: IERC20(_mockQuoteAsset),
    // //             curator:IPriceOracle(_mockOracle),
    // //             debtDuration: 7776000,
    // //             lex: ILiquidExchangeModel(lexImplementation),
    // //             lexInitParams: abi.encode(LatentSwapLEX_InitParams({debtPriceDiscountBalanced: 990000000000000000}))
    // //         })
    // //     );

    // //     uint256 baseAmountIn = 1 * 10 ** 18;
    // //     IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn << 10);

    // //     (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
    // //         MintParams({
    // //             marketId: marketId,
    // //             baseAmountIn: baseAmountIn,
    // //
    // //             to: address(this),
    // //             minATokenAmountOut: 0,
    // //             minZTokenAmountOut: 0
    // //         })
    // //     );

    // //     MarketConfig memory market = covenantCore.getMarketConfig(marketId);

    // //     // Calculate expected swap amount
    // //     (uint256 aTokenAmountOut, uint256 zTokenAmountOut) = covenantCore.quoteSwap(
    // //         SwapParams({
    // //             marketId: marketId,
    // //             assetIn: address(market.aToken),
    // //             assetOut: address(market.zToken),
    // //
    // //             to: address(this),
    // //             amount: 1 * 10 ** 16,
    // //             amountLimit: 0,
    // //             swapType: SwapType.EXACT_IN
    // //         })
    // //     );

    // //     // Test Swap event emission
    // //     vm.expectEmit(true, true, true, true);
    // //     emit Swap(marketId, address(this), address(this), aTokenAmountOut, zTokenAmountOut);
    // //     covenantCore.swap(
    // //         SwapParams({
    // //             marketId: marketId,
    // //             assetIn: address(market.aToken),
    // //             assetOut: address(market.zToken),
    // //
    // //             to: address(this),
    // //             amount: 1 * 10 ** 16,
    // //             amountLimit: 0,
    // //             swapType: SwapType.EXACT_IN
    // //         })
    // //     );
    // // }

    // /////////////////////////////////////////////////////////////////////////////////////////////
    // // Return Value Tests
    // /////////////////////////////////////////////////////////////////////////////////////////////

    function test_getMarketConfig_return_value() external {
        Covenant covenantCore = new Covenant(address(this));
        // deploy lex implementation
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Test getMarketConfig returns correct values
        MarketParams memory MarketParamsGet = covenantCore.getIdToMarketParams(marketId);

        assertEq(MarketParamsGet.baseToken, _mockBaseAsset, "Base token should match");
        assertEq(MarketParamsGet.quoteToken, _mockQuoteAsset, "Quote token should match");
        assertEq(MarketParamsGet.curator, _mockOracle, "Oracle should match");
        assertEq(MarketParamsGet.lex, lexImplementation, "LEX should match");
    }

    // /////////////////////////////////////////////////////////////////////////////////////////////
    // // Edge Cases and Error Conditions
    // /////////////////////////////////////////////////////////////////////////////////////////////

    function test_market_locked_views() external {
        Covenant covenantCore = new Covenant(address(this));
        // deploy lex implementation
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Test that non-existent market reverts
        MarketId nonExistentMarketId = MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(999))))));

        vm.expectRevert(Errors.E_MarketNonExistent.selector);
        covenantCore.previewMint(
            MintParams({
                marketId: nonExistentMarketId,
                marketParams: marketParams,
                baseAmountIn: 1 * 10 ** 18,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        vm.expectRevert(Errors.E_MarketNonExistent.selector);
        covenantCore.previewRedeem(
            RedeemParams({
                marketId: nonExistentMarketId,
                marketParams: marketParams,
                aTokenAmountIn: 1 * 10 ** 16,
                zTokenAmountIn: 1 * 10 ** 16,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        vm.expectRevert(Errors.E_MarketNonExistent.selector);
        covenantCore.previewSwap(
            SwapParams({
                marketId: nonExistentMarketId,
                marketParams: marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: 1 * 10 ** 18,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );
    }

    function test_previewMint_zero_amount() external {
        Covenant covenantCore = new Covenant(address(this));
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Test previewMint with zero amount
        vm.expectRevert(Errors.E_ZeroAmount.selector);
        (uint256 aTokenAmountOut, uint256 zTokenAmountOut, , , ) = covenantCore.previewMint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: 0,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );
    }

    function test_previewRedeem_zero_amount() external {
        Covenant covenantCore = new Covenant(address(this));
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Mint
        IERC20(_mockBaseAsset).approve(address(covenantCore), 1e18);
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: 1e18,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test previewRedeem with zero amounts
        vm.expectRevert(Errors.E_ZeroAmount.selector);
        (uint256 amountOut, , , ) = covenantCore.previewRedeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: 0,
                zTokenAmountIn: 0,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );
    }

    function test_previewSwap_edge_cases() external {
        uint256 baseAmountIn = 1 * 10 ** 18;

        Covenant covenantCore = new Covenant(address(this));
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Test previewSwap with zero liquidity in market
        vm.expectRevert();
        covenantCore.previewSwap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: 100,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );

        // Mint
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test revert 0 amount being swapped
        vm.expectRevert(Errors.E_ZeroAmount.selector);
        (uint256 amountCalc, , , ) = covenantCore.previewSwap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: 0,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );

        // Test previewSwap with same asset in and out (should revert)
        vm.expectRevert(Errors.E_EqualSwapAssets.selector);
        covenantCore.previewSwap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: 10,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );
    }

    // /////////////////////////////////////////////////////////////////////////////////////////////
    // // Reentrancy Protection Tests
    // /////////////////////////////////////////////////////////////////////////////////////////////

    function test_reentrancy_protection() external {
        Covenant covenantCore = new Covenant(address(this));
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Test that market is unlocked after initialization
        MarketState memory marketState = covenantCore.getMarketState(marketId);
        assertEq(marketState.statusFlag, 1, "Market should be unlocked after initialization");

        // Test that non-existent market is locked
        marketState = covenantCore.getMarketState(MarketId.wrap(bytes20(uint160(uint256(keccak256(abi.encode(999)))))));
        assertEq(marketState.statusFlag, 0, "Market should be locked if not initialized");
    }

    // /////////////////////////////////////////////////////////////////////////////////////////////
    // // NoDelegateCall Protection Tests
    // /////////////////////////////////////////////////////////////////////////////////////////////

    function test_noDelegateCall_protection() external {
        Covenant covenantCore = new Covenant(address(this));
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Test that functions with noDelegateCall modifier work normally when called directly
        uint256 baseAmountIn = 1 * 10 ** 18;
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // These should work normally (no delegate call)
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test that delegate calls are properly prevented
        // Create a contract that will attempt to delegate call to the covenant core
        DelegateCallTester delegateCallTester = new DelegateCallTester();

        // Test that delegate call to mint function reverts
        vm.expectRevert(abi.encodeWithSignature("E_DelegateCallNotAllowed()"));
        delegateCallTester.helpDelegateCall(
            address(covenantCore),
            abi.encodeWithSelector(
                covenantCore.mint.selector,
                MintParams({
                    marketId: marketId,
                    marketParams: marketParams,
                    baseAmountIn: baseAmountIn,
                    to: address(this),
                    minATokenAmountOut: 0,
                    minZTokenAmountOut: 0,
                    data: hex"",
                    msgValue: 0
                })
            )
        );

        vm.expectRevert(abi.encodeWithSignature("E_DelegateCallNotAllowed()"));
        delegateCallTester.helpDelegateCall(
            address(covenantCore),
            abi.encodeWithSelector(
                covenantCore.redeem.selector,
                RedeemParams({
                    marketId: marketId,
                    marketParams: marketParams,
                    aTokenAmountIn: aTokenAmount / 2,
                    zTokenAmountIn: zTokenAmount / 2,
                    to: address(this),
                    minAmountOut: 0,
                    data: hex"",
                    msgValue: 0
                })
            )
        );
        // Test that delegate call to swap function reverts
        vm.expectRevert(abi.encodeWithSignature("E_DelegateCallNotAllowed()"));
        delegateCallTester.helpDelegateCall(
            address(covenantCore),
            abi.encodeWithSelector(
                covenantCore.swap.selector,
                SwapParams({
                    marketId: marketId,
                    marketParams: marketParams,
                    assetIn: AssetType.LEVERAGE,
                    assetOut: AssetType.DEBT,
                    to: address(this),
                    amountSpecified: 1 * 10 ** 16,
                    amountLimit: 0,
                    isExactIn: true,
                    data: hex"",
                    msgValue: 0
                })
            )
        );
        // Test that delegate call to view functions with noDelegateCall modifier reverts
        vm.expectRevert(abi.encodeWithSignature("E_DelegateCallNotAllowed()"));
        delegateCallTester.helpDelegateCall(
            address(covenantCore),
            abi.encodeWithSelector(
                covenantCore.previewMint.selector,
                MintParams({
                    marketId: marketId,
                    marketParams: marketParams,
                    baseAmountIn: 1 * 10 ** 18,
                    to: address(this),
                    minATokenAmountOut: 0,
                    minZTokenAmountOut: 0,
                    data: hex"",
                    msgValue: 0
                })
            )
        );
        vm.expectRevert(abi.encodeWithSignature("E_DelegateCallNotAllowed()"));
        delegateCallTester.helpDelegateCall(
            address(covenantCore),
            abi.encodeWithSelector(
                covenantCore.previewRedeem.selector,
                RedeemParams({
                    marketId: marketId,
                    marketParams: marketParams,
                    aTokenAmountIn: 1 * 10 ** 16,
                    zTokenAmountIn: 1 * 10 ** 16,
                    to: address(this),
                    minAmountOut: 0,
                    data: hex"",
                    msgValue: 0
                })
            )
        );

        vm.expectRevert(abi.encodeWithSignature("E_DelegateCallNotAllowed()"));
        delegateCallTester.helpDelegateCall(
            address(covenantCore),
            abi.encodeWithSelector(
                covenantCore.previewSwap.selector,
                SwapParams({
                    marketId: marketId,
                    marketParams: marketParams,
                    assetIn: AssetType.LEVERAGE,
                    assetOut: AssetType.DEBT,
                    to: address(this),
                    amountSpecified: 1 * 10 ** 16,
                    amountLimit: 0,
                    isExactIn: true,
                    data: hex"",
                    msgValue: 0
                })
            )
        );
    }

    ////////////////////////////////////////////////////////////////////////////
    // Market Pausing Tests
    ////////////////////////////////////////////////////////////////////////////

    function test_pauseMarket_AdminPermissions() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        address pauseAdmin = address(0x123);
        address nonPauseAdmin = address(0x456);

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // create market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test: Only owner can set default pause address
        vm.prank(nonPauseAdmin);
        vm.expectRevert();
        covenantCore.setDefaultPauseAddress(pauseAdmin);

        // Set default pause address as owner
        covenantCore.setDefaultPauseAddress(pauseAdmin);

        // Test: Only owner can set market pause address
        vm.prank(nonPauseAdmin);
        vm.expectRevert();
        covenantCore.setMarketPauseAddress(marketId, pauseAdmin);

        // Set market pause address as owner
        covenantCore.setMarketPauseAddress(marketId, pauseAdmin);

        // Test: Only authorized pause address can pause market
        vm.prank(nonPauseAdmin);
        vm.expectRevert(Errors.E_Unauthorized.selector);
        covenantCore.setMarketPause(marketId, true);

        // Test: Authorized pause address can pause market
        vm.prank(pauseAdmin);
        covenantCore.setMarketPause(marketId, true);

        // Verify market is paused
        MarketState memory marketState = covenantCore.getMarketState(marketId);
        assertEq(marketState.statusFlag, 3, "Market should be paused");

        // Test: Only authorized pause address can unpause market
        vm.prank(nonPauseAdmin);
        vm.expectRevert(Errors.E_Unauthorized.selector);
        covenantCore.setMarketPause(marketId, false);

        // Test: Authorized pause address can unpause market
        vm.prank(pauseAdmin);
        covenantCore.setMarketPause(marketId, false);

        // Verify market is unpaused
        marketState = covenantCore.getMarketState(marketId);
        assertEq(marketState.statusFlag, 1, "Market should be unlocked");
    }

    function test_pauseMarket_WriteFunctionsPaused() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        address pauseAdmin = address(0x123);
        uint256 baseAmountIn = 1 * 10 ** 18;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // create market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Set pause admin and pause market
        covenantCore.setDefaultPauseAddress(pauseAdmin);
        covenantCore.setMarketPauseAddress(marketId, pauseAdmin);
        vm.prank(pauseAdmin);
        covenantCore.setMarketPause(marketId, true);

        // Approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // Test: Mint function should be paused
        vm.expectRevert(Errors.E_MarketPaused.selector);
        covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test: Redeem function should be paused
        vm.expectRevert(Errors.E_MarketPaused.selector);
        covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: 0,
                zTokenAmountIn: 0,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test: Swap function should be paused
        vm.expectRevert(Errors.E_MarketPaused.selector);
        covenantCore.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.BASE,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: baseAmountIn,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );

        // Test: UpdateState function should be paused
        vm.expectRevert(Errors.E_MarketPaused.selector);
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        // Test: SetMarketProtocolFee function should be paused
        vm.expectRevert(Errors.E_MarketPaused.selector);
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, 5);

        // Test: CollectProtocol function should be paused
        vm.expectRevert(Errors.E_MarketPaused.selector);
        covenantCore.collectProtocolFee(marketId, address(this), 1000);
    }

    function test_pauseMarket_ViewFunctionsWorkWhenPaused() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        address pauseAdmin = address(0x123);

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // create market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Set pause admin and pause market
        covenantCore.setDefaultPauseAddress(pauseAdmin);
        covenantCore.setMarketPauseAddress(marketId, pauseAdmin);
        vm.prank(pauseAdmin);
        covenantCore.setMarketPause(marketId, true);

        // Test: View functions should still work when market is paused
        MarketParams memory retrievedParams = covenantCore.getIdToMarketParams(marketId);
        assertEq(retrievedParams.baseToken, _mockBaseAsset, "Base token should be retrievable");
        assertEq(retrievedParams.quoteToken, _mockQuoteAsset, "Quote token should be retrievable");
        assertEq(retrievedParams.curator, _mockOracle, "Oracle should be retrievable");
        assertEq(retrievedParams.lex, lexImplementation, "LEX should be retrievable");

        MarketState memory marketState = covenantCore.getMarketState(marketId);
        assertEq(marketState.statusFlag, 3, "Market state should show paused status");
        assertEq(marketState.authorizedPauseAddress, pauseAdmin, "Pause address should be retrievable");

        // Test: Preview functions should still work (they're view functions)
        uint256 baseAmountIn = 1 * 10 ** 18;
        (uint256 previewATokenAmount, uint256 previewZTokenAmount, , , ) = covenantCore.previewMint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );
        assertTrue(previewATokenAmount > 0, "Preview mint should work when paused");
        assertTrue(previewZTokenAmount > 0, "Preview mint should work when paused");
    }

    function test_pauseMarket_DefaultPauseAddress() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        address newDefaultPause = address(0x789);

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test: Default pause address should be set to owner initially
        covenantCore.setDefaultPauseAddress(newDefaultPause);

        // create market - should inherit default pause address
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Verify market inherited default pause address
        MarketState memory marketState = covenantCore.getMarketState(marketId);
        assertEq(marketState.authorizedPauseAddress, newDefaultPause, "Market should inherit default pause address");

        // Test: New default pause address can pause market
        vm.prank(newDefaultPause);
        covenantCore.setMarketPause(marketId, true);

        // Verify market is paused
        marketState = covenantCore.getMarketState(marketId);
        assertEq(marketState.statusFlag, 3, "Market should be paused by new default pause address");
    }

    function test_pauseMarket_EventsEmitted() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        address pauseAdmin = address(0x123);

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // create market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Set pause admin
        covenantCore.setDefaultPauseAddress(pauseAdmin);
        covenantCore.setMarketPauseAddress(marketId, pauseAdmin);

        // Test: Pause event should be emitted
        vm.prank(pauseAdmin);
        vm.expectEmit(true, false, false, false);
        emit Events.MarketPaused(marketId, true);
        covenantCore.setMarketPause(marketId, true);

        // Test: Unpause event should be emitted
        vm.prank(pauseAdmin);
        vm.expectEmit(true, false, false, false);
        emit Events.MarketPaused(marketId, false);
        covenantCore.setMarketPause(marketId, false);

        // Test: UpdateDefaultPauseAddress event should be emitted
        address newDefaultPause = address(0x456);
        vm.expectEmit(false, false, false, false);
        emit Events.UpdateDefaultPauseAddress(pauseAdmin, newDefaultPause);
        covenantCore.setDefaultPauseAddress(newDefaultPause);

        // Test: UpdateMarketPauseAddress event should be emitted
        address newMarketPause = address(0x789);
        vm.expectEmit(true, false, false, false);
        emit Events.UpdateMarketPauseAddress(marketId, pauseAdmin, newMarketPause);
        covenantCore.setMarketPauseAddress(marketId, newMarketPause);
    }

    function test_pauseMarket_ReentrancyProtection() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        address pauseAdmin = address(0x123);

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // create market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Set pause admin
        covenantCore.setDefaultPauseAddress(pauseAdmin);
        covenantCore.setMarketPauseAddress(marketId, pauseAdmin);

        // Test: Pause function should not allow delegate calls
        DelegateCallTester delegateCallTester = new DelegateCallTester();
        bytes memory pauseData = abi.encodeWithSelector(covenantCore.setMarketPause.selector, marketId, true);

        vm.expectRevert();
        delegateCallTester.helpDelegateCall(address(covenantCore), pauseData);
    }

    function test_excessRedeem() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        uint256 aTokenAmount;
        uint256 zTokenAmount;
        uint256 baseAmountOut;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // set market fee to 100
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, 100);

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // mint
        (aTokenAmount, zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // This would be the actual amount out if we redeemed
        (uint256 previewBaseAmountOut, , , ) = covenantCore.previewRedeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount >> 8,
                zTokenAmountIn: zTokenAmount >> 8,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Let's pass some time
        vm.warp(block.timestamp + 30 days);

        // Now, let's redeem with the same amounts as the preview
        baseAmountOut = covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount >> 8,
                zTokenAmountIn: zTokenAmount >> 8,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // This would be a mismatch, however, if we hadn't updated the state, the preview would match
        assertNotEq(baseAmountOut, previewBaseAmountOut, "Actual base amount out does not match preview");
    }

    function test_redeem_cap_on_swap() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 10 * 10 ** 18;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        uint32 newFee = 255; // 2.55%
        covenantCore.setDefaultFee(newFee);
        //set base token e.g;WETH price to $2k
        MockOracle(_mockOracle).setPrice(2000 * (10 ** 18));

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");
        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        //user 01 mint first

        (uint256 aTokenAmount_user01, uint256 zTokenAmount_user01) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn, //10 WETH
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        //Update State - after 30 min
        vm.warp(block.timestamp + 3600);
        covenantCore.updateState(marketId, marketParams, hex"", 0);
        vm.warp(block.timestamp + 3600);
        covenantCore.updateState(marketId, marketParams, hex"", 0);
        vm.warp(block.timestamp + 3600);
        covenantCore.updateState(marketId, marketParams, hex"", 0);
        vm.warp(block.timestamp + 3600);
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        address user_02 = address(0x123);
        IERC20(_mockBaseAsset).transfer(user_02, baseAmountIn);
        vm.startPrank(user_02);
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        (uint256 aTokenAmount_user02, uint256 zTokenAmount_user02) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams, //10 WETH
                baseAmountIn: baseAmountIn / 2,
                to: address(user_02),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );
        vm.stopPrank();

        //Update State - after 15 days and price drop
        vm.warp(block.timestamp + 1 days);
        covenantCore.updateState(marketId, marketParams, hex"", 0);
        vm.warp(block.timestamp + 1 days);
        covenantCore.updateState(marketId, marketParams, hex"", 0);
        vm.warp(block.timestamp + 1 days);
        covenantCore.updateState(marketId, marketParams, hex"", 0);
        vm.warp(block.timestamp + 12 days);
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        // change price from $2k to $1.2k
        MockOracle(_mockOracle).setPrice(1200 * (10 ** 18));
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        //redeem
        uint256 baseAmountOut = covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount_user01 / 2,
                zTokenAmountIn: zTokenAmount_user02 / 2,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        //User ask to burn `aTokenAmount_user02 / 2` of zTokens.
        //Tx will revert, because of the redeem cap exceeded in lex contract
        vm.expectRevert(LSErrors.E_LEX_RedeemCapExceeded.selector);

        //failed redeem
        baseAmountOut = covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: 0,
                zTokenAmountIn: zTokenAmount_user02 / 2,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        //User ask to burn `aTokenAmount_user02` of zTokens.
        //Tx will revert, because of the redeem cap exceeded in lex contract
        vm.expectRevert(LSErrors.E_LEX_RedeemCapExceeded.selector);
        uint256 swapAmountOut = covenantCore.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.DEBT,
                assetOut: AssetType.BASE,
                to: address(this),
                amountSpecified: zTokenAmount_user02, //zTokens
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );
    }

    function test_mint_cap_on_swap() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 10 * 10 ** 18;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        uint32 newFee = 255; // 2.55%
        covenantCore.setDefaultFee(newFee);
        //set base token e.g;WETH price to $2k
        MockOracle(_mockOracle).setPrice(2000 * (10 ** 18));

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");
        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        //user 01 mint first

        (uint256 aTokenAmount_user01, uint256 zTokenAmount_user01) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn, //10 WETH
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        //Update State - after 30 min
        vm.warp(block.timestamp + 3600);
        covenantCore.updateState(marketId, marketParams, hex"", 0);
        vm.warp(block.timestamp + 3600);
        covenantCore.updateState(marketId, marketParams, hex"", 0);
        vm.warp(block.timestamp + 3600);
        covenantCore.updateState(marketId, marketParams, hex"", 0);
        vm.warp(block.timestamp + 3600);
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        address user_02 = address(0x123);
        IERC20(_mockBaseAsset).transfer(user_02, baseAmountIn);
        vm.startPrank(user_02);
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        (uint256 aTokenAmount_user02, uint256 zTokenAmount_user02) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams, //10 WETH
                baseAmountIn: baseAmountIn / 2,
                to: address(user_02),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );
        vm.stopPrank();

        //User ask to burn `aTokenAmount_user02` of zTokens.
        //Tx will revert, because of the mint cap exceeded in lex contract
        vm.expectRevert(LSErrors.E_LEX_MintCapExceeded.selector);
        uint256 swapAmountOut = covenantCore.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.BASE,
                assetOut: AssetType.LEVERAGE,
                to: address(this),
                amountSpecified: zTokenAmount_user02, //zTokens
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Data and msgValue Flow Tests
    /////////////////////////////////////////////////////////////////////////////////////////////

    function test_mint_withDataAndMsgValue() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        bytes memory testData = abi.encode("test_data_for_mint", 12345);
        uint256 testMsgValue = 0.1 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // mint with data and msgValue
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint{value: testMsgValue}(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: testData,
                msgValue: testMsgValue
            })
        );

        // Verify mint was successful
        assertGt(aTokenAmount, 0, "Mint should succeed");
        assertGt(zTokenAmount, 0, "Mint should succeed");

        // Verify oracle received the data and msgValue
        (bytes memory receivedData, uint256 receivedMsgValue, uint256 callCount) = MockOracle(_mockOracle)
            .getLastCallInfo();
        assertEq(callCount, 1, "Oracle should be called once");
        assertEq(receivedData, testData, "Oracle should receive correct data");
        assertEq(receivedMsgValue, testMsgValue, "Oracle should receive correct msgValue");

        // Verify oracle actually received the ETH
        (
            bytes memory data,
            uint256 msgValue,
            uint256 calls,
            uint256 balanceBefore,
            uint256 balanceAfter,
            uint256 balanceIncrease
        ) = MockOracle(_mockOracle).getLastCallInfoWithBalance();
        assertEq(balanceIncrease, testMsgValue, "Oracle balance should increase by the msgValue amount");
        assertEq(balanceAfter - balanceBefore, testMsgValue, "Oracle should actually receive the ETH");
    }

    function test_mint_withDataButNoMsgValue() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        bytes memory testData = abi.encode("test_data_no_eth", 67890);

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // mint with data but no msgValue
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: testData,
                msgValue: 0
            })
        );

        // Verify mint was successful
        assertGt(aTokenAmount, 0, "Mint should succeed");
        assertGt(zTokenAmount, 0, "Mint should succeed");

        // Verify oracle received the data but no msgValue
        (bytes memory receivedData, uint256 receivedMsgValue, uint256 callCount) = MockOracle(_mockOracle)
            .getLastCallInfo();
        assertEq(callCount, 1, "Oracle should be called once");
        assertEq(receivedData, testData, "Oracle should receive correct data");
        assertEq(receivedMsgValue, 0, "Oracle should receive no msgValue");
    }

    function test_mint_withMsgValueButNoData() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        uint256 testMsgValue = 0.05 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // mint with msgValue but no data - should revert due to incorrect msgValue
        vm.expectRevert(LSErrors.E_LEX_Overdeposit.selector);
        covenantCore.mint{value: testMsgValue}(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: testMsgValue
            })
        );
    }

    function test_redeem_withDataAndMsgValue() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        bytes memory testData = abi.encode("test_data_for_redeem", 54321);
        uint256 testMsgValue = 0.2 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom and mint first
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // redeem with data and msgValue
        uint256 baseAmountOut = covenantCore.redeem{value: testMsgValue}(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount / 2,
                zTokenAmountIn: zTokenAmount / 2,
                to: address(this),
                minAmountOut: 0,
                data: testData,
                msgValue: testMsgValue
            })
        );

        // Verify redeem was successful
        assertGt(baseAmountOut, 0, "Redeem should succeed");

        // Verify oracle received the data and msgValue
        (bytes memory receivedData, uint256 receivedMsgValue, uint256 callCount) = MockOracle(_mockOracle)
            .getLastCallInfo();
        assertEq(callCount, 1, "Oracle should be called once");
        assertEq(receivedData, testData, "Oracle should receive correct data");
        assertEq(receivedMsgValue, testMsgValue, "Oracle should receive correct msgValue");
    }

    function test_redeem_withDataButNoMsgValue() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        bytes memory testData = abi.encode("test_data_redeem_no_eth", 98765);

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom and mint first
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // redeem with data but no msgValue
        uint256 baseAmountOut = covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount / 2,
                zTokenAmountIn: zTokenAmount / 2,
                to: address(this),
                minAmountOut: 0,
                data: testData,
                msgValue: 0
            })
        );

        // Verify redeem was successful
        assertGt(baseAmountOut, 0, "Redeem should succeed");

        // Verify oracle received the data but no msgValue
        (bytes memory receivedData, uint256 receivedMsgValue, uint256 callCount) = MockOracle(_mockOracle)
            .getLastCallInfo();
        assertEq(callCount, 1, "Oracle should be called once");
        assertEq(receivedData, testData, "Oracle should receive correct data");
        assertEq(receivedMsgValue, 0, "Oracle should receive no msgValue");
    }

    function test_swap_withDataAndMsgValue() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        uint256 swapAmount = 10 ** 16;
        bytes memory testData = abi.encode("test_data_for_swap", 11111);
        uint256 testMsgValue = 0.15 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom and mint first
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // allow for time (to reset mint cap)
        vm.warp(block.timestamp + 1 days);
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        // Get market info
        SynthTokens memory synthTokens = ILiquidExchangeModel(marketParams.lex).getSynthTokens(marketId);

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // swap with data and msgValue
        uint256 swapAmountOut = covenantCore.swap{value: testMsgValue}(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: swapAmount,
                amountLimit: 0,
                isExactIn: true,
                data: testData,
                msgValue: testMsgValue
            })
        );

        // Verify swap was successful
        assertGt(swapAmountOut, 0, "Swap should succeed");

        // Verify oracle received the data and msgValue
        (bytes memory receivedData, uint256 receivedMsgValue, uint256 callCount) = MockOracle(_mockOracle)
            .getLastCallInfo();
        assertEq(callCount, 1, "Oracle should be called once");
        assertEq(receivedData, testData, "Oracle should receive correct data");
        assertEq(receivedMsgValue, testMsgValue, "Oracle should receive correct msgValue");
    }

    function test_swap_withDataButNoMsgValue() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        uint256 swapAmount = 10 ** 16;
        bytes memory testData = abi.encode("test_data_swap_no_eth", 22222);

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom and mint first
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // allow for time (to reset mint cap)
        vm.warp(block.timestamp + 1 days);
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // swap with data but no msgValue
        uint256 swapAmountOut = covenantCore.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: swapAmount,
                amountLimit: 0,
                isExactIn: true,
                data: testData,
                msgValue: 0
            })
        );

        // Verify swap was successful
        assertGt(swapAmountOut, 0, "Swap should succeed");

        // Verify oracle received the data but no msgValue
        (bytes memory receivedData, uint256 receivedMsgValue, uint256 callCount) = MockOracle(_mockOracle)
            .getLastCallInfo();
        assertEq(callCount, 1, "Oracle should be called once");
        assertEq(receivedData, testData, "Oracle should receive correct data");
        assertEq(receivedMsgValue, 0, "Oracle should receive no msgValue");
    }

    function test_updateState_withDataAndMsgValue() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        bytes memory testData = abi.encode("test_data_for_updateState", 33333);
        uint256 testMsgValue = 0.25 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // updateState with data and msgValue
        covenantCore.updateState{value: testMsgValue}(marketId, marketParams, testData, testMsgValue);

        // Verify oracle received the data and msgValue
        (bytes memory receivedData, uint256 receivedMsgValue, uint256 callCount) = MockOracle(_mockOracle)
            .getLastCallInfo();
        assertEq(callCount, 1, "Oracle should be called once");
        assertEq(receivedData, testData, "Oracle should receive correct data");
        assertEq(receivedMsgValue, testMsgValue, "Oracle should receive correct msgValue");
    }

    function test_updateState_withDataButNoMsgValue() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        bytes memory testData = abi.encode("test_data_updateState_no_eth", 44444);

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // updateState with data but no msgValue
        covenantCore.updateState(marketId, marketParams, testData, 0);

        // Verify oracle received the data but no msgValue
        (bytes memory receivedData, uint256 receivedMsgValue, uint256 callCount) = MockOracle(_mockOracle)
            .getLastCallInfo();
        assertEq(callCount, 1, "Oracle should be called once");
        assertEq(receivedData, testData, "Oracle should receive correct data");
        assertEq(receivedMsgValue, 0, "Oracle should receive no msgValue");
    }

    function test_updateState_withMsgValueButNoData() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 testMsgValue = 0.1 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
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
        covenantCore.setEnabledLEX(lexImplementation, true);

        // authorize oracle
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // updateState with msgValue but no data - should revert due to incorrect msgValue
        vm.expectRevert(LSErrors.E_LEX_Overdeposit.selector);
        covenantCore.updateState{value: testMsgValue}(marketId, marketParams, hex"", testMsgValue);
    }

    function test_multipleOperationsDataFlow() external {
        Covenant covenantCore = new Covenant(address(this));
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), 1 * 10 ** 18);

        // 1. Mint with data
        bytes memory mintData = abi.encode("mint_data", 1);
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: 1 * 10 ** 18,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: mintData,
                msgValue: 0
            })
        );

        // Verify mint data was received
        (bytes memory receivedData, , uint256 callCount) = MockOracle(_mockOracle).getLastCallInfo();
        assertEq(callCount, 1, "Oracle should be called once for mint");
        assertEq(receivedData, mintData, "Oracle should receive mint data");

        // 2. UpdateState with data
        bytes memory updateData = abi.encode("update_data", 2);
        covenantCore.updateState(marketId, marketParams, updateData, 0);

        // Verify updateState data was received
        (receivedData, , callCount) = MockOracle(_mockOracle).getLastCallInfo();
        assertEq(callCount, 2, "Oracle should be called twice total");
        assertEq(receivedData, updateData, "Oracle should receive updateState data");

        // 3. Swap with data
        vm.warp(block.timestamp + 1 days);
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        bytes memory swapData = abi.encode("swap_data", 3);
        covenantCore.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: 10 ** 16,
                amountLimit: 0,
                isExactIn: true,
                data: swapData,
                msgValue: 0
            })
        );

        // Verify swap data was received
        (receivedData, , callCount) = MockOracle(_mockOracle).getLastCallInfo();
        assertEq(callCount, 3, "Oracle should be called three times total");
        assertEq(receivedData, swapData, "Oracle should receive swap data");

        // 4. Redeem with data
        bytes memory redeemData = abi.encode("redeem_data", 4);
        covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount / 4,
                zTokenAmountIn: zTokenAmount / 4,
                to: address(this),
                minAmountOut: 0,
                data: redeemData,
                msgValue: 0
            })
        );

        // Verify redeem data was received
        (receivedData, , callCount) = MockOracle(_mockOracle).getLastCallInfo();
        assertEq(callCount, 4, "Oracle should be called four times total");
        assertEq(receivedData, redeemData, "Oracle should receive redeem data");
    }

    function test_oracleReceivesETH() external {
        Covenant covenantCore = new Covenant(address(this));
        address lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        MarketId marketId = covenantCore.createMarket(marketParams, hex"");

        // Get initial oracle balance
        uint256 initialOracleBalance = address(_mockOracle).balance;

        // Reset oracle tracking
        MockOracle(_mockOracle).resetTracking();

        // Test with different ETH amounts
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 0.01 ether;
        testAmounts[1] = 0.1 ether;
        testAmounts[2] = 0.5 ether;

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 testAmount = testAmounts[i];
            bytes memory testData = abi.encode("eth_test", i, testAmount);

            // Send ETH to oracle via updateState
            covenantCore.updateState{value: testAmount}(marketId, marketParams, testData, testAmount);

            // Verify oracle received the ETH
            uint256 currentOracleBalance = address(_mockOracle).balance;
            uint256 expectedBalance = initialOracleBalance + testAmount;

            assertEq(currentOracleBalance, expectedBalance, "Oracle balance should increase by the sent amount");

            // Verify tracking shows correct balance change
            (
                bytes memory data,
                uint256 msgValue,
                uint256 calls,
                uint256 balanceBefore,
                uint256 balanceAfter,
                uint256 balanceIncrease
            ) = MockOracle(_mockOracle).getLastCallInfoWithBalance();

            assertEq(balanceIncrease, testAmount, "Balance increase should match sent amount");
            assertEq(msgValue, testAmount, "MsgValue should match sent amount");
            assertEq(data, testData, "Data should match sent data");

            // Update initial balance for next iteration
            initialOracleBalance = currentOracleBalance;
        }
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Overdeposit Protection Tests
    /////////////////////////////////////////////////////////////////////////////////////////////

    function test_mint_overdepositProtection() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        uint256 excessEth = 0.1 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom for all tests (3x baseAmountIn)
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn * 3);

        // Test 1: Mint with no msgValue should work
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        assertGt(aTokenAmount, 0, "Mint should succeed with no msgValue");
        assertGt(zTokenAmount, 0, "Mint should succeed with no msgValue");

        // Test 2: Mint with excess ETH should revert
        vm.expectRevert(Errors.E_IncorrectPayment.selector);
        covenantCore.mint{value: excessEth}(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test 3: Mint with correct msgValue should work
        bytes memory testData = abi.encode("test_data");
        (aTokenAmount, zTokenAmount) = covenantCore.mint{value: excessEth}(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: testData,
                msgValue: excessEth
            })
        );

        assertGt(aTokenAmount, 0, "Mint should succeed with correct msgValue");
        assertGt(zTokenAmount, 0, "Mint should succeed with correct msgValue");
    }

    function test_redeem_overdepositProtection() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        uint256 excessEth = 0.1 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom and mint first
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test 1: Redeem with no msgValue should work
        uint256 baseAmountOut = covenantCore.redeem(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount / 2,
                zTokenAmountIn: zTokenAmount / 2,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        assertGt(baseAmountOut, 0, "Redeem should succeed with no msgValue");

        // Test 2: Redeem with excess ETH should revert
        vm.expectRevert(Errors.E_IncorrectPayment.selector);
        covenantCore.redeem{value: excessEth}(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount / 4,
                zTokenAmountIn: zTokenAmount / 4,
                to: address(this),
                minAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test 3: Redeem with correct msgValue should work
        bytes memory testData = abi.encode("test_data");
        baseAmountOut = covenantCore.redeem{value: excessEth}(
            RedeemParams({
                marketId: marketId,
                marketParams: marketParams,
                aTokenAmountIn: aTokenAmount / 4,
                zTokenAmountIn: zTokenAmount / 4,
                to: address(this),
                minAmountOut: 0,
                data: testData,
                msgValue: excessEth
            })
        );

        assertGt(baseAmountOut, 0, "Redeem should succeed with correct msgValue");
    }

    function test_swap_overdepositProtection() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        uint256 swapAmount = 10 ** 16;
        uint256 excessEth = 0.1 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom and mint first
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // allow for time (to reset mint cap)
        vm.warp(block.timestamp + 1 days);
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        // Test 1: Swap with no msgValue should work
        uint256 swapAmountOut = covenantCore.swap(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: swapAmount,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );

        assertGt(swapAmountOut, 0, "Swap should succeed with no msgValue");

        // Test 2: Swap with excess ETH should revert
        vm.expectRevert(Errors.E_IncorrectPayment.selector);
        covenantCore.swap{value: excessEth}(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: swapAmount,
                amountLimit: 0,
                isExactIn: true,
                data: hex"",
                msgValue: 0
            })
        );

        // Test 3: Swap with correct msgValue should work
        bytes memory testData = abi.encode("test_data");
        swapAmountOut = covenantCore.swap{value: excessEth}(
            SwapParams({
                marketId: marketId,
                marketParams: marketParams,
                assetIn: AssetType.LEVERAGE,
                assetOut: AssetType.DEBT,
                to: address(this),
                amountSpecified: swapAmount,
                amountLimit: 0,
                isExactIn: true,
                data: testData,
                msgValue: excessEth
            })
        );

        assertGt(swapAmountOut, 0, "Swap should succeed with correct msgValue");
    }

    function test_updateState_overdepositProtection() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 excessEth = 0.1 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test 1: UpdateState with no msgValue should work
        covenantCore.updateState(marketId, marketParams, hex"", 0);

        // Test 2: UpdateState with excess ETH should revert
        vm.expectRevert(Errors.E_IncorrectPayment.selector);
        covenantCore.updateState{value: excessEth}(marketId, marketParams, hex"", 0);

        // Test 3: UpdateState with correct msgValue should work
        bytes memory testData = abi.encode("test_data");
        covenantCore.updateState{value: excessEth}(marketId, marketParams, testData, excessEth);
    }

    function test_multicall_overdepositProtection() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;
        uint256 excessEth = 0.1 ether;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom for all tests (3x baseAmountIn)
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn * 3);

        // Test 1: Multicall with no msgValue should work
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            covenantCore.mint.selector,
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );
        covenantCore.multicall(calls);

        // Test 2: Multicall with excess ETH should revert
        calls[0] = abi.encodeWithSelector(
            covenantCore.mint.selector,
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );
        // Multicall does not allow overdeposit
        vm.expectRevert(Errors.E_IncorrectPayment.selector);
        covenantCore.multicall{value: excessEth}(calls);

        // Test 3: Multicall with correct msgValue should work
        calls[0] = abi.encodeWithSelector(
            covenantCore.mint.selector,
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: abi.encode("test_data"),
                msgValue: excessEth
            })
        );
        covenantCore.multicall{value: excessEth}(calls);
    }

    function test_overdepositProtection_edgeCases() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;
        uint256 baseAmountIn = 1 * 10 ** 18;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // approve transferFrom
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);

        // Test 1: Very small excess ETH should still revert
        vm.expectRevert(Errors.E_IncorrectPayment.selector);
        covenantCore.mint{value: 1 wei}(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test 2: Large excess ETH should revert
        vm.expectRevert(Errors.E_IncorrectPayment.selector);
        covenantCore.mint{value: 1 ether}(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Test 3: Exact msgValue should work
        uint256 exactMsgValue = 0.05 ether;
        (uint256 aTokenAmount, uint256 zTokenAmount) = covenantCore.mint{value: exactMsgValue}(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: abi.encode("test_data"),
                msgValue: exactMsgValue
            })
        );

        assertGt(aTokenAmount, 0, "Mint should succeed with exact msgValue");
        assertGt(zTokenAmount, 0, "Mint should succeed with exact msgValue");
    }

    //////////////////////////////////////////////////////////////////////////
    // Protocol Fee Validation Tests
    //////////////////////////////////////////////////////////////////////////

    function test_protocolFeeValidation_ValidFees() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test valid fee combinations
        uint32[] memory validFees = new uint32[](6);
        validFees[0] = UtilsLib.encodeFee(0, 0); // 0% yield, 0% tvl
        validFees[1] = UtilsLib.encodeFee(1000, 100); // 10% yield, 1% tvl
        validFees[2] = UtilsLib.encodeFee(3000, 500); // 30% yield, 5% tvl (max allowed)
        validFees[3] = UtilsLib.encodeFee(1500, 250); // 15% yield, 2.5% tvl
        validFees[4] = UtilsLib.encodeFee(1, 1); // 0.01% yield, 0.01% tvl (min values)
        validFees[5] = UtilsLib.encodeFee(2000, 300); // 20% yield, 3% tvl

        for (uint i = 0; i < validFees.length; i++) {
            // Test setting default fee
            covenantCore.setDefaultFee(validFees[i]);
        }

        // Test creating market with valid fee
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test setting market-specific fees
        for (uint i = 0; i < validFees.length; i++) {
            covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, validFees[i]);
        }
    }

    function test_protocolFeeValidation_InvalidYieldFee() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test invalid yield fees (should revert in LEX implementation)
        uint32[] memory invalidFees = new uint32[](3);
        invalidFees[0] = UtilsLib.encodeFee(3001, 100); // 30.01% yield (exceeds 30% limit)
        invalidFees[1] = UtilsLib.encodeFee(5000, 100); // 50% yield (exceeds 30% limit)
        invalidFees[2] = UtilsLib.encodeFee(10000, 100); // 100% yield (exceeds 30% limit)

        for (uint i = 0; i < invalidFees.length; i++) {
            // Test setting default fee with invalid yield fee
            vm.expectRevert(Errors.E_ProtocolFeeTooHigh.selector);
            covenantCore.setDefaultFee(invalidFees[i]);
        }

        // Create a market with valid fee first
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test setting market-specific fee with invalid yield fee
        for (uint i = 0; i < invalidFees.length; i++) {
            vm.expectRevert(Errors.E_ProtocolFeeTooHigh.selector);
            covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, invalidFees[i]);
        }
    }

    function test_protocolFeeValidation_InvalidTvlFee() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test invalid TVL fees (should revert in LEX implementation)
        uint32[] memory invalidFees = new uint32[](3);
        invalidFees[0] = UtilsLib.encodeFee(1000, 501); // 1% yield, 5.01% tvl (exceeds 5% limit)
        invalidFees[1] = UtilsLib.encodeFee(1000, 1000); // 1% yield, 10% tvl (exceeds 5% limit)
        invalidFees[2] = UtilsLib.encodeFee(1000, 2000); // 1% yield, 20% tvl (exceeds 5% limit)

        for (uint i = 0; i < invalidFees.length; i++) {
            // Test setting default fee with invalid TVL fee
            vm.expectRevert(Errors.E_ProtocolFeeTooHigh.selector);
            covenantCore.setDefaultFee(invalidFees[i]);
        }

        // Create a market with valid fee first
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test setting market-specific fee with invalid TVL fee
        for (uint i = 0; i < invalidFees.length; i++) {
            vm.expectRevert(Errors.E_ProtocolFeeTooHigh.selector);
            covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, invalidFees[i]);
        }
    }

    function test_protocolFeeValidation_MaximumAllowedFees() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test maximum allowed fees (should not revert)
        uint32 maxYieldFee = UtilsLib.encodeFee(3000, 0); // 30% yield, 0% tvl
        uint32 maxTvlFee = UtilsLib.encodeFee(0, 500); // 0% yield, 5% tvl
        uint32 maxBothFees = UtilsLib.encodeFee(3000, 500); // 30% yield, 5% tvl

        // Test setting default fees
        covenantCore.setDefaultFee(maxYieldFee);
        covenantCore.setDefaultFee(maxTvlFee);
        covenantCore.setDefaultFee(maxBothFees);

        // Test creating market with maximum fees
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test setting market-specific fees
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, maxYieldFee);
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, maxTvlFee);
        covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, maxBothFees);
    }

    function test_protocolFeeValidation_FeeEncodingDecoding() external {
        // Test UtilsLib fee encoding and decoding functions
        uint16[] memory yieldFees = new uint16[](5);
        uint16[] memory tvlFees = new uint16[](5);

        yieldFees[0] = 0;
        tvlFees[0] = 0;
        yieldFees[1] = 1000;
        tvlFees[1] = 100;
        yieldFees[2] = 3000;
        tvlFees[2] = 500;
        yieldFees[3] = 1500;
        tvlFees[3] = 250;
        yieldFees[4] = 1;
        tvlFees[4] = 1;

        for (uint i = 0; i < yieldFees.length; i++) {
            // Encode fee
            uint32 encodedFee = UtilsLib.encodeFee(yieldFees[i], tvlFees[i]);

            // Decode fee
            (uint16 decodedYieldFee, uint16 decodedTvlFee) = UtilsLib.decodeFee(encodedFee);

            // Verify round-trip encoding/decoding
            assertEq(decodedYieldFee, yieldFees[i], "Yield fee encoding/decoding mismatch");
            assertEq(decodedTvlFee, tvlFees[i], "TVL fee encoding/decoding mismatch");
        }
    }

    function test_protocolFeeValidation_EdgeCases() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test edge cases
        uint32[] memory edgeCaseFees = new uint32[](4);
        edgeCaseFees[0] = UtilsLib.encodeFee(0, 500); // 0% yield, 5% tvl (max tvl only)
        edgeCaseFees[1] = UtilsLib.encodeFee(3000, 0); // 30% yield, 0% tvl (max yield only)
        edgeCaseFees[2] = UtilsLib.encodeFee(1, 1); // 0.01% yield, 0.01% tvl (min values)
        edgeCaseFees[3] = UtilsLib.encodeFee(1500, 250); // 15% yield, 2.5% tvl (middle values)

        for (uint i = 0; i < edgeCaseFees.length; i++) {
            // Test setting default fee
            covenantCore.setDefaultFee(edgeCaseFees[i]);
        }

        // Test creating market with edge case fee
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test setting market-specific fees
        for (uint i = 0; i < edgeCaseFees.length; i++) {
            covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, edgeCaseFees[i]);
        }
    }

    function test_protocolFeeValidation_InvalidCombinations() external {
        Covenant covenantCore;
        address lexImplementation;
        MarketId marketId;

        // deploy covenant liquid
        covenantCore = new Covenant(address(this));

        // deploy lex implementation
        lexImplementation = address(
            new LatentSwapLEX(
                address(this),
                address(covenantCore),
                P_MAX,
                P_MIN,
                P_LIM_H,
                P_LIM_MAX,
                LN_RATE_BIAS,
                DURATION,
                SWAP_FEE
            )
        );

        // authorize lex and oracle
        covenantCore.setEnabledLEX(lexImplementation, true);
        covenantCore.setEnabledCurator(_mockOracle, true);

        // Test invalid combinations (both fees exceed limits)
        uint32[] memory invalidCombinations = new uint32[](3);
        invalidCombinations[0] = UtilsLib.encodeFee(3001, 501); // Both exceed limits
        invalidCombinations[1] = UtilsLib.encodeFee(5000, 1000); // Both exceed limits significantly
        invalidCombinations[2] = UtilsLib.encodeFee(10000, 2000); // Both exceed limits by large amounts

        for (uint i = 0; i < invalidCombinations.length; i++) {
            // Test setting default fee with invalid combination
            vm.expectRevert(Errors.E_ProtocolFeeTooHigh.selector);
            covenantCore.setDefaultFee(invalidCombinations[i]);
        }

        // Create a market with valid fee first
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: lexImplementation
        });
        marketId = covenantCore.createMarket(marketParams, hex"");

        // Test setting market-specific fee with invalid combination
        for (uint i = 0; i < invalidCombinations.length; i++) {
            vm.expectRevert(Errors.E_ProtocolFeeTooHigh.selector);
            covenantCore.setMarketProtocolFee(marketId, marketParams, hex"", 0, invalidCombinations[i]);
        }
    }

    function test_undercollateralized_minimal_liquidity() external {
        // Test the scenario where minimal liquidity causes MaxDebt = 0 in undercollateralized state
        // This blocks zToken to Base swaps even when liquidity > 0
        uint256 baseAmountIn = 10;
        uint104 MIN_SQRTPRICE_RATIO = uint104((1005 * FixedPoint.WAD) / 1000);

        // deploy covenant liquid
        Covenant covenantCore = new Covenant(address(this));

        // Setup: 50% target LTV market with very narrow price width
        (uint160 edgeSqrtRatioX96_A, uint160 edgeSqrtRatioX96_B) = LatentSwapLib.getMarketEdgePrices(
            uint32(PercentageMath.HALF_PERCENTAGE_FACTOR),
            MIN_SQRTPRICE_RATIO
        );

        console.log("step1");

        // Initialize LEX
        LatentSwapLEX lexImplementation = new LatentSwapLEX(
            address(this),
            address(covenantCore),
            edgeSqrtRatioX96_B,
            edgeSqrtRatioX96_A,
            edgeSqrtRatioX96_B - 2,
            edgeSqrtRatioX96_B - 1,
            0,
            DURATION,
            0
        );
        console.log("step2");

        // authorize lex and oracle
        covenantCore.setEnabledLEX(address(lexImplementation), true);
        covenantCore.setEnabledCurator(_mockOracle, true);
        console.log("step3");

        // initialize market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(lexImplementation)
        });

        MarketId marketId = covenantCore.createMarket(marketParams, hex"");
        console.log("step4");

        // approve transferFrom and mint initial liquidity
        IERC20(_mockBaseAsset).approve(address(covenantCore), baseAmountIn);
        (uint256 aTokenAmountOut, uint256 zTokenAmountOut) = covenantCore.mint(
            MintParams({
                marketId: marketId,
                marketParams: marketParams,
                baseAmountIn: baseAmountIn,
                to: address(this),
                minATokenAmountOut: 0,
                minZTokenAmountOut: 0,
                data: hex"",
                msgValue: 0
            })
        );

        // Reduce price to put into an undercollateralized state
        MockOracle(_mockOracle).setPrice(1 * 10 ** 17);

        uint256 debtOut = (zTokenAmountOut >> 2);

        uint256 baseAmountOut = covenantCore.swap(
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
            })
        );

        assertLe(
            baseAmountOut,
            baseAmountIn >> 2,
            "When undercollateralized, zToken to Base swap should be proportional."
        );
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

    function test_undercollateralized_market_comprehensive() external {
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

        console.log("step1");

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
        console.log("step2");

        // authorize lex and oracle
        vars.covenantCore.setEnabledLEX(address(vars.lexImplementation), true);
        vars.covenantCore.setEnabledCurator(_mockOracle, true);
        console.log("step3");

        // initialize market
        vars.marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(vars.lexImplementation)
        });

        vars.marketId = vars.covenantCore.createMarket(vars.marketParams, hex"");
        console.log("step4");

        // approve transferFrom and mint initial liquidity
        IERC20(_mockBaseAsset).approve(address(vars.covenantCore), 2 * vars.baseAmountIn);
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

        // Reduce price to put into an undercollateralized state
        MockOracle(_mockOracle).setPrice(1 * 10 ** 17);

        vars.debtOut = (vars.zTokenAmountOut >> 2);

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

        assertLe(
            vars.baseAmountOut,
            vars.baseAmountIn >> 2,
            "When undercollateralized, zToken to Base swap should be proportional."
        );

        // Step 6: Do full redeem of remaining zTokens
        vars.remainingZTokens = vars.zTokenAmountOut - vars.debtOut;

        console.log("step 5");
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

        ///////////////////////////////////////////////////////////////
        // now try and mint again (only aTokens should be minted given market state)
        // to ensure the market is not blocked by having no baseTokens, no zTokens, but some aTokens.
        vars.baseAmountIn = 1000000;
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

        assertGt(vars.aTokenAmountOut, 0, "Only aTokens should be minted given market state");
        assertEq(vars.zTokenAmountOut, 0, "No zTokens should be minted given market state");
        console.log("vars.aTokenAmountOut", vars.aTokenAmountOut);
        console.log("vars.zTokenAmountOut", vars.zTokenAmountOut);
    }
}

//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {TokenPrices, AssetType} from "../../../interfaces/ILiquidExchangeModel.sol";
import {LexConfig, LexState, MintParams, RedeemParams, SwapParams, MarketId, MarketParams, LexParams} from "../interfaces/ILatentSwapLEX.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {LSErrors} from "./LSErrors.sol";
import {LatentMath} from "./LatentMath.sol";
import {FixedPoint} from "./FixedPoint.sol";
import {DebtMath} from "./DebtMath.sol";
import {UtilsLib} from "../../../libraries/Utils.sol";
import {PercentageMath} from "@aave/libraries/math/PercentageMath.sol";
import {SaturatingMath} from "./SaturatingMath.sol";
import {IPriceOracle} from "../../../interfaces/IPriceOracle.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {SafeMetadata} from "../../../libraries/SafeMetadata.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";

/**
 * @title Latent Swap Logic
 * @author Covenant Labs
 **/

library LatentSwapLogic {
    using SafeCast for uint256;
    using SafeCast for bool;
    using Math for uint256;
    using SaturatingMath for uint256;
    using PercentageMath for uint256;
    using SafeMetadata for IERC20;

    uint8 constant MAX_MINT_FACTOR_CAP = 1; // x1 max liquidity mint as a % of total market liquidity (measured through ETWAP). ie, limits amount that can be minted in ETWAP_MIN_HALF_LIFE minutes
    uint8 constant MAX_REDEEM_FACTOR_CAP = 2; // 1/4 max liquidity burn as a % of total market liquidity (measured through ETWAP). ie, limits amount that can be burned in ETWAP_MIN_HALF_LIFE minutes
    uint256 constant MAX_SYNTH_MINT_CAP = uint256(1) << 242; // do not allow minting more than 2^242 in aTokens and zTokens.  This allows for further market appreciation in value (and protects from percentageMul overflows)
    uint16 constant ETWAP_MIN_HALF_LIFE = 30 minutes; // Minimum half life of ETWAP calculations (ETWAP can have a longer halflife if market has infrequent updates)
    uint96 constant LN2 = 693147180559945331; // ln(2) in WADs.  Used for half-life calculations
    uint32 constant MIN_LIQRATIOX96 = 1e9; // Minimum Price * LiqRatio for market.  Prices under 1 wei (if in WADs) will revert.
    uint40 constant NEG_WORKOUT_LN_RATE = 116323331638; // -1% daily workout rate (when undercollateralized or above MAX_LIMIT_LTV). Expressed as lnRate per second in WADs.  Workout rate is negative, but here expressed as positive.
    uint8 constant DEBT = 0; // used for indexing into supplyAmounts and dexAmounts
    uint8 constant LVRG = 1; // used for indexing into supplyAmounts and dexAmounts

    // Market state - for cache + state calculated values
    struct LexFullState {
        LexState lexState;
        LexConfig lexConfig;
        uint256 baseTokenSupply;
        uint256[2] supplyAmounts;
        uint256[2] dexAmounts;
        uint256[3] dexAmountsScaled;
        uint256[3] synthAmountsScaled;
        uint256 liquidityRatioX96;
        uint160 liquidity;
        uint96 accruedProtocolFee;
        bool underCollateralized;
    }

    // Market init info struct
    struct MarketInitInfo {
        string baseName;
        string baseSymbol;
        string quoteSymbol;
        string aTokenName;
        string aTokenSymbol;
        string zTokenName;
        string zTokenSymbol;
        uint8 synthDecimals;
        uint8 quoteDecimals;
        uint8 noCapLimit;
        string levStr;
        string durStr;
    }

    ///////////////////////////////////////////////////////////////////////////////
    // External library functions
    ///////////////////////////////////////////////////////////////////////////////

    function mintLogic(
        MintParams calldata mintParams,
        LexParams memory lexParams,
        LexConfig storage lexConfig,
        LexState storage lexState,
        uint256 baseTokenSupply,
        bool isPreview
    )
        external
        view
        returns (
            LexFullState memory currentState,
            TokenPrices memory tokenPrices,
            uint256 aTokenAmountOut,
            uint256 zTokenAmountOut
        )
    {
        ///////////////////////////////
        // Calculate market state (storage read)
        currentState = _calculateMarketState(
            mintParams.marketParams,
            lexParams,
            lexConfig,
            lexState,
            baseTokenSupply,
            isPreview
        );

        ///////////////////////////////
        // Calculate mint
        (aTokenAmountOut, zTokenAmountOut) = _calcMint(lexParams, currentState, mintParams.baseAmountIn);

        /////////////////////////////////////
        // Calculate token prices (post action)
        tokenPrices = _calculateTokenPrices(lexParams, currentState);
    }

    function redeemLogic(
        RedeemParams calldata redeemParams,
        LexParams memory lexParams,
        LexConfig storage lexConfig,
        LexState storage lexState,
        uint256 baseTokenSupply,
        bool isPreview
    ) external view returns (LexFullState memory currentState, TokenPrices memory tokenPrices, uint256 amountOut) {
        ///////////////////////////////
        // Calculate market state (storage read)
        currentState = _calculateMarketState(
            redeemParams.marketParams,
            lexParams,
            lexConfig,
            lexState,
            baseTokenSupply,
            isPreview
        );

        ///////////////////////////////
        // Calculate redeem
        (amountOut, currentState.lexState.lastSqrtPriceX96) = _calcRedeem(
            lexParams,
            currentState,
            redeemParams.aTokenAmountIn,
            redeemParams.zTokenAmountIn
        );

        /////////////////////////////////////
        // Calculate token prices (post action)
        // @dev - prices are miscalculated if a market is fully redeemed, and are stated pre-action instead.
        tokenPrices = _calculateTokenPrices(lexParams, currentState);
    }

    function swapLogic(
        SwapParams calldata swapParams,
        LexParams memory lexParams,
        LexConfig storage lexConfig,
        LexState storage lexState,
        uint256 baseTokenSupply,
        bool isPreview
    )
        external
        view
        returns (LexFullState memory currentState, TokenPrices memory tokenPrices, uint256 amountCalculated)
    {
        ///////////////////////////////
        // Calculate market state (storage read)
        currentState = _calculateMarketState(
            swapParams.marketParams,
            lexParams,
            lexConfig,
            lexState,
            baseTokenSupply,
            isPreview
        ); ///////////////////////////////

        // Calculate swap
        (amountCalculated, currentState.lexState.lastSqrtPriceX96) = _calcSwap(
            lexParams,
            currentState,
            swapParams.amountSpecified,
            swapParams.assetIn,
            swapParams.assetOut,
            swapParams.isExactIn
        );

        /////////////////////////////////////
        // Calculate token prices (post action)
        // @dev - prices are miscalculated if a market is fully redeemed, and are stated pre-action instead.
        tokenPrices = _calculateTokenPrices(lexParams, currentState);
    }

    // Retrieve baseToken price
    // @dev - baseTokenPrice is the value of 10^18 baseTokens, in quoteTokens, irrespective of actual # of decimal precision the baseToken has
    function readBasePriceAndCalculateLiqRatio(
        MarketParams calldata marketParams,
        uint256 liquidityConcentrationX96,
        int8 scaleDecimals,
        bool isPreview
    ) external view returns (uint256 price, uint256 liqRatioX96) {
        return _readBasePriceAndCalculateLiqRatio(marketParams, liquidityConcentrationX96, scaleDecimals, isPreview);
    }

    function calculateMarketState(
        MarketParams calldata marketParams,
        LexParams memory lexParams,
        LexConfig storage lexConfig,
        LexState storage lexState,
        uint256 baseTokenSupply,
        bool isPreview
    ) external view returns (LexFullState memory marketState) {
        return _calculateMarketState(marketParams, lexParams, lexConfig, lexState, baseTokenSupply, isPreview);
    }

    function calcRatio(
        LexParams memory lexParams,
        LexFullState memory marketState,
        AssetType base,
        AssetType quote
    ) external pure returns (uint256 price) {
        return _calcRatio(lexParams, marketState, base, quote);
    }

    function getDebtPriceDiscount(
        uint160 edgeSqrtPriceX96_A,
        uint160 edgeSqrtPriceX96_B,
        uint160 currentSqrtPriceX96,
        uint256 target_dXdL_X96
    ) external pure returns (uint256 currentPriceDiscount) {
        return _getDebtPriceDiscount(edgeSqrtPriceX96_A, edgeSqrtPriceX96_B, currentSqrtPriceX96, target_dXdL_X96);
    }

    // @dev - externalizing computations used during LatentSwapLEX contract creation
    function computeMaxLTVandTargetdXdL(
        uint160 edgeSqrtPriceX96_A,
        uint160 edgeSqrtPriceX96_B,
        uint160 limMaxSqrtPriceX96
    ) external pure returns (uint256 maxLTV, uint256 target_dXdL_X96) {
        maxLTV = LatentMath.computeLTV(edgeSqrtPriceX96_A, edgeSqrtPriceX96_B, limMaxSqrtPriceX96);
        target_dXdL_X96 = LatentMath.targetXvsL(edgeSqrtPriceX96_A, edgeSqrtPriceX96_B);
    }

    // @dev - externalizing computations used during market initialization
    function getInitMarketInfo(
        MarketParams calldata marketParams,
        uint256 debtDuration,
        uint160 edgeSqrtPriceX96_A,
        uint160 edgeSqrtPriceX96_B,
        uint8 baseTokenNoCapLimit,
        uint8 quoteDecimals,
        string memory quoteSymbol
    ) external view returns (MarketInitInfo memory info) {
        bool success;

        // Get base asset name and symbol (cannot be overriden)
        (success, info.baseName) = IERC20(marketParams.baseToken).tryGetName();
        if (!success) revert LSErrors.E_LEX_BaseAssetNotERC20();
        (success, info.baseSymbol) = IERC20(marketParams.baseToken).tryGetSymbol();
        if (!success) revert LSErrors.E_LEX_BaseAssetNotERC20();

        // Get quote symbol with overrides
        info.quoteSymbol = quoteSymbol; // read
        if (bytes(info.quoteSymbol).length == 0) revert LSErrors.E_LEX_QuoteAssetHasNoSymbol();

        // Get synthDecimals decimals (== quote decimals with overrides)
        info.synthDecimals = quoteDecimals;
        if (info.synthDecimals == 0) info.synthDecimals = 18;

        // Get actual quote decimals (as would be returned by IPriceOracle)
        (success, info.quoteDecimals) = IERC20(marketParams.quoteToken).tryGetDecimals();
        if (!success) info.quoteDecimals = 18;

        // Get base Token noCap decimals
        info.noCapLimit = baseTokenNoCapLimit;
        if (info.noCapLimit == 0) {
            // default threshold above which mint / redeem cap are applied is equivalent to ~1 baseToken
            (bool success2, uint8 baseDecimals) = IERC20(marketParams.baseToken).tryGetDecimals();
            if (!success2)
                info.noCapLimit = uint8(60); // 18 Decimals -> 60 noCapLimit
            else info.noCapLimit = (FixedPointMathLib.log2(10 ** baseDecimals) + 1).toUint8();
        }

        // Calculate target leverage
        // leverage factor = 1/(1-targetLTV).  e.g., 50% -> 2, 80% -> 5, 90% -> 10, 95% -> 20
        info.levStr = Strings.toString(
            (FixedPoint.PERCENTAGE_FACTOR + 1) /
                (FixedPoint.PERCENTAGE_FACTOR -
                    LatentMath.computeLTV(edgeSqrtPriceX96_A, edgeSqrtPriceX96_B, uint160(FixedPoint.Q96)))
        );

        // Calculate duration in months / years
        // e.g., 1M, 3M, 6M, 1Y, 2Y, 5Y
        // @dev - simplified approach rounds down.
        uint256 months = debtDuration / (30 days);
        if (months < 12) info.durStr = string.concat(Strings.toString(months), "M");
        else info.durStr = string.concat(Strings.toString(debtDuration / (365 days)), "Y");

        info.aTokenName = string.concat(info.baseName," x",info.levStr," Leverage Coin (",info.quoteSymbol,"/",info.durStr,")"); // prettier-ignore
        info.aTokenSymbol = string.concat(info.baseSymbol, "x", info.levStr, ".", info.quoteSymbol);
        info.zTokenName = string.concat(info.quoteSymbol," Yield Coin - backed by ",info.baseSymbol," (x",info.levStr,"/",info.durStr,")"); // prettier-ignore
        info.zTokenSymbol = string.concat(info.quoteSymbol, ".b.", info.baseSymbol);
    }

    ///////////////////////////////////////////////////////////////////////////////
    // Internal functions
    ///////////////////////////////////////////////////////////////////////////////

    function _calcMint(
        LexParams memory lexParams,
        LexFullState memory marketState,
        uint256 baseTokenAmountIn
    ) internal pure returns (uint256 aTokenAmountOut, uint256 zTokenAmountOut) {
        ///////////////////////////////
        // Validate inputs

        // Check if undercollateralized (reverts if so)
        _checkUnderCollateralized(marketState);

        // Check LTV before mint (reverts if LTV above MAX_LIMIT_LTV)
        // @dev - minting aTokens when above MAX_LIMIT_LTV is blocked to avoid excessive aToken dilution
        // in high LTV or undercollateralized markets.
        _checkLTV(marketState.lexState.lastSqrtPriceX96, lexParams.limMaxSqrtPriceX96);

        // Check if mint amount is too large given market size
        _checkMintCap(
            marketState.baseTokenSupply,
            marketState.lexState.lastETWAPBaseSupply,
            baseTokenAmountIn,
            marketState.lexConfig.noCapLimit
        );

        ///////////////////////////////
        // Calculate mint
        // Calculate liquidity coming in (round down)
        uint160 liquidityIn = _synthToDex(marketState, baseTokenAmountIn, AssetType.BASE, Math.Rounding.Floor)
            .toUint160();
        // Calculate dex amounts that should be minted

        (uint256 zDexToMint, uint256 aDexToMint) = LatentMath.computeMint(
            marketState.lexState.lastSqrtPriceX96,
            lexParams.edgeSqrtPriceX96_A,
            lexParams.edgeSqrtPriceX96_B,
            liquidityIn
        );

        // Calculate actual zTokens / aTokens to mint (round down).
        // @dev - Use debt ratio for leverage token if this is the first liquidity in
        // (ratio not important for leverage token, so keep in targetLTV range)
        zTokenAmountOut = _dexToSynth(marketState, zDexToMint, AssetType.DEBT, Math.Rounding.Floor);
        aTokenAmountOut = _dexToSynth(marketState, aDexToMint, AssetType.LEVERAGE, Math.Rounding.Floor);

        ///////////////////////////////
        // Validate outputs

        // ensure we are not miniting more than MAX_SYNTH_MINT_CAP for zToken and aToken
        // Block minting while still allowing market value to appreciate.
        _checkSynthMintCap(marketState.supplyAmounts[DEBT], zTokenAmountOut);
        _checkSynthMintCap(marketState.supplyAmounts[LVRG], aTokenAmountOut);

        ///////////////////////////////
        // Charge fee by reducing out amount
        if (lexParams.swapFee > 0) {
            zTokenAmountOut = zTokenAmountOut.percentMul(FixedPoint.PERCENTAGE_FACTOR - lexParams.swapFee);
            aTokenAmountOut = aTokenAmountOut.percentMul(FixedPoint.PERCENTAGE_FACTOR - lexParams.swapFee);
        }
    }

    function _calcRedeem(
        LexParams memory lexParams,
        LexFullState memory marketState,
        uint256 aTokenAmountIn,
        uint256 zTokenAmountIn
    ) internal pure returns (uint256 amountOut, uint160 nextSqrtPriceX96) {
        // store for output validation
        uint160 beforeSqrtPriceX96 = marketState.lexState.lastSqrtPriceX96;

        ///////////////////////////////
        // Validate inputs
        if (aTokenAmountIn > marketState.supplyAmounts[LVRG]) revert LSErrors.E_LEX_InsufficientTokens();
        if (zTokenAmountIn > marketState.supplyAmounts[DEBT]) revert LSErrors.E_LEX_InsufficientTokens();

        // Validate liquidity
        // @dev - testing baseTokenSupply, because logic below allows for removal of baseTokenSupply
        // even if the market's calculated liquidity = 0.  In these situations, we do not go through
        // the latentSwap invariant, but instead assume all baseTokens belong to zToken holders (if any),
        // or otherwise to aToken holders, and redeem actionas are done proportioanl to holdings.
        if (marketState.baseTokenSupply == 0) revert LSErrors.E_LEX_ZeroLiquidity();

        ///////////////////////////////
        // Calculate redeem

        // Check for a full redeem
        if (aTokenAmountIn == marketState.supplyAmounts[LVRG] && zTokenAmountIn == marketState.supplyAmounts[DEBT]) {
            // @dev - when full redeem, no swap fee nor redeemCap checks, set to target price
            // @dev - we acknowledge that there is a footgun risk or someone preemptin a full redeem to capture fees
            // ie, redeem fees would not be captured by the attacker.  This can be mitigated by redeeming in two steps if
            // the last user feels the fees are worth it...
            // @dev - it is possible to redeem dust baseToken amounts even when liquidity == 0
            amountOut = marketState.baseTokenSupply;
            nextSqrtPriceX96 = uint160(FixedPoint.Q96);
        } else {
            if (marketState.underCollateralized || marketState.liquidity == 0) {
                if (marketState.supplyAmounts[DEBT] > 0) {
                    // if market is undercollateralized, only allow zToken -> base redeems, and make these proportional
                    // @dev - it is possible to redeem undercollateralized markets even if baseSupply > 0 but liquidity == 0
                    if (aTokenAmountIn > 0) revert LSErrors.E_LEX_ActionNotAllowedUnderCollateralized();

                    // Proportional redeem
                    // @dev - we do not go through the _synthToDex -> LatentMath -> _dexToSynth pathway
                    // to calculate amounts given we are at the market extreme where debt tokens are the full owners of base tokens
                    // and amounts can be just calculated proportional to market amounts
                    // @notice - amount out is a floor, but we can do a full redeem if zTokenAmountIn == marketState.supplyAmounts[DEBT]
                    amountOut = marketState.baseTokenSupply.mulDiv(zTokenAmountIn, marketState.supplyAmounts[DEBT]);

                    // Calc next price across the following three states:
                    // 1 - zTokens still in market, so remains undercollateralized and nextSqrtPrice = edgeSqrtPriceX96_B
                    // 1 - No baseTokens or zTokens left, but aTokens still in market -> nextSqrtPrice = edgeSqrtPriceX96_A
                    // 2 - fully empy market -> nextSqrtPrice = 1
                    nextSqrtPriceX96 = (amountOut < marketState.baseTokenSupply)
                        ? lexParams.edgeSqrtPriceX96_B
                        : (marketState.supplyAmounts[LVRG] > 0)
                            ? lexParams.edgeSqrtPriceX96_A
                            : uint160(FixedPoint.Q96);
                } else {
                    ////////////////////////////////////
                    // Allow proprional redeeming of baseTokens with leverage tokens, given no zTokens in the market
                    amountOut = marketState.baseTokenSupply.mulDiv(aTokenAmountIn, marketState.supplyAmounts[LVRG]);
                    nextSqrtPriceX96 = (amountOut < marketState.baseTokenSupply)
                        ? lexParams.edgeSqrtPriceX96_A
                        : uint160(FixedPoint.Q96);
                }
                // No redeem fees charged in undercollateralized or  zero liquiditymarket

                ///////////////////////////////////////
                // Validate output
                // Check if redeem amount is too large given market size, even when undercollateralized
                _checkRedeemCap(
                    marketState.baseTokenSupply,
                    marketState.lexState.lastETWAPBaseSupply,
                    amountOut,
                    marketState.lexConfig.noCapLimit
                );
            } else {
                uint256 zTokenDexIn = _synthToDex(marketState, zTokenAmountIn, AssetType.DEBT, Math.Rounding.Floor);
                uint256 aTokenDexIn = _synthToDex(marketState, aTokenAmountIn, AssetType.LEVERAGE, Math.Rounding.Floor);

                // Calculate liquidity out given tokens in
                uint160 liquidityOut;
                (liquidityOut, nextSqrtPriceX96) = LatentMath.computeRedeem(
                    marketState.liquidity,
                    marketState.lexState.lastSqrtPriceX96,
                    lexParams.edgeSqrtPriceX96_A,
                    lexParams.edgeSqrtPriceX96_B,
                    zTokenDexIn,
                    aTokenDexIn
                );

                // Calculate baseToken amount out given liquidity out
                // Round down amount out
                amountOut = _dexToSynth(marketState, liquidityOut, AssetType.BASE, Math.Rounding.Floor);

                if (amountOut >= marketState.baseTokenSupply || liquidityOut >= marketState.liquidity) {
                    // @dev - this is close to a full redeem, but there is some aToken or zToken dust left in the market
                    // @dev - when full redeem, no swap fee nor redeemCap checks, set to target price
                    // @dev - we acknowledge that there is a footgun risk or someone preemptin a full redeem to capture fees
                    // ie, redeem fees would not be captured by the attacker.  This can be mitigated by redeeming in two steps if
                    // the last user feels the fees are worth it...
                    // @dev - it is possible to redeem dust baseToken amounts even when liquidity == 0
                    // @dev - some dust aTokens or zTokens might be left in the market (valueless).
                    // @dev - We ackownolded that it could be argued that fees should not be skipped in this case.
                    // If we charged fees, a majority holder could redeeming here in various steps to avoid paying dust holders
                    // We acknowledge this fact by just not charging fees in this scenario when only dust holders are left.
                    amountOut = marketState.baseTokenSupply;
                    nextSqrtPriceX96 = uint160(FixedPoint.Q96);
                } else {
                    ///////////////////////////////////////
                    // Validate output
                    // Check if redeem amount is too large given market size
                    _checkRedeemCap(
                        marketState.baseTokenSupply,
                        marketState.lexState.lastETWAPBaseSupply,
                        amountOut,
                        marketState.lexConfig.noCapLimit
                    );

                    ////////////////////////////////////////
                    // Charge fee by reducing out amount (after checkRedeemCap)
                    if (lexParams.swapFee > 0)
                        amountOut = amountOut.percentMul(FixedPoint.PERCENTAGE_FACTOR - lexParams.swapFee);
                }
            }
        }

        // Additional validate outputs

        // Allow redeems that lower LTV (lower DEX price) or keep as is, and otherwise
        // check whether action pushes LTV past High limit (reverts if so)
        if (nextSqrtPriceX96 > beforeSqrtPriceX96) _checkLTV(nextSqrtPriceX96, lexParams.limHighSqrtPriceX96);

        // @dev - allow redeeming 0 base tokens (as a way to remove dust in markets if need be)
    }

    struct calcSwapVars {
        uint256 inputDexAmount;
        uint256 calcDexAmount;
        uint256 aDexTokenAmount;
        uint256 zDexTokenAmount;
        uint256 newDexTokenAmount;
        uint160 liquidityNew;
        AssetType fixedSynth;
    }

    function _calcSwap(
        LexParams memory lexParams,
        LexFullState memory marketState,
        uint256 swapAmount,
        AssetType assetIn,
        AssetType assetOut,
        bool isExactIn
    ) internal pure returns (uint256 calcAmount, uint160 nextSqrtPriceX96) {
        ///////////////////////////////
        // Validate inputs
        require(assetIn != assetOut);

        // check market liquidity
        // @dev - it can happen that the market has liquidity == 0, even if baseTokenSupply > 0 and aTokens or zTokens > 0.
        // However, the market is not operational (more liquidity needs to be added)
        if (marketState.liquidity == 0) revert LSErrors.E_LEX_ZeroLiquidity();

        // Undercollateralized checks
        // If undercollateralized, only allow zToken to baseToken swaps  (ie redeem zTokens only)
        if ((assetIn != AssetType.DEBT) || (assetOut != AssetType.BASE)) _checkUnderCollateralized(marketState);

        // Do not allow buying aTokens if market above MAX_LIMIT_LTV
        // @dev - markets above MAX_LIMIT_LTV return to a lower LTV through negative funding (zTokens paying aTokens), collateral price appreciation, or zToken -> base swaps
        if (assetOut == AssetType.LEVERAGE)
            _checkLTV(marketState.lexState.lastSqrtPriceX96, lexParams.limMaxSqrtPriceX96);

        ///////////////////////////////
        // Calculate swap

        calcSwapVars memory vars;

        if ((assetIn != AssetType.BASE) && (assetOut != AssetType.BASE)) {
            // case1: synth for synth swap
            vars.fixedSynth = isExactIn ? assetIn : assetOut;
            vars.inputDexAmount = _synthToDex(
                marketState,
                swapAmount,
                vars.fixedSynth,
                isExactIn ? Math.Rounding.Floor : Math.Rounding.Ceil
            );

            (vars.calcDexAmount, nextSqrtPriceX96) = LatentMath.computeSwap(
                marketState.liquidity,
                marketState.lexState.lastSqrtPriceX96,
                vars.fixedSynth,
                vars.inputDexAmount,
                isExactIn
            );

            // Convert internal DEX output to synth amounts
            calcAmount = _dexToSynth(
                marketState,
                vars.calcDexAmount,
                isExactIn ? assetOut : assetIn,
                isExactIn ? Math.Rounding.Floor : Math.Rounding.Ceil
            );

            ////////////////////////////////////////////////////////
            // Validate swap amounts
            // Do not allow ExactOut > 0 if InputAmount ends being 0
            if (!isExactIn && calcAmount == 0) revert LSErrors.E_LEX_InsufficientAmount();

            // ensure we are not miniting more than MAX_SYNTH_MINT_CAP for zToken and aToken
            // Block minting while still allowing market value to appreciate.
            _checkSynthMintCap(
                marketState.supplyAmounts[assetOut == AssetType.DEBT ? DEBT : LVRG],
                isExactIn ? calcAmount : swapAmount
            );
        } else if ((assetIn == AssetType.BASE) && isExactIn) {
            // case2: base token is being swapped with an exact amount in

            // @dev - round down for all conditions
            vars.liquidityNew = _synthToDex(marketState, swapAmount, AssetType.BASE, Math.Rounding.Floor).toUint160();

            // Mint tokens given liquidity in
            (vars.zDexTokenAmount, vars.aDexTokenAmount) = LatentMath.computeMint(
                marketState.lexState.lastSqrtPriceX96,
                lexParams.edgeSqrtPriceX96_A,
                lexParams.edgeSqrtPriceX96_B,
                vars.liquidityNew
            );

            // update liquidity
            marketState.liquidity += vars.liquidityNew;

            // swap assetOut
            (vars.newDexTokenAmount, nextSqrtPriceX96) = LatentMath.computeSwap(
                marketState.liquidity,
                marketState.lexState.lastSqrtPriceX96,
                assetOut == AssetType.DEBT ? AssetType.LEVERAGE : AssetType.DEBT,
                assetOut == AssetType.DEBT ? vars.aDexTokenAmount : vars.zDexTokenAmount,
                true
            );

            // add to swap output the original mint amount of assetOut
            vars.newDexTokenAmount += Math.ternary(
                assetOut == AssetType.LEVERAGE,
                vars.aDexTokenAmount,
                vars.zDexTokenAmount
            );

            calcAmount = _dexToSynth(marketState, vars.newDexTokenAmount, assetOut, Math.Rounding.Floor);

            ////////////////////////////////////////////////////////
            // Validate mintCap if baseToken is being swapped in
            _checkMintCap(
                marketState.baseTokenSupply,
                marketState.lexState.lastETWAPBaseSupply,
                swapAmount,
                marketState.lexConfig.noCapLimit
            );

            ////////////////////////////////////////////////////////
            // Validate synth mint cap
            _checkSynthMintCap(marketState.supplyAmounts[assetOut == AssetType.DEBT ? DEBT : LVRG], calcAmount);
        } else if ((assetOut == AssetType.BASE) && isExactIn) {
            // case3: base token is being swapped out, with exact synth amount in
            // @dev - equivalent to redeeming swapAmount of assetIn
            (calcAmount, nextSqrtPriceX96) = _calcRedeem(
                lexParams,
                marketState,
                (assetIn == AssetType.LEVERAGE) ? swapAmount : 0,
                (assetIn == AssetType.DEBT) ? swapAmount : 0
            );
        } else {
            revert LSErrors.E_LEX_OperationNotAllowed();
        }

        // Charge fee by reducing out amount (or increasing in amount)
        // @dev - Base out swaps were already charged when calling _calcRedeem
        if (lexParams.swapFee > 0 && (assetOut != AssetType.BASE))
            calcAmount = isExactIn
                ? calcAmount.percentMul(FixedPoint.PERCENTAGE_FACTOR - lexParams.swapFee)
                : calcAmount.percentDiv(FixedPoint.PERCENTAGE_FACTOR - lexParams.swapFee);

        ///////////////////////////////
        // Additional validate outputs

        // Do not allow actions that increase LTV (and end past High LTV limits)
        // e.g. aToken sales, or zToken buys if it takes market past High LTV limits
        // @dev - however, allow actions that make LTV better
        if (nextSqrtPriceX96 > marketState.lexState.lastSqrtPriceX96)
            _checkLTV(nextSqrtPriceX96, lexParams.limHighSqrtPriceX96);

        // Validate enough tokens in the market
        if (
            (assetIn != AssetType.BASE) &&
            ((isExactIn ? swapAmount : calcAmount) > marketState.supplyAmounts[(assetIn == AssetType.DEBT) ? 0 : 1])
        ) revert LSErrors.E_LEX_InsufficientTokens();

        // Validate nextSqrtPriceX96 did not pass lower bound (upper bound already checked above)
        // @dev - this can happen at the extreme of LTV -> 0% (no debt)
        if (nextSqrtPriceX96 < lexParams.edgeSqrtPriceX96_A) revert LSErrors.E_LEX_OperationNotAllowed();
    }

    // /// @dev - returns ratio (price) in WADs
    function _calcRatio(
        LexParams memory lexParams,
        LexFullState memory marketState,
        AssetType base,
        AssetType quote
    ) internal pure returns (uint256 price) {
        uint256 dexPrice;

        // Calculate price for converting one dex asset to another
        if (base != AssetType.BASE && quote != AssetType.BASE) {
            dexPrice = (base == AssetType.DEBT)
                ? Math.mulDiv(
                    marketState.lexState.lastSqrtPriceX96 * FixedPoint.WAD,
                    marketState.lexState.lastSqrtPriceX96,
                    FixedPoint.Q192
                )
                : ((FixedPoint.Q192 * FixedPoint.WAD) / marketState.lexState.lastSqrtPriceX96) /
                    marketState.lexState.lastSqrtPriceX96;
        } else {
            AssetType synthAsset = (base == AssetType.BASE) ? quote : base;
            // calculates BASE vs Synth price
            dexPrice = LatentMath.get_XvsL(
                marketState.lexState.lastSqrtPriceX96,
                lexParams.edgeSqrtPriceX96_A,
                lexParams.edgeSqrtPriceX96_B,
                synthAsset
            );
            if (quote == AssetType.BASE) dexPrice = (FixedPoint.WAD << FixedPoint.RESOLUTION) / dexPrice;
            else dexPrice = (FixedPoint.WAD * dexPrice) / FixedPoint.Q96;
        }

        // When calculating price between tokens, we must convert from dex prices to synth prices
        // ie dexToken1 = currentMarketPrice*dexToken0
        // => Token1amount * dexTokenRatio[LVRG] = currentMarketPrice * Token0amount * dexTokenRatio[DEBT]
        // => Token1amount / Token0amount = currentMarketPrice * dexTokenRatio[DEBT] / dexTokenRatio[LVRG]
        price = _dexToSynth(
            marketState,
            _synthToDex(marketState, dexPrice, base, Math.Rounding.Ceil),
            quote,
            Math.Rounding.Ceil
        );
    }

    // Local variables for _calculateMarketState to avoid stack too deep
    struct CalcMarketStateVars {
        uint256 elapsedTime;
        uint256 spotPriceDiscount;
        int256 spotLnRateBias;
        uint256 newDebtNotionalPrice;
        uint16 yieldFee;
        uint16 tvlFee;
        uint256 feeX96;
        uint256 yieldInBaseUnits;
        uint256 fee;
        uint256 invUpdateFactor;
        uint256 maxDebtValue;
    }

    // calculates current market state given market params, used by all other internal functions
    function _calculateMarketState(
        MarketParams calldata marketParams,
        LexParams memory lexParams,
        LexConfig storage lexConfig,
        LexState storage lexState,
        uint256 baseTokenSupply,
        bool isPreview
    ) internal view returns (LexFullState memory marketState) {
        CalcMarketStateVars memory vars;

        ////////////////////////////////////////////////////////////////////////////////
        // Read and cache variables
        marketState.lexState = lexState;
        marketState.lexConfig = lexConfig;
        marketState.baseTokenSupply = baseTokenSupply;

        ////////////////////////////////////////////////////////////////////////////////
        // Read external values
        // read synth token supplies (external call to trusted protocol)
        marketState.supplyAmounts[DEBT] = IERC20(marketState.lexConfig.zToken).totalSupply();
        marketState.supplyAmounts[LVRG] = IERC20(marketState.lexConfig.aToken).totalSupply();

        // get current baseToken market price from oracle and calculate liquidity ratio
        (marketState.lexState.lastBaseTokenPrice, marketState.liquidityRatioX96) = _readBasePriceAndCalculateLiqRatio(
            marketParams,
            lexParams.targetXvsL,
            marketState.lexConfig.scaleDecimals,
            isPreview
        );
        ////////////////////////////////////////////////////////////////////////////////
        // Execute time based accruals
        // update accrued yield + calc fees according to current blocktime + last market prices
        // update interest if the current block timestamp is greater than the last update timestamp
        if (block.timestamp > marketState.lexState.lastUpdateTimestamp) {
            vars.elapsedTime = block.timestamp - marketState.lexState.lastUpdateTimestamp;
            marketState.lexState.lastUpdateTimestamp = uint96(block.timestamp);

            // get debt price discount given last dex price. This is done on purpose, to accrue interest
            // based on past values (and time accrued with those values) vs current spot oracle and market values
            vars.spotPriceDiscount = _getDebtPriceDiscount(
                lexParams.edgeSqrtPriceX96_A,
                lexParams.edgeSqrtPriceX96_B,
                marketState.lexState.lastSqrtPriceX96,
                lexParams.targetXvsL
            );

            // if market price > _limMaxSqrtPriceX96 (ie, aToken selling is locked given high LTV)
            // this means market is undercollateralized or close to undercollateralized.  We thus activate a slowly increasing workout rate.
            // which creates ever higher positive interest rates as we get closer to the edge of the market
            // which also constitutes the underCollateralization event edge.
            // @dev - sqrtPrices have a max of uint104, so _squareUnsafe will not overflow.
            // @dev - WORKOUT_LN_RATE is negative
            vars.spotLnRateBias =
                int256(marketState.lexState.lastLnRateBias) -
                int256(
                    (marketState.lexState.lastSqrtPriceX96 <= lexParams.limMaxSqrtPriceX96)
                        ? 0
                        : Math.mulDiv(
                            uint256(lexParams.debtDuration) * NEG_WORKOUT_LN_RATE,
                            _squareUnsafe(marketState.lexState.lastSqrtPriceX96 - lexParams.limMaxSqrtPriceX96),
                            _squareUnsafe(lexParams.edgeSqrtPriceX96_B - lexParams.limMaxSqrtPriceX96)
                        )
                );

            // accrue interest (update cached debtNotionalPrice)
            // @dev limits elapsedTime for the update to a full duration interval.
            // @dev this limits interest accrual for inactive markets,
            // but ensures interest accrual does not overshoot given accrueInterest approximations
            // The maximum interest accrual below (in this update) is 1/price
            // (e.g., if price is 0.95 in a 12 month duration market, and market gets updated in 24 months... the update is still only 5.2%)
            vars.newDebtNotionalPrice = DebtMath.accrueInterest(
                marketState.lexState.lastDebtNotionalPrice,
                lexParams.debtDuration,
                vars.spotPriceDiscount,
                (vars.elapsedTime > lexParams.debtDuration) ? lexParams.debtDuration : vars.elapsedTime,
                vars.spotLnRateBias
            );

            // accrue fees
            // @dev - fee accruel linear instead of geometric to simplify math
            // large timesteps lead to underaccrual of protocol fees
            // @dev - do not accrue fees if LTV > MAX_LIMIT_LTV (high LTV or undercollateralized market)
            if (
                (marketState.lexConfig.protocolFee > 0) &&
                (marketState.lexState.lastSqrtPriceX96 <= lexParams.limMaxSqrtPriceX96)
            ) {
                // split out fees
                (vars.yieldFee, vars.tvlFee) = UtilsLib.decodeFee(marketState.lexConfig.protocolFee);

                vars.feeX96 = 0;
                if (vars.tvlFee > 0) {
                    // @dev - increase resolution of calculation to X96 to account for small fees, baseTokenSupplies or elapsedTime
                    vars.feeX96 = DebtMath.calculateLinearAccrual(
                        baseTokenSupply,
                        uint256(vars.tvlFee) << FixedPoint.RESOLUTION,
                        vars.elapsedTime
                    );
                }
                if ((vars.yieldFee > 0) && (vars.newDebtNotionalPrice > marketState.lexState.lastDebtNotionalPrice)) {
                    // calculate estimate of yield accrued in base units
                    // @dev - uses LTV instead of spot prices to lower gas cost
                    // this uses the avg market price instead of spot price for conversion,
                    // which leads to a higher yield estimation in low LTV environments vs high LTV environments
                    // this behavior is acceptable given gas savings.
                    vars.yieldInBaseUnits = marketState.baseTokenSupply.mulDiv(
                        (vars.newDebtNotionalPrice - marketState.lexState.lastDebtNotionalPrice) *
                            LatentMath.computeLTV(
                                lexParams.edgeSqrtPriceX96_A,
                                lexParams.edgeSqrtPriceX96_B,
                                marketState.lexState.lastSqrtPriceX96
                            ),
                        marketState.lexState.lastDebtNotionalPrice * FixedPoint.PERCENTAGE_FACTOR
                    );

                    vars.feeX96 += vars.yieldInBaseUnits.mulDiv(
                        uint256(vars.yieldFee) << FixedPoint.RESOLUTION,
                        FixedPoint.PERCENTAGE_FACTOR
                    );
                }

                vars.fee = vars.feeX96 / FixedPoint.Q96;

                // Probabilistically (best effort) add +1 fee depending on remainder for small fees (FIX from Pashov Audit)
                // @dev - this allows to probabilistically collect fees for low baseTokenSupplies, small fees, or small elapseTime
                // @dev -  We use the probabilistic approach to lower gas cost (avoid an SSTORE),
                // and only for fees < 100 given we are ok with a < 1% underaccrual of fees.
                if (vars.fee < 100) {
                    if (
                        (vars.feeX96 % FixedPoint.Q96) >
                        (uint256(
                            keccak256(
                                abi.encodePacked(
                                    uint32(block.prevrandao),
                                    uint32(block.timestamp),
                                    uint128(marketState.baseTokenSupply),
                                    uint64(marketState.lexState.lastSqrtPriceX96)
                                )
                            )
                        ) >> 160)
                    ) vars.fee += 1;
                } else if (vars.fee > type(uint96).max) vars.fee = type(uint96).max;
                if (vars.fee > (baseTokenSupply / 8)) vars.fee = baseTokenSupply / 8; // @dev set max update of 12.5% of baseTokenSupply

                unchecked {
                    marketState.accruedProtocolFee = uint96(vars.fee); //fits in uint96 given previous checks
                    marketState.baseTokenSupply -= vars.fee; // @dev - remove fee from baseTokenSupply for all calculations going fwd
                }
            }
            marketState.lexState.lastDebtNotionalPrice = vars.newDebtNotionalPrice;

            /////////////////////////////////////
            // Exponential TWAP
            // @dev - stores an exponential moving avg of market baseSupply

            // Calculate update factor with an approximate ETWAP_HALF_LIFE.
            vars.invUpdateFactor = DebtMath.calculateApproxExponentialUpdate(
                LN2,
                vars.elapsedTime,
                ETWAP_MIN_HALF_LIFE
            );

            marketState.lexState.lastETWAPBaseSupply =
                marketState.lexState.lastETWAPBaseSupply.mulDiv(FixedPoint.RAY, vars.invUpdateFactor) +
                marketState.baseTokenSupply.mulDiv(
                    FixedPoint.RAY - (FixedPoint.RAY * FixedPoint.RAY) / vars.invUpdateFactor,
                    FixedPoint.RAY
                );
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // Calculate parameters for synth -> dex -> synth transforms (for BASE + DEBT only)
        // @dev - these scaled amounts seek to ensure liquidity < 2^152.
        // so, if liquidity is too big, I would make liquidityScaled ~ 2^152 = liquidity * X96 / divScaleFactorX96.
        // so, divScaleFactorX96 = liquidity * X96 / 2^152 = liquidityRatioX96 * BaseTokenSupply / 2^152;
        // @dev - saturates instead of reverting, meaning liquidity could still be > 2^152 even after applying this scaling.
        // This would only happen in markets where the oracle price * baseTokenSupply itself overflows, and thus an unlikely scenario.
        // if so, it will revert later when calculating liquidity.
        // @dev - if baseTokenSupply < X96, then use X96.  We assume all viable markets can price (without overflow a minimum of X96 base tokens)
        uint256 divScaleFactorX96 = marketState.liquidityRatioX96.saturatingMulShr(
            marketState.baseTokenSupply.max(FixedPoint.Q96),
            152
        );
        bool scaledLiquidity = divScaleFactorX96 > FixedPoint.Q96; // scaling only applies if divScaleFactorX96 > X96

        // if divScaleFactorX96 < X96, then liquidity already < 2^152.  liquidity = liquidityRatioX96 * BaseTokenSupply / X96
        // if divScaleFactorX96 > X96, then liquidityScaled = 2^152 = liquidityRatioX96 * BaseTokenSupply / divScaleFactorX96
        marketState.dexAmountsScaled[uint8(AssetType.BASE)] = marketState.liquidityRatioX96;
        marketState.synthAmountsScaled[uint8(AssetType.BASE)] = Math.ternary(
            scaledLiquidity,
            divScaleFactorX96,
            FixedPoint.Q96
        );

        // check that (notionalPrice * debtSupply * X96 / WAD / synthAmountScaled[Base]) does not overflow.
        // we have to use the synthAmountScaled[Base] across all assets to make the market consistent.
        // dex amount cannot be bigger than maxDebt * X96 / synthAmountScaled[Base] < notionalPrice * debtSupply * X96 / WAD / synthAmountScaled[Base]
        // thus, if maxDebt / notionalPrice < debtSupply / WAD, then market is undercollateralized.
        marketState.dexAmountsScaled[uint8(AssetType.DEBT)] = (scaledLiquidity &&
            marketState.lexState.lastDebtNotionalPrice < FixedPoint.Q160)
            ? (divScaleFactorX96 < FixedPoint.Q192)
                ? marketState.lexState.lastDebtNotionalPrice * FixedPoint.Q96
                : marketState.lexState.lastDebtNotionalPrice.mulDiv(FixedPoint.Q96, FixedPoint.WAD)
            : marketState.lexState.lastDebtNotionalPrice;

        marketState.synthAmountsScaled[uint8(AssetType.DEBT)] = scaledLiquidity
            ? (marketState.lexState.lastDebtNotionalPrice < FixedPoint.Q160)
                ? (divScaleFactorX96 < FixedPoint.Q192)
                    ? FixedPoint.WAD * divScaleFactorX96
                    : divScaleFactorX96
                : FixedPoint.WAD.mulDiv(divScaleFactorX96, FixedPoint.Q96)
            : FixedPoint.WAD;

        ////////////////////////////////////////////////////////////////////////////////
        // Calculate liquidity from baseTokenSupply
        marketState.liquidity = _synthToDex(
            marketState,
            marketState.baseTokenSupply,
            AssetType.BASE,
            Math.Rounding.Floor
        ).toUint160();

        ////////////////////////////////////////////////////////////////////////////////
        // calculate values if market has liquidity
        if (marketState.liquidity > 0) {
            // Calculate debt balanced value from zTokenSupply
            marketState.dexAmounts[DEBT] = _synthToDex(
                marketState,
                marketState.supplyAmounts[DEBT],
                AssetType.DEBT,
                Math.Rounding.Floor
            );

            // Check max value for debt, given availablie liquidity in market.
            vars.maxDebtValue = LatentMath.computeMaxDebt(
                lexParams.edgeSqrtPriceX96_A,
                lexParams.edgeSqrtPriceX96_B,
                marketState.liquidity
            );

            // if true, then system is undercollateralized (ie, debt notional value is above liquidity value)
            // if so, reduce debt value to be system liquidity value
            if (marketState.dexAmounts[DEBT] > vars.maxDebtValue) {
                marketState.lexState.lastSqrtPriceX96 = lexParams.edgeSqrtPriceX96_B;
                marketState.dexAmounts[DEBT] = vars.maxDebtValue;
                marketState.dexAmounts[LVRG] = 0;
                marketState.underCollateralized = true;
            } else {
                // calculate market price and aDexAmount given liquidity and zDexAmount
                // @dev - it could happen that marketState.dexAmounts[LVRG] == 0,
                // even if Liquidity > 0 and marketState.dexAmounts[DEBT] < maxDebtValue.
                (marketState.dexAmounts[LVRG], marketState.lexState.lastSqrtPriceX96) = LatentMath
                    .getMarketStateFromLiquidityAndDebt(
                        lexParams.edgeSqrtPriceX96_A,
                        lexParams.edgeSqrtPriceX96_B,
                        marketState.liquidity,
                        marketState.dexAmounts[DEBT]
                    );
            }
        } else {
            // If liquidity == 0, go through following scenarios to set price depending on whether
            // there is any debt or leverage tokens in the market, or whether it is a fully empty market.
            // @dev - any dust aTokens that might be left in the market is valueless.
            // @dev - any dust zTokens left might have some value (if baseTokenSupply > 0) but very small (under < 10-15 in quote tokens for most market setups)
            // but this undercollateralized state would not be resolved via workout accrual and might block the market,
            // so we consider them valueless as well.
            // Thus, we set the market price to uint160(FixedPoint.Q96) - uninitialized.
            marketState.dexAmounts[LVRG] = 0;
            marketState.dexAmounts[DEBT] = 0;
            marketState.lexState.lastSqrtPriceX96 = (marketState.supplyAmounts[LVRG] > 0 &&
                marketState.supplyAmounts[DEBT] == 0)
                ? lexParams.edgeSqrtPriceX96_A
                : uint160(FixedPoint.Q96);
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // Calculate parameters for synth -> dex -> synth transforms (for LVRG only)
        // if no supply for leverage token, assume ratio == 1
        // if dexAmounts[LVRG] = 0 while supplyAmounts[LVRG] > 0, we will set dexAmountScaled[LVRG] = 1
        //  To ensure _synthToDex and _DexToSynth ratios work (and allow for LTV and cap checks)
        // This might happen when liquidity > 0 but very close to being undercollateralized (without triggering the flag),
        // or in markets where liquidity = 0 with leftover dust.
        marketState.dexAmountsScaled[uint8(AssetType.LEVERAGE)] = Math.ternary(
            marketState.supplyAmounts[LVRG] > 0,
            Math.max(marketState.dexAmounts[LVRG], 1),
            1
        );
        marketState.synthAmountsScaled[uint8(AssetType.LEVERAGE)] = Math.ternary(
            marketState.supplyAmounts[LVRG] > 0,
            marketState.supplyAmounts[LVRG],
            1
        );

        return marketState;
    }

    // @dev - returns price discount in WADs
    // ie. currentNotionalPrice = WAD indicates a price of 1 (ie, debt is trading at par)
    function _getDebtPriceDiscount(
        uint160 edgeSqrtPriceX96_A,
        uint160 edgeSqrtPriceX96_B,
        uint160 currentSqrtPriceX96,
        uint256 target_dXdL_X96
    ) internal pure returns (uint256 currentPriceDiscount) {
        // @dev - in undercollateralized case, will correctly price discount such that
        // the interest rate corresponds to a market that is 100% debt and 0% leverage,
        // ie, the max interest rate of the market
        uint256 current_dXdL_X96 = LatentMath.get_XvsL(
            currentSqrtPriceX96,
            edgeSqrtPriceX96_A,
            edgeSqrtPriceX96_B,
            AssetType.DEBT
        );

        return FixedPoint.WAD.mulDiv(target_dXdL_X96, current_dXdL_X96);
    }

    // checks market LTV and reverts if beyond bounds
    // @dev - perform after action that should be prohibited if LTVs are off limits
    function _checkLTV(uint160 nextSqrtPriceX96, uint160 sqrtPriceLimitX96) internal pure {
        if (nextSqrtPriceX96 > sqrtPriceLimitX96) revert LSErrors.E_LEX_ActionNotAllowedGivenLTVlimit();
    }

    // checks and reverts if in undercollateralized state
    function _checkUnderCollateralized(LexFullState memory marketState) internal pure {
        if (marketState.underCollateralized) revert LSErrors.E_LEX_ActionNotAllowedUnderCollateralized();
    }

    function _checkMintCap(
        uint256 marketBaseTokenSupply,
        uint256 eTWAPBaseTokenSupply,
        uint256 mintAmount,
        uint8 noCapLimit
    ) internal pure {
        // if marketBaseTokenSupply <= AMOUNT_NO_CAP, then we can mint upto 2^96.
        // ie, for small markets we can mint up 2^96 in one go (we assume markets can price correctly this amount of base tokens)
        // But for bigger markets, mintAmount <= marketBaseTokenSupply << (MAX_MINT_FACTOR_CAP - 1)
        // and marketBaseTokenSupply + mintAmount <= eTWAPBaseTokenSupply << MAX_MINT_FACTOR_CAP
        // For MaxMintFactorCap = 1, this means mintAmount <= marketBaseTokenSupply (ie, we can double the market size in one call)
        // as long as marketBaseTokenSupply + mintAmount <= eTWAPBaseTokenSupply << MAX_MINT_FACTOR_CAP.
        // in practice, a user can mint upto  and are approx. ~MAX_MINT_FACTOR_CAP/2 can be minted every 1hr
        // (this is based on ETWAP_MIN_HALF_LIFE and MAX_REDEEM_FACTOR_CAP values)
        unchecked {
            if (marketBaseTokenSupply <= (1 << noCapLimit)) {
                if ((mintAmount > FixedPoint.Q96) && (mintAmount > marketBaseTokenSupply)) {
                    revert LSErrors.E_LEX_MintCapExceeded();
                }
            } else if (
                (mintAmount > marketBaseTokenSupply) ||
                ((type(uint256).max - mintAmount) < marketBaseTokenSupply) ||
                ((eTWAPBaseTokenSupply < (type(uint256).max >> MAX_MINT_FACTOR_CAP)) &&
                    ((marketBaseTokenSupply + mintAmount) > (eTWAPBaseTokenSupply << MAX_MINT_FACTOR_CAP)))
            ) {
                revert LSErrors.E_LEX_MintCapExceeded();
            }
        }
    }

    function _checkRedeemCap(
        uint256 marketBaseTokenSupply,
        uint256 eTWAPBaseTokenSupply,
        uint256 redeemAmount,
        uint8 noCapLimit
    ) internal pure {
        // OK to redeem any amount if marketBaseTokenSupply < 10^noCapLimit
        // ie, for small markets there is no limit on how much can be redeemed.
        // But for bigger markets, approx. ~MAX_REDEEM_FACTOR_CAP/2 can be redeemed every 1hr
        // (this is based on ETWAP_MIN_HALF_LIFE and MAX_REDEEM_FACTOR_CAP values)
        unchecked {
            if (
                (marketBaseTokenSupply > (1 << noCapLimit)) &&
                (marketBaseTokenSupply > redeemAmount) &&
                ((marketBaseTokenSupply - redeemAmount) <
                    (eTWAPBaseTokenSupply - (eTWAPBaseTokenSupply >> MAX_REDEEM_FACTOR_CAP)))
            ) revert LSErrors.E_LEX_RedeemCapExceeded();
        }
    }

    function _checkSynthMintCap(uint256 synthSupplyAmount, uint256 mintAmount) internal pure {
        // ensure we are not miniting more than MAX_SYNTH_MINT_CAP for zToken and aToken
        // Block minting while still allowing market value to appreciate.
        if ((mintAmount > MAX_SYNTH_MINT_CAP) || ((MAX_SYNTH_MINT_CAP - mintAmount) < synthSupplyAmount))
            revert LSErrors.E_LEX_MarketSizeLimitExceeded();
    }

    // ------------------ Synth to Dex conversions ---------

    function _synthToDex(
        LexFullState memory marketState,
        uint256 synthAmount,
        AssetType assetType,
        Math.Rounding rounding
    ) internal pure returns (uint256 dexAmount) {
        return
            synthAmount.mulDiv(
                marketState.dexAmountsScaled[uint8(assetType)],
                marketState.synthAmountsScaled[uint8(assetType)],
                rounding
            );
    }

    function _dexToSynth(
        LexFullState memory marketState,
        uint256 dexAmount,
        AssetType assetType,
        Math.Rounding rounding
    ) internal pure returns (uint256 synthAmount) {
        // @dev - using saturatingMulDiv avoids overflows that are then captured downstream.
        // Specifically:
        // 1) in ExactIn cases with synth outputs (e.g., mint, swap base -> synth, swap synth -> synth),
        // if we saturate the amount of synth output, this is expected to be caught in the _checkSynthMintCap
        // check.
        // 2) in the ExactIn synth -> base swap, this would not saturate given we don't control the baseTokens in existence.
        // 3) in the ExactOut case with synth inputs (e.g. swap synth -> synth), it would seem saturating the amount of synth coming in
        // might create an issue (given more synths would be expected to come in given the synths going out).  however , we sould
        // recall we are saturating to the max synth tokens in existence 2^256-1, and thus we are removing all of one type of synth and
        // making the market be 100% the other type of synth.  In this situation, the market is correct.  We are eitehr 100% equity
        // LatentSwap DEX will correctly price the leverage token.  Or we are 100% debt (and the transaction will revert given LTV limits).
        return
            dexAmount.saturatingMulDiv(
                marketState.synthAmountsScaled[uint8(assetType)],
                marketState.dexAmountsScaled[uint8(assetType)],
                rounding
            );
    }

    // Retrieve baseToken price
    // @dev - baseTokenPrice is the value of 10^18 baseTokens, in quoteTokens, irrespective of actual # of decimal precision the baseToken has
    function _readBasePriceAndCalculateLiqRatio(
        MarketParams calldata marketParams,
        uint256 targetXvsL,
        int8 scaleDecimals,
        bool isPreview
    ) internal view returns (uint256 price, uint256 liqRatioX96) {
        // targetXvsL is also the liquidity concentration of the market, and used here when calculating the liquidityRatio
        // scaleDecimals ensures that final 'value' is in synth decimals (and not quote decimals)
        uint256 scaledLiquidityConcentrationX96 = (scaleDecimals > 0)
            ? FixedPoint.Q192 / (targetXvsL * (10 ** uint8(scaleDecimals)))
            : (FixedPoint.Q192 * (10 ** uint8(-scaleDecimals))) / targetXvsL;

        // liqRatioX96 represents the ratio transforming base token amounts to a concentrated value denominated liquidity
        // @dev - getQuote is such that it returns the # of quote tokens, given # of base tokens coming in (irrespective of actual decimal representation).
        liqRatioX96 = (isPreview)
            ? IPriceOracle(marketParams.curator).previewGetQuote(
                scaledLiquidityConcentrationX96,
                marketParams.baseToken,
                marketParams.quoteToken
            )
            : liqRatioX96 = IPriceOracle(marketParams.curator).getQuote(
            scaledLiquidityConcentrationX96,
            marketParams.baseToken,
            marketParams.quoteToken
        );

        if (liqRatioX96 < MIN_LIQRATIOX96) revert LSErrors.E_LEX_OraclePriceTooLowForMarket();

        // calculate price
        // @dev - price is the # of quote tokens given 10^18 base tokens ,
        // irrespective of actual # of decimal precision that baseToken or quoteToken has
        price = FixedPoint.WAD.mulDiv(liqRatioX96, scaledLiquidityConcentrationX96);
    }

    function _calculateTokenPrices(
        LexParams memory lexParams,
        LexFullState memory marketState
    ) internal pure returns (TokenPrices memory tokenPrices) {
        // @notice - all prices are # of quote tokens received for 10^18 of base, leverage, or debt tokens
        //(irrespective of actual decimal precision of each token type).
        tokenPrices.baseTokenPrice = marketState.lexState.lastBaseTokenPrice;

        // if market is undercollateralized and has leverage tokens, then leverage value is zero.
        // otherwise, calculate price of leverage token  given baseTokenPrice and leverage price in the Covenant market
        tokenPrices.aTokenPrice = (marketState.underCollateralized && marketState.dexAmounts[LVRG] > 0)
            ? 0
            : tokenPrices.baseTokenPrice.mulDiv(
                _calcRatio(lexParams, marketState, AssetType.LEVERAGE, AssetType.BASE),
                FixedPoint.WAD
            );

        // if market is undercollateralized and has debt, all base value is owned by debt.
        // otherwise, calculate price of debt token  given baseTokenPrice and debt price in the Covenant market
        tokenPrices.zTokenPrice = (marketState.underCollateralized && marketState.dexAmounts[DEBT] > 0)
            ? tokenPrices.baseTokenPrice.mulDiv(marketState.baseTokenSupply, marketState.supplyAmounts[DEBT])
            : tokenPrices.baseTokenPrice.mulDiv(
                _calcRatio(lexParams, marketState, AssetType.DEBT, AssetType.BASE),
                FixedPoint.WAD
            );
    }

    function _squareUnsafe(uint256 value) internal pure returns (uint256) {
        unchecked {
            return value * value;
        }
    }
}

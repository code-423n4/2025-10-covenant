// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {MarketState, AssetType, TokenPrices, MarketParams} from "../../interfaces/ICovenant.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {MarketDetails, LexParams, LexConfig, LexState} from "../interfaces/IDataProvider.sol";
import {ILatentSwapLEX} from "../../lex/latentSwap/LatentSwapLEX.sol";
import {LatentSwapLogic} from "../../lex/latentSwap/libraries/LatentSwapLogic.sol";
import {LatentMath, Math, AssetType, FixedPoint} from "../../lex/latentswap/libraries/LatentMath.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {SaturatingMath} from "../../lex/latentswap/libraries/SaturatingMath.sol";

/**
 * @title LatentSwapLib library
 * @author Covenant Labs
 * @notice Implements Non-Core LatentSwap Utils
 */
library LatentSwapLib {
    using SafeCast for uint256;
    using Math for uint256;
    using SaturatingMath for uint256;

    uint8 constant DEBT = 0; // used for indexing into supplyAmounts and dexAmounts
    uint8 constant LVRG = 1; // used for indexing into supplyAmounts and dexAmounts

    /**
     * @notice Calculates sqrt(Pb) and sqrt(Pa) given a target LTV and price width X
     * @notice The market with returned Pb and Pa will have a pric == 1 at the target LTV
     * @param targetLTV target LTV for a new market
     * @param targetPriceWidth where sqrt(Pb) = sqrt(Pa) * X, in WAD precision and > 1
     * @return edgeSqrtPriceX96_A low market price edge (< 1)
     * @return edgeSqrtPriceX96_B high market price edge (> 1)
     */
    function getMarketEdgePrices(
        uint32 targetLTV,
        uint256 targetPriceWidth
    ) internal pure returns (uint160 edgeSqrtPriceX96_A, uint160 edgeSqrtPriceX96_B) {
        require(targetLTV < FixedPoint.PERCENTAGE_FACTOR);
        require(targetPriceWidth > FixedPoint.WAD);

        uint256 targetPriceWidthX96 = targetPriceWidth.mulDiv(FixedPoint.Q96, FixedPoint.WAD);
        uint256 betaX96 = (targetPriceWidthX96 *
            (
                (targetLTV >= FixedPoint.HALF_PERCENTAGE_FACTOR)
                    ? (targetLTV - FixedPoint.HALF_PERCENTAGE_FACTOR)
                    : (FixedPoint.HALF_PERCENTAGE_FACTOR - targetLTV)
            )) / (FixedPoint.PERCENTAGE_FACTOR - targetLTV);
        uint256 qX192 = Math.mulDiv(
            targetPriceWidthX96,
            uint256(targetLTV) << FixedPoint.RESOLUTION,
            FixedPoint.PERCENTAGE_FACTOR - targetLTV
        );

        edgeSqrtPriceX96_B = (
            (targetLTV >= FixedPoint.HALF_PERCENTAGE_FACTOR)
                ? Math.sqrt((betaX96 * betaX96) + qX192) - betaX96
                : Math.sqrt((betaX96 * betaX96) + qX192) + betaX96
        ).toUint160();

        edgeSqrtPriceX96_A = Math.mulDiv(edgeSqrtPriceX96_B, FixedPoint.Q96, targetPriceWidthX96).toUint160();

        return (edgeSqrtPriceX96_A, edgeSqrtPriceX96_B);
    }

    /**
     * @notice Calculates current debt discount price (which can be used to calculate effective debt APY)
     * @param currentSqrtPriceX96 current market price
     * @param edgeSqrtPriceX96_A low market price edge
     * @param edgeSqrtPriceX96_B high market price edge
     * @return currentDebtDiscountPrice in WADs
     */
    function getDebtDiscount(
        uint160 currentSqrtPriceX96,
        uint160 edgeSqrtPriceX96_A,
        uint160 edgeSqrtPriceX96_B
    ) internal pure returns (uint128 currentDebtDiscountPrice) {
        uint256 current_dXdL_X96 = LatentMath.get_XvsL(
            currentSqrtPriceX96,
            edgeSqrtPriceX96_A,
            edgeSqrtPriceX96_B,
            AssetType.DEBT
        );

        uint256 target_dXdL_X96 = LatentMath.get_XvsL(
            uint160(FixedPoint.Q96),
            edgeSqrtPriceX96_A,
            edgeSqrtPriceX96_B,
            AssetType.DEBT
        );

        return uint128(Math.mulDiv(target_dXdL_X96, FixedPoint.WAD, current_dXdL_X96));
    }

    /**
     * @notice Calculates an approximate target price given target LTV and market edges.
     * @dev Monotonic approximation of the inverse of LatentMath.computeLTV() for LTV >= 50%.
     * The result is always clamped to [edgeSqrtRatioX96_A, edgeSqrtRatioX96_B] and may not exactly
     * correspond to the requested LTV, especially near 100%. Callers should re-compute LTV via
     * LatentMath.computeLTV(edgeSqrtRatioX96_A, edgeSqrtRatioX96_B, returnedPrice) if exactness is required.
     * @dev Inverse of LatentMath.computeLTV().  Solution only for LTV >= 50%
     * @param edgeSqrtRatioX96_A low market price edge
     * @param edgeSqrtRatioX96_B high market price edge
     * @param targetLTV  where 10000 = 100%
     * @return sqrtRatioX96 market price equivalent to target LTV
     */
    function getSqrtPriceFromLTVX96(
        uint160 edgeSqrtRatioX96_A,
        uint160 edgeSqrtRatioX96_B,
        uint32 targetLTV
    ) internal pure returns (uint160 sqrtRatioX96) {
        require(targetLTV >= FixedPoint.HALF_PERCENTAGE_FACTOR && targetLTV <= FixedPoint.PERCENTAGE_FACTOR);

        uint256 beta = Math.mulDiv(
            edgeSqrtRatioX96_B,
            targetLTV - FixedPoint.HALF_PERCENTAGE_FACTOR,
            targetLTV,
            Math.Rounding.Ceil
        );
        uint256 q = Math.mulDiv(
            edgeSqrtRatioX96_B,
            edgeSqrtRatioX96_A * (FixedPoint.PERCENTAGE_FACTOR - targetLTV),
            targetLTV,
            Math.Rounding.Ceil
        );

        // Clamp to the upper edge to enforce domain bounds; near extremes this may yield
        // a price whose effective LTV (via computeLTV) is slightly above target. See NatSpec.
        // can cast directly given upper bound clamp.
        return uint160((beta + Math.sqrt(beta * beta + q, Math.Rounding.Ceil)).min(edgeSqrtRatioX96_B));
    }

    function getSpotPrices(MarketDetails memory marketDetails) internal view returns (TokenPrices memory tokenPrices) {
        LatentSwapLogic.LexFullState memory localLEXState = _calculateMarketState(marketDetails);
        return LatentSwapLogic._calculateTokenPrices(marketDetails.lexParams, localLEXState);
    }

    function encodePriceSqrtQ96(uint256 reserve1, uint256 reserve2) internal pure returns (uint160) {
        return Math.sqrt(Math.mulDiv(reserve1, 1 << (FixedPoint.RESOLUTION << 1), reserve2)).toUint160();
    }

    ////////////////////////////////////////////////////////////////////////////////
    // LatentSwapLogic functions
    ////////////////////////////////////////////////////////////////////////////////

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
        uint256 updateFactor;
        uint256 maxDebtValue;
    }

    // @dev - copy of LatentSwapLogic._calculateMarketState, but with memory params
    function _calculateMarketState(
        MarketDetails memory marketDetails
    ) internal view returns (LatentSwapLogic.LexFullState memory marketState) {
        // set _calculateMarketState variables given marketDetails
        MarketParams memory marketParams = marketDetails.marketParams;
        LexParams memory lexParams = marketDetails.lexParams;
        LexConfig memory lexConfig = marketDetails.lexConfig;
        LexState memory lexState = marketDetails.lexState;
        uint256 baseTokenSupply = marketDetails.marketState.baseSupply;
        bool isPreview = true;

        CalcMarketStateVars memory vars;

        ////////////////////////////////////////////////////////////////////////////////
        // Read and cache variables
        marketState.lexState = lexState;
        marketState.lexConfig = lexConfig;
        marketState.baseTokenSupply = baseTokenSupply;

        ////////////////////////////////////////////////////////////////////////////////
        // Read external values

        // read synth token supplies (external call to trusted protocol)
        marketState.supplyAmounts[DEBT] = marketDetails.zToken.totalSupply; //IERC20(marketState.lexConfig.zToken).totalSupply();
        marketState.supplyAmounts[LVRG] = marketDetails.aToken.totalSupply; //IERC20(marketState.lexConfig.aToken).totalSupply();

        // get current baseToken market price from oracle and calculate liquidity ratio
        (marketState.lexState.lastBaseTokenPrice, marketState.liquidityRatioX96) = _readBasePriceAndCalculateLiqRatio(
            marketParams,
            lexParams.targetXvsL,
            marketState.lexConfig.scaleDecimals,
            isPreview
        );

        /// @dev - removed time based accruals and fee calculations

        //////////////////////////////////////////////////////////////////////////////////////
        // Calculate parameters for synth -> dex -> synth transforms (for BASE + DEBT only)
        // @dev - these scaled amounts seek to ensure liquidity < 2^152.
        // so, if liquidity is too big, I would make liquidityScaled ~ 2^152 = liquidity * X96 / divScaleFactorX96.
        // so, divScaleFactorX96 = liquidity * X96 / 2^152 = liquidityRatioX96 * BaseTokenSupply / 2^152;
        // @dev - saturates instead of reverting, meaning liquidity could still be > 2^152 even after applying this scaling.
        // This would only happen in markets where the oracle price * baseTokenSupply itself overflows, and thus an unlikely scenario.
        // if so, it will revert later when calculating liquidity.
        uint256 divScaleFactorX96 = marketState.liquidityRatioX96.saturatingMulShr(marketState.baseTokenSupply, 152);

        // if divScaleFactorX96 < X96, then liquidity already < 2^152.  liquidity = liquidityRatioX96 * BaseTokenSupply / X96
        // if divScaleFactorX96 > X96, then liquidityScaled = 2^152 = liquidityRatioX96 * BaseTokenSupply / divScaleFactorX96
        marketState.dexAmountsScaled[uint8(AssetType.BASE)] = marketState.liquidityRatioX96;
        marketState.synthAmountsScaled[uint8(AssetType.BASE)] = Math.ternary(
            divScaleFactorX96 > FixedPoint.Q96,
            divScaleFactorX96,
            FixedPoint.Q96
        );

        // check that (notionalPrice * debtSupply * X96 / WAD / synthAmountScaled[Base]) does not overflow.
        // we have to use the synthAmountScaled[Base] across all assets to make the market consistent.
        // dex amount cannot be bigger than maxDebt * X96 / synthAmountScaled[Base] < notionalPrice * debtSupply * X96 / WAD / synthAmountScaled[Base]
        // thus, if maxDebt / notionalPrice < debtSupply / WAD, then market is undercollateralized.
        marketState.dexAmountsScaled[uint8(AssetType.DEBT)] = (divScaleFactorX96 > FixedPoint.Q96 &&
            marketState.lexState.lastDebtNotionalPrice < FixedPoint.Q192)
            ? marketState.lexState.lastDebtNotionalPrice * FixedPoint.Q96
            : marketState.lexState.lastDebtNotionalPrice;
        marketState.synthAmountsScaled[uint8(AssetType.DEBT)] = (divScaleFactorX96 > FixedPoint.Q96)
            ? (marketState.lexState.lastDebtNotionalPrice < FixedPoint.Q192)
                ? FixedPoint.WAD * divScaleFactorX96
                : FixedPoint.WAD.mulDiv(divScaleFactorX96, FixedPoint.Q96)
            : FixedPoint.WAD;

        ////////////////////////////////////////////////////////////////////////////////
        // Calculate liquidity from baseTokenSupply
        marketState.liquidity = LatentSwapLogic
            ._synthToDex(marketState, marketState.baseTokenSupply, AssetType.BASE, Math.Rounding.Floor)
            .toUint160();

        ////////////////////////////////////////////////////////////////////////////////
        // calculate values if market has liquidity
        if (marketState.liquidity > 0) {
            // Calculate debt balanced value from zTokenSupply
            marketState.dexAmounts[DEBT] = LatentSwapLogic._synthToDex(
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
            if (marketState.dexAmounts[DEBT] >= vars.maxDebtValue) {
                marketState.lexState.lastSqrtPriceX96 = lexParams.edgeSqrtPriceX96_B;
                marketState.dexAmounts[DEBT] = vars.maxDebtValue;
                marketState.dexAmounts[LVRG] = 0;
                marketState.underCollateralized = true;
            } else {
                // calculate market price and aDexAmount given liquidity and zDexAmount
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
            // there is any debt or leverage tokens in the market, or whether it is an empty market.
            marketState.underCollateralized = (marketState.supplyAmounts[DEBT] > 0);
            marketState.lexState.lastSqrtPriceX96 = (marketState.underCollateralized)
                ? lexParams.edgeSqrtPriceX96_B
                : (marketState.supplyAmounts[LVRG] > 0)
                    ? lexParams.edgeSqrtPriceX96_A
                    : uint160(FixedPoint.Q96);
            marketState.dexAmounts[DEBT] = marketState.dexAmounts[LVRG] = 0;
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // Calculate parameters for synth -> dex -> synth transforms (for LVRG only)
        marketState.dexAmountsScaled[uint8(AssetType.LEVERAGE)] = Math.ternary(
            marketState.supplyAmounts[LVRG] > 0,
            marketState.dexAmounts[LVRG],
            1
        );
        marketState.synthAmountsScaled[uint8(AssetType.LEVERAGE)] = Math.ternary(
            marketState.supplyAmounts[LVRG] > 0,
            marketState.supplyAmounts[LVRG],
            1
        );

        return marketState;
    }

    // @dev - copy of LatentSwapLogic._readBasePriceAndCalculateLiqRatio, but with memory params
    function _readBasePriceAndCalculateLiqRatio(
        MarketParams memory marketParams,
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

        //if (liqRatioX96 < MIN_LIQRATIOX96) revert LSErrors.E_LEX_OraclePriceTooLowForMarket();

        // calculate price
        // @dev - price is the # of quote tokens given 10^18 base tokens ,
        // irrespective of actual # of decimal precision that baseToken or quoteToken has
        price = Math.mulDiv(liqRatioX96, FixedPoint.WAD, scaledLiquidityConcentrationX96);
    }
}

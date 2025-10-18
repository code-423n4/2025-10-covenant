// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

import {ICovenant, MarketParams, MarketState, SynthTokens, AssetType, TokenPrices, MarketId} from "../interfaces/ICovenant.sol";
import {IDataProvider, MarketDetails, SynthDetails, ERC20Details, LexParams} from "./interfaces/IDataProvider.sol";
import {ITokenData} from "../lex/latentswap/interfaces/ITokenData.sol";
import {ILatentSwapLEX} from "../lex/latentSwap/interfaces/ILatentSwapLEX.sol";
import {IERC4626, IERC20, IERC20Metadata} from "@openzeppelin/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {LatentSwapLib} from "./libraries/LatentSwapLib.sol";
import {FixedPoint} from "../lex/latentSwap/libraries/FixedPoint.sol";
import {LatentMath} from "../lex/latentSwap/libraries/LatentMath.sol";

contract DataProvider is IDataProvider {
    function getMarketDetails(
        address covenantLiquid,
        MarketId marketId
    ) external view returns (MarketDetails memory marketsDetails) {
        return _getMarketDetails(covenantLiquid, marketId);
    }

    function getMarketsDetails(
        address covenantLiquid,
        MarketId[] calldata marketIds
    ) external view returns (MarketDetails[] memory marketsDetails) {
        marketsDetails = new MarketDetails[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; ++i) {
            marketsDetails[i] = _getMarketDetails(covenantLiquid, marketIds[i]);
        }
    }

    function _getMarketDetails(
        address covenantLiquid,
        MarketId marketId
    ) internal view returns (MarketDetails memory marketDetails) {
        // Set marketId
        marketDetails.marketId = marketId;

        //get core market data
        marketDetails.marketParams = ICovenant(covenantLiquid).getIdToMarketParams(marketId);
        marketDetails.marketState = ICovenant(covenantLiquid).getMarketState(marketId);

        // get LEX info
        marketDetails.lexState = ILatentSwapLEX(marketDetails.marketParams.lex).getLexState(marketId);
        marketDetails.lexConfig = ILatentSwapLEX(marketDetails.marketParams.lex).getLexConfig(marketId);
        SynthTokens memory synthTokens = ILatentSwapLEX(marketDetails.marketParams.lex).getSynthTokens(marketId);
        marketDetails.lexParams = ILatentSwapLEX(marketDetails.marketParams.lex).getLexParams();

        //get ERC20 info
        marketDetails.baseToken = _getTokenData(
            address(marketDetails.marketParams.lex),
            address(marketDetails.marketParams.baseToken)
        );
        marketDetails.quoteToken = _getTokenData(
            address(marketDetails.marketParams.lex),
            address(marketDetails.marketParams.quoteToken)
        );

        //get synth info
        marketDetails.aToken = _getSynthInfo(synthTokens.aToken);
        marketDetails.zToken = _getSynthInfo(synthTokens.zToken);

        //get supplemental info
        marketDetails.currentLTV = uint32(
            LatentMath.computeLTV(
                marketDetails.lexParams.edgeSqrtPriceX96_A,
                marketDetails.lexParams.edgeSqrtPriceX96_B,
                marketDetails.lexState.lastSqrtPriceX96
            )
        );

        marketDetails.targetLTV = uint32(
            LatentMath.computeLTV(
                marketDetails.lexParams.edgeSqrtPriceX96_A,
                marketDetails.lexParams.edgeSqrtPriceX96_B,
                uint160(FixedPoint.Q96)
            )
        );

        marketDetails.debtPriceDiscount = LatentSwapLib.getDebtDiscount(
            marketDetails.lexState.lastSqrtPriceX96,
            marketDetails.lexParams.edgeSqrtPriceX96_A,
            marketDetails.lexParams.edgeSqrtPriceX96_B
        );

        marketDetails.tokenPrices = LatentSwapLib.getSpotPrices(marketDetails);
    }

    function _getSynthInfo(address token) internal view returns (SynthDetails memory synthDetails) {
        synthDetails.tokenAddress = token;
        synthDetails.name = IERC20Metadata(token).name();
        synthDetails.symbol = IERC20Metadata(token).symbol();
        synthDetails.decimals = IERC20Metadata(token).decimals();
        synthDetails.totalSupply = IERC20(token).totalSupply();
    }

    function _getTokenData(address lex, address token) internal view returns (ERC20Details memory details) {
        details.name = ITokenData(lex).assetName(token);
        details.symbol = ITokenData(lex).assetSymbol(token);
        details.decimals = ITokenData(lex).assetDecimals(token);
    }
}

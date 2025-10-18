// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {LatentSwapLEX, MarketId, MarketParams, AssetType, LatentSwapLogic} from "../../src/lex/latentswap/LatentSwapLex.sol";
import {LatentMath} from "../../src/lex/latentswap/libraries/LatentMath.sol";

/// @notice provide wrapper to expose internal functions for testing purposes
contract MockLatentSwapLEX is LatentSwapLEX {
    uint256 internal _halfLife;

    constructor(
        address initialOwner_,
        address covenantCore_,
        uint160 edgeHighSqrtPriceX96_,
        uint160 edgeLowSqrtPriceX96_,
        uint160 limHighSqrtPriceX96_,
        uint160 limMaxSqrtPriceX96_,
        int64 initLnRateBias_,
        uint32 debtDuration_,
        uint8 swapFee_
    )
        LatentSwapLEX(
            initialOwner_,
            covenantCore_,
            edgeHighSqrtPriceX96_,
            edgeLowSqrtPriceX96_,
            limHighSqrtPriceX96_,
            limMaxSqrtPriceX96_,
            initLnRateBias_,
            debtDuration_,
            swapFee_
        )
    {}

    function getDebtPriceDiscount(MarketId marketId) external view returns (uint256 currentPriceDiscount) {
        return
            LatentSwapLogic.getDebtPriceDiscount(
                _edgeSqrtPriceX96_A,
                _edgeSqrtPriceX96_B,
                lexState[marketId].lastSqrtPriceX96,
                _targetXvsL
            );
    }

    function getLTV(MarketId marketId) external view returns (uint256 currentLTV) {
        return LatentMath.computeLTV(_edgeSqrtPriceX96_A, _edgeSqrtPriceX96_B, lexState[marketId].lastSqrtPriceX96);
    }

    function quoteRatio(
        MarketId marketId,
        MarketParams calldata marketParams,
        uint256 baseTokenSupply,
        AssetType base,
        AssetType quote
    ) external view returns (uint256 price) {
        // Calculate market state (storage read)
        LatentSwapLogic.LexFullState memory currentState = LatentSwapLogic.calculateMarketState(
            marketParams,
            _lexParams(),
            lexConfig[marketId],
            lexState[marketId],
            baseTokenSupply,
            false
        );
        return LatentSwapLogic.calcRatio(_lexParams(), currentState, base, quote);
    }

    function setDebtNotionalPrice(MarketId marketId, uint256 newDebtNotionalPrice) external {
        lexState[marketId].lastDebtNotionalPrice = newDebtNotionalPrice;
    }

    function isUnderCollateralized(
        MarketId marketId,
        MarketParams calldata marketParams,
        uint256 baseTokenSupply
    ) external view returns (bool) {
        // Calculate market state (storage read)
        LatentSwapLogic.LexFullState memory currentState = LatentSwapLogic.calculateMarketState(
            marketParams,
            _lexParams(),
            lexConfig[marketId],
            lexState[marketId],
            baseTokenSupply,
            false
        );
        return currentState.underCollateralized;
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MarketId, MarketParams, MarketState, SynthTokens, TokenPrices} from "../../interfaces/ICovenant.sol";
import {LexState, LexConfig, LexParams} from "../../lex/latentSwap/interfaces/ILatentSwapLEX.sol";

/**
 * @title IDataProvider
 * @author Covenant Labs
 **/
struct ERC20Details {
    string name;
    string symbol;
    uint8 decimals;
}

struct SynthDetails {
    address tokenAddress;
    string name;
    string symbol;
    uint256 totalSupply;
    uint8 decimals;
}

struct MarketDetails {
    MarketId marketId;
    ERC20Details baseToken;
    ERC20Details quoteToken;
    SynthDetails aToken;
    SynthDetails zToken;
    MarketParams marketParams;
    MarketState marketState;
    LexState lexState;
    LexConfig lexConfig;
    LexParams lexParams;
    uint32 currentLTV;
    uint32 targetLTV;
    uint128 debtPriceDiscount;
    TokenPrices tokenPrices;
}

interface IDataProvider {
    function getMarketDetails(
        address covenantLiquid,
        MarketId marketId
    ) external view returns (MarketDetails memory marketDetails);

    function getMarketsDetails(
        address covenantLiquid,
        MarketId[] calldata marketIds
    ) external view returns (MarketDetails[] memory marketsDetails);
}

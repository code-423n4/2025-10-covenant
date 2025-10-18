// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ILiquidExchangeModel, AssetType, MintParams, RedeemParams, SwapParams, MarketId, MarketParams, TokenPrices, SynthTokens} from "src/interfaces/ILiquidExchangeModel.sol";

struct LexState {
    uint256 lastDebtNotionalPrice; // WAD units
    uint256 lastBaseTokenPrice; // Last oracle read WAD units
    uint256 lastETWAPBaseSupply; // Tracks baseSupply for redeem cap
    uint160 lastSqrtPriceX96; // Last DEX price, X96 units
    uint96 lastUpdateTimestamp; // Timestamp in seconds
    int64 lastLnRateBias; // WAD units.
}

struct LexConfig {
    uint32 protocolFee; // Protocol fees in BPS units (uint16 tvlFee, uint16 yieldFee)
    address aToken;
    address zToken;
    uint8 noCapLimit; // Max liquidity mint / burn without a cap limit.  Limit = 2^noCapLimit
    int8 scaleDecimals; // Scale decimals (used for scaling the price from the oracle)
    bool adaptive; // Whether debtPriceDiscountBalanced is adaptive
}

struct LexParams {
    address covenantCore;
    int64 initLnRateBias;
    uint160 edgeSqrtPriceX96_B; // high edge of concentrated liquidity
    uint160 edgeSqrtPriceX96_A; // low edge of concentrated liquidity
    uint160 limHighSqrtPriceX96; // from which _highLTV can be derived (no aToken sales, no zToken buys)
    uint160 limMaxSqrtPriceX96; // from which _maxLTV can be derived (same as _highLTV && no aToken buys)
    uint32 debtDuration; // perpetual duration of debt, in seconds (max 100 years)
    uint8 swapFee; // BPS fee when swapping tokens.  Max of 2.55% swap fee
    uint256 targetXvsL; // pre-calculated static value
}

/**
 * @title ILatentSwapLEX
 * @author Covenant Labs
 * @notice Defines the interface for ILatentSwapLEX.sol
 **/
interface ILatentSwapLEX is ILiquidExchangeModel {
    ///////////////////////////////////////////////////////////////////////////////
    // Getters

    /// @notice LexParams (constructor) getter
    function getLexParams() external view returns (LexParams memory);

    /// @notice LexState getter
    function getLexState(MarketId marketId) external view returns (LexState memory);

    /// @notice LexConfig getter
    function getLexConfig(MarketId marketId) external view returns (LexConfig memory);

    ///////////////////////////////////////////////////////////////////////////////
    // Write functions (only Owner calls)

    /// @notice sets default noCapDecimals for a quote token
    /// @dev setting noCapLimit = 255 removes mint / redeem restriction for markets using this quoteToken
    /// @param token the quote token address
    /// @param newDefaultNoCapLimit the default noCapLimit for markets with this quote token
    function setDefaultNoCapLimit(address token, uint8 newDefaultNoCapLimit) external;

    /// @notice updates the noCapDecimals for a live market
    /// @dev this is useful when the market is live and the quote token is not an actual ERC20
    /// @dev setting noCapLimit = 255 removes mint / redeem restriction for the market
    /// @param marketId the market id
    /// @param newNoCapLimit the noCapLimit for the market (in power of 2).  Markets can mint and redeem baseTokens
    //  wihout mint and redeem caps if baseTokenSupply < 2^nowCapLimt.
    function setMarketNoCapLimit(MarketId marketId, uint8 newNoCapLimit) external;
}

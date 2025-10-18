// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {AssetType, MintParams, RedeemParams, SwapParams, MarketId, MarketParams, TokenPrices, SynthTokens} from "./ICovenant.sol";

/**
 * @title ILiquidExchangeModel
 * @author Covenant Labs
 * @notice Defines the the core interface of Liquid Exchange Models
 **/
interface ILiquidExchangeModel {
    ///////////////////////////////////////////////////////////////////////////////
    // Getters

    /// @notice ProtocolFee getter
    function getProtocolFee(MarketId marketId) external view returns (uint32);

    /// @notice SynthTokens getter
    function getSynthTokens(MarketId marketId) external view returns (SynthTokens memory);

    /// @notice LEX name getter
    function name() external view returns (string memory);

    ///////////////////////////////////////////////////////////////////////////////
    // Write functions (only Covenant calls)

    /// @notice sets protocol Fee for a given market
    function setMarketProtocolFee(MarketId marketId, uint32 newFee) external;

    /// @notice initializes LEX variables for a market
    function initMarket(
        MarketId marketId,
        MarketParams calldata marketParams,
        uint32 protocolFee,
        bytes memory initData
    ) external returns (SynthTokens memory, bytes memory);

    /**
     * @notice calculate Synth tokens to mint given baseLiquidityIn, and updates internal states.
     * @notice does not include fees
     * @param mintParams covenant mint parameters
     * @param baseTokenSupply total baseToken supply in the market
     * @param sender sender of tokens coming in
     * @return aTokenAmountOut amount of aToken to be minted given amountIn
     * @return zTokenAmountOut amount of zToken to be minted given amountIn
     * @return protocolFees calculated protocol fees to be charged
     * @return tokenPrices prices of baseToken, aToken and zToken (in quote tokens) after mint
     **/
    function mint(
        MintParams calldata mintParams,
        address sender,
        uint256 baseTokenSupply
    )
        external
        payable
        returns (
            uint256 aTokenAmountOut,
            uint256 zTokenAmountOut,
            uint128 protocolFees,
            TokenPrices memory tokenPrices
        );

    /**
     * @notice calculates base liquidity out, given synth tokens redeemed, and updates internal states
     * @notice does not include fees
     * @notice Treats amounts as exact input, and does not check for slippage
     * @param redeemParams covenant redeem parameters
     * @param sender sender of tokens coming in
     * @param baseTokenSupply total baseToken supply in the market
     * @return amountOut amount of base token being redeemed
     * @return protocolFees calculated protocol fees to be charged
     * @return tokenPrices prices of baseToken, aToken and zToken (in quote tokens) after redeem
     **/
    function redeem(
        RedeemParams calldata redeemParams,
        address sender,
        uint256 baseTokenSupply
    ) external payable returns (uint256 amountOut, uint128 protocolFees, TokenPrices memory tokenPrices);

    /**
     * @notice calculates swap between tokens (base or synths), and updates internal states
     * @notice does not include fees
     * @dev All parameters are given in raw token decimal encoding.
     * @param swapParams covenant swap parameters
     * @param sender sender of tokens coming in
     * @param baseTokenSupply total baseToken supply in the market
     * @return amountCalculated amount of liquidity swapped out / in, depending on whether swap is EXACT_IN / EXACT_OUT
     * @return protocolFees calculated protocol fees to be charged
     * @return tokenPrices prices of baseToken, aToken and zToken (in quote tokens) after swap
     **/
    function swap(
        SwapParams calldata swapParams,
        address sender,
        uint256 baseTokenSupply
    ) external payable returns (uint256 amountCalculated, uint128 protocolFees, TokenPrices memory tokenPrices);

    /**
     * @notice Updates market state (e.g., accrues debt fees and protocol fees)
     * @dev Calling mint / redeem / swap also updates internal states, but updateState allows a user to update the state without mint / redeem /swapping tokens
     * @param marketId market to update
     * @param marketParams marketParams of market to update
     * @param baseTokenSupply total baseToken supply in the market
     * @param data additional data to send to LEX
     * @return protocolFees calculated protocol fees to be charged
     **/
    function updateState(
        MarketId marketId,
        MarketParams calldata marketParams,
        uint256 baseTokenSupply,
        bytes calldata data
    ) external payable returns (uint128 protocolFees);

    ///////////////////////////////////////////////////////////////////////////////
    // Quote functions (do not update internal state)

    /**
     * @notice calculate Synth tokens to mint given baseLiquidityIn
     * @notice does not include fees
     * @param mintParams covenant mint parameters
     * @param baseTokenSupply total baseToken supply in the market
     * @param sender sender of tokens coming in
     * @return aTokenAmountOut amount of aToken to be minted given amountIn
     * @return zTokenAmountOut amount of zToken to be minted given amountIn
     * @return protocolFees calculated protocol fees to be charged
     * @return oracleUpdateFee fees to pay as msgValue when calling mint() given mintParams.data package, if any
     * @return tokenPrices prices of baseToken, aToken and zToken (in quote tokens) after mint
     **/
    function quoteMint(
        MintParams calldata mintParams,
        address sender,
        uint256 baseTokenSupply
    )
        external
        view
        returns (
            uint256 aTokenAmountOut,
            uint256 zTokenAmountOut,
            uint128 protocolFees,
            uint128 oracleUpdateFee,
            TokenPrices memory tokenPrices
        );

    /**
     * @notice calculates base liquidity out, given synth tokens redeemed
     * @notice does not include fees
     * @notice Treats amounts as exact input, and does not check for slippage
     * @param redeemParams covenant redeem parameters
     * @param sender sender of tokens coming in
     * @param baseTokenSupply total baseToken supply in the market
     * @return baseAmountOut base tokens that would come out
     * @return protocolFees calculated protocol fees to be charged
     * @return oracleUpdateFee fees to pay as msgValue when calling mint() given mintParams.data package, if any
     * @return tokenPrices prices of baseToken, aToken and zToken (in quote tokens) after redeem
     **/
    function quoteRedeem(
        RedeemParams calldata redeemParams,
        address sender,
        uint256 baseTokenSupply
    )
        external
        view
        returns (uint256 baseAmountOut, uint128 protocolFees, uint128 oracleUpdateFee, TokenPrices memory tokenPrices);
    /**
     * @notice calculates swap between tokens (base or synths)
     * @notice does not include fees
     * @dev All parameters are given in raw token decimal encoding.
     * @param swapParams covenant swap parameters
     * @param sender sender of tokens coming in
     * @param baseTokenSupply total baseToken supply in the market
     * @return amountCalculated amount of liquidity swapped out / in, depending on whether swap is EXACT_IN / EXACT_OUT
     * @return protocolFees calculated protocol fees to be charged
     * @return oracleUpdateFee fees to pay as msgValue when calling mint() given mintParams.data package, if any
     * @return tokenPrices prices of baseToken, aToken and zToken (in quote tokens) after swap
     **/
    function quoteSwap(
        SwapParams calldata swapParams,
        address sender,
        uint256 baseTokenSupply
    )
        external
        view
        returns (
            uint256 amountCalculated,
            uint128 protocolFees,
            uint128 oracleUpdateFee,
            TokenPrices memory tokenPrices
        );
}

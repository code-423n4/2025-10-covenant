// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {MarketId, MarketParams, SynthTokens, TokenPrices, AssetType} from "../interfaces/ICovenant.sol";

library Events {
    /**
     * @dev Emitted on market creation
     * @param marketId the market ID
     * @param marketParams the market params
     * @param initData additional data passed to LEX during initialization
     * @param lexData additional data returned by LEX during initialization (ABI encoded)
     **/
    event CreateMarket(
        MarketId indexed marketId,
        MarketParams marketParams,
        SynthTokens synthTokens,
        bytes initData,
        bytes lexData
    );

    /**
     * @dev Emitted on mint
     * @notice Event incorporates minimal price information (from which all prices can be derived)
     * @param marketId the market indicating the aTokens / zTokens to mint given baseToken (there could be more than one market for the same baseToken)
     * @param baseAmountIn the amount of base token to deposit (and against which to mint a and z tokens)
     * @param sender the supplier of base Tokens
     * @param receiver the receiver of aTokens and zTokens
     * @param aTokenAmountOut amount of aToken minted
     * @param zTokenAmountOut amount of zToken minted
     * @param tokenPrices Prices, in WADS, of baseToken, aToken and zToken after action (denominated in Quote tokens)
     **/
    event Mint(
        MarketId indexed marketId,
        uint256 baseAmountIn,
        address indexed sender,
        address indexed receiver,
        uint256 aTokenAmountOut,
        uint256 zTokenAmountOut,
        uint128 protocolFees,
        TokenPrices tokenPrices
    );

    /**
     * @dev Emitted on redeem
     * @param marketId the market for which the aTokens / zTokens will be redeemed for baseToken
     * @param aTokenAmountIn the aTokenAmount being redeemed / burned (exact in)
     * @param zTokenAmountIn the zTokenAmount being redeemed / burned (exact in)
     * @param sender the supplier of a and z tokens
     * @param receiver the receiver of base tokens
     * @param amountOut amount of base tokens sent out to receiver
     * @param tokenPrices Prices, in WADS, of baseToken, aToken and zToken after action (denominated in Quote tokens)
     **/
    event Redeem(
        MarketId indexed marketId,
        uint256 aTokenAmountIn,
        uint256 zTokenAmountIn,
        address indexed sender,
        address indexed receiver,
        uint256 amountOut,
        uint128 protocolFees,
        TokenPrices tokenPrices
    );

    /**
     * @dev Emitted on swap
     * @param marketId the market in which the swap is executed
     * @param assetIn type of token swapped in
     * @param assetOut type of token swapped out
     * @param amountIn amount of tokenIn received and burned by market during swap
     * @param amountOut amount of tokenOut minted and sent by market during swap
     * @param sender the supplier of tokenIn
     * @param receiver the receiver of tokenOut
     * @param tokenPrices Prices, in WADS, of baseToken, aToken and zToken after action (denominated in Quote tokens)
     **/
    event Swap(
        MarketId indexed marketId,
        AssetType assetIn,
        AssetType assetOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed sender,
        address indexed receiver,
        uint128 protocolFees,
        TokenPrices tokenPrices
    );

    /**
     * @dev Emitted on LEX update
     * @param LEXImplementationAddress address of lex logic implementation
     * @param isEnabled whether the address is a valid implementation for new markets
     **/
    event UpdateEnabledLEX(address indexed LEXImplementationAddress, bool isEnabled);

    /**
     * @dev Emitted on Oracle update
     * @param oracle address of oracle
     * @param isEnabled whether the address is a valid oracle for new markets
     **/
    event UpdateEnabledOracle(address indexed oracle, bool isEnabled);

    /**
     * @dev Emitted on update of default protocol fee
     * @param oldDefaultFee old default fee
     * @param newDefaultFee new default fee
     **/
    event UpdateDefaultProtocolFee(uint32 oldDefaultFee, uint32 newDefaultFee);

    /**
     * @dev Emitted on update of a market protocol fee
     * @param marketId market being updated
     * @param oldMarketFee old default fee
     * @param newMarketFee new default fee
     **/
    event UpdateMarketProtocolFee(MarketId indexed marketId, uint32 oldMarketFee, uint32 newMarketFee);

    /**
     * @dev Emitted when protocol fees are collected
     * @param marketId market from which fees are being collected
     * @param recipient recipient of collected fees
     * @param asset asset in which fees are denominated
     * @param amount amount collected
     **/
    event CollectProtocolFee(MarketId indexed marketId, address recipient, address asset, uint128 amount);

    /**
     * @dev Emitted when protocol is paused or unpaused
     * @param marketId market from which fees are being collected
     * @param isPaused whether the market is paused
     **/
    event MarketPaused(MarketId indexed marketId, bool isPaused);

    /**
     * @dev Emitted when default pause address is updated
     * @param oldDefaultPauseAddress old default pause address
     * @param newDefaultPauseAddress new default pause address
     **/
    event UpdateDefaultPauseAddress(address oldDefaultPauseAddress, address newDefaultPauseAddress);

    /**
     * @dev Emitted when authorized pause address for a market is updated
     * @param marketId market from which pause address is being updated
     * @param oldPauseAddress old authorized pause address
     * @param newPauseAddress new authorized pause address
     **/
    event UpdateMarketPauseAddress(MarketId indexed marketId, address oldPauseAddress, address newPauseAddress);
}

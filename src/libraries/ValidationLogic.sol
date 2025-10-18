// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Errors} from "./Errors.sol";
import {MarketId, MarketParams, SwapParams, MintParams, RedeemParams, AssetType} from "../interfaces/ICovenant.sol";
import {MarketParamsLib} from "./MarketParams.sol";
import {UtilsLib} from "./Utils.sol";

/**
 * @title ValidationLogic library
 * @author Covenant Labs
 * @notice Implements functions to validate the different actions of the protocol
 */
library ValidationLogic {
    using MarketParamsLib for MarketParams;

    function checkUpdateParams(MarketId marketId, MarketParams calldata marketParams) internal pure {
        // check marketParams
        if (MarketId.unwrap(marketId) != MarketId.unwrap(marketParams.id())) revert Errors.E_IncorrectMarketParams();
    }

    function checkMintParams(MintParams calldata mintParams) internal pure {
        // check marketParams
        if (MarketId.unwrap(mintParams.marketId) != MarketId.unwrap(mintParams.marketParams.id()))
            revert Errors.E_IncorrectMarketParams();

        // check mintParams
        if (mintParams.baseAmountIn == 0) revert Errors.E_ZeroAmount();
        if (mintParams.to == address(0)) revert Errors.E_ZeroAddress();
    }

    function checkMintOutputs(
        MintParams calldata mintParams,
        uint256 aTokenAmountOut,
        uint256 zTokenAmountOut
    ) internal pure {
        if (aTokenAmountOut < mintParams.minATokenAmountOut) revert Errors.E_CrossedLimit();
        if (zTokenAmountOut < mintParams.minZTokenAmountOut) revert Errors.E_CrossedLimit();
        if (zTokenAmountOut == 0 && aTokenAmountOut == 0) revert Errors.E_InsufficientAmount();
    }

    function checkRedeemParams(RedeemParams calldata redeemParams) internal pure {
        // check marketParams
        if (MarketId.unwrap(redeemParams.marketId) != MarketId.unwrap(redeemParams.marketParams.id()))
            revert Errors.E_IncorrectMarketParams();

        // check redeemParams
        if (redeemParams.aTokenAmountIn == 0 && redeemParams.zTokenAmountIn == 0) revert Errors.E_ZeroAmount();
        if (redeemParams.to == address(0)) revert Errors.E_ZeroAddress();
    }

    function checkRedeemOutputs(
        RedeemParams calldata redeemParams,
        uint256 baseSupply,
        uint256 amountOut
    ) internal pure {
        if (amountOut < redeemParams.minAmountOut) revert Errors.E_CrossedLimit();
        if (amountOut > baseSupply) revert Errors.E_InsufficientAmount();
        if (amountOut == 0) revert Errors.E_InsufficientAmount();
    }

    function checkSwapParams(SwapParams calldata swapParams, uint256 baseSupply) internal pure {
        // check marketParams
        if (MarketId.unwrap(swapParams.marketId) != MarketId.unwrap(swapParams.marketParams.id()))
            revert Errors.E_IncorrectMarketParams();

        // check swapParams
        if (swapParams.amountSpecified == 0) revert Errors.E_ZeroAmount();
        if (swapParams.to == address(0)) revert Errors.E_ZeroAddress();
        if (swapParams.assetOut == swapParams.assetIn) revert Errors.E_EqualSwapAssets();
        if (
            (uint8(swapParams.assetOut) >= uint8(AssetType.COUNT)) ||
            (uint8(swapParams.assetIn) >= uint8(AssetType.COUNT))
        ) revert Errors.E_IncorrectMarketAsset();

        // check if requesting more base tokens than available
        if (
            !swapParams.isExactIn &&
            (swapParams.assetOut == AssetType.BASE) &&
            (swapParams.amountSpecified > baseSupply)
        ) revert Errors.E_InsufficientAmount();
    }

    function checkSwapOutputs(
        SwapParams calldata swapParams,
        uint256 baseSupply,
        uint256 amountCalculated,
        uint256 protocolFees
    ) internal pure {
        if (amountCalculated == 0) {
            if (!swapParams.isExactIn) revert Errors.E_InsufficientAmount();
            // Do not allow 0 input if this is an exactOut swap
            else if (swapParams.assetIn == AssetType.BASE) revert Errors.E_InsufficientAmount(); //  Do not allow zero out swaps with BASE token as input
            // @dev - the above conditions allow exactIn swaps where a Synth token is donated in, but no Base tokens come out (0 output)
            // This is to allow donation of valueless synth dust to the Covenant Protocol.
        }

        // check amounts do not surpass swapParam limits
        if (swapParams.isExactIn) {
            if (amountCalculated < swapParams.amountLimit) revert Errors.E_CrossedLimit(); // check minimum limit is coming out
        } else {
            if (amountCalculated > swapParams.amountLimit) revert Errors.E_CrossedLimit(); // check less than max limit is coming in
        }

        // if Base asset out check base supply limits
        if (
            (swapParams.assetOut == AssetType.BASE) &&
            (((swapParams.isExactIn ? amountCalculated : swapParams.amountSpecified) + protocolFees) > baseSupply)
        ) revert Errors.E_InsufficientAmount();
    }

    function checkMarketParams(
        MarketParams calldata marketParams,
        MarketParams storage storageMarketParams,
        mapping(address LEXimplementation => bool) storage validLEX,
        mapping(address Oracle => bool) storage validCurator
    ) internal view {
        // check whether lex is enabled
        if (!validLEX[address(marketParams.lex)]) revert Errors.E_LEXimplementationNotAuthorized();

        // check whether curator is enabled
        if (!validCurator[address(marketParams.curator)]) revert Errors.E_CuratorNotAuthorized();

        // check whether market already exists
        if (address(storageMarketParams.baseToken) != address(0)) revert Errors.E_MarketAlreadyExists();
    }

    function checkProtocolFee(uint32 protocolFee) internal pure {
        // split out fees
        (uint16 yieldFee, uint16 tvlFee) = UtilsLib.decodeFee(protocolFee);

        if (yieldFee > 3000) revert Errors.E_ProtocolFeeTooHigh(); // 30% max of yield as additional fee
        if (tvlFee > 500) revert Errors.E_ProtocolFeeTooHigh(); // 5% max of tvl as yearly fee
    }
}

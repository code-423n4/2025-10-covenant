// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IERC20} from "./ISynthToken.sol";
import {ILiquidExchangeModel} from "./ILiquidExchangeModel.sol";
import {Events} from "../libraries/Events.sol";
import {Errors} from "../libraries/Errors.sol";

type MarketId is bytes20;

// Parameters that uniquely defines a Covenant market
struct MarketParams {
    address baseToken;
    address quoteToken;
    address curator; // address of the oracle router
    address lex;
}

struct SynthTokens {
    address aToken;
    address zToken;
}

struct MarketState {
    uint256 baseSupply; // total base tokens for market
    uint128 protocolFeeGrowth; // cumulative fee accrued by protocol in base tokens (unclaimed)
    address authorizedPauseAddress; // address authorized to pause market
    uint8 statusFlag; // 0 = uninitialized, 1 = unlocked, 2 = locked, 3 = paused
}

struct SwapParams {
    MarketId marketId;
    MarketParams marketParams;
    AssetType assetIn;
    AssetType assetOut;
    address to;
    uint256 amountSpecified;
    uint256 amountLimit;
    bool isExactIn;
    bytes data;
    uint256 msgValue;
}

struct RedeemParams {
    MarketId marketId;
    MarketParams marketParams;
    uint256 aTokenAmountIn;
    uint256 zTokenAmountIn;
    address to;
    uint256 minAmountOut;
    bytes data;
    uint256 msgValue;
}

struct MintParams {
    MarketId marketId;
    MarketParams marketParams;
    uint256 baseAmountIn;
    address to;
    uint256 minATokenAmountOut;
    uint256 minZTokenAmountOut;
    bytes data;
    uint256 msgValue;
}

struct TokenPrices {
    uint256 baseTokenPrice;
    uint256 aTokenPrice;
    uint256 zTokenPrice;
}

enum AssetType {
    BASE, // index 0
    DEBT, // index 1
    LEVERAGE, // index 2
    COUNT // used to get the count of asset types
}

/**
 * @title ICovenant
 * @author Covenant Labs
 * @notice Defines the the core interface of Covenant Liquid markets.
 **/
interface ICovenant {
    /// @notice Covenant name getter
    function name() external view returns (string memory);

    /// @notice MarketParams getter
    function getIdToMarketParams(MarketId marketId) external view returns (MarketParams memory);

    /// @notice MarketState getter
    function getMarketState(MarketId marketId) external view returns (MarketState memory);

    /// @notice Whether the LEX is enabled.
    function isLexEnabled(address lex) external view returns (bool);

    /// @notice Whether the Curator (oracle router) is enabled.
    function isCuratorEnabled(address curator) external view returns (bool);

    /**
     * @notice creates a new Covenant Liquid market
     * @param marketParams market initialization parameters
     **/
    function createMarket(MarketParams calldata marketParams, bytes calldata initData) external returns (MarketId);

    /**
     * @notice mints aTokens and zTokens from base tokens.
     * @param mintParams mint parameters, as detailed below:
     * - marketId: the marketId
     * - marketParams: the marketParams (can be derived from Id by caller using getIdToMarketParams)
     * - baseAmountIn: the amount of base token to deposit (and against which to mint a and z tokens)
     * - to: the receiver of aTokens and zTokens
     * - minATokenAmountOut: minimum ATokens out
     * - minZTokenAmountOut: minimum Ztokens out
     * - data: additional data to send to LEX
     * - msgValue: msgValue to send to LEX if needed
     * @return aTokenAmountOut amount of aToken minted
     * @return zTokenAmountOut amount of zToken minted
     **/
    function mint(
        MintParams calldata mintParams
    ) external payable returns (uint256 aTokenAmountOut, uint256 zTokenAmountOut);

    /**
     * @notice Redeems aTokenAmount and zTokenAmount for base token.
     * @notice Treats amounts as exact input, and does not check for slippage
     * @dev This function send to LEX msgValue, but does not check whether msg.Value == msgValue (this is done to enable multicalls)
     * @dev This means that calling with msgValue > msg.Value will revert, and msgValue < msg.Value
     * @dev will leave excess value in the Covenant contract (which can be used by subsequent function calls or users)
     * @param redeemParams redeem parameters, as follows:
     * - marketId: the marketId
     * - marketParams: the marketParams (can be derived from Id by caller using getIdToMarketParams)
     * - aTokenAmountIn: the aTokenAmount being redeemed / burned (exact in)
     * - zTokenAmountIn: the zTokenAmount being redeemed / burned (exact in)
     * - to: the receiver of base tokens
     * - minAmountOut: the minimum amount of base token out (for slippage / MEV protection)
     * - data: additional data to send to LEX
     * - msgValue: msgValue to send to LEX if needed
     * @return baseAmountOut actual base tokens redeemed
     **/
    function redeem(RedeemParams calldata redeemParams) external payable returns (uint256 baseAmountOut);

    /**
     * @notice Executes a swap between any of the base, aToken, or zToken assets
     * @dev All parameters are given in raw token decimal encoding.
     * @dev function returns error if assets being swapped are not part of the same market
     * @dev swapping between aTokens / zTokens actually mints / burns tokens
     * @dev This function send to LEX msgValue, but does not check whether msg.Value == msgValue (this is done to enable multicalls)
     * @dev This means that calling with msgValue > msg.Value will revert, and msgValue < msg.Value
     * @dev will leave excess value in the Covenant contract (which can be used by subsequent function calls or users)
     * @param swapParams swap parameters
     * - marketId: the marketId
     * - marketParams: the marketParams (can be derived from Id by caller using getIdToMarketParams)
     * - assetIn: AssetType in
     * - assetOut: AssetType out
     * - to: the receiver of base tokens
     * - amountSpecified: swap amount specified (amount in, if isExactIn == true)
     * - amountLimit: swap reverts if less than amountLimit is return (if isExactIn), or more than amountLimit is expected as input (if !isExactIn)
     * - isExactIn: whether swap is exact in, or exact out
     * - data: additional data to send to LEX
     * - msgValue: msgValue to send to LEX if needed
     * @return amount amount of tokens swapped out / in, depending on whether swap isExactIn
     **/
    function swap(SwapParams calldata swapParams) external payable returns (uint256 amount);

    /**
     * @notice Updates market state (e.g., accrues debt fees and protocol fees)
     * @dev Calling mint / redeem / swap also updates internal states, but updateState allows a user to update the state without mint / redeem /swapping tokens
     * @dev This function send to LEX msgValue, but does not check whether msg.Value == msgValue (this is done to enable multicalls)
     * @dev This means that calling with msgValue > msg.Value will revert, and msgValue < msg.Value
     * @dev will leave excess value in the Covenant contract (which can be used by subsequent function calls or users)
     * @param marketId market to update
     * @param marketParams marketParams of market to update
     * @param data additional data to send to LEX
     * @param msgValue msgValue to send to LEX if needed
     **/
    function updateState(
        MarketId marketId,
        MarketParams calldata marketParams,
        bytes calldata data,
        uint256 msgValue
    ) external payable;

    /**
     * @notice previews mint of aTokens and zTokens from base tokens, without changing market state
     * @notice Treats amounts as exact input, runs validation logic as actual mint call
     * @param mintParams mint parameters, as detailed below:
     * - marketId: the marketId
     * - marketParams: the marketParams (can be derived from Id by caller using getIdToMarketParams)
     * - baseAmountIn: the amount of base token to deposit (and against which to mint a and z tokens)
     * - to: the receiver of aTokens and zTokens
     * - minATokenAmountOut: minimum ATokens out
     * - minZTokenAmountOut: minimum Ztokens out
     * @return aTokenAmountOut amount of aToken minted
     * @return zTokenAmountOut amount of zToken minted
     * @return protocolFees amount of fee charged by protocol in base tokens
     * @return oracleUpdateFee fees to pay as msgValue when calling mint() given mintParams.data package, if any
     * @return tokenPrices returns the dex prices after the action
     **/
    function previewMint(
        MintParams calldata mintParams
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
     * @notice previews redeem of aTokenAmount and zTokenAmount for base token, without changing market state.
     * @notice Treats amounts as exact input, runs validation logic as actual redeem call
     * @param redeemParams redeem parameters, as follows:
     * - marketId: the marketId
     * - marketParams: the marketParams (can be derived from Id by caller using getIdToMarketParams)
     * - aTokenAmountIn: the aTokenAmount being redeemed / burned (exact in)
     * - zTokenAmountIn: the zTokenAmount being redeemed / burned (exact in)
     * - to: the receiver of base tokens
     * - minAmountOut: the minimum amount of base token out (for slippage / MEV protection)
     * @return amountOut actual base tokens redeemed
     * @return protocolFees amount of fee charged by protocol in base tokens
     * @return oracleUpdateFee fees to pay as msgValue when calling mint() given mintParams.data package, if any
     * @return tokenPrices returns the dex prices after the action
     **/
    function previewRedeem(
        RedeemParams calldata redeemParams
    )
        external
        view
        returns (uint256 amountOut, uint128 protocolFees, uint128 oracleUpdateFee, TokenPrices memory tokenPrices);

    /**
     * @notice Calculates output of a swap between any of the base, aToken, or zToken assets, without changing market
     * @notice Runs validation logic as actual swap call
     * @param swapParams swap parameters
     * - marketId: the marketId
     * - marketParams: the marketParams (can be derived from Id by caller using getIdToMarketParams)
     * - assetIn: AssetType in
     * - assetOut: AssetType out
     * - to: the receiver of base tokens
     * - amountSpecified: swap amount specified (amount in, if isExactIn == true)
     * - amountLimit: swap reverts if less than amountLimit is return (if isExactIn), or more than amountLimit is expected as input (if !isExactIn)
     * - isExactIn: whether swap is exact in, or exact out
     * @return amountCalc amount of tokens swapped out / in, depending on whether swap is EXACT_IN / EXACT_OUT
     * @return protocolFees amount of fee charged by protocol in base tokens
     * @return oracleUpdateFee fees to pay as msgValue when calling mint() given mintParams.data package, if any
     * @return tokenPrices returns the dex prices after the action
     **/
    function previewSwap(
        SwapParams calldata swapParams
    )
        external
        view
        returns (uint256 amountCalc, uint128 protocolFees, uint128 oracleUpdateFee, TokenPrices memory tokenPrices);

    /**
     * @notice Payable multicall
     * @notice Does not check msg.value received.  Instead, it uses any msgValues encoded in data and sends those onwards
     * @notice This means that calling multicall where sum(data(msgValues)) > msg.Value will revert, and
     * @notice sum(data(msgValues)) < msg.Value will leave excess value in the Covenant contract (which can be used by subsequent users)
     * @param data array of call data
     * @return results an array of return info
     */
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);

    /////////////////////////////////////////////////////////////////////////////////
    // Restricted functions

    /// @notice Set valid LEX contracts (onlyOwner)
    /// @notice Disabling a LEX does not allow new markets with this LEX
    /// but does not invalidate already created markets
    function setEnabledLEX(address lex, bool isValid) external;

    /// @notice Set valid Curator (oracle router) contracts (onlyOwner)
    /// @notice Disabling a Curator does not allow new markets with this Curator
    /// but does not invalidate already created markets
    function setEnabledCurator(address curator, bool isValid) external;

    /// @notice Set default protocol fee (onlyOwner)
    function setDefaultFee(uint32 newFee) external;

    /// @notice Set protocol fee for a market (onlyOwner)
    function setMarketProtocolFee(
        MarketId marketId,
        MarketParams calldata marketParams,
        bytes calldata data,
        uint256 msgValue,
        uint32 newFee
    ) external payable;

    /// @notice Collect protocol fees for a market (onlyOwner)
    function collectProtocolFee(MarketId marketId, address recipient, uint128 amountRequested) external;

    /// @notice Pause a market (only authorized pause address)
    function setMarketPause(MarketId marketId, bool isPaused) external;

    /// @notice Set default pause address (onlyOwner)
    function setDefaultPauseAddress(address newPauseAddress) external;

    /// @notice Set pause address for a market (onlyOwner)
    function setMarketPauseAddress(MarketId marketId, address newPauseAddress) external;
}

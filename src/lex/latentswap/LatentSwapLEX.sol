// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {ILatentSwapLEX, LexState, LexConfig, AssetType, MintParams, RedeemParams, SwapParams, MarketId, MarketParams, TokenPrices, SynthTokens, LexParams} from "./interfaces/ILatentSwapLEX.sol";
import {ILiquidExchangeModel} from "../../interfaces/ILiquidExchangeModel.sol";
import {ISynthToken, IERC20} from "../../interfaces/ISynthToken.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {ITokenData} from "./interfaces/ITokenData.sol";
import {TokenData} from "./libraries/TokenData.sol";
import {FixedPoint} from "./libraries/FixedPoint.sol";
import {LSErrors} from "./libraries/LSErrors.sol";
import {LatentSwapLogic} from "./libraries/LatentSwapLogic.sol";
import {SynthToken} from "../../synths/SynthToken.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/access/Ownable2Step.sol";

/**
 * @title Latent Swap LEX
 * @author Covenant Labs
 **/

/**
 * @dev Emitted when default noCapLimit is set for a token
 * @param token the token address
 * @param oldDefaultNoCapLimit the old default noCapLimit for markets with this quote token
 * @param newDefaultNoCapLimit the new default noCapLimit for markets with this quote token
 **/
event SetDefaultNoCapLimit(address indexed token, uint8 oldDefaultNoCapLimit, uint8 newDefaultNoCapLimit);
event SetMarketNoCapLimit(MarketId indexed marketId, uint8 oldNoCapLimit, uint8 newNoCapLimit);

contract LatentSwapLEX is ILatentSwapLEX, TokenData, Ownable2Step {
    /// @inheritdoc ILiquidExchangeModel
    string public constant name = "LatentSwap V1.0"; // LEX name

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Constants and immutables
    uint16 constant MAX_LIMIT_LTV = 9999; // 99.99% max limit LTV, above which aTokens cannot be minted.
    uint104 constant MAX_SQRTPRICE = uint104(8 * FixedPoint.Q96); // 64 max DEX price
    uint104 constant MIN_SQRTPRICE = uint104(FixedPoint.Q96 / 32); // 0.001 min DEX price
    uint104 constant MIN_SQRTPRICE_RATIO = uint104((1004 * FixedPoint.Q96) / 1000); // (1.0001)^80 MIN price width = 1.004 MIN sqrt price ratio.  Given this,  max market concentration is max 2^8. ie, Liquidity <= (BaseTokenValue * 2^8)
    int64 constant MAX_LN_RATE_BIAS = 405465108108164000; // ln(1.5) in WADs -> 50% max rate bias
    int64 constant MIN_LN_RATE_BIAS = -223143551314209704; // ln(0.8) in WADs -> -20% min rate bias
    uint32 constant MIN_DURATION = 1 days; // 1 day (in seconds)
    uint8 constant DEBT = 0; // used for indexing into supplyAmounts and dexAmounts
    uint8 constant LVRG = 1; // used for indexing into supplyAmounts and dexAmounts

    // Immutables
    address internal immutable _covenantCore;
    int64 internal immutable _initLnRateBias; // ln of initial rate bias (WADs)
    uint160 internal immutable _edgeSqrtPriceX96_B; // high edge of concentrated liquidity
    uint160 internal immutable _edgeSqrtPriceX96_A; // low edge of concentrated liquidity
    uint160 internal immutable _limHighSqrtPriceX96; // from which _highLTV can be derived (no aToken sales, no zToken buys)
    uint160 internal immutable _limMaxSqrtPriceX96; // from which _maxLTV can be derived (same as _highLTV && no aToken buys)
    uint32 internal immutable _debtDuration; // perpetual duration of debt, in seconds (max 100 years)
    uint8 internal immutable _swapFee; // BPS fee when swapping tokens.  Max of 2.55% swap fee

    // pre-calculated values
    uint256 internal immutable _targetXvsL; // pre-calculated static value, X96 precision

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Storage

    // Map of Lex market states (marketId to data)
    mapping(MarketId marketId => LexState) internal lexState;

    // Map of Lex market configs (marketId to data)
    mapping(MarketId marketId => LexConfig) internal lexConfig;

    // Map of default NoCapLimit overrides for specific token addresses
    mapping(address token => uint8) internal tokenNoCapLimit;

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Modifiers
    modifier onlyCovenantCore() {
        if (_covenantCore != _msgSender()) revert LSErrors.E_LEX_OnlyCovenantCanCall();
        _;
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Constructor

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
    ) Ownable(initialOwner_) {
        // checks
        if (covenantCore_ == address(0)) revert LSErrors.E_LEX_ZeroAddress();

        // Check correct price ordering
        if (edgeHighSqrtPriceX96_ < limMaxSqrtPriceX96_) revert LSErrors.E_LEX_IncorrectInitializationPrice();
        if (limMaxSqrtPriceX96_ <= limHighSqrtPriceX96_) revert LSErrors.E_LEX_IncorrectInitializationPrice();
        if (limHighSqrtPriceX96_ <= FixedPoint.Q96) revert LSErrors.E_LEX_IncorrectInitializationPrice();
        if (FixedPoint.Q96 < edgeLowSqrtPriceX96_) revert LSErrors.E_LEX_IncorrectInitializationPrice();
        if (initLnRateBias_ > MAX_LN_RATE_BIAS || initLnRateBias_ < MIN_LN_RATE_BIAS)
            revert LSErrors.E_LEX_IncorrectInitializationLnRateBias();
        if (debtDuration_ < MIN_DURATION) revert LSErrors.E_LEX_IncorrectInitializationDuration();

        // check vs hardcoded limits
        if (edgeHighSqrtPriceX96_ > MAX_SQRTPRICE) revert LSErrors.E_LEX_IncorrectInitializationPrice();
        if (edgeLowSqrtPriceX96_ < MIN_SQRTPRICE) revert LSErrors.E_LEX_IncorrectInitializationPrice();
        if (((edgeHighSqrtPriceX96_ * FixedPoint.Q96) / edgeLowSqrtPriceX96_) < MIN_SQRTPRICE_RATIO)
            revert LSErrors.E_LEX_IncorrectInitializationPrice();

        // calculate maxLTV and target_dXdL_X96
        (uint256 maxLTV, uint256 target_dXdL_X96) = LatentSwapLogic.computeMaxLTVandTargetdXdL(
            edgeLowSqrtPriceX96_,
            edgeHighSqrtPriceX96_,
            limMaxSqrtPriceX96_
        );

        // check limMax <= MAX_LIMIT_LTV
        if (maxLTV > MAX_LIMIT_LTV) revert LSErrors.E_LEX_IncorrectInitializationPrice();

        // set implementation immutables
        _covenantCore = covenantCore_;
        _edgeSqrtPriceX96_B = edgeHighSqrtPriceX96_;
        _edgeSqrtPriceX96_A = edgeLowSqrtPriceX96_;
        _limHighSqrtPriceX96 = limHighSqrtPriceX96_;
        _limMaxSqrtPriceX96 = limMaxSqrtPriceX96_;
        _initLnRateBias = initLnRateBias_;
        _debtDuration = debtDuration_;
        _swapFee = swapFee_;

        // Pre-calculate static values
        // This is equivalent to dX/dL at the target price of 1
        _targetXvsL = target_dXdL_X96;
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // OnlyOwner functions

    /// @inheritdoc ILatentSwapLEX
    function setDefaultNoCapLimit(address token, uint8 newDefaultMintRedeemNoCap) external onlyOwner {
        // @dev - if defaultMintRedeemNoCap == 0, new markets will use 1 baseToken as the MintRedeemNoCap as the default
        uint8 oldDefaulNoCapLimit = tokenNoCapLimit[token];
        tokenNoCapLimit[token] = newDefaultMintRedeemNoCap;
        emit SetDefaultNoCapLimit(token, oldDefaulNoCapLimit, newDefaultMintRedeemNoCap);
    }

    /// @inheritdoc ILatentSwapLEX
    function setMarketNoCapLimit(MarketId marketId, uint8 newNoCapLimit) external onlyOwner {
        if (lexConfig[marketId].aToken == address(0)) revert LSErrors.E_LEX_MarketDoesNotExist();
        uint8 oldNoCapLimit = lexConfig[marketId].noCapLimit;
        lexConfig[marketId].noCapLimit = newNoCapLimit;
        emit SetMarketNoCapLimit(marketId, oldNoCapLimit, newNoCapLimit);
    }

    function setQuoteTokenDecimalsOverrideForNewMarkets(address asset, uint8 newDecimals) external onlyOwner {
        _updateAssetDecimals(asset, newDecimals);
    }

    function setQuoteTokenSymbolOverrideForNewMarkets(address asset, string calldata newSymbol) external onlyOwner {
        _updateAssetSymbol(asset, newSymbol);
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // ILiquidExchangeModel Getters

    /// @inheritdoc ILiquidExchangeModel
    function getProtocolFee(MarketId marketId) external view returns (uint32) {
        return lexConfig[marketId].protocolFee;
    }

    /// @inheritdoc ILiquidExchangeModel
    function getSynthTokens(MarketId marketId) external view returns (SynthTokens memory synthTokens) {
        synthTokens.aToken = lexConfig[marketId].aToken;
        synthTokens.zToken = lexConfig[marketId].zToken;
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // ILatentSwapLEX Getters

    /// @inheritdoc ILatentSwapLEX
    function getLexParams() external view returns (LexParams memory) {
        return _lexParams();
    }

    /// @inheritdoc ILatentSwapLEX
    function getLexState(MarketId marketId) external view returns (LexState memory) {
        return lexState[marketId];
    }

    /// @inheritdoc ILatentSwapLEX
    function getLexConfig(MarketId marketId) external view returns (LexConfig memory) {
        return lexConfig[marketId];
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // CovenantCore actions

    /// @inheritdoc ILiquidExchangeModel
    function initMarket(
        MarketId marketId,
        MarketParams calldata marketParams,
        uint32 protocolFee,
        bytes calldata initData
    ) external onlyCovenantCore returns (SynthTokens memory synthTokens, bytes memory lexData) {
        if (lexConfig[marketId].aToken != address(0)) revert LSErrors.E_LEX_AlreadyInitialized();

        LatentSwapLogic.MarketInitInfo memory info = LatentSwapLogic.getInitMarketInfo(
            marketParams,
            _debtDuration,
            _edgeSqrtPriceX96_A,
            _edgeSqrtPriceX96_B,
            tokenNoCapLimit[marketParams.baseToken],
            _assetDecimals(marketParams.quoteToken),
            _assetSymbol(marketParams.quoteToken)
        );

        // Create new leverage synth token
        // e.g., Symbol: ETHx2.USDT  Name: ETH x2 Leverage Coin (USDT/3M)
        synthTokens.aToken = address(
            new SynthToken(
                _covenantCore,
                address(this),
                marketId,
                IERC20(marketParams.baseToken),
                AssetType.LEVERAGE,
                info.aTokenName,
                info.aTokenSymbol,
                info.synthDecimals
            )
        );

        // Create new debt synth token
        // e.g., Symbol: USDT.bETH  Name: USDT ETH-backed Margin Coin (x2/3M)
        synthTokens.zToken = address(
            new SynthToken(
                _covenantCore,
                address(this),
                marketId,
                IERC20(marketParams.baseToken),
                AssetType.DEBT,
                info.zTokenName,
                info.zTokenSymbol,
                info.synthDecimals
            )
        );

        // Read oracle (current market price) - revert on error
        // @dev this can revert if the Oracle does not return a price, or if
        // price * (1/_targetXvsL) * (10 ^ (vars.synthDecimals - vars.quoteDecimals)) is too small
        // given oracle price being too low given other market parameters
        (uint256 currentBasePrice, ) = LatentSwapLogic.readBasePriceAndCalculateLiqRatio(
            marketParams,
            _targetXvsL,
            int8(info.quoteDecimals) - int8(info.synthDecimals),
            false
        );

        // Initialize lex config
        lexConfig[marketId] = LexConfig({
            aToken: synthTokens.aToken,
            zToken: synthTokens.zToken,
            protocolFee: protocolFee,
            noCapLimit: info.noCapLimit,
            scaleDecimals: int8(info.quoteDecimals) - int8(info.synthDecimals),
            adaptive: false
        });

        // Initialize lex state
        lexState[marketId] = LexState({
            lastBaseTokenPrice: currentBasePrice,
            lastDebtNotionalPrice: FixedPoint.WAD, //Notice: Upon market initialization, 1 zToken = 1 quoteToken in value
            lastLnRateBias: _initLnRateBias,
            lastETWAPBaseSupply: 0,
            lastSqrtPriceX96: uint160(FixedPoint.Q96), //Notice: Upon market initialization, market is at target LTV
            lastUpdateTimestamp: uint96(block.timestamp)
        });
    }

    /// @inheritdoc ILiquidExchangeModel
    function setMarketProtocolFee(MarketId marketId, uint32 newFee) external onlyCovenantCore {
        lexConfig[marketId].protocolFee = newFee;
    }

    /// @inheritdoc ILiquidExchangeModel
    // @Notice. When depositing baseTokens, how many aTokens and zTokens should be minted?
    // Target is not to have price impact from this operation, so minted amounts are all proportional
    // @dev - sender address not used (left empty)
    function mint(
        MintParams calldata mintParams,
        address,
        uint256 baseTokenSupply
    )
        external
        payable
        onlyCovenantCore
        returns (uint256 aTokenAmountOut, uint256 zTokenAmountOut, uint128 protocolFees, TokenPrices memory tokenPrices)
    {
        // Update oracle price if necessary (external call and storage write)
        _updateOraclePrice(mintParams.marketParams, mintParams.data);

        ///////////////////////////////
        // Mint logic
        LatentSwapLogic.LexFullState memory currentState;
        (currentState, tokenPrices, aTokenAmountOut, zTokenAmountOut) = LatentSwapLogic.mintLogic(
            mintParams,
            _lexParams(),
            lexConfig[mintParams.marketId],
            lexState[mintParams.marketId],
            baseTokenSupply,
            false
        );

        ///////////////////////////////
        // Write changes (storage writes)

        // Mint aTokens / zTokens (storage write)
        ISynthToken(currentState.lexConfig.aToken).lexMint(mintParams.to, aTokenAmountOut);
        ISynthToken(currentState.lexConfig.zToken).lexMint(mintParams.to, zTokenAmountOut);

        // Update lex state (storage write)
        lexState[mintParams.marketId] = currentState.lexState;

        return (aTokenAmountOut, zTokenAmountOut, currentState.accruedProtocolFee, tokenPrices);
    }

    /// @inheritdoc ILiquidExchangeModel
    // @Notice. When redeeming baseTokens, we might require to swap aTokens for zTokens before doing a balanced redeem operation
    // We calculate amount of baseTokens redeemed using stableMath logic.
    function redeem(
        RedeemParams calldata redeemParams,
        address sender,
        uint256 baseTokenSupply
    )
        external
        payable
        onlyCovenantCore
        returns (uint256 amountOut, uint128 protocolFees, TokenPrices memory tokenPrices)
    {
        // Update oracle price if necessary (external call and storage write) and check for overdeposit
        _updateOraclePrice(redeemParams.marketParams, redeemParams.data);

        ///////////////////////////////
        // Redeem logic
        LatentSwapLogic.LexFullState memory currentState;
        (currentState, tokenPrices, amountOut) = LatentSwapLogic.redeemLogic(
            redeemParams,
            _lexParams(),
            lexConfig[redeemParams.marketId],
            lexState[redeemParams.marketId],
            baseTokenSupply,
            false
        );

        ///////////////////////////////
        // Write changes (storage writes)

        // Burn aTokens / zTokens (storage write)
        ISynthToken(currentState.lexConfig.aToken).lexBurn(sender, redeemParams.aTokenAmountIn);
        ISynthToken(currentState.lexConfig.zToken).lexBurn(sender, redeemParams.zTokenAmountIn);

        // Update lex state (storage write)
        lexState[redeemParams.marketId] = currentState.lexState;

        return (amountOut, currentState.accruedProtocolFee, tokenPrices);
    }

    /// @inheritdoc ILiquidExchangeModel
    function swap(
        SwapParams calldata swapParams,
        address sender,
        uint256 baseTokenSupply
    )
        external
        payable
        onlyCovenantCore
        returns (uint256 amountCalculated, uint128 protocolFees, TokenPrices memory tokenPrices)
    {
        // Update oracle price if necessary (external call and storage write) and check for overdeposit
        _updateOraclePrice(swapParams.marketParams, swapParams.data);

        ///////////////////////////////
        // Swap logic
        LatentSwapLogic.LexFullState memory currentState;
        (currentState, tokenPrices, amountCalculated) = LatentSwapLogic.swapLogic(
            swapParams,
            _lexParams(),
            lexConfig[swapParams.marketId],
            lexState[swapParams.marketId],
            baseTokenSupply,
            false
        );

        ///////////////////////////////
        // Write changes (storage writes)

        // Burn aTokens / zTokens coming in (storage write in trusted external call)
        if (swapParams.assetIn != AssetType.BASE)
            ISynthToken(
                (swapParams.assetIn == AssetType.DEBT) ? currentState.lexConfig.zToken : currentState.lexConfig.aToken
            ).lexBurn(sender, (swapParams.isExactIn) ? swapParams.amountSpecified : amountCalculated);
        // Mint aTokens / zTokens going out (storage write in trusted external call)
        if (swapParams.assetOut != AssetType.BASE)
            ISynthToken(
                (swapParams.assetOut == AssetType.DEBT) ? currentState.lexConfig.zToken : currentState.lexConfig.aToken
            ).lexMint(swapParams.to, (swapParams.isExactIn) ? amountCalculated : swapParams.amountSpecified);

        // Update lex state (storage write)
        lexState[swapParams.marketId] = currentState.lexState;

        return (amountCalculated, currentState.accruedProtocolFee, tokenPrices);
    }

    /// @inheritdoc ILiquidExchangeModel
    function updateState(
        MarketId marketId,
        MarketParams calldata marketParams,
        uint256 baseTokenSupply,
        bytes calldata data
    ) external payable onlyCovenantCore returns (uint128 protocolFees) {
        // Update oracle price if necessary (external call and storage write) and check for overdeposit
        _updateOraclePrice(marketParams, data);

        // Calculate market state (storage read)
        LatentSwapLogic.LexFullState memory currentState = LatentSwapLogic.calculateMarketState(
            marketParams,
            _lexParams(),
            lexConfig[marketId],
            lexState[marketId],
            baseTokenSupply,
            false
        );

        // Update lex state (storage write)
        lexState[marketId] = currentState.lexState;

        return currentState.accruedProtocolFee;
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Quotes

    /// @inheritdoc ILiquidExchangeModel
    function quoteMint(
        MintParams calldata mintParams,
        address,
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
        )
    {
        oracleUpdateFee = _getOracleUpdateFee(mintParams.marketParams, mintParams.data); // Get oracle update fee, if any
        LatentSwapLogic.LexFullState memory currentState;
        (currentState, tokenPrices, aTokenAmountOut, zTokenAmountOut) = LatentSwapLogic.mintLogic(
            mintParams,
            _lexParams(),
            lexConfig[mintParams.marketId],
            lexState[mintParams.marketId],
            baseTokenSupply,
            true
        );
        return (aTokenAmountOut, zTokenAmountOut, currentState.accruedProtocolFee, oracleUpdateFee, tokenPrices);
    }

    /// @inheritdoc ILiquidExchangeModel
    function quoteRedeem(
        RedeemParams calldata redeemParams,
        address,
        uint256 baseTokenSupply
    )
        external
        view
        returns (uint256 amountOut, uint128 protocolFees, uint128 oracleUpdateFee, TokenPrices memory tokenPrices)
    {
        oracleUpdateFee = _getOracleUpdateFee(redeemParams.marketParams, redeemParams.data); // Get oracle update fee, if any
        LatentSwapLogic.LexFullState memory currentState;
        (currentState, tokenPrices, amountOut) = LatentSwapLogic.redeemLogic(
            redeemParams,
            _lexParams(),
            lexConfig[redeemParams.marketId],
            lexState[redeemParams.marketId],
            baseTokenSupply,
            true
        );
        return (amountOut, currentState.accruedProtocolFee, oracleUpdateFee, tokenPrices);
    }

    /// @inheritdoc ILiquidExchangeModel
    function quoteSwap(
        SwapParams calldata swapParams,
        address,
        uint256 baseTokenSupply
    )
        external
        view
        returns (
            uint256 amountCalculated,
            uint128 protocolFees,
            uint128 oracleUpdateFee,
            TokenPrices memory tokenPrices
        )
    {
        oracleUpdateFee = _getOracleUpdateFee(swapParams.marketParams, swapParams.data); // Get oracle update fee, if any
        LatentSwapLogic.LexFullState memory currentState;
        (currentState, tokenPrices, amountCalculated) = LatentSwapLogic.swapLogic(
            swapParams,
            _lexParams(),
            lexConfig[swapParams.marketId],
            lexState[swapParams.marketId],
            baseTokenSupply,
            true
        );
        return (amountCalculated, currentState.accruedProtocolFee, oracleUpdateFee, tokenPrices);
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Internal functions

    function _lexParams() internal view returns (LexParams memory lexParams) {
        return
            LexParams({
                covenantCore: _covenantCore,
                initLnRateBias: _initLnRateBias, // Init rate bias (in LN terms, WADs)
                edgeSqrtPriceX96_B: _edgeSqrtPriceX96_B, // high edge of concentrated liquidity
                edgeSqrtPriceX96_A: _edgeSqrtPriceX96_A, // low edge of concentrated liquidity
                limHighSqrtPriceX96: _limHighSqrtPriceX96, // from which _highLTV can be derived (no aToken sales, no zToken buys)
                limMaxSqrtPriceX96: _limMaxSqrtPriceX96, // from which _maxLTV can be derived (same as _highLTV && no aToken buys)
                debtDuration: _debtDuration, // perpetual duration of debt, in seconds (max 100 years)
                swapFee: _swapFee, // BPS fee when swapping tokens.  Max of 2.55% swap fee
                targetXvsL: _targetXvsL // pre-calculated liquidity concentration
            });
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Pull Oracle functions

    // updatePrices if there is data
    function _updateOraclePrice(MarketParams calldata marketParams, bytes calldata data) internal {
        // send data package and msgValue to Oracle, if data was sent
        if (data.length > 0)
            IPriceOracle(marketParams.curator).updatePriceFeeds{value: msg.value}(
                marketParams.baseToken,
                marketParams.quoteToken,
                data
            );
        else if (msg.value > 0) revert LSErrors.E_LEX_Overdeposit();
    }

    function _getOracleUpdateFee(
        MarketParams calldata marketParams,
        bytes calldata data
    ) internal view returns (uint128 oracleFee) {
        return
            (data.length > 0)
                ? IPriceOracle(marketParams.curator).getUpdateFee(marketParams.baseToken, marketParams.quoteToken, data)
                : 0;
    }
}

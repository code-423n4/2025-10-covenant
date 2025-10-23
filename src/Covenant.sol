// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {ICovenant, MarketId, MarketParams, MarketState, SwapParams, RedeemParams, MintParams, SynthTokens, TokenPrices, AssetType} from "./interfaces/ICovenant.sol";
import {ILiquidExchangeModel} from "./interfaces/ILiquidExchangeModel.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/access/Ownable2Step.sol";
import {NoDelegateCall} from "./libraries/NoDelegateCall.sol";
import {ValidationLogic} from "./libraries/ValidationLogic.sol";
import {MarketParamsLib} from "./libraries/MarketParams.sol";
import {MulticallLib} from "./libraries/MultiCall.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

/**
 * @title Covenant contract
 * @author Covenant Labs
 **/

contract Covenant is ICovenant, NoDelegateCall, Ownable2Step {
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;

    /// @inheritdoc ICovenant
    string public constant name = "Covenant V1.0";

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Storage

    // Map of Liquid market params (marketID to data)
    mapping(MarketId marketId => MarketParams) internal idToMarketParams;

    // Map of Liquid base asset states (marketID to data)
    mapping(MarketId marketId => MarketState) internal marketState;

    // Map of valid Lending Exchanges
    mapping(address lex => bool) public isLexEnabled;

    // Map of valid curators
    mapping(address curator => bool) public isCuratorEnabled;

    // Default protocol fee
    uint32 private _defaultProtocolFee;

    // Default address authorized to pause markets
    address private _defaultPauseAddress;

    // Global flag to check if the contract is in a multicall
    bool private _isMulticall;

    /////////////////////////////////////////////////////////////////////////////////////////////
    // Modifiers

    uint8 constant STATE_UNINITIALIZED = 0;
    uint8 constant STATE_UNLOCKED = 1;
    uint8 constant STATE_LOCKED = 2;
    uint8 constant STATE_PAUSED = 3;

    /// @dev Mutually exclusive reentrancy protection into each Market.
    /// This method also prevents entrance to a function before the market is initialized.
    modifier lock(MarketId marketId) {
        {
            uint8 statusFlag = marketState[marketId].statusFlag;
            if (statusFlag != STATE_UNLOCKED) {
                if (statusFlag == STATE_LOCKED) revert Errors.E_MarketLocked();
                else if (statusFlag == STATE_PAUSED) revert Errors.E_MarketPaused();
                else revert Errors.E_MarketNonExistent();
            }
        }
        marketState[marketId].statusFlag = STATE_LOCKED;
        _;
        marketState[marketId].statusFlag = STATE_UNLOCKED;
    }

    // Prevent read only reentrancy
    // @dev - allows read operations on paused markets
    modifier lockView(MarketId marketId) {
        {
            uint8 statusFlag = marketState[marketId].statusFlag;
            if (statusFlag != STATE_UNLOCKED && statusFlag != STATE_PAUSED) {
                if (statusFlag == STATE_LOCKED) revert Errors.E_MarketLocked();
                else revert Errors.E_MarketNonExistent();
            }
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////
    // Constructor
    constructor(address initialOwner) Ownable(initialOwner) {
        _defaultPauseAddress = initialOwner;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////
    // Getters

    /// @inheritdoc ICovenant
    function getIdToMarketParams(MarketId marketId) external view returns (MarketParams memory) {
        return idToMarketParams[marketId];
    }

    /// @inheritdoc ICovenant
    function getMarketState(MarketId marketId) external view returns (MarketState memory) {
        return marketState[marketId];
    }

    ///////////////////////////////////////////////////////////////////////////////////////////
    // OnlyOwner functions

    /// @inheritdoc ICovenant
    function setEnabledLEX(address lex, bool isEnabled) external onlyOwner noDelegateCall {
        isLexEnabled[lex] = isEnabled;
        emit Events.UpdateEnabledLEX(lex, isEnabled);
    }

    /// @inheritdoc ICovenant
    function setEnabledCurator(address curator, bool isEnabled) external onlyOwner noDelegateCall {
        isCuratorEnabled[curator] = isEnabled;
        emit Events.UpdateEnabledOracle(curator, isEnabled);
    }

    /// @inheritdoc ICovenant
    function setDefaultFee(uint32 newFee) external onlyOwner noDelegateCall {
        // Validate protocol fee
        ValidationLogic.checkProtocolFee(newFee);

        uint32 oldFee = _defaultProtocolFee;
        _defaultProtocolFee = newFee;
        emit Events.UpdateDefaultProtocolFee(oldFee, newFee);
    }

    /// @inheritdoc ICovenant
    function setMarketProtocolFee(
        MarketId marketId,
        MarketParams calldata marketParams,
        bytes calldata data,
        uint256 msgValue,
        uint32 newFee
    ) external payable onlyOwner noDelegateCall lock(marketId) {
        // Validate protocol fee
        ValidationLogic.checkProtocolFee(newFee);

        // update market state beforehand to accrue any fees at current rate till now
        _updateState(marketId, marketParams, data, msgValue);

        uint32 oldFee = ILiquidExchangeModel(marketParams.lex).getProtocolFee(marketId);
        ILiquidExchangeModel(marketParams.lex).setMarketProtocolFee(marketId, newFee);
        emit Events.UpdateMarketProtocolFee(marketId, oldFee, newFee);
    }

    /// @inheritdoc ICovenant
    function collectProtocolFee(
        MarketId marketId,
        address recipient,
        uint128 amountRequested
    ) external onlyOwner noDelegateCall lock(marketId) {
        if (amountRequested == 0) revert Errors.E_ZeroAmount();
        if (recipient == address(0)) revert Errors.E_ZeroAddress();
        if (recipient == address(this)) revert Errors.E_Unauthorized();

        // update state
        uint128 accruedFees = marketState[marketId].protocolFeeGrowth;
        address baseToken = idToMarketParams[marketId].baseToken;
        if (amountRequested > accruedFees) amountRequested = accruedFees;
        unchecked {
            marketState[marketId].protocolFeeGrowth = accruedFees - amountRequested;
        }

        // transfer
        IERC20(baseToken).safeTransfer(recipient, amountRequested);

        // emit
        emit Events.CollectProtocolFee(marketId, recipient, baseToken, amountRequested);
    }

    /// @inheritdoc ICovenant
    function setMarketPause(MarketId marketId, bool isPaused) external noDelegateCall lockView(marketId) {
        // only authorized pause address can pause / unpause market
        if (_msgSender() != marketState[marketId].authorizedPauseAddress) revert Errors.E_Unauthorized();

        // @dev - lockView only allows operations on existing and unlocked markets
        marketState[marketId].statusFlag = isPaused ? STATE_PAUSED : STATE_UNLOCKED;
        emit Events.MarketPaused(marketId, isPaused);
    }

    /// @inheritdoc ICovenant
    function setDefaultPauseAddress(address newPauseAddress) external onlyOwner noDelegateCall {
        address oldPauseAddress = _defaultPauseAddress;
        _defaultPauseAddress = newPauseAddress;
        emit Events.UpdateDefaultPauseAddress(oldPauseAddress, newPauseAddress);
    }

    /// @inheritdoc ICovenant
    function setMarketPauseAddress(
        MarketId marketId,
        address newPauseAddress
    ) external noDelegateCall lockView(marketId) {
        // only owner or authorized pause address can set pause address for a market
        if (_msgSender() != owner() && _msgSender() != marketState[marketId].authorizedPauseAddress)
            revert Errors.E_Unauthorized();

        address oldPauseAddress = marketState[marketId].authorizedPauseAddress;
        marketState[marketId].authorizedPauseAddress = newPauseAddress;
        emit Events.UpdateMarketPauseAddress(marketId, oldPauseAddress, newPauseAddress);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////
    // External Functions (mostly covering internal function and implementing a lock per market)

    /// @inheritdoc ICovenant
    function createMarket(
        MarketParams calldata marketParams,
        bytes calldata initData
    ) external noDelegateCall returns (MarketId) {
        // Calculate marketId
        MarketId marketId = marketParams.id();

        // validate marketParams
        ValidationLogic.checkMarketParams(marketParams, idToMarketParams[marketId], isLexEnabled, isCuratorEnabled);

        // initialize LEX for market
        (SynthTokens memory synthTokens, bytes memory lexData) = ILiquidExchangeModel(marketParams.lex).initMarket(
            marketId,
            marketParams,
            _defaultProtocolFee,
            initData
        );

        idToMarketParams[marketId] = marketParams;
        marketState[marketId].authorizedPauseAddress = _defaultPauseAddress;
        marketState[marketId].statusFlag = STATE_UNLOCKED; // unlock market to enable its us

        // emit new market creation event
        emit Events.CreateMarket(marketId, marketParams, synthTokens, initData, lexData);

        return marketId;
    }

    /// @inheritdoc ICovenant
    /// @notice - reverts if market is locked or non-existent
    function mint(
        MintParams calldata mintParams
    ) external payable override noDelegateCall lock(mintParams.marketId) returns (uint256, uint256) {
        // Caches
        MarketState storage ms = marketState[mintParams.marketId];
        MarketParams calldata mp = mintParams.marketParams;
        uint256 localBaseSupply = ms.baseSupply;

        // check payment
        _checkPayment(mintParams.msgValue);

        // Validate mint params
        ValidationLogic.checkMintParams(mintParams);

        // Mint synthTokens through LEX. @dev - accrues debt interest, mints aTokens/zTokens.
        // @dev - only passes msgValue to LEX (to enable multicall).  Does not check for overdeposit.
        (
            uint256 aTokenAmountOut,
            uint256 zTokenAmountOut,
            uint128 protocolFees,
            TokenPrices memory tokenPrices
        ) = ILiquidExchangeModel(mp.lex).mint{value: mintParams.msgValue}(mintParams, _msgSender(), localBaseSupply);

        // Validate mint amounts
        ValidationLogic.checkMintOutputs(mintParams, aTokenAmountOut, zTokenAmountOut);

        // emit mint event
        emit Events.Mint(
            mintParams.marketId,
            mintParams.baseAmountIn,
            _msgSender(),
            mintParams.to,
            aTokenAmountOut,
            zTokenAmountOut,
            protocolFees,
            tokenPrices
        );

        // Update market state (storage)
        ms.baseSupply = (localBaseSupply + mintParams.baseAmountIn) - protocolFees;
        if (protocolFees > 0) ms.protocolFeeGrowth += protocolFees;

        // Transfer base asset in
        IERC20(mp.baseToken).safeTransferFrom(_msgSender(), address(this), mintParams.baseAmountIn);

        return (aTokenAmountOut, zTokenAmountOut);
    }

    /// @inheritdoc ICovenant
    /// @notice - reverts if market is locked or non-existent
    function redeem(
        RedeemParams calldata redeemParams
    ) external payable override noDelegateCall lock(redeemParams.marketId) returns (uint256) {
        // Cache pointers
        MarketState storage ms = marketState[redeemParams.marketId];
        MarketParams calldata mp = redeemParams.marketParams;
        uint256 localBaseSupply = ms.baseSupply;

        // check payment
        _checkPayment(redeemParams.msgValue);

        // check redeemParams
        ValidationLogic.checkRedeemParams(redeemParams);

        // Redeem synthTokens through LEX. @dev - accrues debt interest, burns aTokens/zTokens.
        // @dev - only passes msgValue to LEX (to enable multicall).  Does not check for overdeposit.
        (uint256 amountOut, uint128 protocolFees, TokenPrices memory tokenPrices) = ILiquidExchangeModel(mp.lex).redeem{
            value: redeemParams.msgValue
        }(redeemParams, _msgSender(), localBaseSupply);

        // Validate redeem amounts
        ValidationLogic.checkRedeemOutputs(redeemParams, localBaseSupply, amountOut);

        // emit event
        emit Events.Redeem(
            redeemParams.marketId,
            redeemParams.aTokenAmountIn,
            redeemParams.zTokenAmountIn,
            _msgSender(),
            redeemParams.to,
            amountOut,
            protocolFees,
            tokenPrices
        );

        // Update market state (storage)
        ms.baseSupply = localBaseSupply - amountOut - protocolFees;
        if (protocolFees > 0) ms.protocolFeeGrowth += protocolFees;

        // Transfer base asset out
        IERC20(mp.baseToken).safeTransfer(redeemParams.to, amountOut);

        // return
        return amountOut;
    }

    /// @inheritdoc ICovenant
    /// @notice - reverts if market is locked or non-existent
    /// @dev if assetIn or assetOut is the base token, then swap will perform a mint / redeem in addition to a swap
    function swap(
        SwapParams calldata swapParams
    ) external payable override noDelegateCall lock(swapParams.marketId) returns (uint256) {
        // Caches
        MarketState storage ms = marketState[swapParams.marketId];
        MarketParams calldata mp = swapParams.marketParams;
        uint256 localBaseSupply = ms.baseSupply;

        // check payment
        _checkPayment(swapParams.msgValue);

        // check swapParams
        ValidationLogic.checkSwapParams(swapParams, localBaseSupply);

        // Swap synthTokens through LEX. @dev - accrues debt interest, burns/mints aTokens/zTokens when needed
        // @dev - only passes msgValue to LEX (to enable multicall).  Does not check for overdeposit.
        (uint256 amountCalculated, uint128 protocolFees, TokenPrices memory tokenPrices) = ILiquidExchangeModel(mp.lex)
            .swap{value: swapParams.msgValue}(swapParams, _msgSender(), localBaseSupply);

        // Validate swap amounts
        ValidationLogic.checkSwapOutputs(swapParams, localBaseSupply, amountCalculated, protocolFees);

        // emit event
        emit Events.Swap(
            swapParams.marketId,
            swapParams.assetIn,
            swapParams.assetOut,
            swapParams.isExactIn ? swapParams.amountSpecified : amountCalculated,
            swapParams.isExactIn ? amountCalculated : swapParams.amountSpecified,
            _msgSender(),
            swapParams.to,
            protocolFees,
            tokenPrices
        );

        // Update market state (storage) and transfer if swap involves base tokens
        if (protocolFees > 0) ms.protocolFeeGrowth += protocolFees;
        if (swapParams.assetIn == AssetType.BASE) {
            uint256 amount = swapParams.isExactIn ? swapParams.amountSpecified : amountCalculated;
            // update state
            ms.baseSupply = localBaseSupply + amount - protocolFees;
            // transfer
            IERC20(mp.baseToken).safeTransferFrom(_msgSender(), address(this), amount);
        } else if (swapParams.assetOut == AssetType.BASE) {
            uint256 amount = swapParams.isExactIn ? amountCalculated : swapParams.amountSpecified;
            // update state
            ms.baseSupply = localBaseSupply - amount - protocolFees;
            // transfer
            IERC20(mp.baseToken).safeTransfer(swapParams.to, amount);
        } else if (protocolFees > 0) {
            ms.baseSupply = localBaseSupply - protocolFees;
        }

        return amountCalculated;
    }

    /// @inheritdoc ICovenant
    function updateState(
        MarketId marketId,
        MarketParams calldata marketParams,
        bytes calldata data,
        uint256 msgValue
    ) external payable noDelegateCall lock(marketId) {
        // update state
        _updateState(marketId, marketParams, data, msgValue);
    }

    /// @inheritdoc ICovenant
    function previewMint(
        MintParams calldata mintParams
    )
        external
        view
        override
        noDelegateCall
        lockView(mintParams.marketId)
        returns (
            uint256 aTokenAmountOut,
            uint256 zTokenAmountOut,
            uint128 protocolFees,
            uint128 oracleUpdateFee,
            TokenPrices memory tokenPrices
        )
    {
        // Caches
        MarketState storage ms = marketState[mintParams.marketId];
        MarketParams calldata mp = mintParams.marketParams;
        uint256 localBaseSupply = ms.baseSupply;

        // Validate mint params
        ValidationLogic.checkMintParams(mintParams);

        // Mint synthTokens through LEX. @dev - accrues debt interest, mints aTokens/zTokens.
        (aTokenAmountOut, zTokenAmountOut, protocolFees, oracleUpdateFee, tokenPrices) = ILiquidExchangeModel(mp.lex)
            .quoteMint(mintParams, _msgSender(), localBaseSupply);

        // Validate mint amounts
        ValidationLogic.checkMintOutputs(mintParams, aTokenAmountOut, zTokenAmountOut);
    }

    /// @inheritdoc ICovenant
    function previewRedeem(
        RedeemParams calldata redeemParams
    )
        external
        view
        override
        noDelegateCall
        lockView(redeemParams.marketId)
        returns (uint256 amountOut, uint128 protocolFees, uint128 oracleUpdateFee, TokenPrices memory tokenPrices)
    {
        // Cache pointers
        MarketState storage ms = marketState[redeemParams.marketId];
        MarketParams calldata mp = redeemParams.marketParams;
        uint256 localBaseSupply = ms.baseSupply;

        // check redeemParams
        ValidationLogic.checkRedeemParams(redeemParams);

        // Redeem synthTokens through LEX. @dev - accrues debt interest, burns aTokens/zTokens.
        (amountOut, protocolFees, oracleUpdateFee, tokenPrices) = ILiquidExchangeModel(mp.lex).quoteRedeem(
            redeemParams,
            _msgSender(),
            localBaseSupply
        );

        // Validate redeem amounts
        ValidationLogic.checkRedeemOutputs(redeemParams, localBaseSupply, amountOut);
    }

    /// @inheritdoc ICovenant
    function previewSwap(
        SwapParams calldata swapParams
    )
        external
        view
        override
        noDelegateCall
        lockView(swapParams.marketId)
        returns (
            uint256 amountCalculated,
            uint128 protocolFees,
            uint128 oracleUpdateFee,
            TokenPrices memory tokenPrices
        )
    {
        // Caches
        MarketState storage ms = marketState[swapParams.marketId];
        MarketParams calldata mp = swapParams.marketParams;
        uint256 localBaseSupply = ms.baseSupply;

        // check swapParams
        ValidationLogic.checkSwapParams(swapParams, localBaseSupply);

        // Swap synthTokens through LEX. @dev - accrues debt interest, burns/mints aTokens/zTokens when needed
        (amountCalculated, protocolFees, oracleUpdateFee, tokenPrices) = ILiquidExchangeModel(mp.lex).quoteSwap(
            swapParams,
            _msgSender(),
            localBaseSupply
        );

        // Validate swap amounts
        ValidationLogic.checkSwapOutputs(swapParams, localBaseSupply, amountCalculated, protocolFees);
    }

    /// @inheritdoc ICovenant
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        // @dev - runs in the context of this call, and hence inherits msg.value
        // @dev - does not check whether msg.value is enough for tx to succeed
        // if not enough, it reverts.  If msg.value higher than needed, it also reverts (does not allow excess deposit)
        // @dev - code does not guard against reentrancy overdeposits.
        // @dev - code looks to protect common users from overdeposits, not malicious donations....
        uint256 balanceBeforeCall = address(this).balance - msg.value;

        // perform multicall
        _isMulticall = true;
        results = MulticallLib.multicall(data);
        _isMulticall = false;

        // validate balance (do not allow over or under deposit)
        if (address(this).balance != balanceBeforeCall) revert Errors.E_IncorrectPayment();

        return results;
    }

    //////////////////////////////////////////////////////////////////////////
    // private

    function _updateState(
        MarketId marketId,
        MarketParams calldata marketParams,
        bytes calldata data,
        uint256 msgValue
    ) private {
        // check payment
        _checkPayment(msgValue);

        // check update params
        ValidationLogic.checkUpdateParams(marketId, marketParams);

        // update LEX state (pass msgValue to LEX)
        uint128 protocolFees = ILiquidExchangeModel(marketParams.lex).updateState{value: msgValue}(
            marketId,
            marketParams,
            marketState[marketId].baseSupply,
            data
        );

        // Update market state (storage)
        if (protocolFees > 0) {
            marketState[marketId].protocolFeeGrowth += protocolFees;
            marketState[marketId].baseSupply -= protocolFees;
        }
    }

    function _checkPayment(uint256 msgValue) private {
        // check for overdeposit (if not multicall)
        // @dev - allows user to underdeposit (will revert if not enough balance in contract)
        if (msg.value != msgValue && !_isMulticall) revert Errors.E_IncorrectPayment();
    }
}

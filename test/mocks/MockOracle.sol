// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Ownable Oracle for testnet purposes
 * @author Covenant Labs
 **/
contract MockOracle is Ownable {
    uint256 private _price; // Asset price in WADs

    string public constant name = "TestOracle";
    uint256 private constant _feedDecimals = 18;

    // Track last received data and msgValue for testing
    bytes public lastReceivedData;
    uint256 public lastReceivedMsgValue;
    uint256 public callCount;
    uint256 public balanceBeforeCall;
    uint256 public balanceAfterCall;

    constructor(address initialOwner) Ownable(initialOwner) {
        _price = 10 ** _feedDecimals; // initial price = 1
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        _price = newPrice;
    }

    function updatePriceFeeds(address, address, bytes calldata updateData) external payable {
        // Track the received data and msgValue for testing
        balanceBeforeCall = address(this).balance - msg.value;
        lastReceivedData = updateData;
        lastReceivedMsgValue = msg.value;
        callCount++;
        balanceAfterCall = address(this).balance;
    }

    function getQuote(uint256 inAmount, address baseAsset, address quoteAsset) external view returns (uint256) {
        return _getQuote(inAmount, baseAsset, quoteAsset);
    }

    function previewGetQuote(uint256 inAmount, address baseAsset, address quoteAsset) external view returns (uint256) {
        return _getQuote(inAmount, baseAsset, quoteAsset);
    }

    function getQuotes(
        uint256 inAmount,
        address baseAsset,
        address quoteAsset
    ) external view returns (uint256, uint256) {
        uint256 amount = _getQuote(inAmount, baseAsset, quoteAsset);
        return (amount, amount);
    }

    function previewGetQuotes(
        uint256 inAmount,
        address baseAsset,
        address quoteAsset
    ) external view returns (uint256, uint256) {
        uint256 amount = _getQuote(inAmount, baseAsset, quoteAsset);
        return (amount, amount);
    }

    function _getQuote(uint256 inAmount, address baseAsset, address quoteAsset) internal view returns (uint256) {
        uint8 baseDecimals = IERC20Metadata(baseAsset).decimals();
        uint8 quoteDecimals = IERC20Metadata(quoteAsset).decimals();
        uint256 priceScale = 10 ** quoteDecimals;
        uint256 feedScale = 10 ** (baseDecimals + _feedDecimals);
        return FixedPointMathLib.fullMulDiv(inAmount, priceScale * _price, feedScale);
    }

    // Helper functions for testing
    function resetTracking() external onlyOwner {
        delete lastReceivedData;
        lastReceivedMsgValue = 0;
        callCount = 0;
        balanceBeforeCall = 0;
        balanceAfterCall = 0;
    }

    function getLastCallInfo() external view returns (bytes memory data, uint256 msgValue, uint256 calls) {
        return (lastReceivedData, lastReceivedMsgValue, callCount);
    }

    function getLastCallInfoWithBalance()
        external
        view
        returns (
            bytes memory data,
            uint256 msgValue,
            uint256 calls,
            uint256 balanceBefore,
            uint256 balanceAfter,
            uint256 balanceIncrease
        )
    {
        return (
            lastReceivedData,
            lastReceivedMsgValue,
            callCount,
            balanceBeforeCall,
            balanceAfterCall,
            balanceAfterCall - balanceBeforeCall
        );
    }
}

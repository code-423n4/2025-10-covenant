// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

/**
 * @title Ownable Oracle for testnet purposes
 * @author Covenant Labs
 **/
contract MockOracleNonERC20 is Ownable {
    uint256 private _price; // Asset price in WADs

    string public constant name = "TestOracle";
    uint256 private constant _feedDecimals = 18;

    constructor(address initialOwner) Ownable(initialOwner) {
        _price = 10 ** _feedDecimals; // initial price = 1
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        _price = newPrice;
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

    function _getQuote(uint256 inAmount, address baseAsset, address) internal view returns (uint256) {
        uint8 baseDecimals = IERC20Metadata(baseAsset).decimals();
        uint8 quoteDecimals = 18;
        uint256 priceScale = 10 ** quoteDecimals;
        uint256 feedScale = 10 ** (baseDecimals + _feedDecimals);
        return FixedPointMathLib.fullMulDiv(inAmount, priceScale * _price, feedScale);
    }
}

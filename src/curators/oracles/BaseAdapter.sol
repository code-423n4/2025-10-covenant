// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter as EulerBaseAdapter, IERC20} from "@euler-price-oracle/adapter/BaseAdapter.sol";
import {ICovenantPriceOracle} from "../interfaces/ICovenantPriceOracle.sol";
import {Errors} from "../lib/Errors.sol";

/// @title BaseAdapter
/// @author Covenant Labs
/// @notice Abstract adapter with virtual bid/ask pricing.
/// @notice This extends the Euler BaseAdapter and adds the ICovenantPriceOracle interface.
abstract contract BaseAdapter is EulerBaseAdapter, ICovenantPriceOracle {
    /// @inheritdoc ICovenantPriceOracle
    function previewGetQuote(uint256 inAmount, address base, address quote) external view returns (uint256) {
        return _previewGetQuote(inAmount, base, quote);
    }

    /// @inheritdoc ICovenantPriceOracle
    /// @dev Does not support true bid/ask pricing.
    function previewGetQuotes(uint256 inAmount, address base, address quote) external view returns (uint256, uint256) {
        uint256 outAmount = _previewGetQuote(inAmount, base, quote);
        return (outAmount, outAmount);
    }

    /// @inheritdoc ICovenantPriceOracle
    function updatePriceFeeds(address base, address quote, bytes calldata updateData) external payable {
        _updatePriceFeeds(base, quote, updateData);
    }

    /// @inheritdoc ICovenantPriceOracle
    function getUpdateFee(address base, address quote, bytes calldata updateData) external view returns (uint128) {
        return _getUpdateFee(base, quote, updateData);
    }

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Internal functions to be overridden in the inheriting contract

    /// @notice Return the preview quote for the given price query.
    /// @dev Must be overridden in the inheriting contract.
    function _previewGetQuote(uint256 inAmount, address base, address quote) internal view virtual returns (uint256) {
        // Unless overridden, return the live quote.
        return _getQuote(inAmount, base, quote);
    }

    /// @notice Updates price feeds for pull type oracles
    /// @dev Must be overridden in the inheriting contract.
    function _updatePriceFeeds(address base, address quote, bytes calldata updateData) internal virtual {
        // Unless overridden, do not accept any value and return.
        if (msg.value > 0) revert Errors.PriceOracle_IncorrectPayment();
    }

    /// @notice Calculates fee when updating price feed for pull type oracles
    /// @dev Must be overridden in the inheriting contract.
    function _getUpdateFee(
        address base,
        address quote,
        bytes calldata updateData
    ) internal view virtual returns (uint128) {
        // Unless overridden, return 0.
        return 0;
    }
}

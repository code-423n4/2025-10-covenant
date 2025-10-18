// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter} from "./BaseAdapter.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {ScaleUtils} from "@euler-price-oracle/lib/ScaleUtils.sol";
import {Errors} from "../lib/Errors.sol";

/// @title CrossAdapter
/// @author Covenant Labs
/// @notice PriceOracle that chains two PriceOracles.
/// @dev For example, CrossAdapter can price wstETH/USD by querying a wstETH/stETH oracle and a stETH/USD oracle.
/// @notice This is a very close copy to the Errors contract in the euler-price-oracle library, adapted for Covenant under GPL.
contract CrossAdapter is BaseAdapter {
    string public constant name = "CrossAdapter";
    /// @notice The address of the base asset.
    address public immutable base;
    /// @notice The address of the cross/through asset.
    address public immutable cross;
    /// @notice The address of the quote asset.
    address public immutable quote;
    /// @notice The oracle that resolves base/cross and cross/base.
    /// @dev The oracle MUST be bidirectional.
    address public immutable oracleBaseCross;
    /// @notice The oracle that resolves quote/cross and cross/quote.
    /// @dev The oracle MUST be bidirectional.
    address public immutable oracleCrossQuote;

    /// @notice Deploy a CrossAdapter.
    /// @param _base The address of the base asset.
    /// @param _cross The address of the cross/through asset.
    /// @param _quote The address of the quote asset.
    /// @param _oracleBaseCross The oracle that resolves base/cross and cross/base.
    /// @param _oracleCrossQuote The oracle that resolves quote/cross and cross/quote.
    /// @dev Both cross oracles MUST be bidirectional.
    /// @dev Does not support bid/ask pricing.
    constructor(address _base, address _cross, address _quote, address _oracleBaseCross, address _oracleCrossQuote) {
        base = _base;
        cross = _cross;
        quote = _quote;
        oracleBaseCross = _oracleBaseCross;
        oracleCrossQuote = _oracleCrossQuote;
    }

    /// @notice Get a quote by chaining the cross oracles.
    /// @dev For the inverse direction it calculates quote/cross * cross/base.
    /// For the forward direction it calculates base/cross * cross/quote.
    /// @param inAmount The amount of `base` to convert.
    /// @param _base The token that is being priced.
    /// @param _quote The token that is the unit of account.
    /// @return The converted amount by chaining the cross oracles.
    function _getQuote(uint256 inAmount, address _base, address _quote) internal view override returns (uint256) {
        bool inverse = ScaleUtils.getDirectionOrRevert(_base, base, _quote, quote);

        if (inverse) {
            inAmount = IPriceOracle(oracleCrossQuote).getQuote(inAmount, quote, cross);
            return IPriceOracle(oracleBaseCross).getQuote(inAmount, cross, base);
        } else {
            inAmount = IPriceOracle(oracleBaseCross).getQuote(inAmount, base, cross);
            return IPriceOracle(oracleCrossQuote).getQuote(inAmount, cross, quote);
        }
    }

    /// @notice Get a quote preview by chaining the cross oracles.
    /// @dev For the inverse direction it calculates quote/cross * cross/base.
    /// For the forward direction it calculates base/cross * cross/quote.
    /// @param inAmount The amount of `base` to convert.
    /// @param _base The token that is being priced.
    /// @param _quote The token that is the unit of account.
    /// @return The converted amount by chaining the cross oracles.
    function _previewGetQuote(
        uint256 inAmount,
        address _base,
        address _quote
    ) internal view override returns (uint256) {
        bool inverse = ScaleUtils.getDirectionOrRevert(_base, base, _quote, quote);

        if (inverse) {
            inAmount = IPriceOracle(oracleCrossQuote).previewGetQuote(inAmount, quote, cross);
            return IPriceOracle(oracleBaseCross).previewGetQuote(inAmount, cross, base);
        } else {
            inAmount = IPriceOracle(oracleBaseCross).previewGetQuote(inAmount, base, cross);
            return IPriceOracle(oracleCrossQuote).previewGetQuote(inAmount, cross, quote);
        }
    }

    /// @notice Updates price feeds for pull type oracles
    function _updatePriceFeeds(address _base, address _quote, bytes calldata updateData) internal override {
        // decode updateData
        if (updateData.length == 0) {
            // no price feed to update
            // revert if there was a fee payment
            if (msg.value > 0) revert Errors.PriceOracle_IncorrectPayment();
        } else {
            bytes[] memory crossUpdateData = abi.decode(updateData, (bytes[]));
            if (crossUpdateData.length != 2) revert Errors.PriceOracle_InvalidUpdateData();

            // read expected fee payment
            // @dev - note updateData encoding, where base feed data comes first
            uint128 baseFee = IPriceOracle(oracleBaseCross).getUpdateFee(_base, cross, crossUpdateData[0]);
            uint128 quoteFee = IPriceOracle(oracleCrossQuote).getUpdateFee(_quote, cross, crossUpdateData[1]);

            if (msg.value != (baseFee + quoteFee)) revert Errors.PriceOracle_IncorrectPayment();

            // @dev - note updateData encoding, where base feed data comes first
            IPriceOracle(oracleBaseCross).updatePriceFeeds{value: baseFee}(_base, cross, crossUpdateData[0]);
            IPriceOracle(oracleCrossQuote).updatePriceFeeds{value: quoteFee}(_quote, cross, crossUpdateData[1]);
        }
    }

    /// @notice Gets update fee for pull oracles
    function _getUpdateFee(
        address _base,
        address _quote,
        bytes calldata updateData
    ) internal view override returns (uint128 updateFee) {
        // decode updateData
        if (updateData.length == 0) {
            return 0;
        } else {
            bytes[] memory crossUpdateData = abi.decode(updateData, (bytes[]));
            if (crossUpdateData.length != 2) revert Errors.PriceOracle_InvalidUpdateData();

            // read expected fee payment
            // @dev - note updateData encoding, where base feed data comes first
            uint128 baseFee = IPriceOracle(oracleBaseCross).getUpdateFee(_base, cross, crossUpdateData[0]);
            uint128 quoteFee = IPriceOracle(oracleCrossQuote).getUpdateFee(_quote, cross, crossUpdateData[1]);

            return baseFee + quoteFee;
        }
    }
}

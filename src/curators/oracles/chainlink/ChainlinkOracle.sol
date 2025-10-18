// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

//import {IPriceOracle} from "../../../interfaces/IPriceOracle.sol";
import {ChainlinkOracle as EulerChainlinkOracle} from "@euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";
import {AggregatorV3Interface} from "@euler-price-oracle/adapter/chainlink/AggregatorV3Interface.sol";
import {ScaleUtils, Scale} from "@euler-price-oracle/lib/ScaleUtils.sol";
import {Errors} from "../../lib/Errors.sol";

/// @title ChainlinkOracle
/// @author Covenant Labs (expands Euler Labs interface, but does not change functionality))
/// @notice PriceOracle adapter for Chainlink push-based price feeds.
/// @dev Integration Note: `maxStaleness` is an immutable parameter set in the constructor.
/// If the aggregator's heartbeat changes, this adapter may exhibit unintended behavior.
contract ChainlinkOracle is EulerChainlinkOracle {
    /// @notice Deploy a ChainlinkOracle.
    /// @param _base The address of the base asset corresponding to the feed.
    /// @param _quote The address of the quote asset corresponding to the feed.
    /// @param _feed The address of the Chainlink price feed.
    /// @param _maxStaleness The maximum allowed age of the price.
    /// @dev Consider setting `_maxStaleness` to slightly more than the feed's heartbeat
    /// to account for possible network delays when the heartbeat is triggered.
    constructor(
        address _base,
        address _quote,
        address _feed,
        uint256 _maxStaleness
    ) EulerChainlinkOracle(_base, _quote, _feed, _maxStaleness) {}

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Additional Covenant interface

    /// inheritdoc IPriceOracle
    /// @dev For chainlink push-based price feeds, the preview quote is the same as the live quote.
    function previewGetQuote(uint256 inAmount, address base, address quote) external view returns (uint256) {
        return _getQuote(inAmount, base, quote);
    }

    /// inheritdoc IPriceOracle
    /// @dev Does not support true bid/ask pricing.
    /// @dev For chainlink push-based price feeds, the preview quote is the same as the live quote.
    function previewGetQuotes(uint256 inAmount, address base, address quote) external view returns (uint256, uint256) {
        uint256 outAmount = _getQuote(inAmount, base, quote);
        return (outAmount, outAmount);
    }

    /// inheritdoc IPriceOracle
    function updatePriceFeeds(address base, address quote, bytes calldata updateData) external payable {
        // Do not accept any value and return.
        if (msg.value > 0) revert Errors.PriceOracle_IncorrectPayment();
    }

    /// inheritdoc IPriceOracle
    function getUpdateFee(address base, address quote, bytes calldata updateData) external view returns (uint128) {
        // Return 0.
        return 0;
    }
}

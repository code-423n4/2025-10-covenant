// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IPyth} from "@pyth/IPyth.sol";
import {PythStructs} from "@pyth/PythStructs.sol";
import {PythOracle as EulerPythOracle, ScaleUtils, Scale} from "@euler-price-oracle/adapter/pyth/PythOracle.sol";
import {Errors} from "../../lib/Errors.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title PythOracle
/// @author Covenant Labs (Expands Euler Labs interface to include feed updates and getUpdateFee)
contract PythOracle is EulerPythOracle {
    using SafeCast for uint256;

    /// @notice Deploy a PythOracle.
    /// @param _pyth The address of the Pyth oracle proxy.
    /// @param _base The address of the base asset corresponding to the feed.
    /// @param _quote The address of the quote asset corresponding to the feed.
    /// @param _feedId The id of the feed in the Pyth network.
    /// @param _maxStaleness The maximum allowed age of the price.
    /// @param _maxConfWidth The maximum width of the confidence interval in basis points.
    /// @dev Note: A high confidence interval indicates market volatility or Pyth consensus instability.
    /// Consider a lower `_maxConfWidth` for highly-correlated pairs and a higher value for uncorrelated pairs.
    /// Pairs with few data sources and low liquidity are more prone to volatility spikes and consensus instability.
    constructor(
        address _pyth,
        address _base,
        address _quote,
        bytes32 _feedId,
        uint256 _maxStaleness,
        uint256 _maxConfWidth
    ) EulerPythOracle(_pyth, _base, _quote, _feedId, _maxStaleness, _maxConfWidth) {}

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Additional Covenant interface

    /// inheritdoc IPriceOracle
    /// @dev For chainlink push-based price feeds, the preview quote is the same as the live quote.
    function previewGetQuote(uint256 inAmount, address base, address quote) external view returns (uint256) {
        return _previewGetQuote(inAmount, base, quote);
    }

    /// inheritdoc IPriceOracle
    /// @dev Does not support true bid/ask pricing.
    /// @dev For chainlink push-based price feeds, the preview quote is the same as the live quote.
    function previewGetQuotes(uint256 inAmount, address base, address quote) external view returns (uint256, uint256) {
        uint256 outAmount = _previewGetQuote(inAmount, base, quote);
        return (outAmount, outAmount);
    }

    /// inheritdoc IPriceOracle
    function updatePriceFeeds(address, address, bytes calldata updateData) external payable {
        bytes[] memory priceUpdate = abi.decode(updateData, (bytes[]));
        uint fee = IPyth(pyth).getUpdateFee(priceUpdate);
        if (msg.value != fee) revert Errors.PriceOracle_IncorrectPayment();
        IPyth(pyth).updatePriceFeeds{value: fee}(priceUpdate);
    }

    /// inheritdoc IPriceOracle
    function getUpdateFee(address, address, bytes calldata updateData) external view returns (uint128) {
        return IPyth(pyth).getUpdateFee(abi.decode(updateData, (bytes[]))).toUint128();
    }

    //////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Internal functions below are the same as the Euler PythOracle, but with the following changes:
    // - Changed maxStaleness to MAX_STALENESS_UPPER_BOUND
    // - Changed fetchPriceStruct to previewFetchPriceStruct

    /// @notice Same code as _getQuote, but using previewFetchPriceStruct instead of fetchPriceStruct
    function _previewGetQuote(uint256 inAmount, address _base, address _quote) internal view returns (uint256) {
        bool inverse = ScaleUtils.getDirectionOrRevert(_base, base, _quote, quote);

        PythStructs.Price memory priceStruct = _previewFetchPriceStruct();

        uint256 price = uint256(uint64(priceStruct.price));
        int8 feedExponent = int8(baseDecimals) - int8(priceStruct.expo);

        Scale scale;
        if (feedExponent > 0) {
            scale = ScaleUtils.from(quoteDecimals, uint8(feedExponent));
        } else {
            scale = ScaleUtils.from(quoteDecimals + uint8(-feedExponent), 0);
        }
        return ScaleUtils.calcOutAmount(inAmount, price, scale, inverse);
    }

    /// @notice same code as _fetchPriceStruct, but using MAX_STALENESS_UPPER_BOUND instead of maxStaleness
    function _previewFetchPriceStruct() internal view returns (PythStructs.Price memory) {
        PythStructs.Price memory p = IPyth(pyth).getPriceUnsafe(feedId);

        if (p.publishTime < block.timestamp) {
            // Verify that the price is not too stale
            uint256 staleness = block.timestamp - p.publishTime;
            if (staleness > MAX_STALENESS_UPPER_BOUND) revert Errors.PriceOracle_InvalidAnswer(); // @dev Changed from maxStaleness to MAX_STALENESS_UPPER_BOUND
        } else {
            // Verify that the price is not too ahead
            uint256 aheadness = p.publishTime - block.timestamp;
            if (aheadness > MAX_AHEADNESS) revert Errors.PriceOracle_InvalidAnswer();
        }

        // Verify that the price is positive and within the confidence width.
        if (p.price <= 0 || p.conf > (uint64(p.price) * maxConfWidth) / BASIS_POINTS) {
            revert Errors.PriceOracle_InvalidAnswer();
        }

        // Verify that the price exponent is within bounds.
        if (p.expo < MIN_EXPONENT || p.expo > MAX_EXPONENT) {
            revert Errors.PriceOracle_InvalidAnswer();
        }
        return p;
    }
}

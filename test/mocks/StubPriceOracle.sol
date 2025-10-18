// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

contract StubPriceOracle is IPriceOracle {
    mapping(address => mapping(address => uint256)) prices;
    mapping(address => mapping(address => mapping(bytes32 => uint128))) updateFees;

    function name() external pure override returns (string memory) {
        return "StubPriceOracle";
    }

    function setPrice(address base, address quote, uint256 price) external {
        prices[base][quote] = price;
    }

    function getQuote(uint256 inAmount, address base, address quote) external view override returns (uint256) {
        return _calcQuote(inAmount, base, quote);
    }

    function getQuotes(
        uint256 inAmount,
        address base,
        address quote
    ) external view override returns (uint256, uint256) {
        return (_calcQuote(inAmount, base, quote), _calcQuote(inAmount, base, quote));
    }

    function previewGetQuote(uint256 inAmount, address base, address quote) external view override returns (uint256) {
        return _calcQuote(inAmount, base, quote);
    }

    function previewGetQuotes(
        uint256 inAmount,
        address base,
        address quote
    ) external view override returns (uint256, uint256) {
        return (_calcQuote(inAmount, base, quote), _calcQuote(inAmount, base, quote));
    }

    function updatePriceFeeds(address base, address quote, bytes calldata updateData) external payable override {
        // Stub implementation - does nothing
    }

    function getUpdateFee(
        address base,
        address quote,
        bytes calldata updateData
    ) external view override returns (uint128) {
        return updateFees[base][quote][keccak256(updateData)];
    }

    function setUpdateFee(address base, address quote, bytes calldata updateData, uint128 fee) external {
        updateFees[base][quote][keccak256(updateData)] = fee;
    }

    function _calcQuote(uint256 inAmount, address base, address quote) internal view returns (uint256) {
        return (inAmount * prices[base][quote]) / 1e18;
    }
}

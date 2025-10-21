// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IPyth} from "@pyth/IPyth.sol";
import {PythStructs} from "@pyth/PythStructs.sol";

/**
 * @title Mock Chainlink aggregator implementation that is configurable for C4 PoC
 * @author Code4rena
 **/
contract MockPyth is IPyth {
    PythStructs.Price internal _price;
    uint256 public updateFee = 0.001 ether;
    bool internal _shouldRevert;

    modifier canRevert() {
        if (_shouldRevert) revert("Oops");
        _;
    }

    function setPrice(PythStructs.Price memory price_) external {
        _price = price_;
    }

    function setRevert(bool shouldRevert_) external {
        _shouldRevert = shouldRevert_;
    }

    function setUpdateFee(uint256 updateFee_) external {
        updateFee = updateFee_;
    }

    function getValidTimePeriod() external pure override returns (uint) {
        return 3600; // 1 hour
    }

    function getPriceUnsafe(bytes32) external view override canRevert returns (PythStructs.Price memory) {
        return _price;
    }

    function getPrice(bytes32) external view override canRevert returns (PythStructs.Price memory) {
        return _price;
    }

    function getPriceNoOlderThan(bytes32, uint256) external view override canRevert returns (PythStructs.Price memory) {
        return _price;
    }

    function getEmaPriceUnsafe(bytes32) external view override canRevert returns (PythStructs.Price memory) {
        return _price;
    }

    function getEmaPrice(bytes32) external view override canRevert returns (PythStructs.Price memory) {
        return _price;
    }

    function getEmaPriceNoOlderThan(
        bytes32,
        uint256
    ) external view override canRevert returns (PythStructs.Price memory) {
        return _price;
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {
        // Stub implementation - do nothing
    }

    function updatePriceFeedsIfNecessary(
        bytes[] calldata,
        bytes32[] calldata,
        uint64[] calldata
    ) external payable override {
        // Stub implementation - do nothing
    }

    function getUpdateFee(bytes[] calldata) external view override returns (uint256) {
        return updateFee; // Return a small fee for testing
    }

    function parsePriceFeedUpdates(
        bytes[] calldata,
        bytes32[] calldata,
        uint64,
        uint64
    ) external payable override returns (PythStructs.PriceFeed[] memory) {
        // Stub implementation - return empty array
        return new PythStructs.PriceFeed[](0);
    }
}

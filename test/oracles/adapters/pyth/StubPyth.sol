// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IPyth} from "@pyth/IPyth.sol";
import {PythStructs} from "@pyth/PythStructs.sol";

contract StubPyth is IPyth {
    PythStructs.Price private price;
    bool private shouldRevert;

    function setPrice(PythStructs.Price memory _price) external {
        price = _price;
    }

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getValidTimePeriod() external view override returns (uint) {
        return 3600; // 1 hour
    }

    function getPriceUnsafe(bytes32 id) external view override returns (PythStructs.Price memory) {
        if (shouldRevert) {
            revert("StubPyth: reverted");
        }
        return price;
    }

    function getPrice(bytes32 id) external view override returns (PythStructs.Price memory) {
        if (shouldRevert) {
            revert("StubPyth: reverted");
        }
        return price;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view override returns (PythStructs.Price memory) {
        if (shouldRevert) {
            revert("StubPyth: reverted");
        }
        return price;
    }

    function getEmaPriceUnsafe(bytes32 id) external view override returns (PythStructs.Price memory) {
        if (shouldRevert) {
            revert("StubPyth: reverted");
        }
        return price;
    }

    function getEmaPrice(bytes32 id) external view override returns (PythStructs.Price memory) {
        if (shouldRevert) {
            revert("StubPyth: reverted");
        }
        return price;
    }

    function getEmaPriceNoOlderThan(bytes32 id, uint256 age) external view override returns (PythStructs.Price memory) {
        if (shouldRevert) {
            revert("StubPyth: reverted");
        }
        return price;
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable override {
        // Stub implementation - do nothing
    }

    function updatePriceFeedsIfNecessary(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes
    ) external payable override {
        // Stub implementation - do nothing
    }

    function getUpdateFee(bytes[] calldata updateData) external view override returns (uint256) {
        return 0.001 ether; // Return a small fee for testing
    }

    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable override returns (PythStructs.PriceFeed[] memory) {
        // Stub implementation - return empty array
        return new PythStructs.PriceFeed[](0);
    }
}

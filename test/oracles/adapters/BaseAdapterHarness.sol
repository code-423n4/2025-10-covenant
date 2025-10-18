// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter} from "../../../src/curators/oracles/BaseAdapter.sol";

contract BaseAdapterHarness is BaseAdapter {
    string public constant name = "BaseAdapterHarness";

    function _getQuote(uint256, address, address) internal pure override returns (uint256) {
        return 0;
    }

    function _previewGetQuote(uint256, address, address) internal pure override returns (uint256) {
        return 0;
    }

    function _updatePriceFeeds(address, address, bytes calldata) internal pure override {
        // No-op for testing
    }

    function _getUpdateFee(address, address, bytes calldata) internal pure override returns (uint128) {
        return 0;
    }

    function getDecimals(address token) external view returns (uint8) {
        return _getDecimals(token);
    }
}

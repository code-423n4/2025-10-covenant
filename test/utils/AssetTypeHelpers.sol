// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

import {AssetType} from "../../src/interfaces/ICovenant.sol";

/// @notice Library of helper functions to convert fixed-sized array types to dynamic arrays in tests.
library AssetTypeHelpers {
    function debtAndLeverageSwap(AssetType assetIn) internal pure returns (AssetType) {
        if (assetIn == AssetType.DEBT) return AssetType.LEVERAGE;
        if (assetIn == AssetType.LEVERAGE) return AssetType.DEBT;
        return AssetType.BASE;
    }
}

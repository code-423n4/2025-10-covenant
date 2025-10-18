// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @title Utils Library
/// @author Covenant Labs
/// @notice Library to convert a market to its id.
library UtilsLib {
    function encodeFee(uint16 yieldFee, uint16 tvlFee) internal pure returns (uint32 protocolFee) {
        return ((uint32(yieldFee) << 16) | uint32(tvlFee));
    }

    function decodeFee(uint32 protocolFee) internal pure returns (uint16 yieldFee, uint16 tvlFee) {
        yieldFee = uint16(protocolFee >> 16);
        tvlFee = uint16(protocolFee & 0xFFFF);
    }
}

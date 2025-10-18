// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

library SafeMetadata {
    /**
     * @dev Attempts to fetch the asset name as a string. A return value of false indicates that the attempt failed in some way.
     */
    function tryGetName(IERC20 token) internal view returns (bool ok, string memory out) {
        return _tryStringOrBytes32(address(token), IERC20Metadata.name.selector);
    }

    /**
     * @dev Attempts to fetch the asset symbol as a string. A return value of false indicates that the attempt failed in some way.
     */
    function tryGetSymbol(IERC20 token) internal view returns (bool ok, string memory out) {
        return _tryStringOrBytes32(address(token), IERC20Metadata.symbol.selector);
    }

    /**
     * @dev Attempts to fetch the asset decimals. A return value of false indicates that the attempt failed in some way.
     */
    function tryGetDecimals(IERC20 token) internal view returns (bool ok, uint8 assetDecimals) {
        (bool success, bytes memory encodedDecimals) = address(token).staticcall(
            abi.encodeCall(IERC20Metadata.decimals, ())
        );
        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                return (true, uint8(returnedDecimals));
            }
        }
        return (false, 0);
    }

    function _tryStringOrBytes32(address token, bytes4 selector) private view returns (bool ok, string memory out) {
        // Enforce read-only
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector));
        if (!success) return (false, "");

        // Try standard (string).  Reverts on malformed data.
        if (data.length >= 64) return (true, abi.decode(data, (string)));

        // Fallback: bytes32 (older tokens)
        if (data.length == 32) {
            bytes32 raw = abi.decode(data, (bytes32));
            return (true, _bytes32ToString(raw));
        }

        // Anything else: treat as failure
        return (false, "");
    }

    // separate to allow try/catch
    function _decodeString(bytes memory data) internal pure returns (string memory s) {
        return abi.decode(data, (string));
    }

    function _bytes32ToString(bytes32 x) private pure returns (string memory) {
        uint256 len = 32;
        while (len > 0 && x[len - 1] == 0) {
            unchecked {
                len--;
            }
        }
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) out[i] = x[i];
        return string(out);
    }
}

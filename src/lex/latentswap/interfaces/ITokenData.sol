// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

/**
 * @title ITokenData
 * @author Covenant Labs
 * @notice Defines interface for symbol and decimal overrides
 **/

interface ITokenData {
    function assetDecimals(address asset) external view returns (uint8);
    function assetSymbol(address asset) external view returns (string memory);
    function assetName(address asset) external view returns (string memory);
}

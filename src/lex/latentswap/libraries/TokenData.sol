// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {SafeMetadata, IERC20} from "../../../libraries/SafeMetadata.sol";
import {ITokenData} from "../interfaces/ITokenData.sol";

/// @title TokenData
/// @author Covenant Labs
/// @notice sets symbol, decimals and name overrides for a token
/// @dev each item can be set independently, and will override existing ERC20 values for the respecitve token
/// @dev if both symbol and decimals are overriden, a quote token need not be an actual ERC20
/// @dev this gives the flexibility to use currency ISO addresses and symbols for quote tokens.
/// @dev Oracles can use ERC-7535, ISO 4217 or other conventions to represent non-ERC20 assets as addresses.
/// @dev e.g., EIP7528 would set address = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE", symbol = "ETH", decimals = 18.
abstract contract TokenData is ITokenData {
    using SafeMetadata for IERC20;

    // mapping of decimal overrides for specific assets
    mapping(address => uint8) _decimals;

    // mapping of symbol overrides for specific assets
    mapping(address => string) _symbol;

    // mapping of name overrides for specific assets
    mapping(address => string) _name;

    error TokenData_InvalidDecimals();

    event SetTokenDecimals(address indexed token, uint8 oldDecimals, uint8 newDecimals);
    event SetTokenSymbol(address indexed token, string oldSymbol, string newSymbol);
    event SetTokenName(address indexed token, string oldName, string newName);

    function assetDecimals(address asset) public view returns (uint8 decimals_) {
        return _assetDecimals(asset);
    }

    function assetSymbol(address asset) public view returns (string memory symbol_) {
        return _assetSymbol(asset);
    }

    function assetName(address asset) public view returns (string memory name_) {
        return _assetName(asset);
    }

    //////////////////////////////////////////////////////////////////////////

    // @dev - Stored decimals are an override.
    // if stored decimals is 0, try and get ERC20 decimals
    function _assetDecimals(address asset) internal view returns (uint8 decimals_) {
        decimals_ = _decimals[asset]; //check if there is an override for this asset
        if (decimals_ > 0) return decimals_;
        else {
            // try and read from asset itself
            bool success;
            (success, decimals_) = IERC20(asset).tryGetDecimals();
            return success ? decimals_ : 18;
        }
    }

    // @dev - Stored symbol are an override.
    // @dev - if stored symbol is "", try and get ERC20 symbol
    function _assetSymbol(address asset) internal view returns (string memory symbol_) {
        symbol_ = _symbol[asset]; //check if there is an override for this asset
        if (bytes(symbol_).length > 0) return symbol_;
        else {
            // try and read from asset itself
            bool success;
            (success, symbol_) = IERC20(asset).tryGetSymbol();
            return success ? symbol_ : "";
        }
    }

    // @dev - Stored name are an override.
    // @dev - if stored name is "", try and get ERC20 name
    function _assetName(address asset) internal view returns (string memory name_) {
        name_ = _name[asset]; //check if there is an override for this asset
        if (bytes(name_).length > 0) return name_;
        else {
            // try and read from asset itself
            bool success;
            (success, name_) = IERC20(asset).tryGetName();
            return success ? name_ : "";
        }
    }

    // internal functions.  These should be exposed with the appropriate access modifiers
    // @dev - if newDecimals = 0, then _assetDecimals will try and get ERC20 decimals
    function _updateAssetDecimals(address asset, uint8 newDecimals) internal {
        if (newDecimals > 18) revert TokenData_InvalidDecimals();
        uint8 oldDecimals = _assetDecimals(asset); // get old decimals
        _decimals[asset] = newDecimals;
        emit SetTokenDecimals(asset, oldDecimals, newDecimals);
    }

    // internal functions.  These should be exposed with the appropriate access modifiers
    // @dev - if newSymbol = "", then _assetSymbol will try and get ERC20 symbol
    function _updateAssetSymbol(address asset, string calldata newSymbol) internal {
        string memory oldSymbol = _assetSymbol(asset); // get old symbol
        _symbol[asset] = newSymbol;
        emit SetTokenSymbol(asset, oldSymbol, newSymbol);
    }

    // internal functions.  These should be exposed with the appropriate access modifiers
    // @dev - if newName = "", then _assetNAme will try and get ERC20 name
    function _updateAssetName(address asset, string calldata newName) internal {
        string memory oldName = _assetName(asset); // get old symbol
        _name[asset] = newName;
        emit SetTokenName(asset, oldName, newName);
    }
}

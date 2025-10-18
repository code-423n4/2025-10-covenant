// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

contract StubERC4626 is IERC4626 {
    address public asset;
    uint256 private rate;
    string revertMsg = "oops";
    bool doRevert;

    constructor(address _asset, uint256 _rate) {
        asset = _asset;
        rate = _rate;
    }

    function setRevert(bool _doRevert) external {
        doRevert = _doRevert;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function convertToAssets(uint256 shares) external view override returns (uint256) {
        if (doRevert) revert(revertMsg);
        return (shares * rate) / 1e18;
    }

    function convertToShares(uint256 assets) external view override returns (uint256) {
        if (doRevert) revert(revertMsg);
        return (assets * 1e18) / rate;
    }

    // Stub implementations for other IERC4626 functions
    function totalAssets() external view override returns (uint256) {
        return 0;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return 0; // Simplified for testing
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return 0; // Simplified for testing
    }

    function previewDeposit(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function previewMint(uint256 shares) external view override returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return (assets * 1e18) / rate;
    }

    function previewRedeem(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        return assets;
    }

    function mint(uint256 shares, address receiver) external override returns (uint256) {
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256) {
        return assets;
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256) {
        return shares;
    }

    // Stub implementations for IERC20 functions
    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure override returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure override returns (bool) {
        return true;
    }

    function allowance(address, address) external pure override returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure override returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return true;
    }

    // Stub implementations for IERC20Metadata functions
    function name() external pure override returns (string memory) {
        return "StubERC4626";
    }

    function symbol() external pure override returns (string memory) {
        return "STUB";
    }

    function decimals() external pure override returns (uint8) {
        return 18;
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CovenantCurator} from "../../src/curators/CovenantCurator.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {Errors} from "../../src/curators/lib/Errors.sol";
import {StubPriceOracle} from "../mocks/StubPriceOracle.sol";
import {StubERC4626} from "../mocks/StubERC4626.sol";
import {boundAddr, distinct} from "../utils/TestUtils.sol";

contract CovenantCuratorTest is Test {
    address OWNER = makeAddr("OWNER");
    CovenantCurator router;

    address WETH = makeAddr("WETH");
    address DAI = makeAddr("DAI");
    address USDC = makeAddr("USDC");
    address WBTC = makeAddr("WBTC");

    StubPriceOracle stubOracle;

    function setUp() public {
        router = new CovenantCurator(OWNER);
        stubOracle = new StubPriceOracle();
    }

    function test_Constructor_Integrity() public view {
        assertEq(router.owner(), OWNER);
        assertEq(router.fallbackOracle(), address(0));
        assertEq(router.name(), "CovenantCurator V1.0");
    }

    function test_Constructor_RevertsWhen_OwnerIsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CovenantCurator(address(0));
    }

    function test_GovSetConfig_Integrity(address base, address quote, address oracle) public {
        vm.assume(base != quote);
        (address token0, address token1) = base < quote ? (base, quote) : (quote, base);
        vm.expectEmit();
        emit CovenantCurator.ConfigSet(token0, token1, oracle);
        vm.prank(OWNER);
        router.govSetConfig(base, quote, oracle);

        assertEq(router.getConfiguredOracle(base, quote), oracle);
        assertEq(router.getConfiguredOracle(quote, base), oracle);
    }

    function test_GovSetConfig_Integrity_OverwriteOk(
        address base,
        address quote,
        address oracleA,
        address oracleB
    ) public {
        vm.assume(base != quote);
        (address token0, address token1) = base < quote ? (base, quote) : (quote, base);
        vm.expectEmit();
        emit CovenantCurator.ConfigSet(token0, token1, oracleA);
        vm.prank(OWNER);
        router.govSetConfig(base, quote, oracleA);

        vm.expectEmit();
        emit CovenantCurator.ConfigSet(token0, token1, oracleB);
        vm.prank(OWNER);
        router.govSetConfig(base, quote, oracleB);

        assertEq(router.getConfiguredOracle(base, quote), oracleB);
        assertEq(router.getConfiguredOracle(quote, base), oracleB);
    }

    function test_GovSetConfig_RevertsWhen_CallerNotOwner(
        address caller,
        address base,
        address quote,
        address oracle
    ) public {
        vm.assume(base != quote);
        vm.assume(caller != OWNER);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        router.govSetConfig(base, quote, oracle);
    }

    function test_GovSetConfig_RevertsWhen_BaseEqQuote(address base, address oracle) public {
        vm.expectRevert(Errors.PriceOracle_InvalidConfiguration.selector);
        vm.prank(OWNER);
        router.govSetConfig(base, base, oracle);
    }

    function test_GovSetResolvedVault_Integrity(address vault, address asset) public {
        vault = boundAddr(vault);
        vm.mockCall(vault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(asset));
        vm.expectEmit();
        emit CovenantCurator.ResolvedVaultSet(vault, asset);

        vm.prank(OWNER);
        router.govSetResolvedVault(vault, true);

        assertEq(router.resolvedVaults(vault), asset);
    }

    function test_GovSetResolvedVault_Integrity_OverwriteOk(address vault, address assetA, address assetB) public {
        vault = boundAddr(vault);
        vm.mockCall(vault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(assetA));
        vm.prank(OWNER);
        router.govSetResolvedVault(vault, true);

        vm.mockCall(vault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(assetB));
        vm.prank(OWNER);
        router.govSetResolvedVault(vault, true);

        assertEq(router.resolvedVaults(vault), assetB);
    }

    function test_GovSetResolvedVault_RevertsWhen_CallerNotOwner(address caller, address vault) public {
        vm.assume(caller != OWNER);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        router.govSetResolvedVault(vault, true);
    }

    function test_GovSetFallbackOracle_Integrity(address fallbackOracle) public {
        vm.prank(OWNER);
        router.govSetFallbackOracle(fallbackOracle);

        assertEq(router.fallbackOracle(), fallbackOracle);
    }

    function test_GovSetFallbackOracle_OverwriteOk(address fallbackOracleA, address fallbackOracleB) public {
        vm.prank(OWNER);
        router.govSetFallbackOracle(fallbackOracleA);

        vm.prank(OWNER);
        router.govSetFallbackOracle(fallbackOracleB);

        assertEq(router.fallbackOracle(), fallbackOracleB);
    }

    function test_GovSetFallbackOracle_ZeroOk() public {
        vm.prank(OWNER);
        router.govSetFallbackOracle(address(0));

        assertEq(router.fallbackOracle(), address(0));
    }

    function test_GovSetFallbackOracle_RevertsWhen_CallerNotOwner(address caller, address fallbackOracle) public {
        vm.assume(caller != OWNER);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        router.govSetFallbackOracle(fallbackOracle);
    }

    function test_Quote_Integrity_BaseEqQuote(uint256 inAmount, address base, address oracle) public view {
        base = boundAddr(base);
        oracle = boundAddr(oracle);
        vm.assume(base != oracle);
        inAmount = bound(inAmount, 1, type(uint128).max);

        uint256 outAmount = router.getQuote(inAmount, base, base);
        assertEq(outAmount, inAmount);
        (uint256 bidOutAmount, uint256 askOutAmount) = router.getQuotes(inAmount, base, base);
        assertEq(bidOutAmount, inAmount);
        assertEq(askOutAmount, inAmount);
    }

    function test_Quote_Integrity_HasOracle(
        uint256 inAmount,
        address base,
        address quote,
        address oracle,
        uint256 outAmount
    ) public {
        base = boundAddr(base);
        quote = boundAddr(quote);
        oracle = boundAddr(oracle);
        vm.assume(distinct(base, quote, oracle));
        inAmount = bound(inAmount, 1, type(uint128).max);

        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IPriceOracle.getQuote.selector, inAmount, base, quote),
            abi.encode(outAmount)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IPriceOracle.getQuotes.selector, inAmount, base, quote),
            abi.encode(outAmount, outAmount)
        );
        vm.prank(OWNER);
        router.govSetConfig(base, quote, oracle);

        uint256 _outAmount = router.getQuote(inAmount, base, quote);
        assertEq(_outAmount, outAmount);
        (uint256 bidOutAmount, uint256 askOutAmount) = router.getQuotes(inAmount, base, quote);
        assertEq(bidOutAmount, outAmount);
        assertEq(askOutAmount, outAmount);
    }

    function test_Quote_Integrity_BaseIsVault(
        uint256 inAmount,
        address baseAsset,
        address quote,
        uint256 rate1,
        uint256 rate2
    ) public {
        baseAsset = boundAddr(baseAsset);
        quote = boundAddr(quote);
        rate1 = bound(rate1, 1, 1e24);
        rate2 = bound(rate2, 1, 1e24);

        address oracle = address(new StubPriceOracle());
        address base = address(new StubERC4626(baseAsset, rate2));
        vm.assume(distinct(base, baseAsset, quote, oracle));

        vm.startPrank(OWNER);
        StubPriceOracle(oracle).setPrice(baseAsset, quote, rate1);
        router.govSetConfig(baseAsset, quote, oracle);
        router.govSetResolvedVault(base, true);
        inAmount = bound(inAmount, 1, type(uint128).max);
        uint256 expectedOutAmount = (((inAmount * rate2) / 1e18) * rate1) / 1e18;
        uint256 outAmount = router.getQuote(inAmount, base, quote);
        assertEq(outAmount, expectedOutAmount);
        (uint256 bidOutAmount, uint256 askOutAmount) = router.getQuotes(inAmount, base, quote);
        assertEq(bidOutAmount, expectedOutAmount);
        assertEq(askOutAmount, expectedOutAmount);
    }

    function test_GetQuote_Integrity_NoOracleButHasFallback(
        uint256 inAmount,
        address base,
        address quote,
        address fallbackOracle,
        uint256 outAmount
    ) public {
        base = boundAddr(base);
        quote = boundAddr(quote);
        fallbackOracle = boundAddr(fallbackOracle);
        vm.assume(distinct(base, quote, fallbackOracle));
        inAmount = bound(inAmount, 1, type(uint128).max);

        vm.prank(OWNER);
        router.govSetFallbackOracle(fallbackOracle);

        vm.mockCall(
            fallbackOracle,
            abi.encodeWithSelector(IPriceOracle.getQuote.selector, inAmount, base, quote),
            abi.encode(outAmount)
        );
        vm.mockCall(
            fallbackOracle,
            abi.encodeWithSelector(IPriceOracle.getQuotes.selector, inAmount, base, quote),
            abi.encode(outAmount, outAmount)
        );
        uint256 _outAmount = router.getQuote(inAmount, base, quote);
        assertEq(_outAmount, outAmount);
        (uint256 bidOutAmount, uint256 askOutAmount) = router.getQuotes(inAmount, base, quote);
        assertEq(bidOutAmount, outAmount);
        assertEq(askOutAmount, outAmount);
    }

    function test_GetQuote_RevertsWhen_NoOracleNoFallback(uint256 inAmount, address base, address quote) public {
        base = boundAddr(base);
        quote = boundAddr(quote);
        vm.assume(base != quote);
        inAmount = bound(inAmount, 1, type(uint128).max);

        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, base, quote));
        router.getQuote(inAmount, base, quote);
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, base, quote));
        router.getQuotes(inAmount, base, quote);
    }

    function test_ResolveOracle_BaseEqQuote(uint256 inAmount, address base) public view {
        (uint256 resolvedInAmount, address resolvedBase, address resolvedQuote, address resolvedOracle) = router
            .resolveOracle(inAmount, base, base);

        assertEq(resolvedInAmount, inAmount);
        assertEq(resolvedBase, base);
        assertEq(resolvedQuote, base);
        assertEq(resolvedOracle, address(0));
    }

    function test_ResolveOracle_HasOracle(uint256 inAmount, address base, address quote, address oracle) public {
        vm.assume(base != quote);
        vm.assume(oracle != address(0));
        vm.prank(OWNER);
        router.govSetConfig(base, quote, oracle);

        (uint256 resolvedInAmount, address resolvedBase, address resolvedQuote, address resolvedOracle) = router
            .resolveOracle(inAmount, base, quote);
        assertEq(resolvedInAmount, inAmount);
        assertEq(resolvedBase, base);
        assertEq(resolvedQuote, quote);
        assertEq(resolvedOracle, oracle);
    }

    function test_ResolveOracle_BaseIsVault(
        uint256 inAmount,
        address baseAsset,
        address quote,
        uint256 rate1,
        uint256 rate2
    ) public {
        baseAsset = boundAddr(baseAsset);
        quote = boundAddr(quote);
        rate1 = bound(rate1, 1, 1e24);
        rate2 = bound(rate2, 1, 1e24);

        address oracle = address(new StubPriceOracle());
        address base = address(new StubERC4626(baseAsset, rate2));
        vm.assume(distinct(base, baseAsset, quote, oracle));

        vm.startPrank(OWNER);
        StubPriceOracle(oracle).setPrice(baseAsset, quote, rate1);
        router.govSetConfig(baseAsset, quote, oracle);
        router.govSetResolvedVault(base, true);
        inAmount = bound(inAmount, 1, type(uint128).max);

        (, address resolvedBase, address resolvedQuote, address resolvedOracle) = router.resolveOracle(
            inAmount,
            base,
            quote
        );
        assertEq(resolvedBase, baseAsset);
        assertEq(resolvedQuote, quote);
        assertEq(resolvedOracle, oracle);
    }

    function test_ResolveOracle_BaseIsVaultWithAssetEqQuote(uint256 inAmount, address baseAsset, uint256 rate1) public {
        baseAsset = boundAddr(baseAsset);
        rate1 = bound(rate1, 1, 1e24);

        address oracle = address(new StubPriceOracle());
        address base = address(new StubERC4626(baseAsset, rate1));
        vm.assume(distinct(base, baseAsset, oracle));

        vm.startPrank(OWNER);
        router.govSetResolvedVault(base, true);
        inAmount = bound(inAmount, 1, type(uint128).max);

        (, address resolvedBase, address resolvedQuote, address resolvedOracle) = router.resolveOracle(
            inAmount,
            base,
            baseAsset
        );
        assertEq(resolvedBase, baseAsset);
        assertEq(resolvedQuote, baseAsset);
        assertEq(resolvedOracle, address(0));
    }

    function test_ResolveOracle_HasOracleInverse(uint256 inAmount, address base, address quote, address oracle) public {
        vm.assume(base != quote);
        vm.assume(oracle != address(0));
        vm.prank(OWNER);
        router.govSetConfig(base, quote, oracle);

        (uint256 resolvedInAmount, address resolvedBase, address resolvedQuote, address resolvedOracle) = router
            .resolveOracle(inAmount, base, quote);
        assertEq(resolvedInAmount, inAmount);
        assertEq(resolvedBase, base);
        assertEq(resolvedQuote, quote);
        assertEq(resolvedOracle, oracle);
    }

    function test_ResolveOracle_NoOracleButHasFallback(
        uint256 inAmount,
        address base,
        address quote,
        address oracle
    ) public {
        vm.assume(base != quote);
        vm.assume(oracle != address(0));
        vm.prank(OWNER);
        router.govSetFallbackOracle(oracle);

        (uint256 resolvedInAmount, address resolvedBase, address resolvedQuote, address resolvedOracle) = router
            .resolveOracle(inAmount, base, quote);
        assertEq(resolvedInAmount, inAmount);
        assertEq(resolvedBase, base);
        assertEq(resolvedQuote, quote);
        assertEq(resolvedOracle, oracle);
    }

    function test_ResolveOracle_NoOracleNoFallback(uint256 inAmount, address base, address quote) public {
        vm.assume(base != quote);
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, base, quote));
        router.resolveOracle(inAmount, base, quote);
    }

    function test_TransferOwnership_RevertsWhen_CallerNotOwner(address caller, address newOwner) public {
        vm.assume(caller != OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        router.transferOwnership(newOwner);
    }

    function test_TransferOwnership_Integrity(address newOwner) public {
        vm.assume(newOwner != address(0));
        vm.prank(OWNER);
        router.transferOwnership(newOwner);

        // In Ownable2Step, the ownership transfer requires the new owner to accept
        vm.prank(newOwner);
        router.acceptOwnership();

        assertEq(router.owner(), newOwner);
    }

    function test_TransferOwnership_Integrity_ZeroAddress() public {
        vm.prank(OWNER);
        router.transferOwnership(address(0));

        // In Ownable2Step, transferring to zero address cancels the ownership transfer
        // The owner should remain the same
        assertEq(router.owner(), OWNER);
        assertEq(router.pendingOwner(), address(0));
    }

    function test_PreviewGetQuote_Integrity(
        uint256 inAmount,
        address base,
        address quote,
        address oracle,
        uint256 outAmount
    ) public {
        base = boundAddr(base);
        quote = boundAddr(quote);
        oracle = boundAddr(oracle);
        vm.assume(distinct(base, quote, oracle));
        inAmount = bound(inAmount, 1, type(uint128).max);

        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IPriceOracle.previewGetQuote.selector, inAmount, base, quote),
            abi.encode(outAmount)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IPriceOracle.previewGetQuotes.selector, inAmount, base, quote),
            abi.encode(outAmount, outAmount)
        );
        vm.prank(OWNER);
        router.govSetConfig(base, quote, oracle);

        uint256 _outAmount = router.previewGetQuote(inAmount, base, quote);
        assertEq(_outAmount, outAmount);
        (uint256 bidOutAmount, uint256 askOutAmount) = router.previewGetQuotes(inAmount, base, quote);
        assertEq(bidOutAmount, outAmount);
        assertEq(askOutAmount, outAmount);
    }

    function test_UpdatePriceFeeds_Integrity(address base, address quote, bytes calldata updateData) public {
        vm.assume(base != quote);

        StubPriceOracle oracle = new StubPriceOracle();
        vm.prank(OWNER);
        router.govSetConfig(base, quote, address(oracle));

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IPriceOracle.updatePriceFeeds.selector, base, quote, updateData),
            abi.encode()
        );

        router.updatePriceFeeds(base, quote, updateData);
    }

    function test_GetUpdateFee_Integrity(address base, address quote, bytes calldata updateData) public {
        vm.assume(base != quote);

        StubPriceOracle oracle = new StubPriceOracle();
        vm.prank(OWNER);
        router.govSetConfig(base, quote, address(oracle));

        uint128 fee = 1000;
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IPriceOracle.getUpdateFee.selector, base, quote, updateData),
            abi.encode(fee)
        );

        uint128 _fee = router.getUpdateFee(base, quote, updateData);
        assertEq(_fee, fee);
    }
}

contract MockToken is IERC20Metadata {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure override returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure override returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure override returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {StubPriceOracle} from "../../mocks/StubPriceOracle.sol";
import {CrossAdapter} from "../../../src/curators/oracles/CrossAdapter.sol";
import {ScaleUtils} from "@euler-price-oracle/lib/ScaleUtils.sol";

contract CrossAdapterTest is Test {
    address BASE = makeAddr("BASE");
    address CROSS = makeAddr("CROSS");
    address QUOTE = makeAddr("QUOTE");
    StubPriceOracle oracleBaseCross;
    StubPriceOracle oracleCrossQuote;
    CrossAdapter oracle;

    function setUp() public {
        oracleBaseCross = new StubPriceOracle();
        oracleCrossQuote = new StubPriceOracle();
        oracle = new CrossAdapter(BASE, CROSS, QUOTE, address(oracleBaseCross), address(oracleCrossQuote));
    }

    function test_Constructor_Integrity() public view {
        assertEq(oracle.base(), BASE);
        assertEq(oracle.cross(), CROSS);
        assertEq(oracle.quote(), QUOTE);
        assertEq(oracle.oracleBaseCross(), address(oracleBaseCross));
        assertEq(oracle.oracleCrossQuote(), address(oracleCrossQuote));
    }

    function test_GetQuote_Integrity(uint256 inAmount, uint256 priceBaseCross, uint256 priceCrossQuote) public {
        inAmount = bound(inAmount, 0, type(uint128).max);
        priceBaseCross = bound(priceBaseCross, 1, 1e27);
        priceCrossQuote = bound(priceCrossQuote, 1, 1e27);

        oracleBaseCross.setPrice(BASE, CROSS, priceBaseCross);
        oracleCrossQuote.setPrice(CROSS, QUOTE, priceCrossQuote);

        uint256 expectedOutAmount = (((inAmount * priceBaseCross) / 1e18) * priceCrossQuote) / 1e18;
        assertEq(oracle.getQuote(inAmount, BASE, QUOTE), expectedOutAmount);
    }

    function test_GetQuote_Integrity_Inverse(uint256 inAmount, uint256 priceQuoteCross, uint256 priceCrossBase) public {
        inAmount = bound(inAmount, 0, type(uint128).max);
        priceQuoteCross = bound(priceQuoteCross, 1, 1e27);
        priceCrossBase = bound(priceCrossBase, 1, 1e27);

        oracleCrossQuote.setPrice(QUOTE, CROSS, priceQuoteCross);
        oracleBaseCross.setPrice(CROSS, BASE, priceCrossBase);

        uint256 expectedOutAmount = (((inAmount * priceQuoteCross) / 1e18) * priceCrossBase) / 1e18;
        assertEq(oracle.getQuote(inAmount, QUOTE, BASE), expectedOutAmount);
    }

    function test_GetQuotes_Integrity(uint256 inAmount, uint256 priceBaseCross, uint256 priceCrossQuote) public {
        inAmount = bound(inAmount, 0, type(uint128).max);
        priceBaseCross = bound(priceBaseCross, 1, 1e27);
        priceCrossQuote = bound(priceCrossQuote, 1, 1e27);

        oracleBaseCross.setPrice(BASE, CROSS, priceBaseCross);
        oracleCrossQuote.setPrice(CROSS, QUOTE, priceCrossQuote);

        uint256 expectedOutAmount = (((inAmount * priceBaseCross) / 1e18) * priceCrossQuote) / 1e18;
        (uint256 bidOutAmount, uint256 askOutAmount) = oracle.getQuotes(inAmount, BASE, QUOTE);
        assertEq(bidOutAmount, expectedOutAmount);
        assertEq(askOutAmount, expectedOutAmount);
    }

    function test_PreviewGetQuote_Integrity(uint256 inAmount, uint256 priceBaseCross, uint256 priceCrossQuote) public {
        inAmount = bound(inAmount, 0, type(uint128).max);
        priceBaseCross = bound(priceBaseCross, 1, 1e27);
        priceCrossQuote = bound(priceCrossQuote, 1, 1e27);

        oracleBaseCross.setPrice(BASE, CROSS, priceBaseCross);
        oracleCrossQuote.setPrice(CROSS, QUOTE, priceCrossQuote);

        uint256 expectedOutAmount = (((inAmount * priceBaseCross) / 1e18) * priceCrossQuote) / 1e18;
        assertEq(oracle.previewGetQuote(inAmount, BASE, QUOTE), expectedOutAmount);
    }

    function test_PreviewGetQuotes_Integrity(uint256 inAmount, uint256 priceBaseCross, uint256 priceCrossQuote) public {
        inAmount = bound(inAmount, 0, type(uint128).max);
        priceBaseCross = bound(priceBaseCross, 1, 1e27);
        priceCrossQuote = bound(priceCrossQuote, 1, 1e27);

        oracleBaseCross.setPrice(BASE, CROSS, priceBaseCross);
        oracleCrossQuote.setPrice(CROSS, QUOTE, priceCrossQuote);

        uint256 expectedOutAmount = (((inAmount * priceBaseCross) / 1e18) * priceCrossQuote) / 1e18;
        (uint256 bidOutAmount, uint256 askOutAmount) = oracle.previewGetQuotes(inAmount, BASE, QUOTE);
        assertEq(bidOutAmount, expectedOutAmount);
        assertEq(askOutAmount, expectedOutAmount);
    }

    function test_UpdatePriceFeeds_Integrity_EmptyData() public {
        // Should not revert with empty data
        oracle.updatePriceFeeds(BASE, QUOTE, "");
    }

    function test_UpdatePriceFeeds_Integrity_WithData() public {
        bytes memory baseCrossData = abi.encode("baseCrossData");
        bytes memory crossQuoteData = abi.encode("crossQuoteData");

        bytes[] memory arr = new bytes[](2);
        arr[0] = baseCrossData;
        arr[1] = crossQuoteData;
        bytes memory updateData = abi.encode(arr);

        // Set the fees directly on the StubPriceOracle instances
        oracleBaseCross.setUpdateFee(BASE, CROSS, baseCrossData, 100);
        oracleCrossQuote.setUpdateFee(QUOTE, CROSS, crossQuoteData, 200);

        // Send enough ETH to cover the fees
        oracle.updatePriceFeeds{value: 300}(BASE, QUOTE, updateData);
    }

    function test_UpdatePriceFeeds_RevertsWhen_InsufficientFee() public {
        bytes memory updateData = abi.encode(abi.encode("baseCrossData"), abi.encode("crossQuoteData"));

        // Mock the fee calls to return high fees
        vm.mockCall(
            address(oracleBaseCross),
            abi.encodeWithSelector(oracleBaseCross.getUpdateFee.selector, BASE, CROSS, abi.encode("baseCrossData")),
            abi.encode(uint128(1000))
        );
        vm.mockCall(
            address(oracleCrossQuote),
            abi.encodeWithSelector(oracleCrossQuote.getUpdateFee.selector, QUOTE, CROSS, abi.encode("crossQuoteData")),
            abi.encode(uint128(2000))
        );

        // Send insufficient ETH
        vm.expectRevert();
        oracle.updatePriceFeeds{value: 100}(BASE, QUOTE, updateData);
    }

    function test_GetUpdateFee_Integrity_EmptyData() public view {
        uint128 fee = oracle.getUpdateFee(BASE, QUOTE, "");
        assertEq(fee, 0);
    }

    function test_GetUpdateFee_Integrity_WithData() public {
        bytes memory baseCrossData = abi.encode("baseCrossData");
        bytes memory crossQuoteData = abi.encode("crossQuoteData");

        bytes[] memory arr = new bytes[](2);
        arr[0] = baseCrossData;
        arr[1] = crossQuoteData;
        bytes memory updateData = abi.encode(arr);

        // Set the fees directly on the StubPriceOracle instances
        oracleBaseCross.setUpdateFee(BASE, CROSS, baseCrossData, 100);
        oracleCrossQuote.setUpdateFee(QUOTE, CROSS, crossQuoteData, 200);

        uint128 fee = oracle.getUpdateFee(BASE, QUOTE, updateData);
        assertEq(fee, 300);
    }

    function test_GetUpdateFee_RevertsWhen_InvalidDataLength() public {
        bytes memory updateData = abi.encode(abi.encode("singleData"));

        vm.expectRevert();
        oracle.getUpdateFee(BASE, QUOTE, updateData);
    }

    function test_GetQuote_RevertsWhen_InvalidTokens(address invalidBase, address invalidQuote) public {
        vm.assume(invalidBase != BASE && invalidBase != QUOTE);
        vm.assume(invalidQuote != BASE && invalidQuote != QUOTE);

        vm.expectRevert();
        oracle.getQuote(1000, invalidBase, invalidQuote);
    }

    function test_GetQuote_RevertsWhen_SameToken() public {
        vm.expectRevert();
        oracle.getQuote(1000, BASE, BASE);
    }

    function test_GetQuote_RevertsWhen_QuoteEqualsCross() public {
        vm.expectRevert();
        oracle.getQuote(1000, BASE, CROSS);
    }

    function test_GetQuote_RevertsWhen_BaseEqualsCross() public {
        vm.expectRevert();
        oracle.getQuote(1000, CROSS, QUOTE);
    }
}

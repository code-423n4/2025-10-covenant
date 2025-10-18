// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {PythOracleHelper} from "./PythOracleHelper.sol";
import {TestUtils} from "../../utils/TestUtils.sol";
import {PythOracle} from "../../../../src/curators/oracles/pyth/PythOracle.sol";
import {Errors} from "../../../../src/curators/lib/Errors.sol";

contract PythOracleTest is PythOracleHelper {
    function test_Constructor_Integrity(FuzzableState memory s) public {
        setUpState(s);

        assertEq(address(PythOracle(oracle).pyth()), PYTH);
        assertEq(PythOracle(oracle).base(), s.base);
        assertEq(PythOracle(oracle).quote(), s.quote);
        assertEq(PythOracle(oracle).feedId(), s.feedId);
        assertEq(PythOracle(oracle).maxStaleness(), s.maxStaleness);
    }

    function test_Constructor_RevertsWhen_MaxStalenessTooHigh(FuzzableState memory s) public {
        setBehavior(Behavior.Constructor_MaxStalenessTooHigh, true);
        vm.expectRevert();
        setUpState(s);
    }

    function test_Constructor_RevertsWhen_MaxConfWidthTooLow(FuzzableState memory s) public {
        setBehavior(Behavior.Constructor_MaxConfWidthTooLow, true);
        vm.expectRevert();
        setUpState(s);
    }

    function test_Constructor_RevertsWhen_MaxConfWidthTooHigh(FuzzableState memory s) public {
        setBehavior(Behavior.Constructor_MaxConfWidthTooHigh, true);
        vm.expectRevert();
        setUpState(s);
    }

    function test_Quote_RevertsWhen_InvalidTokens(FuzzableState memory s, address otherA, address otherB) public {
        setUpState(s);
        otherA = TestUtils.boundAddr(otherA);
        otherB = TestUtils.boundAddr(otherB);
        vm.assume(otherA != s.base && otherA != s.quote);
        vm.assume(otherB != s.base && otherB != s.quote);
        expectNotSupported(s.inAmount, s.base, s.base);
        expectNotSupported(s.inAmount, s.quote, s.quote);
        expectNotSupported(s.inAmount, s.base, otherA);
        expectNotSupported(s.inAmount, otherA, s.base);
        expectNotSupported(s.inAmount, s.quote, otherA);
        expectNotSupported(s.inAmount, otherA, s.quote);
        expectNotSupported(s.inAmount, otherA, otherA);
        expectNotSupported(s.inAmount, otherA, otherB);
    }

    function test_Quote_RevertsWhen_PythReverts(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReverts, true);
        setUpState(s);

        bytes memory err = abi.encodePacked("StubPyth: reverted");
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_ZeroPrice(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsZeroPrice, true);
        setUpState(s);

        bytes memory err = abi.encodeWithSelector(Errors.PriceOracle_InvalidAnswer.selector);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_NegativePrice(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsNegativePrice, true);
        setUpState(s);

        bytes memory err = abi.encodeWithSelector(Errors.PriceOracle_InvalidAnswer.selector);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_TooStale(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsStalePrice, true);
        setUpState(s);

        bytes memory err = abi.encodeWithSelector(Errors.PriceOracle_InvalidAnswer.selector);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_TooAhead(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsTooAheadPrice, true);
        setUpState(s);

        bytes memory err = abi.encodeWithSelector(Errors.PriceOracle_InvalidAnswer.selector);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_ConfTooWide(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsConfTooWide, true);
        setUpState(s);

        bytes memory err = abi.encodeWithSelector(Errors.PriceOracle_InvalidAnswer.selector);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_ExpoTooLow(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsExpoTooLow, true);
        setUpState(s);

        bytes memory err = abi.encodeWithSelector(Errors.PriceOracle_InvalidAnswer.selector);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_ExpoTooHigh(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsExpoTooHigh, true);
        setUpState(s);

        bytes memory err = abi.encodeWithSelector(Errors.PriceOracle_InvalidAnswer.selector);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_Integrity(FuzzableState memory s) public {
        setUpState(s);

        uint256 expectedOutAmount = calcOutAmount(s);
        uint256 outAmount = PythOracle(oracle).getQuote(s.inAmount, s.base, s.quote);
        assertEq(outAmount, expectedOutAmount);

        (uint256 bidOutAmount, uint256 askOutAmount) = PythOracle(oracle).getQuotes(s.inAmount, s.base, s.quote);
        assertEq(bidOutAmount, expectedOutAmount);
        assertEq(askOutAmount, expectedOutAmount);
    }

    function test_Quote_Integrity_Inverse(FuzzableState memory s) public {
        setUpState(s);

        uint256 expectedOutAmount = calcOutAmountInverse(s);
        uint256 outAmount = PythOracle(oracle).getQuote(s.inAmount, s.quote, s.base);
        assertEq(outAmount, expectedOutAmount);

        (uint256 bidOutAmount, uint256 askOutAmount) = PythOracle(oracle).getQuotes(s.inAmount, s.quote, s.base);
        assertEq(bidOutAmount, expectedOutAmount);
        assertEq(askOutAmount, expectedOutAmount);
    }

    // Test the additional Covenant interface methods
    function test_PreviewGetQuote_Integrity(FuzzableState memory s) public {
        setUpState(s);

        uint256 expectedOutAmount = calcOutAmount(s);
        uint256 outAmount = PythOracle(oracle).previewGetQuote(s.inAmount, s.base, s.quote);
        assertEq(outAmount, expectedOutAmount);
    }

    function test_PreviewGetQuote_Integrity_Inverse(FuzzableState memory s) public {
        setUpState(s);

        uint256 expectedOutAmount = calcOutAmountInverse(s);
        uint256 outAmount = PythOracle(oracle).previewGetQuote(s.inAmount, s.quote, s.base);
        assertEq(outAmount, expectedOutAmount);
    }

    function test_PreviewGetQuotes_Integrity(FuzzableState memory s) public {
        setUpState(s);

        uint256 expectedOutAmount = calcOutAmount(s);
        (uint256 bidOutAmount, uint256 askOutAmount) = PythOracle(oracle).previewGetQuotes(s.inAmount, s.base, s.quote);
        assertEq(bidOutAmount, expectedOutAmount);
        assertEq(askOutAmount, expectedOutAmount);
    }

    function test_PreviewGetQuotes_Integrity_Inverse(FuzzableState memory s) public {
        setUpState(s);

        uint256 expectedOutAmount = calcOutAmountInverse(s);
        (uint256 bidOutAmount, uint256 askOutAmount) = PythOracle(oracle).previewGetQuotes(s.inAmount, s.quote, s.base);
        assertEq(bidOutAmount, expectedOutAmount);
        assertEq(askOutAmount, expectedOutAmount);
    }

    function test_UpdatePriceFeeds_RevertsWhen_ExcessValue(FuzzableState memory s) public {
        setUpState(s);

        bytes memory updateData = abi.encode(new bytes[](1));
        uint256 fee = PythOracle(oracle).getUpdateFee(s.base, s.quote, updateData);

        vm.expectRevert(Errors.PriceOracle_IncorrectPayment.selector);
        PythOracle(oracle).updatePriceFeeds{value: fee + 1}(s.base, s.quote, updateData);
    }

    function test_UpdatePriceFeeds_Success_WithCorrectValue(FuzzableState memory s) public {
        setUpState(s);

        bytes memory updateData = abi.encode(new bytes[](1));
        uint256 fee = PythOracle(oracle).getUpdateFee(s.base, s.quote, updateData);

        // Should not revert when called with correct fee
        PythOracle(oracle).updatePriceFeeds{value: fee}(s.base, s.quote, updateData);
    }

    function test_GetUpdateFee_ReturnsCorrectFee(FuzzableState memory s) public {
        setUpState(s);

        bytes memory updateData = abi.encode(new bytes[](1));
        uint128 fee = PythOracle(oracle).getUpdateFee(s.base, s.quote, updateData);
        assertEq(fee, 0.001 ether);
    }
}

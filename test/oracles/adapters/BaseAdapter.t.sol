// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";
import {BaseAdapterHarness} from "./BaseAdapterHarness.sol";
import {boundAddr} from "../../utils/TestUtils.sol";

contract BaseAdapterTest is Test {
    uint160 internal constant ADDRESS_RESERVED_RANGE = 0xffffffff;
    BaseAdapterHarness oracle;

    function setUp() public {
        oracle = new BaseAdapterHarness();
    }

    function test_GetDecimals_Integrity_ReservedRange(address x) public view {
        x = address(uint160(x) % ADDRESS_RESERVED_RANGE);
        assertEq(oracle.getDecimals(x), 18);
    }

    function test_GetDecimals_Integrity_ERC20(address x, uint8 decimals) public {
        x = boundAddr(x);
        vm.assume(uint160(x) > ADDRESS_RESERVED_RANGE);
        vm.mockCall(x, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(decimals));

        uint8 _decimals = oracle.getDecimals(x);
        assertEq(_decimals, decimals);
    }

    function test_GetDecimals_Integrity_nonERC20(address x) public view {
        x = boundAddr(x);
        vm.assume(uint160(x) > ADDRESS_RESERVED_RANGE);

        uint8 decimals = oracle.getDecimals(x);
        assertEq(decimals, 18);
    }

    function test_GetQuote_Integrity() public {
        address base = makeAddr("base");
        address quote = makeAddr("quote");
        uint256 outAmount = oracle.getQuote(1000, base, quote);
        assertEq(outAmount, 0); // BaseAdapterHarness returns 0
    }

    function test_GetQuotes_Integrity() public {
        address base = makeAddr("base");
        address quote = makeAddr("quote");
        (uint256 bidOutAmount, uint256 askOutAmount) = oracle.getQuotes(1000, base, quote);
        assertEq(bidOutAmount, 0); // BaseAdapterHarness returns 0
        assertEq(askOutAmount, 0); // BaseAdapterHarness returns 0
    }

    function test_PreviewGetQuote_Integrity() public {
        address base = makeAddr("base");
        address quote = makeAddr("quote");
        uint256 outAmount = oracle.previewGetQuote(1000, base, quote);
        assertEq(outAmount, 0); // BaseAdapterHarness returns 0
    }

    function test_PreviewGetQuotes_Integrity() public {
        address base = makeAddr("base");
        address quote = makeAddr("quote");
        (uint256 bidOutAmount, uint256 askOutAmount) = oracle.previewGetQuotes(1000, base, quote);
        assertEq(bidOutAmount, 0); // BaseAdapterHarness returns 0
        assertEq(askOutAmount, 0); // BaseAdapterHarness returns 0
    }

    function test_UpdatePriceFeeds_Integrity() public {
        // Should not revert
        address base = makeAddr("base");
        address quote = makeAddr("quote");
        oracle.updatePriceFeeds(base, quote, "");
    }

    function test_GetUpdateFee_Integrity() public {
        address base = makeAddr("base");
        address quote = makeAddr("quote");
        uint128 fee = oracle.getUpdateFee(base, quote, "");
        assertEq(fee, 0); // BaseAdapter returns 0
    }
}

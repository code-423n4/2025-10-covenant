// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

library TestUtils {
    function boundAddr(address addr) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(addr)))));
    }

    function distinct(address a, address b) internal pure returns (bool) {
        return a != b;
    }

    function distinct(address a, address b, address c) internal pure returns (bool) {
        return a != b && a != c && b != c;
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

contract NoDelegateCall {
    address private immutable originalAddress;
    error E_DelegateCallNotAllowed();

    constructor() {
        originalAddress = address(this);
    }

    modifier noDelegateCall() {
        if (address(this) != originalAddress) revert E_DelegateCallNotAllowed();
        _;
    }
}

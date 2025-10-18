// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {MarketId, MarketParams} from "../interfaces/ICovenant.sol";

/// @title MarketParams Library
/// @author Covenant Labs
/// @notice Library to convert a market to its id.
library MarketParamsLib {
    /// @notice Returns the id of the market `marketParams`.
    function id(MarketParams calldata p) internal pure returns (MarketId marketParamsId) {
        return
            MarketId.wrap(
                bytes20(uint160(uint256(keccak256(abi.encodePacked(p.baseToken, p.quoteToken, p.curator, p.lex)))))
            );
    }
}

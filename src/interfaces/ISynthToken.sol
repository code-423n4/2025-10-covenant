// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MarketId, AssetType} from "../interfaces/ICovenant.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/**
 * @title ICovenant
 * @author Amorphous
 * @notice Defines the the core interface of Covenant Liquid markets.
 **/
interface ISynthToken is IERC20 {
    // Notice - gets CovenantCore associated with the SynthToken
    function getCovenantCore() external returns (address);

    // Notice - gets marketId associated with the SynthToken
    function getMarketId() external returns (MarketId);

    // Notice - gets synthType associated with the SynthToken
    function getSynthType() external returns (AssetType);

    /**
     * @dev Expose share mint functionality to Covenant Liquid
     */
    function lexMint(address account, uint256 value) external;

    /**
     * @dev Expose share redeem functionality to Covenant Liquid
     */
    function lexBurn(address account, uint256 value) external;
}

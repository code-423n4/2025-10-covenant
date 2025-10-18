// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

library LSErrors {
    error E_LEX_OnlyCovenantCanCall(); // 0x1150f470
    error E_LEX_ZeroAddress(); // 0xad5292ae
    error E_LEX_ZeroLiquidity(); // 0xb38d3cff
    error E_LEX_AlreadyInitialized(); // 0xbb304191
    error E_LEX_IncorrectInitializationPrice(); // 0xc868f36a
    error E_LEX_IncorrectInitializationLnRateBias(); // 0x4cf570ef
    error E_LEX_InsufficientTokens(); // 0x6cf03401
    error E_LEX_ActionNotAllowedGivenLTVlimit(); // 0x2ab66638
    error E_LEX_ActionNotAllowedUnderCollateralized(); // 0xabc1fa28
    error E_LEX_OperationNotAllowed(); // 0x82a547cd
    error E_LEX_RedeemCapExceeded(); // 0xef9b092a
    error E_LEX_MintCapExceeded(); // 0x6c8de6e1
    error E_LEX_OraclePriceTooLowForMarket(); // 0x417969ec
    error E_LEX_IncorrectInitializationDuration(); // 0x50560b48
    error E_LEX_BaseAssetNotERC20(); // 0x77e6fe18
    error E_LEX_QuoteAssetHasNoSymbol(); // 0xd5862a35
    error E_LEX_MarketDoesNotExist(); // 0xda47482e
    error E_LEX_Overdeposit(); // 0x94f85219
    error E_LEX_InsufficientAmount(); // 0xe869f1da
    error E_LEX_MarketSizeLimitExceeded(); // 0x23565a11
}

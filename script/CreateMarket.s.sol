// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICovenant, MarketParams, MarketId} from "../src/interfaces/ICovenant.sol";

// @dev - order needs to be alphabetical given forge-std constraints
struct CreateMarketParams {
    address baseToken;
    address covenant;
    address curator;
    address lex;
    address quoteToken;
}

contract CastCreateMarket is Script {
    function run() external {
        // Read market param JSON
        string memory jsonString = vm.readFile("./script/CreateMarketParams.json"); //prettier-ignore
        bytes memory jsonData = vm.parseJson(jsonString);
        CreateMarketParams memory createParams = abi.decode(jsonData, (CreateMarketParams)); //prettier-ignore

        // Print parsing
        console.log("Market Parameters");
        console.log(createParams.covenant);
        console.log(createParams.baseToken);
        console.log(createParams.quoteToken);
        console.log(createParams.curator);
        console.log(createParams.lex);

        // Create market onchain
        vm.startBroadcast();

        ICovenant(createParams.covenant).setEnabledCurator(createParams.curator, true);

        // init market
        MarketParams memory marketParams = MarketParams({
            baseToken: createParams.baseToken,
            quoteToken: createParams.quoteToken,
            curator: createParams.curator,
            lex: createParams.lex
        });
        MarketId marketId = ICovenant(createParams.covenant).createMarket(marketParams, hex"");

        vm.stopBroadcast();

        console.log("Market created.  MarkedId = ", address(MarketId.unwrap(marketId)));
    }
}

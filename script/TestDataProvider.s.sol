// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DataProvider, MarketDetails} from "../src/periphery/DataProvider.sol";
import {ICovenant, MarketId} from "../src/interfaces/ICovenant.sol";

// @dev - order needs to be alphabetical given forge-std constraints
struct TestConfig {
    address covenantAddress;
    string marketId;
}

contract TestDataProvider is Script {
    function run() external {
        // Read test config JSON
        string memory jsonString = vm.readFile("./script/TestDataProviderConfig.json"); //prettier-ignore
        bytes memory jsonData = vm.parseJson(jsonString);
        TestConfig memory config = abi.decode(jsonData, (TestConfig)); //prettier-ignore

        // Print parsing
        console.log("Test Configuration");
        console.log("Covenant Address:", config.covenantAddress);
        console.log("Market ID:", config.marketId);

        vm.startBroadcast();

        // Deploy DataProvider
        DataProvider dataProvider = new DataProvider();
        console.log("DataProvider deployed at:", address(dataProvider));

        // Convert string market ID to bytes20
        MarketId marketId = MarketId.wrap(bytes20(abi.encodePacked(config.marketId)));

        // Get market details
        MarketDetails memory details = dataProvider.getMarketDetails(config.covenantAddress, marketId);

        console.log("=== Market Details ===");
        console.log("Market ID:");
        console.logBytes32(MarketId.unwrap(details.marketId));
        console.log("Base Token Address:", address(details.marketParams.baseToken));
        console.log("Quote Token Address:", address(details.marketParams.quoteToken));
        console.log("Oracle Address:", details.marketParams.curator);
        console.log("LEX Address:", details.marketParams.lex);

        console.log("=== Token Prices ===");
        console.log("Base Token Price:", details.tokenPrices.baseTokenPrice);
        console.log("A Token Price:", details.tokenPrices.aTokenPrice);
        console.log("Z Token Price:", details.tokenPrices.zTokenPrice);

        console.log("=== Market State ===");
        console.log("Base Supply:", details.marketState.baseSupply);
        console.log("Last Sqrt Price X96:", details.lexState.lastSqrtPriceX96);
        console.log("Last Base Token Price:", details.lexState.lastBaseTokenPrice);
        console.log("Last Debt Notional Price:", details.lexState.lastDebtNotionalPrice);

        console.log("=== Synth Token Details ===");
        console.log("A Token Address:", details.aToken.tokenAddress);
        console.log("A Token Name:", details.aToken.name);
        console.log("A Token Symbol:", details.aToken.symbol);
        console.log("A Token Decimals:", details.aToken.decimals);
        console.log("A Token Total Supply:", details.aToken.totalSupply);

        console.log("Z Token Address:", details.zToken.tokenAddress);
        console.log("Z Token Name:", details.zToken.name);
        console.log("Z Token Symbol:", details.zToken.symbol);
        console.log("Z Token Decimals:", details.zToken.decimals);
        console.log("Z Token Total Supply:", details.zToken.totalSupply);

        console.log("=== LEX Configuration ===");
        console.log("Protocol Fee:", details.lexConfig.protocolFee);
        console.log("A Token Address:", details.lexConfig.aToken);
        console.log("Z Token Address:", details.lexConfig.zToken);
        console.log("No Cap Limit:", details.lexConfig.noCapLimit);
        console.log("Scale Decimals:", details.lexConfig.scaleDecimals);
        console.log("Adaptive:", details.lexConfig.adaptive);

        console.log("=== Additional Info ===");
        console.log("Current LTV:", details.currentLTV);
        console.log("Target LTV:", details.targetLTV);
        console.log("Debt Price Discount:", details.debtPriceDiscount);

        vm.stopBroadcast();
    }
}

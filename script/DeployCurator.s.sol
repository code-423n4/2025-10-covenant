// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CovenantCurator} from "../src/curators/CovenantCurator.sol";

// @dev - order needs to be alphabetical given forge-std constraints
struct OraclePair {
    address base;
    address oracle;
    address quote;
}

struct RouterConfig {
    address fallbackOracle;
    OraclePair[] oraclePairs;
}

contract DeployCurator is Script {
    function run() external {
        // Read router config JSON
        string memory jsonString = vm.readFile("./script/OracleConfig-Router.json"); //prettier-ignore
        bytes memory jsonData = vm.parseJson(jsonString);
        RouterConfig memory config = abi.decode(jsonData, (RouterConfig)); //prettier-ignore

        // Print parsing
        console.log("=== Covenant Oracle Router Configuration ===");
        console.log("Fallback Oracle:", config.fallbackOracle);
        console.log("Number of Oracle Pairs:", config.oraclePairs.length);

        vm.startBroadcast();

        // Deploy Covenant Oracle Router
        CovenantCurator router = new CovenantCurator(msg.sender);
        console.log("CovenantCurator deployed at:", address(router));

        // set fallback oracle
        router.govSetFallbackOracle(config.fallbackOracle);
        console.log("Fallback Oracle set to:", config.fallbackOracle);

        // Register oracle pairs
        console.log("\n=== Registering Oracle Pairs ===");
        for (uint256 i = 0; i < config.oraclePairs.length; i++) {
            OraclePair memory pair = config.oraclePairs[i];
            console.log("Registering pair", i + 1, ":");
            console.log("  Base:", pair.base);
            console.log("  Quote:", pair.quote);
            console.log("  Oracle:", pair.oracle);

            router.govSetConfig(pair.base, pair.quote, pair.oracle);
            console.log("  Registered successfully");
        }

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("CovenantCurator:", address(router));
        console.log("Fallback Oracle:", config.fallbackOracle);
        console.log("Registered Oracle Pairs:", config.oraclePairs.length);
    }
}

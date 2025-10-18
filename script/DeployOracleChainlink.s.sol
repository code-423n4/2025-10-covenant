// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ChainlinkOracle} from "../src/curators/oracles/chainlink/ChainlinkOracle.sol";

// @dev - order needs to be alphabetical given forge-std constraints
struct ChainlinkConfig {
    address baseToken;
    address feedAddress;
    uint256 maxStaleness;
    string name;
    string oracleType;
    address quoteToken;
}

contract DeployChainlinkOracle is Script {
    function run() external {
        // Read chainlink config JSON
        string memory jsonString = vm.readFile("./script/OracleConfig-Chainlink.json"); //prettier-ignore
        bytes memory jsonData = vm.parseJson(jsonString);
        ChainlinkConfig memory config = abi.decode(jsonData, (ChainlinkConfig)); //prettier-ignore

        // Print parsing
        console.log("=== Chainlink Oracle Configuration ===");
        console.log("Oracle Type:", config.oracleType);
        console.log("Name:", config.name);
        console.log("Base Token:", config.baseToken);
        console.log("Quote Token:", config.quoteToken);
        console.log("Feed Address:", config.feedAddress);
        console.log("Max Staleness:", config.maxStaleness);

        vm.startBroadcast();

        // Deploy Chainlink Oracle
        ChainlinkOracle chainlinkOracle = new ChainlinkOracle(
            config.baseToken,
            config.quoteToken,
            config.feedAddress,
            config.maxStaleness
        );

        console.log("ChainlinkOracle deployed at:", address(chainlinkOracle));

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("ChainlinkOracle:", address(chainlinkOracle));
    }
}

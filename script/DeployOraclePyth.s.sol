// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PythOracle} from "../src/curators/oracles/pyth/PythOracle.sol";

// @dev - order needs to be alphabetical given forge-std constraints
struct PythConfig {
    address baseToken;
    bytes32 feedId;
    uint256 maxConfWidth;
    uint256 maxStaleness;
    string name;
    string oracleType;
    address pythAddress;
    address quoteToken;
}

contract DeployPythOracle is Script {
    function run() external {
        // Read pyth config JSON
        string memory jsonString = vm.readFile("./script/OracleConfig-Pyth.json"); //prettier-ignore
        bytes memory jsonData = vm.parseJson(jsonString);
        PythConfig memory config = abi.decode(jsonData, (PythConfig)); //prettier-ignore

        // Print parsing
        console.log("=== Pyth Oracle Configuration ===");
        console.log("Oracle Type:", config.oracleType);
        console.log("Name:", config.name);
        console.log("Base Token:", config.baseToken);
        console.log("Quote Token:", config.quoteToken);
        console.log("Pyth Address:", config.pythAddress);
        console.log("Feed ID:");
        console.logBytes32(config.feedId);
        console.log("Max Staleness:", config.maxStaleness);
        console.log("Max Conf Width:", config.maxConfWidth);

        vm.startBroadcast();

        // Deploy Pyth Oracle
        PythOracle pythOracle = new PythOracle(
            config.pythAddress,
            config.baseToken,
            config.quoteToken,
            config.feedId,
            config.maxStaleness,
            config.maxConfWidth
        );

        console.log("PythOracle deployed at:", address(pythOracle));

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("PythOracle:", address(pythOracle));
    }
}

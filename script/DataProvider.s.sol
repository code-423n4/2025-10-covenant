// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DataProvider} from "../src/periphery/DataProvider.sol";

contract DeployDataProvider is Script {
    function run() external {
        vm.startBroadcast();

        DataProvider dataProvider = new DataProvider();
        console.log(address(dataProvider));

        vm.stopBroadcast();
    }
}

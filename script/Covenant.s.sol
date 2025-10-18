// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Covenant} from "../src/Covenant.sol";
import {SynthToken} from "../src/synths/SynthToken.sol";

contract DeployCovenant is Script {
    function run() external {
        vm.startBroadcast();

        Covenant covenantLiquidCore = new Covenant(msg.sender);
        console.log("Covenant Liquid address %s", address(covenantLiquidCore));

        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICovenant} from "../src/interfaces/ICovenant.sol";
import {LatentSwapLEX, ILatentSwapLEX} from "../src/lex/latentswap/LatentSwapLEX.sol";
import {LatentSwapLib} from "../src/periphery/libraries/LatentSwapLib.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";

// @dev - order needs to be alphabetical given forge-std constraints
struct CreateLEXParams {
    address covenantLiquid;
    uint256 debtDuration;
    uint256 highLTV;
    uint256 maxLTV;
    int256 rateBias;
    uint256 swapFee;
    uint256 targetLTV;
    uint256 yieldWidth;
}

struct runVars {
    string jsonString;
    bytes jsonData;
    CreateLEXParams LEXparams;
    uint160 maxMarketPriceX96;
    uint160 minMarketPriceX96;
    uint160 targetPriceX96;
    uint160 maxLimitPriceX96;
    uint160 highLimitPriceX96;
    uint160 edgeHighPriceX96;
    uint160 edgeLowPriceX96;
    address lexImplementation;
}

interface ILatentSwapLEXextended {
    function setQuoteTokenSymbolOverrideForNewMarkets(address token, string memory symbol) external;
    function setQuoteTokenDecimalsOverrideForNewMarkets(address token, uint8 decimals) external;
    function setDefaultNoCapLimit(address token, uint8 noCapLimit) external;
}

contract CastCreateLEX is Script {
    using SafeCast for uint256;
    using SafeCast for int256;

    function run() external {
        runVars memory vars;

        // Read market param JSON
        vars.jsonString = vm.readFile("./script/CreateLEXParams.json"); //prettier-ignore
        vars.jsonData = vm.parseJson(vars.jsonString);
        vars.LEXparams = abi.decode(vars.jsonData, (CreateLEXParams)); //prettier-ignore

        // Print parsing
        console.log("LEX Parameters");
        console.log("covenantLiquid", vars.LEXparams.covenantLiquid);
        console.log("targetLTV", vars.LEXparams.targetLTV);
        console.log("highLTV", vars.LEXparams.highLTV);
        console.log("maxLTV", vars.LEXparams.maxLTV);
        console.log("debtDuration", vars.LEXparams.debtDuration);
        console.log("swapFee", vars.LEXparams.swapFee);
        console.log("yieldWidth", vars.LEXparams.yieldWidth);
        console.log("rateBias", vars.LEXparams.rateBias);

        // convert config parameters to initialization parameters
        (vars.minMarketPriceX96, vars.maxMarketPriceX96) = LatentSwapLib.getMarketEdgePrices(
            vars.LEXparams.targetLTV.toUint32(),
            vars.LEXparams.yieldWidth
        );
        vars.maxLimitPriceX96 = LatentSwapLib.getSqrtPriceFromLTVX96(
            vars.minMarketPriceX96,
            vars.maxMarketPriceX96,
            vars.LEXparams.maxLTV.toUint32()
        );
        vars.highLimitPriceX96 = LatentSwapLib.getSqrtPriceFromLTVX96(
            vars.minMarketPriceX96,
            vars.maxMarketPriceX96,
            vars.LEXparams.highLTV.toUint32()
        );

        // Create market onchain
        vm.startBroadcast();

        // deploy lex implementation
        vars.lexImplementation = address(
            new LatentSwapLEX(
                msg.sender,
                vars.LEXparams.covenantLiquid,
                vars.maxMarketPriceX96,
                vars.minMarketPriceX96,
                vars.highLimitPriceX96,
                vars.maxLimitPriceX96,
                vars.LEXparams.rateBias.toInt64(),
                vars.LEXparams.debtDuration.toUint32(),
                vars.LEXparams.swapFee.toUint8()
            )
        );

        // authorize lex
        ICovenant(vars.LEXparams.covenantLiquid).setEnabledLEX(vars.lexImplementation, true);
        console.log("LEX implementation %s", vars.lexImplementation);

        // configure certain non-standard quote tokens

        // MON
        ILatentSwapLEXextended(vars.lexImplementation).setQuoteTokenSymbolOverrideForNewMarkets(address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), "MON"); // prettier-ignore
        ILatentSwapLEXextended(vars.lexImplementation).setQuoteTokenDecimalsOverrideForNewMarkets(address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), 18); // prettier-ignore
        ILatentSwapLEXextended(vars.lexImplementation).setDefaultNoCapLimit(
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            70
        ); // 1200 MON limit

        // USD
        ILatentSwapLEXextended(vars.lexImplementation).setQuoteTokenSymbolOverrideForNewMarkets(address(0x0000000000000000000000000000000000000348), "USD"); // prettier-ignore
        ILatentSwapLEXextended(vars.lexImplementation).setQuoteTokenDecimalsOverrideForNewMarkets(address(0x0000000000000000000000000000000000000348), 6); // prettier-ignore
        ILatentSwapLEXextended(vars.lexImplementation).setDefaultNoCapLimit(
            address(0x0000000000000000000000000000000000000348),
            37
        ); // $130K limit

        vm.stopBroadcast();
    }
}

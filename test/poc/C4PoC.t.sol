// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

// Test setup dependencies
import "forge-std/Test.sol";
import {CovenantCurator} from "../../src/curators/CovenantCurator.sol";
import {StubPriceOracle} from "../mocks/StubPriceOracle.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";
import {ChainlinkOracle} from "../../src/curators/oracles/chainlink/ChainlinkOracle.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {PythOracle} from "../../src/curators/oracles/pyth/PythOracle.sol";

// Several project dependencies that might be useful in PoCs
import {SynthToken} from "../../src/synths/SynthToken.sol";
import {Covenant, MarketId, MarketParams, MarketState, SynthTokens} from "../../src/Covenant.sol";
import {LatentSwapLEX} from "../../src/lex/latentswap/LatentSwapLEX.sol";
import {LSErrors} from "../../src/lex/latentswap/libraries/LSErrors.sol";
import {FixedPoint} from "../../src/lex/latentswap/libraries/FixedPoint.sol";
import {DebtMath} from "../../src/lex/latentswap/libraries/DebtMath.sol";
import {ICovenant, IERC20, AssetType, SwapParams, RedeemParams, MintParams} from "../../src/interfaces/ICovenant.sol";
import {ISynthToken} from "../../src/interfaces/ISynthToken.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {ILiquidExchangeModel} from "../../src/interfaces/ILiquidExchangeModel.sol";
import {ILatentSwapLEX, LexState} from "../../src/lex/latentswap/interfaces/ILatentSwapLEX.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {WadRayMath} from "@aave/libraries/math/WadRayMath.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {UtilsLib} from "../../src/libraries/Utils.sol";
import {TestMath} from "../utils/TestMath.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {LatentSwapLib} from "../../src/periphery/libraries/LatentSwapLib.sol";
import {PercentageMath} from "@aave/libraries/math/PercentageMath.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {StubERC4626} from "../mocks/StubERC4626.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

contract CovenantTest is Test {
    using WadRayMath for uint256;

    // LatentSwapLEX init pricing constants
    uint160 internal constant P_MAX = uint160((1095445 * FixedPoint.Q96) / 1000000); //uint160(Math.sqrt((FixedPoint.Q192 * 12) / 10)); // Edge price of 1.2
    uint160 internal constant P_MIN = uint160(FixedPoint.Q192 / P_MAX);
    uint32 internal constant DURATION = 30 * 24 * 60 * 60;
    uint8 internal constant SWAP_FEE = 0;
    int64 internal constant LN_RATE_BIAS = 5012540000000000; // WAD

    address private _mockOracle;
    address private _mockBaseAsset;
    address private _mockQuoteAsset;
    uint160 private P_LIM_H = LatentSwapLib.getSqrtPriceFromLTVX96(P_MIN, P_MAX, 9500);
    uint160 private P_LIM_MAX = LatentSwapLib.getSqrtPriceFromLTVX96(P_MIN, P_MAX, 9999);

    // PoC Contract Deployments
    Covenant public covenant;
    LatentSwapLEX public lex;
    CovenantCurator public covenantCurator;
    StubPriceOracle public covenantCuratorOracle;
    MarketId internal _marketId;
    MockChainlinkAggregator public chainlinkAggregator;
    ChainlinkOracle public chainlinkOracle;
    MockPyth public pyth;
    PythOracle public pythOracle;

    ////////////////////////////////////////////////////////////////////////////

    function setUp() public {
        // Deploy mock Oracle
        _mockOracle = address(new MockOracle(address(this)));

        // Deploy mock Base Asset w/ pre-mint
        _mockBaseAsset = address(new MockERC20(address(this), "MockBaseAsset", "MBA", 18));
        MockERC20(_mockBaseAsset).mint(address(this), 100e18);

        // Deploy mock Quote Asset
        _mockQuoteAsset = address(new MockERC20(address(this), "MockQaseAsset", "MQA", 18));

        // Deploy Covenant
        covenant = new Covenant(address(this));

        // Deploy LEX implementation
        lex = new LatentSwapLEX(
            address(this),
            address(covenant),
            P_MAX,
            P_MIN,
            P_LIM_H,
            P_LIM_MAX,
            LN_RATE_BIAS,
            DURATION,
            SWAP_FEE
        );

        // Connect LEX w/ Covenant
        covenant.setEnabledLEX(address(lex), true);

        // Connect mock oracle w/ Covenant
        covenant.setEnabledCurator(_mockOracle, true);

        // Create a mock market
        MarketParams memory marketParams = MarketParams({
            baseToken: _mockBaseAsset,
            quoteToken: _mockQuoteAsset,
            curator: _mockOracle,
            lex: address(lex)
        });
        _marketId = covenant.createMarket(marketParams, hex"");

        // Deploy the Covenant Curator (Oracle Router)
        covenantCurator = new CovenantCurator(address(this));

        // Deploy a *stub* oracle for the Covenant Curator
        covenantCuratorOracle = new StubPriceOracle();

        // Link *stub* oracle with mock base and quote assets
        covenantCurator.govSetConfig(_mockBaseAsset, _mockQuoteAsset, address(covenantCuratorOracle));

        // Deploy mock Chainlink Aggregator
        chainlinkAggregator = new MockChainlinkAggregator(8);

        // Deploy Chainlink Oracle
        chainlinkOracle = new ChainlinkOracle(_mockBaseAsset, _mockQuoteAsset, address(chainlinkAggregator), 1 hours);

        // Deploy mock Pyth
        pyth = new MockPyth();

        // Deploy Pyth Oracle
        pythOracle = new PythOracle(
            address(pyth),
            _mockBaseAsset,
            _mockQuoteAsset,
            bytes32(uint256(196)),
            10 minutes,
            250
        );
    }

    function test_submissionValidity() public {}
}

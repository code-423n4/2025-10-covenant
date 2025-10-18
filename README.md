# Covenant audit details
- Total Prize Pool: $43,000 in USDC
    - HM awards: up to $38,400 in USDC
        - If no valid Highs or Mediums are found, the HM pool is $0
    - QA awards: $1,600 in USDC
    - Judge awards: $2,500 in USDC
    - Scout awards: $500 in USDC
- [Read our guidelines for more details](https://docs.code4rena.com/competitions)
- Starts October 22, 2025 20:00 UTC
- Ends November 3, 2025 20:00 UTC

### ❗ Important notes for wardens
1. A coded, runnable PoC is required for all High/Medium submissions to this audit. 
    - This repo includes a basic template to run the test suite.
    - PoCs must use the test suite provided in this repo.
    - Your submission will be marked as Insufficient if the POC is not runnable and working with the provided test suite.
    - Exception: PoC is optional (though recommended) for wardens with signal ≥ 0.68.
1. Judging phase risk adjustments (upgrades/downgrades):
    - High- or Medium-risk submissions downgraded by the judge to Low-risk (QA) will be ineligible for awards.
    - Upgrading a Low-risk finding from a QA report to a Medium- or High-risk finding is not supported.
    - As such, wardens are encouraged to select the appropriate risk level carefully during the submission phase.

## V12 findings (🐺 C4 staff: remove this section for non-Solidity/EVM audits)

[V12](https://v12.zellic.io/) is [Zellic](https://zellic.io)'s in-house AI auditing tool. It is the only autonomous Solidity auditor that [reliably finds Highs and Criticals](https://www.zellic.io/blog/introducing-v12/). All issues found by V12 will be judged as out of scope and ineligible for awards.

V12 findings will be posted in this section within the first two days of the competition.  

## Publicly known issues

_Anything included in this section is considered a publicly known issue and is therefore ineligible for awards._

## 🐺 C4: Begin Gist paste here (and delete this line)





# Scope

*See [scope.txt](https://github.com/code-423n4/2025-10-covenant/blob/main/scope.txt)*

### Files in scope


| File   | Logic Contracts | Interfaces | nSLOC | Purpose | Libraries used |
| ------ | --------------- | ---------- | ----- | -----   | ------------ |
| /src/Covenant.sol | 1| **** | 274 | |@openzeppelin/token/ERC20/IERC20.sol<br>@openzeppelin/token/ERC20/utils/SafeERC20.sol<br>@openzeppelin/access/Ownable2Step.sol|
| /src/curators/CovenantCurator.sol | 1| **** | 91 | |forge-std/interfaces/IERC4626.sol<br>@openzeppelin/access/Ownable2Step.sol|
| /src/curators/lib/Errors.sol | 1| **** | 12 | ||
| /src/curators/oracles/BaseAdapter.sol | 1| **** | 28 | |@euler-price-oracle/adapter/BaseAdapter.sol|
| /src/curators/oracles/CrossAdapter.sol | 1| **** | 64 | |@euler-price-oracle/lib/ScaleUtils.sol|
| /src/curators/oracles/chainlink/ChainlinkOracle.sol | 1| **** | 26 | |@euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol<br>@euler-price-oracle/adapter/chainlink/AggregatorV3Interface.sol<br>@euler-price-oracle/lib/ScaleUtils.sol|
| /src/curators/oracles/pyth/PythOracle.sol | 1| **** | 63 | |@pyth/IPyth.sol<br>@pyth/PythStructs.sol<br>@euler-price-oracle/adapter/pyth/PythOracle.sol<br>@openzeppelin/contracts/utils/math/SafeCast.sol|
| /src/lex/latentswap/LatentSwapLEX.sol | 1| **** | 310 | |@openzeppelin/access/Ownable2Step.sol|
| /src/lex/latentswap/libraries/DebtMath.sol | 1| **** | 36 | |@solady/utils/FixedPointMathLib.sol<br>@openzeppelin/utils/math/Math.sol|
| /src/lex/latentswap/libraries/FixedPoint.sol | 1| **** | 17 | ||
| /src/lex/latentswap/libraries/LSErrors.sol | 1| **** | 23 | ||
| /src/lex/latentswap/libraries/LatentMath.sol | 1| **** | 159 | |@openzeppelin/utils/math/Math.sol<br>@openzeppelin/utils/math/SafeCast.sol|
| /src/lex/latentswap/libraries/LatentSwapLogic.sol | 1| **** | 656 | |@openzeppelin/utils/math/Math.sol<br>@aave/libraries/math/PercentageMath.sol<br>@openzeppelin/token/ERC20/IERC20.sol<br>@openzeppelin/utils/math/SafeCast.sol<br>@openzeppelin/utils/Strings.sol<br>@solady/utils/FixedPointMathLib.sol|
| /src/lex/latentswap/libraries/SaturatingMath.sol | 1| **** | 34 | |@openzeppelin/utils/math/Math.sol<br>@openzeppelin/utils/math/SafeCast.sol|
| /src/lex/latentswap/libraries/SqrtPriceMath.sol | 1| **** | 79 | |@openzeppelin/utils/math/Math.sol<br>@openzeppelin/utils/math/SafeCast.sol|
| /src/lex/latentswap/libraries/TokenData.sol | 1| **** | 65 | ||
| /src/lex/latentswap/libraries/Uint512.sol | 1| **** | 66 | |@openzeppelin/utils/math/Math.sol|
| /src/libraries/Errors.sol | 1| **** | 19 | ||
| /src/libraries/Events.sol | 1| **** | 50 | ||
| /src/libraries/MarketParams.sol | 1| **** | 10 | ||
| /src/libraries/MultiCall.sol | 1| **** | 8 | |@openzeppelin/utils/Address.sol<br>@openzeppelin/utils/Context.sol|
| /src/libraries/NoDelegateCall.sol | 1| **** | 12 | ||
| /src/libraries/SafeMetadata.sol | 1| **** | 47 | |@openzeppelin/token/ERC20/IERC20.sol<br>@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol|
| /src/libraries/Utils.sol | 1| **** | 10 | ||
| /src/libraries/ValidationLogic.sol | 1| **** | 74 | ||
| /src/synths/SynthToken.sol | 1| **** | 48 | |@openzeppelin/token/ERC20/ERC20.sol|
| **Totals** | **26** | **** | **2281** | | |

### Files out of scope

*See [out_of_scope.txt](https://github.com/code-423n4/2025-10-covenant/blob/main/out_of_scope.txt)*

| File         |
| ------------ |
| ./script/Covenant.s.sol |
| ./script/CreateLEX.s.sol |
| ./script/CreateMarket.s.sol |
| ./script/DataProvider.s.sol |
| ./script/DeployCurator.s.sol |
| ./script/DeployOracleChainlink.s.sol |
| ./script/DeployOraclePyth.s.sol |
| ./script/TestDataProvider.s.sol |
| ./src/curators/interfaces/ICovenantPriceOracle.sol |
| ./src/interfaces/ICovenant.sol |
| ./src/interfaces/ILiquidExchangeModel.sol |
| ./src/interfaces/IPriceOracle.sol |
| ./src/interfaces/ISynthToken.sol |
| ./src/lex/latentswap/interfaces/ILatentSwapLEX.sol |
| ./src/lex/latentswap/interfaces/ITokenData.sol |
| ./src/periphery/DataProvider.sol |
| ./src/periphery/interfaces/IDataProvider.sol |
| ./src/periphery/libraries/LatentSwapLib.sol |
| ./test/Covenant.t.sol |
| ./test/CovenantFuzz.t.sol |
| ./test/DataProvider.t.sol |
| ./test/DebtMath.t.sol |
| ./test/LatentMath.t.sol |
| ./test/LatentMathFuzz.t.sol |
| ./test/LatentSwapLEX.t.sol |
| ./test/LatentSwapLEXFuzz.t.sol |
| ./test/SqrtPriceMath.t.sol |
| ./test/Uint512Fuzz.t.sol |
| ./test/mocks/MockERC20.sol |
| ./test/mocks/MockLatentMath.sol |
| ./test/mocks/MockLatentSwapLEX.sol |
| ./test/mocks/MockOracle.sol |
| ./test/mocks/MockOracleNonERC20.sol |
| ./test/mocks/StubERC4626.sol |
| ./test/mocks/StubPriceOracle.sol |
| ./test/oracles/CovenantCurator.t.sol |
| ./test/oracles/adapters/AdapterHelper.sol |
| ./test/oracles/adapters/BaseAdapter.t.sol |
| ./test/oracles/adapters/BaseAdapterHarness.sol |
| ./test/oracles/adapters/CrossAdapter.t.sol |
| ./test/oracles/adapters/chainlink/ChainlinkOracle.unit.t.sol |
| ./test/oracles/adapters/chainlink/ChainlinkOracleHelper.sol |
| ./test/oracles/adapters/pyth/PythOracle.unit.t.sol |
| ./test/oracles/adapters/pyth/PythOracleHelper.sol |
| ./test/oracles/adapters/pyth/StubPyth.sol |
| ./test/oracles/utils/TestUtils.sol |
| ./test/utils/ArrayHelpers.sol |
| ./test/utils/AssetTypeHelpers.sol |
| ./test/utils/Cheats.sol |
| ./test/utils/TestMath.sol |
| ./test/utils/TestUtils.sol |
| Totals: 51 |


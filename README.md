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

## V12 findings

[V12](https://v12.zellic.io/) is [Zellic](https://zellic.io)'s in-house AI auditing tool. It is the only autonomous Solidity auditor that [reliably finds Highs and Criticals](https://www.zellic.io/blog/introducing-v12/). All issues found by V12 will be judged as out of scope and ineligible for awards.

V12 findings will be posted in this section within the first two days of the competition.  

## Publicly known issues

_Anything included in this section is considered a publicly known issue and is therefore ineligible for awards._

**Invariant precision:**
- The system is a credit DEX (where collateral, leverage and yield tokens can be swapped for each other). We care that there are no arbitrage opportunities (more value taken out than going in) under a circular set of trades upto a 10^20 precision. However, we are ok if value_out is bigger than value_in for smaller amounts (e.g, if 10^21 of a token goes in, then 10^21 + 1 can come out).

**Fees:**
- The protocol does not care from small miscalculations or underaccrual of fees (that go to the protocol vs that go to users). Specifically, there are design choices to accrue small amounts probabilistically that could be manipulated by validators, but we chose to accept this risk. Fees that accrue for users are in scope.
- There are some edge cases for the last user leaving a market where fees can be front-run. As documented in code, this risk is out scope.

**Governance:**
- Once a market is created, the only thing governance can do is pause/unpause the market. The risk that governance keys are compromised and markets are paused (and held hostage) is out of scope.
- The risk of governances keys being compromised and potential consequences of governance incorrect or fraudulent actions is out of scope. This includes incorrect actions by governance (e.g. creating a market with a non-working oracle, etc).

**Oracles:**
- Oracle mispricing is currently out of scope. The oracle contracts are a direct copy of those created for Euler, specifically for Chainlink (push) + Pyth (pull). The DEX effectively prices around the oracle price, and hence DEX actions can compensate (upto a point) for oracle mispricing or lags. However, we expect volatile assets (e.g., ETH, BTC, MON) to be priced through Pyth feeds (similar to a Perp DEX), whereas we are ok with more stable assets (e.g.,, USDC / USDT) being priced through Chainlink. In addition, if approved, ERC4262 prices will be used as a price source, and and mispricing by a Governance approved ERC4262 mispricing is out of scope.

**Market size:**
- We expect Covenant markets to be based on token assets with reasonable FDVs and total token mint amounts, with reasonable pricing from Oracles. We have built some protections for markets that are really big - e.g., where the FDV is bigger than 2^256 when measured in quote token decimal units. Or when markets become big over time. Specifically, we are using saturating multiplications at times which allow markets not to lock - but change market functionality in the following ways: 1) yield tokens might not accrued more yield after a point (>1000 years for most valid markets) 2) it will not be possible to mint new leverage tokens or yield tokens because their amount is over 2^256, etc. In these situations, we want users to be able to unwind their positions (and stop using that market instance) - but acknowledge that pricing might be off and interest might not be accruing in some edge cases.

**Market Parameters:**
- Market parameters are tested with limits upon creation, and only markets within these limits are in scope.

**In code comments**
- There might be additional design choices commented in code that would render these design choices as out of scope.

**Admin risks:**
- Admin risks (if admin is taken over, or if admin misconfigures oracles / latentswap limits, etc) is out of scope.

✅ SCOUTS: Please format the response above 👆 so its not a wall of text and its readable.

# Overview

[TBD]

## Links

- **Previous audits:**  https://github.com/pashov/audits/blob/master/team/pdf/Covenant-security-review_2025-08-18.pdf
- **Documentation:** https://docs.covenant.finance
- **Website:** https://covenant.finance/
- **X/Twitter:** https://x.com/covenantFi

---

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

# Additional context

## Areas of concern (where to focus for bugs)

**LatentSwap**
- Is the LatentSwap invariant upheld at all times for atomic transactions?
- Can anyone mint / redeem / swap more tokens than allowed to (and extract value from the system, upto a 10^-20 precision)?
- Can one user bring in a large amount of base assets (upto allowed limits), and through a series of mint / swap / redeem actions extract value from the system (upto a 10^-20 precision)?

**Covenant** 
- Does the Covenant contract keep base assets between markets siloed and independent of each other (ie, one market cannot take out base assets from another)?
- Can a malformed ERC20 or oracle external contract re-enter the market to extract value?

**General**
- Can a Covenant market be bricked (in situations where the collateral FDV is in an appropriate range)?

✅ SCOUTS: Please format the response above 👆 so its not a wall of text and its readable.

## Main invariants

1. LatentSwap Invariant - sets the relationship between the notional value of yield tokens, the value of leverage tokens, and the value of base assets. This is based on the following two formulas:
\left(\frac{L}{\sqrt{P_a}} - V_{yield}\right )\left(L\sqrt{P_b} - V_{leverage}\right)=L^2
L = V_c \frac{\sqrt{P_a P_b}}{\sqrt{P_b}-\sqrt{P_a}}

Where P_b, P_a are the min / max price of the market (price edges).  V_c is the collateral value, V_{yield} the yield coin notional value, and V_{leverage} the leverage coin value.  The formula above is very similar to a Uniswap V3 concentrated liquidity invariant between two prices p_a and p_b.

2. When initialized, markets are position at target LTV and have a price of 1.  In this instance, V_collateral = V_yield + V_leverage.  However, this equality is not an invariant, it is just a spot case of #1. What does hold however, is V_collateral <= V_yield + V_leverage. 

✅ SCOUTS: Please format the response above 👆 so its not a wall of text and its readable.

## All trusted roles in the protocol

Covenant Governance - can pause market, and add trusted LEX markets and curators (oracles)
Covenant Pause - Per market, an address can pause the market (and transfer this permission)
LEX Governance - can set some market parameters, including mint/redeem limits
Curator Governance - can add / modify / remove oracles. 

✅ SCOUTS: Please format the response above 👆 using the template below👇

| Role                                | Description                       |
| --------------------------------------- | ---------------------------- |
| Owner                          | Has superpowers                |
| Administrator                             | Can change fees                       |

✅ SCOUTS: Please format the response above 👆 so its not a wall of text and its readable.

## Running tests

The project is built with Forge.  

Forge build - builds project
Forge test - runs tests

✅ SCOUTS: Please format the response above 👆 using the template below👇

```bash
git clone https://github.com/code-423n4/2023-08-arbitrum
git submodule update --init --recursive
cd governance
foundryup
make install
make build
make sc-election-test
```
To run code coverage
```bash
make coverage
```

✅ SCOUTS: Add a screenshot of your terminal showing the test coverage

## Miscellaneous
Employees of Covenant Finance or Solana Development Foundation and employees' family members are ineligible to participate in this audit.

Code4rena's rules cannot be overridden by the contents of this README. In case of doubt, please check with C4 staff.

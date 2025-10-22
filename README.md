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

### Arbitrage Opportunities

The system behaves like a DEX (where collateral, leverage and yield tokens can be swapped for each other).

We care that there are no arbitrage opportunities (more value taken out than going in) under a circular set of trades upto a `10e20` precision. 

However, we are ok if `value_out` is bigger than `value_in` for smaller amounts (e.g, if `10e21` of a token goes in, then `10e21 + 1` can come out).

### Administrative Risks

Admin risks (if admin is taken over, or if admin misconfigures oracles / latentswap limits, etc) are out of scope. 

### Fee Handling

The protocol does not care for small miscalculations or underaccruals of fees (that are in favour of the protocol instead of the users). Specifically, there are design choices to accrue small amounts probabilistically that could be manipulated by validators, but we chose to accept this risk. Fees that accrue for users are in scope.

There are some edge cases for the last user leaving a market where fees can be front-run. As documented in code, this risk is out scope.

### Covenant + LatentSwap Governance

Once a market is created, the only thing governance can do is pause/unpause the market, and change mint/redeem caps. The risk that governance keys are compromised and markets are paused (and held hostage) is out of scope, or the risk that caps are removed.

The risk of governances keys being compromised and potential consequences of incorrect or fraudulent governance actions is out of scope. This includes invalid actions by governance (e.g. creating a market with a non-working oracle, etc).

### Curator (oracle) Governance

Covenant governance can approve a curator (oracle router) and subsequently this cannot be changed for a market.  However, Curator governance can change where the router points to, potentially affecting market behaviour.  The risk of curators misconfiguring a live market is out of scope.

### Oracle Misbehaviours

Oracle misbehaviour is currently out of scope. The oracle contracts are a direct copy of those created for Euler, specifically for Chainlink (push) + Pyth (pull). The DEX effectively prices around the oracle price, and hence DEX actions can compensate (up-to a point) for oracle mispricing or lags. However, we expect volatile assets (e.g., ETH, BTC, MON) to be priced through Pyth feeds (similar to a Perp DEX), whereas we are ok with more stable assets (e.g. USDC / USDT) being priced through Chainlink. In addition, if approved, ERC4262 prices will be used as a price source, and mispricing by a Governance approved ERC4262 is out of scope.

### Large Market Size

We expect Covenant markets to be based on token assets with reasonable FDVs and total token mint amounts, with reasonable pricing from Oracles. We have built some protections for markets that are really big - e.g., where the FDV is bigger than 2^256 when measured in quote token decimal units. Or when markets become big over time. Specifically, we are using saturating multiplications at times which allow markets not to lock - but change market functionality in the following ways: 1) yield tokens might not accrued more yield after a point (>1000 years for most valid markets) 2) it will not be possible to mint new leverage tokens or yield tokens because their amount is over 2^256, etc. In these situations, we want users to be able to unwind their positions (and stop using that market instance) - but acknowledge that pricing might be off and interest might not be accruing in some edge cases.

### Market Parameterization

Market parameters are tested with limits upon creation, and only markets within these limits are in scope.

### In-Code Comments

Any in-code comments supercede the functionality outlined in the project's documentation, and may reflect additional design choices that have not been explicitly outlined in this chapter and will be considered out of scope.

# Overview

Covenant enables markets for the use and funding of leverage against any collateral asset, using the collateral itself as liquidity. This facilitates the permissionless creation of structured products and unlocks a 10x increase in DeFi liquidity.

## Links

- **Previous audits:**  https://github.com/pashov/audits/blob/master/team/pdf/Covenant-security-review_2025-08-18.pdf
- **Documentation:** https://docs.covenant.finance
- **Website:** https://covenant.finance/
- **X/Twitter:** https://x.com/covenantFi

---

# Scope

### Files in scope

> Note: The nSLoC counts in the following table have been automatically generated and may differ depending on the definition of what a "significant" line of code represents. As such, they should be considered indicative rather than absolute representations of the lines involved in each contract.

| File   | nSLOC | 
| ------ | ----- | 
| [src/Covenant.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/Covenant.sol) | 274 |
| [src/curators/CovenantCurator.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/curators/CovenantCurator.sol) | 91 |
| [src/curators/lib/Errors.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/curators/lib/Errors.sol) | 12 |
| [src/curators/oracles/BaseAdapter.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/curators/oracles/BaseAdapter.sol) | 28 |
| [src/curators/oracles/CrossAdapter.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/curators/oracles/CrossAdapter.sol) | 64 |
| [src/curators/oracles/chainlink/ChainlinkOracle.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/curators/oracles/chainlink/ChainlinkOracle.sol) | 26 |
| [src/curators/oracles/pyth/PythOracle.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/curators/oracles/pyth/PythOracle.sol) | 63 |
| [src/lex/latentswap/LatentSwapLEX.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/LatentSwapLEX.sol) | 310 |
| [src/lex/latentswap/libraries/DebtMath.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/libraries/DebtMath.sol) | 36 |
| [src/lex/latentswap/libraries/FixedPoint.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/libraries/FixedPoint.sol) | 17 |
| [src/lex/latentswap/libraries/LSErrors.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/libraries/LSErrors.sol) | 23 |
| [src/lex/latentswap/libraries/LatentMath.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/libraries/LatentMath.sol) | 159 |
| [src/lex/latentswap/libraries/LatentSwapLogic.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/libraries/LatentSwapLogic.sol) | 656 |
| [src/lex/latentswap/libraries/SaturatingMath.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/libraries/LatentSwapLogic.sol) | 34 |
| [src/lex/latentswap/libraries/SqrtPriceMath.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/libraries/SqrtPriceMath.sol) | 79 |
| [src/lex/latentswap/libraries/TokenData.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/libraries/TokenData.sol) | 65 |
| [src/lex/latentswap/libraries/Uint512.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/libraries/Uint512.sol) | 66 |
| [src/libraries/Errors.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/libraries/Errors.sol) | 19 |
| [src/libraries/Events.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/libraries/Events.sol) | 50 |
| [src/libraries/MarketParams.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/libraries/MarketParams.sol) | 10 |
| [src/libraries/MultiCall.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/libraries/MultiCall.sol) | 8 |
| [src/libraries/NoDelegateCall.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/libraries/NoDelegateCall.sol) | 12 |
| [src/libraries/SafeMetadata.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/libraries/SafeMetadata.sol) | 47 |
| [src/libraries/Utils.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/libraries/Utils.sol) | 10 |
| [src/libraries/ValidationLogic.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/libraries/ValidationLogic.sol) | 74 |
| [src/synths/SynthToken.sol](https://github.com/code-423n4/2025-10-covenant/tree/main/src/synths/SynthToken.sol) | 48 |
| **Totals** | **2281** | 

*For a machine-readable version, see [scope.txt](https://github.com/code-423n4/2025-10-covenant/blob/main/scope.txt)*

### Files out of scope

| File         |
| ------------ |
| [script/\*\*.\*\*](https://github.com/code-423n4/2025-10-covenant/tree/main/script) |
| [src/curators/interfaces/\*\*.\*\*](https://github.com/code-423n4/2025-10-covenant/tree/main/src/curators/interfaces) |
| [src/interfaces/\*\*.\*\*](https://github.com/code-423n4/2025-10-covenant/tree/main/src/interfaces) |
| [src/lex/latentswap/interfaces/\*\*.\*\*](https://github.com/code-423n4/2025-10-covenant/tree/main/src/lex/latentswap/interfaces) |
| [src/periphery/\*\*.\*\*](https://github.com/code-423n4/2025-10-covenant/tree/main/src/periphery) |
| [test/\*\*.\*\*](https://github.com/code-423n4/2025-10-covenant/tree/main/test) |
| Totals: 51 |

*For a machine-readable version, see [out_of_scope.txt](https://github.com/code-423n4/2025-10-covenant/blob/main/out_of_scope.txt)*

# Additional context

## Areas of concern (where to focus for bugs)

### LatentSwap

- Is the LatentSwap invariant upheld at all times for atomic transactions?
- Can anyone mint / redeem / swap more tokens than allowed to (and extract value from the system, up-to a 10^-20 precision)?
- Can one user bring in a large amount of base assets (up-to allowed limits), and through a series of mint / swap / redeem actions extract value from the system (up-to a 10^-20 precision)?

### Covenant

- Does the Covenant contract keep base assets between markets siloed and independent of each other (i.e., one market cannot take out base assets from another)?
- Can a malformed ERC20 or oracle external contract re-enter the market to extract value?
- Can a Covenant market be bricked (in situations where the collateral FDV is in an appropriate range)?

## Main invariants

### LatentSwap Invariant

This invariant sets the relationship between the notional value of yield tokens, the value of leverage tokens, and the value of base assets. This is based on the following two formulas:

$$
\left(\frac{L}{\sqrt{P_a}} - V_{yield}\right )\left(L\sqrt{P_b} - V_{leverage}\right)=L^2
$$
where
$$
L = V_c \frac{\sqrt{P_a P_b}}{\sqrt{P_b}-\sqrt{P_a}}
$$

Where $P_b$, $P_a$ are the min / max price of the market (price edges). $V_c$ is the collateral value, $V_{yield}$ the yield coin notional value, and $V_{leverage}$ the leverage coin value.  The formula above is very similar to a Uniswap V3 concentrated liquidity invariant between two prices $p_a$ and $p_b$.

When initialized, markets are position at target LTV and have a price of 1.  In this instance, $V_{collateral} = V_{yield} + V_{leverage}$.  However, this equality is not an invariant, it is just a spot case of the previous equation. What does hold however, is that $V_{collateral} <= V_{yield} + V_{leverage}$. 


## All trusted roles in the protocol

| Role                                | Description                       |
| --------------------------------------- | ---------------------------- |
| Covenant Governance                          | Can pause markets, and add trusted LEX markets and curators (oracles)                |
| Covenant Pause                             | Per market, this address can pause the market (and transfer this permission)                       |
| LEX Governance                             | Can set some market parameters, including mint / redeem limits                       |
| Curator Governance                             | Can add / modify / remove oracles                       |

## Running tests

### Prerequisites

The codebase relies on the `foundry` toolkit, installing all relevant dependencies automatically through it. All instructions have been tested under the following configuration:

- forge (foundry): `1.3.5-stable`

### Compilation

The codebase can be compiled using the following command:

```bash
forge build
```

### PoC

A dedicated `C4PoC.t.sol` test file exists in the `test/poc` subfolder of the codebase with a single test suite that can be executed with the following command:

```bash
forge test --match-test submissionValidity -vvv
```

**For any submission to be accepted as valid by wardens who must provide a PoC, the test must execute successfully and must not mock any contract-initiated calls**.

## Miscellaneous

Employees of Covenant Finance and employees' family members are ineligible to participate in this audit.

Code4rena's rules cannot be overridden by the contents of this README. In case of doubt, please check with C4 staff.

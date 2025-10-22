_Note: Not all issues are guaranteed to be correct._

## High Severity Findings


### Denial-of-Service via int256.min Negation Overflow in accrueInterestLnRate

**Severity:** High  

**Affected Contract(s):**
- `DebtMath`

**Affected Function(s):**
- `accrueInterestLnRate()`

**Description:**

In the accrueInterestLnRate function of the DebtMath contract, the absolute value of a signed log rate (_lnRate) is computed by conditionally negating negative values (uint256((_lnRate >= 0) ? _lnRate : -_lnRate)). If _lnRate equals int256.min (-2^255), negating it triggers a Solidity 0.8 checked-arithmetic overflow and reverts the transaction. This edge case is not currently guarded against.

**Root Cause:**

The code uses unary negation on a signed int256 value without handling the special case of int256.min, which has no positive counterpart in the same bit width. When _lnRate is type(int256).min, -_lnRate overflows and reverts under Solidity 0.8+ checked arithmetic.

**Impact:**

An attacker or extreme market conditions could cause _lnRate to equal int256.min (e.g., via a specific lnRateBias combined with price inputs), forcing accrueInterestLnRate-and any public functions that call it (such as getAccruedDebt or previewPoolAccrual)-to revert. This results in a denial-of-service, halting interest accrual and potentially blocking critical protocol operations.

---


### Arithmetic Overflow Vulnerabilities in DebtMath

**Severity:** High  

**Affected Contract(s):**
- `DebtMath`

**Affected Function(s):**
- `accrueInterestLnRate()`
- `calculateLinearAccrual()`

**Description:**

DebtMath contains multiple arithmetic overflow issues that either silently cap values at uint256.max or revert unexpectedly, undermining debt accounting and service continuity.

**Root Cause:**

The contract relies on unchecked or saturating arithmetic without bounding inputs or handling overflows appropriately. Specifically, saturatingMulDiv masks overflows by clamping to uint256.max instead of reverting or validating the intermediate result, and a direct multiplication in calculateLinearAccrual is performed without overflow checks before invocation of saturatingMulDiv.

**Impact:**

1. Silent inflation of debt to the maximum uint256 value when update factors become large, breaking accounting invariants and potentially causing catastrophic economic loss.
2. Denial-of-service via revert when rate and time inputs overflow in linear accrual, blocking interest calculations and halting protocol operations.

---


## Low Severity Findings


### Incorrect 512-bit comparison leading to underflow and inflated liquidity in computeLiquidity

**Severity:** Low  

**Affected Contract(s):**
- `LatentMath`

**Affected Function(s):**
- `computeLiquidity()`

**Description:**

The computeLiquidity function in LatentMath attempts to compare two 512-bit values, b2X192 and qX192, using a flawed OR-based condition. This misclassification allows larger qX192 values to pass the check, leading to an underflow in a subsequent subtraction and an inflated square-root adjustment added to the liquidity result.

**Root Cause:**

A logical operator mistake in the lexicographical comparison: the code uses "(q_high == b_high || q_low < b_low) || q_high < b_high" instead of the correct "q_high < b_high || (q_high == b_high && q_low < b_low)". As a result, cases where q_high == b_high but q_low >= b_low still satisfy the flawed condition, triggering an unsafe subtraction.

**Impact:**

An attacker can craft inputs such that qX192 slightly exceeds b2X192 in the low word while matching in the high word. This causes Uint512.sub512x512 to underflow (silently wrapping in assembly), producing a huge erroneous difference fed into sqrt512. The resulting arbitrarily large root adjustment is added to betaX96, causing computeLiquidity to return a massively overstated liquidity value, undermining protocol invariants and enabling unauthorized over-minting or draining of liquidity.

---


### Unbounded Recursion in resolveOracle Due to Cyclic Vault Mappings

**Severity:** Low  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `resolveOracle()`

**Description:**

The resolveOracle function follows vault-to-asset mappings (resolvedVaults) recursively when no direct oracle is configured. Because the owner can configure these mappings without cycle checks, a cyclic mapping (e.g., vaultA->assetB and vaultB->assetA) leads to unbounded recursion. This recursion continues until the call runs out of gas, causing a denial-of-service in any function (such as getQuote) that relies on resolveOracle.

**Root Cause:**

The govSetResolvedVault setter allows the owner to introduce cycles in resolvedVaults (no self-reference or cycle detection) and resolveOracle has no recursion depth guard.

**Impact:**

An attacker (or malicious owner) can configure a cycle in resolvedVaults to trigger infinite recursion in resolveOracle, resulting in out-of-gas and denial-of-service for price quotes or other dependent functionality.

---


### Fee-on-transfer Token Overstates Collateral in mint()

**Severity:** Low  

**Affected Contract(s):**
- `Covenant`

**Affected Function(s):**
- `mint()`

**Description:**

The mint() function increments the market's recorded baseSupply by the full baseAmountIn (minus protocol fees) before executing safeTransferFrom. If the baseToken charges a fee on transfer, fewer tokens actually arrive, but baseSupply still reflects the full amount, causing Covenant to overstate on-chain collateral.

**Root Cause:**

State update uses the intended input amount (baseAmountIn) without verifying the actual token balance change after transfer, allowing discrepancy when tokens charge transfer fees.

**Impact:**

An attacker can register a fee-on-transfer token, call mint() supplying baseAmountIn, and exploit the inflated baseSupply to mint more aTokens/zTokens than justified by real collateral, leading to potential undercollateralization and protocol loss.

---


### Use of getPriceUnsafe Bypasses Pyth's Integrity Checks

**Severity:** Low  

**Affected Contract(s):**
- `PythOracle (via EulerPythOracle)`

**Affected Function(s):**
- `_previewFetchPriceStruct()`

**Description:**

PythOracle's _previewFetchPriceStruct relies on IPyth.getPriceUnsafe to fetch raw price data, then only applies minimal sanity checks (timestamp staleness bounds, positive price, confidence window and exponent limits). getPriceUnsafe bypasses Pyth's built-in signature verification, fee enforcement, and more comprehensive staleness checks, meaning a malicious or compromised Pyth contract (or manipulated feed data) can return crafted prices that pass the lightweight checks and misreport asset values.

**Root Cause:**

Using getPriceUnsafe-which skips Pyth's native safety and signature checks-instead of the safe getPrice interface, coupled with only basic manual sanity checks.

**Impact:**

An attacker controlling the Pyth contract or its price feed can feed arbitrary manipulated prices into the oracle. Downstream consumers relying on this oracle may make incorrect valuations, leading to mispriced trades, solvency issues, or loss of funds.

---


## QA Severity Findings


### Underflow in Debt Price Discount Calculation

**Severity:** QA  

**Affected Contract(s):**
- `LatentMath`

**Affected Function(s):**
- `get_XvsL()`

**Description:**

In the DEBT branch of get_XvsL, the code computes an unsigned difference

    ratioX96 = term1 + term2 - term3;

without ensuring term1 + term2 >= term3. If term3 exceeds the sum of term1 and term2, the subtraction underflows and reverts.

**Root Cause:**

Missing bounds check before subtracting term3 in unsigned arithmetic, allowing underflow.

**Impact:**

A carefully chosen current or edge price can trigger the underflow, causing a revert and potentially leading to denial of service or unexpected failures in debt pricing and downstream logic.

---


### Small-Market Mint Cap Bypass Due to Logical Conjunction Error

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `_checkMintCap()`

**Description:**

In the small-market branch of _checkMintCap, the function is intended to enforce a supply cap by reverting when mintAmount exceeds either a fixed large threshold (Q96) or the current marketBaseTokenSupply. However, it erroneously uses a logical AND (&&) between the two conditions. Because FixedPoint.Q96 (~=7.9x10^28) vastly exceeds any realistic pool supply, the first condition (mintAmount > Q96) never triggers. Consequently, any mintAmount up to Q96 always bypasses the cap check, allowing attackers to mint arbitrarily large quantities in "small" markets.

**Root Cause:**

The cap enforcement in the small-market branch incorrectly combines two independent limit checks with a logical AND instead of OR. This means both conditions must be true to revert, but the excessively high Q96 threshold prevents the first condition from ever evaluating true in practice.

**Impact:**

An attacker can mint up to Q96 tokens in a single transaction when marketBaseTokenSupply <= 1<<noCapLimit. This allows creation of fictitious liquidity, enabling price manipulation, unfair arbitrage, and potential draining of on-chain pools, severely compromising token economics and protocol integrity.

---


### Off-by-One Overflow Guard Bypass in _checkMintCap

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `_checkMintCap()`

**Description:**

The function uses a strict '<' comparison when verifying eTWAPBaseTokenSupply < (type(uint256).max >> MAX_MINT_FACTOR_CAP). When eTWAPBaseTokenSupply equals the threshold (type(uint256).max >> 1) with MAX_MINT_FACTOR_CAP=1, this guard evaluates false and skips the factor-based cap check-even though shifting by 1 at that boundary does not overflow. As a result, a mintAmount that exceeds the intended cap can proceed without triggering a revert.

**Root Cause:**

An off-by-one error: using '<' instead of '<=' for the overflow-prevention guard excludes the exact boundary case where no overflow would occur, thereby bypassing the factor-cap enforcement.

**Impact:**

An attacker can exploit this edge case to mint more tokens than permitted by the factor-based cap, inflating supply beyond intended limits and potentially destabilizing or devaluing the market.

---


### Missing Input Validation in Constructors Leads to Misconfiguration, DoS, and Mispricing

**Severity:** QA  

**Affected Contract(s):**
- `SynthToken`
- `ChainlinkOracle`
- `CrossAdapter`
- `PythOracle`

**Affected Function(s):**
- `constructor()`

**Description:**

Multiple contracts across the protocol-including SynthToken, ChainlinkOracle, CrossAdapter, and PythOracle-accept critical addresses or numeric parameters in their constructors without enforcing non-zero or sensible value constraints. This omission allows deployers or attackers to supply zero or invalid addresses and inappropriate numeric values, resulting in misconfiguration, bricked functionality, and denial-of-service in core operations.

**Root Cause:**

Constructors in these contracts lack `require` statements or equivalent input-validation logic to ensure that provided address parameters are non-zero (and, where applicable, distinct) and that numeric parameters (e.g., `maxStaleness`, `maxConfWidth`) exceed zero and lie within sensible bounds.

**Impact:**

Depending on the contract and parameter misconfiguration, the following issues can arise:
- Permanent DoS of minting/burning in SynthToken when `_lexCore` (or `_covenantCore`) is set to address(0).
- Bricked oracle adapters (CrossAdapter) due to calls to zero-address oracles, disabling all price quote and fee update functions.
- Deployment of misconfigured ChainlinkOracle or PythOracle instances that cannot fetch price data (zero feed address), revert on stale-check logic (`maxStaleness == 0`), or produce invalid/stale quotes, leading to downstream financial loss.
- Misrouting or silent failure of price queries and updates, undermining dependent protocols' stability.

---


### Denial of Service via Unchecked Zero LexCore

**Severity:** QA  

**Affected Contract(s):**
- `SynthToken`

**Affected Function(s):**
- `constructor()`

**Description:**

The constructor allows `_lexCore` to be initialized to the zero address without validation. Because the onlyLexCore modifier reverts unless the caller matches `_lexCore`, setting it to zero makes both `lexMint` and `lexBurn` permanently unusable, resulting in a denialofservice for synth token supply management.

**Root Cause:**

Missing a check in the constructor to ensure `lexCore_` is not the zero address, causing `_lexCore` to be immutable zero if passed as such.

**Impact:**

Permanent inability to mint or burn tokens. SynthToken supply cannot be managed, breaking any functionality that relies on creating or redeeming the synthetic asset.

---


### Missing Base Asset Initialization in SynthToken Constructor Leads to Unbacked Operations

**Severity:** QA  

**Affected Contract(s):**
- `SynthToken`

**Affected Function(s):**
- `constructor()`

**Description:**

The SynthToken contract's constructor accepts a `baseAsset_` parameter but never declares or assigns it to any state variable. As a result, the synth's base asset reference remains unset (defaulting to the zero address), violating the intended invariant that the contract tracks its underlying collateral token. Any downstream logic or external integrations that rely on a valid base asset-such as collateral checks during minting or asset transfers during redemption-will operate against the zero address, leading to broken functionality or financial loss.

**Root Cause:**

The constructor signature includes a `baseAsset_` parameter, but there is no corresponding state variable declaration or assignment in the contract. Consequently, the provided parameter is silently discarded and never initialized.

**Impact:**

Attackers or misconfigured deployers can mint synth tokens without depositing any collateral or redeem tokens against a zero address. This enables unbacked minting and redemption, potentially creating unlimited synthetic assets out of thin air, misrouting assets, or locking funds in downstream processes.

---


### Missing Input Validation in CrossAdapter Constructor Leads to Misconfiguration, DoS, and Mispricing

**Severity:** QA  

**Affected Contract(s):**
- `CrossAdapter`

**Affected Function(s):**
- `constructor()`

**Description:**

The CrossAdapter contract's constructor accepts five critical addresses (_base, _cross, _quote, _oracleBaseCross, _oracleCrossQuote) without performing any non-zero or uniqueness checks. This allows a deployer or attacker to supply zero addresses, duplicate roles, or otherwise invalid configurations, which breaks the adapter's core price-quoting and fee-update functionality.

**Root Cause:**

Absence of inputvalidation logic (no require statements) in the constructor to enforce that all provided addresses are non-zero and pairwise distinct.

**Impact:**

If the constructor is called with zero or duplicated addresses, any of the adapter's core functions (_getQuote, _previewGetQuote, _updatePriceFeeds, _getUpdateFee) may revert or return misleading data. This can lead to: 1) Permanent denial-of-service of price queries and feed updates; 2) Incorrect price outputs (e.g., 1:1 rates when tokens are identical); 3) Misrouted ETH payments to unintended or zero addresses; and 4) Downstream financial loss or exploitable mispricing in dependent protocols.

---


### Unbounded Recursive Vault Resolution Leading to Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `resolveOracle()`
- `govSetResolvedVault & resolveOracle()`

**Description:**

The CovenantCurator contract's resolveOracle function recursively follows owner-controlled resolvedVaults mappings to locate the underlying asset's price oracle. Because govSetResolvedVault allows arbitrary vault->asset links without preventing cycles-and resolveOracle lacks any cycle detection or maximum recursion depth-a malicious or misconfigured governance action can introduce a cycle in resolvedVaults (e.g., Vault A->Vault B and Vault B->Vault A). Any resolveOracle call on a vault in the cycle will then recurse indefinitely until the call stack or gas is exhausted, causing a denial-of-service for all price resolution and dependent functions.

**Root Cause:**

The govSetResolvedVault setter populates the resolvedVaults mapping without validating that the new vault->asset relationship is acyclic, and resolveOracle blindly traverses this mapping recursively without tracking visited nodes or imposing a recursion depth limit.

**Impact:**

An attacker or compromised governance key can halt all price lookups and feed updates by creating a simple cycle in vault mappings. Calls to getQuote, previewGetQuote, updatePriceFeeds, getUpdateFee, and any other functionality relying on resolveOracle will exhaust gas or overflow the call stack, reverting every transaction and effectively disabling critical protocol operations.

---


### Unbounded Recursive Vault Resolution (resolveOracle) Causing Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `resolveOracle()`

**Description:**

The CovenantCurator contract's resolveOracle function follows owner-controlled vault->asset mappings in resolvedVaults recursively to locate the appropriate price oracle. Because the governance setter (govSetResolvedVault) allows arbitrary mappings-including self-references or mutual cycles-without any validation, and resolveOracle lacks cycle detection or a recursion depth limit, a cyclic mapping (e.g., Vault A->Vault B and Vault B->Vault A) causes resolveOracle to recurse infinitely until gas or call stack is exhausted.

**Root Cause:**

govSetResolvedVault populates resolvedVaults[vault] with IERC4626(vault).asset() without checking for existing dependencies, self-references, or cycles. resolveOracle blindly recurses on resolvedVaults entries without tracking visited nodes or imposing a maximum depth, so any cycle in the mapping leads to unbounded recursion.

**Impact:**

A malicious or compromised governance key can introduce a simple cycle in resolvedVaults, triggering infinite recursion in resolveOracle. Any operation that relies on price resolution-getQuote, previewGetQuote(s), updatePriceFeeds, getUpdateFee, and other dependent functionality-will consume all gas or overflow the call stack, reverting the transaction and effectively disabling critical protocol operations (denial-of-service).

---


### Unbounded Recursive Vault Resolution Leading to Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `resolveOracle()`

**Description:**

The CovenantCurator contract's resolveOracle function recursively follows owner-configured resolvedVaults mappings to locate price oracles for tokens. Since govSetResolvedVault allows arbitrary vault->asset links without preventing self-references or cycles-and resolveOracle lacks any cycle detection or recursion-depth guard-a cyclic mapping (e.g., Vault A->Vault B and Vault B->Vault A) will cause unbounded recursion until gas or stack limits are exhausted.

**Root Cause:**

govSetResolvedVault populates resolvedVaults without validating that new vault->asset relationships are acyclic, and resolveOracle blindly recurses through these mappings without tracking visited nodes or enforcing a depth limit.

**Impact:**

A malicious or compromised governance key can introduce a simple cycle in resolvedVaults to trigger infinite recursion in resolveOracle. Any operation that relies on price resolution-getQuote, previewGetQuote, updatePriceFeeds, getUpdateFee, and other dependent functions-will exhaust gas or overflow the call stack, revert every transaction, and effectively disable critical protocol operations.

---


### Owner-Controlled Oracle Configuration Without Validation or Delay

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `govSetConfig()`
- `govSetFallbackOracle()`
- `govSetConfig / govSetFallbackOracle()`

**Description:**

The CovenantCurator contract allows its owner to configure both direct oracles (via govSetConfig) and the fallbackOracle (via govSetFallbackOracle) instantly and without any safeguards. There is no timelock, no interface or code-existence check, no non-zeroaddress requirement, and no multisignature or governance steps. As a result, the owner (or a compromised key) can swap in arbitrary oracles or zero addresses and immediately affect every price lookup and feed update call.

**Root Cause:**

Both govSetConfig and govSetFallbackOracle are only protected by onlyOwner and apply changes instantly without validating the supplied address. There is no check that the new oracle implements IPriceOracle (no supportsInterface or extcodesize), no require(_oracle != address(0)), and no delay or multisig mechanism.

**Impact:**

A malicious or compromised owner can:
- Atomically replace a legitimate oracle with a manipulated feed, perform trades or liquidations at skewed prices, then restore the original oracle before anyone can react, siphoning value.
- Set the fallbackOracle to a rogue contract or the zero address to return arbitrary prices or revert on every lookup, causing widespread price manipulation or denial-of-service across getQuote, previewGetQuote, updatePriceFeeds, getUpdateFee, and any other functionality dependent on price oracles.

---


### Unchecked or Self-Referential Oracle Configuration in CrossAdapter Leading to Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `CrossAdapter`

**Affected Function(s):**
- `_previewGetQuote()`
- `_getQuote()`

**Description:**

The CrossAdapter contract's internal price-quoting functions (_previewGetQuote and _getQuote) delegate to two owner-configurable oracle addresses (oracleBaseCross and oracleCrossQuote) without any validation or error handling. If either oracle address is set to the adapter's own address, calls recurse indefinitely via IPriceOracle(address(this)).previewGetQuote, exhausting gas and reverting. Similarly, if an oracle address points to a contract that reverts-either through misconfiguration, gas exhaustion, or malicious behavior-those reverts bubble up unhandled, causing every quote request to revert.

**Root Cause:**

The CrossAdapter setters for oracleBaseCross and oracleCrossQuote lack validation to ensure the provided addresses are genuine external oracle contracts distinct from the adapter itself. Both _getQuote and _previewGetQuote perform unchecked external calls without try/catch or depth guards, allowing self-calls or revert propagation to cause unbounded recursion or immediate reversion.

**Impact:**

A malicious or misconfigured owner (or privileged actor) can lock users out of all price-quoting functionality by (1) pointing one of the oracle addresses to the adapter itself-triggering infinite recursion until gas is exhausted-or (2) pointing to an oracle that always reverts, causing every quote call to revert. This denial-of-service can break any downstream feature relying on CrossAdapter's price quotes, halting swaps, routing, or trading strategies.

---


### Unguarded External Vault.asset() Call in govSetResolvedVault Leading to Admin Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `govSetResolvedVault()`

**Description:**

The CovenantCurator contract's govSetResolvedVault function performs an unchecked call to IERC4626(vault).asset() when associating a vault with its underlying asset. Because this external call is neither wrapped in a try/catch nor performed via a low-level staticcall with error handling, any revert or malfunction in the target vault's asset() implementation will bubble up and revert the entire governance transaction.

**Root Cause:**

govSetResolvedVault blindly invokes IERC4626(vault).asset() without validating the vault contract's behavior or catching errors. There is no require(_vault != address(0)), no interface or code-existence check, and no error handling to prevent a revert in asset() from blocking state updates.

**Impact:**

A malicious or buggy vault contract can permanently prevent the owner or governance from registering or updating that vault mapping. This results in an owner-only denial-of-service on any functionality that relies on the resolvedVaults mapping for that vault, effectively freezing price resolution for the affected asset pair.

---


### Improper Owner-Controlled LEX Module Toggling Enables Centralization, Exploits, and Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`

**Affected Function(s):**
- `setEnabledLEX()`

**Description:**

The Covenant contract's setEnabledLEX function allows the owner to enable or disable any ILiquidExchangeModel (LEX) implementation instantly, without any timelock, multisignature governance, or input validation (non-zero address and contract code checks). Downstream, createMarket trusts the isLexEnabled flag and delegatecalls initMarket on the enabled LEX address. Because the setter is only protected by onlyOwner, a malicious or compromised owner key can whitelist a backdoored or invalid address (including address(0) or an EOA).

**Root Cause:**

Critical module toggling is protected only by onlyOwner (and noDelegateCall) and lacks any delay, multisig, or governance constraints. setEnabledLEX does not require the LEX address to be non-zero or point to a contract, and ValidationLogic.checkMarketParams only verifies the isLexEnabled flag without further validation.

**Impact:**

1. Centralization & Theft: An attacker with the owner key can whitelist a malicious LEX module, then create markets under its control to siphon funds or manipulate prices arbitrarily.   2. Denial-of-Service: Whitelisting address(0) or an EOA causes createMarket to delegatecall into non-existent code, revert on initMarket, and block all future market creations. 3. Protocol Disruption: These exploits can freeze new market launches, destabilize existing liquidity, and undermine user trust in protocol safety and governance.

---


### Owner-Controlled Oracle Configuration Without Validation Enables Fund Drain and Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `updatePriceFeeds()`
- `govSetConfig()`
- `govSetFallbackOracle()`

**Description:**

Several functions in CovenantCurator allow the owner to specify oracle addresses or forward ETH to oracles without any input validation or error handling. govSetConfig and govSetFallbackOracle accept zero addresses, non-contract addresses, or malicious contracts with no interface or code checks. updatePriceFeeds blindly forwards the caller's entire msg.value to whatever oracle the owner configured. resolveOracle and updatePriceFeeds for unsupported pairs then unconditionally call fallbackOracle, even if it's invalid. These combined issues let a malicious or misconfigured owner (or compromised governance key) and/or a rogue oracle contract to steal ETH, revert pricefeed operations, or execute arbitrary code.

**Root Cause:**

All owner-controlled oracle setter functions (govSetConfig, govSetFallbackOracle) and ETH-forwarding/update logic (updatePriceFeeds, resolveOracle fallback path) lack:
- non-zero address checks
- contract existence or interface compliance checks
- caps or refund logic for forwarded ETH
- try/catch or fallback handling for external calls
Additionally, updatePriceFeeds and resolveOracle do not validate whether a requested asset pair is supported before making external calls.

**Impact:**

An attacker or compromised owner can:
1. Point oracles to malicious contracts that consume or steal all ETH sent via updatePriceFeeds, with no refund path.
2. Set direct or fallback oracles to zero or non-contract addresses, causing all price lookup functions (getQuote, previewGetQuote, getUpdateFee, updatePriceFeeds) to revert and effectively freeze protocol operations.
3. Exploit unsupported asset pairs to trigger arbitrary external calls through fallbackOracle, enabling reentrancy or execution of malicious code in critical functions.
These combined vulnerabilities can lead to user fund loss, full denial-of-service of price feed and dependent functionality, and potential protocol compromise.

---


### Missing Pause Authority Validation Enables Permanent Pause-Functionality Denial

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`

**Affected Function(s):**
- `setMarketPauseAddress()`
- `setDefaultPauseAddress()`

**Description:**

Both setMarketPauseAddress and setDefaultPauseAddress in the Covenant contract allow the owner or current pause authority to assign the zero address as the market's pause controller without any input validation. Since pause and unpause operations strictly require msg.sender to equal the authorized pause address, setting it to address(0) irrevocably blocks anyone from invoking emergency pause or resume for all existing or newly created markets.

**Root Cause:**

The setter functions (setMarketPauseAddress and setDefaultPauseAddress) do not include any require(newPauseAddress != address(0)) checks or governance safeguards. Authorization logic only verifies the caller's identity, but not the validity of the new pause address, allowing misconfiguration or malicious actors to zero out this critical address.

**Impact:**

An attacker, compromised pause authority, or even the contract owner can permanently disable the emergency pause mechanism. Markets will become unpausable and unresumable, removing a vital safety switch to halt trading during attacks or anomalies, and exposing users to unmitigable risk.

---


### Unprotected External Oracle Calls in LatentSwapLEX and LatentSwapLogic Leading to Reentrancy and Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLEX`
- `LatentSwapLogic`

**Affected Function(s):**
- `mint()`
- `_updateOraclePrice()`
- `_calculateMarketState (via _readBasePriceAndCalculateLiqRatio)()`
- `_readBasePriceAndCalculateLiqRatio()`

**Description:**

Several internal functions in LatentSwapLEX and LatentSwapLogic perform unchecked external calls to owner-configured oracle contracts (e.g., marketParams.curator) without reentrancy guards, error handling, or boundary smoothing. These calls occur during mint (via _updateOraclePrice), swap, redeem, and market-state calculations, and they: 1) allow a malicious oracle to reenter the contract and manipulate state before critical updates complete; 2) bubble up any revert from the oracle to block all parent operations; and 3) unconditionally revert on out-of-range values (e.g., low liquidity ratio), freezing the market.

**Root Cause:**

The contracts rely on direct external calls to untrusted oracle implementations without: * Reentrancy protection (no mutex or nonReentrant) around calls in LatentSwapLEX.mint and related functions, * Try/catch or fallback logic to catch or recover from oracle revert or out-of-gas, * Input validation or smoothing for oracle-returned values (e.g., liquidity ratio threshold).

**Impact:**

An attacker controlling or configuring a malicious oracle can: 1) Reenter mint or other public functions during updatePriceFeeds to perform unauthorized mints or corrupt internal state, draining funds. 2) Trigger a revert in the oracle (via an always-reverting or OOG implementation), causing all core market operations (mint, swap, redeem, updateState) to revert and freeze the market. 3) Return artificially low liquidity ratios to force unconditional reverts in market-state calculations, denying service to all users until the oracle is corrected.

---


### Reentrancy in createMarket Allows State Corruption and Duplicate Markets

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`

**Affected Function(s):**
- `createMarket()`

**Description:**

The Covenant contract's createMarket function invokes an external LEX implementation's initMarket before writing its own storage mappings (idToMarketParams and marketState). Because this external call occurs without any reentrancy guard, a malicious or compromised LEX contract can re-enter createMarket while Covenant's state is still uninitialized for the current marketId.

**Root Cause:**

createMarket performs an unchecked external call to ILiquidExchangeModel.initMarket prior to updating critical internal state, and it lacks any nonReentrant or equivalent mutex to prevent nested calls.

**Impact:**

An attacker controlling a whitelisted LEX module can re-enter createMarket during initMarket and bypass ValidationLogic checks (which still see zeroed state), creating duplicate or conflicting market entries under the same marketId. This state corruption can lead to inconsistent market parameters, loss of user funds, or denial-of-service for legitimate market creation and trading.

---


### Uncapped Minting via Immutable lexMint Authority in SynthToken

**Severity:** QA  

**Affected Contract(s):**
- `SynthToken`

**Affected Function(s):**
- `lexMint()`

**Description:**

The SynthToken contract's lexMint function grants its immutable lexCore address unrestricted authority to mint new tokens via ERC20._mint without any on-chain caps, supply limits, or higher-level governance controls. Because lexCore is hardcoded and cannot be updated after deployment, any compromise or bug in the lexCore contract allows arbitrary token inflation.

**Root Cause:**

lexMint is protected only by an immutable onlyLexCore modifier and lacks any total-supply cap, per-call mint limit, rate limit, or secondary governance checks. SynthToken does not maintain a maximum-supply state variable, and lexMint directly delegates to ERC20._mint without validating that totalSupply + amount <= some hard cap.

**Impact:**

An attacker controlling or exploiting lexCore can mint unlimited SynthTokens to arbitrary addresses. This unrestricted inflation can collapse token value, break economic invariants, enable theft of user funds, and undermine protocol stability.

---


### Unbounded Owner-Controlled No-Cap Limit Configuration in LatentSwapLEX

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLEX`

**Affected Function(s):**
- `setDefaultNoCapLimit()`
- `setMarketNoCapLimit()`

**Description:**

The LatentSwapLEX contract exposes two owner-only setters-setDefaultNoCapLimit (global default) and setMarketNoCapLimit (per-market override)-that accept any uint8 value without enforcing the semantic bounds applied during market initialization (1 <= noCapLimit <= 60). By assigning extreme values (0 or 255), the owner can either block all minting/redeeming or effectively remove risk caps, undermining rate-limiting and solvency controls.

**Root Cause:**

Both setters rely solely on the raw uint8 range and omit the tighter business-logic validations enforced at market creation. There are no require statements or upper/lower bounds checks in setDefaultNoCapLimit or setMarketNoCapLimit to ensure the new noCapLimit falls within the intended [1,60] range.

**Impact:**

A malicious or compromised owner can:
1. Disable issuance and redemption by setting noCapLimit to 0, causing all mint and redeem calls to revert due to zero cap.
2. Bypass all per-transaction caps by setting noCapLimit to 255 (i.e., 2^255), allowing arbitrarily large single-market mints or redeems that can drain or inflate markets.
Either misconfiguration can destabilize markets, trigger insolvency or liquidity crises, and result in a denial-of-service for legitimate users.

---


### Missing Input Validation in Admin-Controlled Configuration Functions

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`
- `SpotMarketFactory`
- `LatentSwapLEX`

**Affected Function(s):**
- `setMarketProtocolFee()`
- `createSpotMarket()`
- `setQuoteTokenSymbolOverrideForNewMarkets()`

**Description:**

Several admin- or owner-controlled setter functions across Covenant and its modules accept critical parameters without validating their correctness (e.g., matching stored state, non-zero addresses, distinct token addresses). This lack of input validation enables misconfiguration, unauthorized operations, and denial-of-service or data corruption in downstream components.

**Root Cause:**

Each affected function trusts caller-supplied values without enforcing basic sanity checks (such as require(address != address(0)), matching expected contract addresses, or validating parameter distinctness). There is no centralized validation logic or reuse of ValidationLogic for these cases.

**Impact:**

* An attacker or mistaken admin can supply an arbitrary LEX address to `setMarketProtocolFee`, causing the protocol to read and set fees on an unintended or malicious contract, corrupting fee accounting.  
* A misconfigured curator can call `createSpotMarket` with zero or duplicate token addresses, creating markets that revert on all operations or enable downstream exploits by components assuming valid tokens.  
* The owner can override the symbol for the zero address in `setQuoteTokenSymbolOverrideForNewMarkets`, leading to misleading market listings, broken price feeds, and confusion in UI or analytics tools.

---


### Unchecked and Unbounded ABI Decoding in SafeMetadata Leading to Panic and Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `SafeMetadata`
- `TokenData`

**Affected Function(s):**
- `_tryStringOrBytes32()`
- `_assetSymbol()`

**Description:**

SafeMetadata's internal helper _tryStringOrBytes32 decodes external token metadata (name, symbol) using simplistic length-based branching and direct abi.decode calls without validation or error handling. This approach assumes that any returned data of length >=64 is properly ABI-encoded, but does not verify the declared string length against the actual payload size, or wrap the decode in try/catch. Attackers can exploit this to craft malformed responses that trigger out-of-bounds memory accesses, panic exceptions, or excessive memory allocation, causing any metadata lookup to revert.

**Root Cause:**

Reliance on data.length thresholds to choose decoding paths and unconditional abi.decode on untrusted return data, without bounds checks on the decoded length field or try/catch guards for decode failures or dynamic-type panics.

**Impact:**

A malicious or buggy token contract can force all calls to SafeMetadata's metadata functions (tryGetName, tryGetSymbol, and any downstream consumers) to revert by returning malformed or oversized payloads. This results in a denial-of-service for any protocol functionality or user interface relying on token metadata.

---


### Inconsistent ERC-4626 Vault Token Handling in CovenantCurator Price Functions

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `previewGetQuote()`
- `getQuote()`
- `getQuote / previewGetQuote()`
- `resolveOracle()`

**Description:**

CovenantCurator's price-quoting and fee-estimation functions correctly detect and unwrap ERC-4626 vault tokens when they appear as the base asset, but fail to apply the reverse conversion (underlying assets -> vault shares) when the quote asset is an ERC-4626 vault. This inconsistency affects functions including previewGetQuote, getQuote, getQuotes, and getUpdateFee, causing callers to receive amounts denominated in underlying assets instead of vault shares for the quote side.

**Root Cause:**

The resolveOracle implementation and related wrappers only check `resolvedVaults[base]` and call `IERC4626(base).convertToAssets(...)`. They do not detect or convert for `quote` vault tokens-no `convertToShares` step is performed on the returned quote amount before returning or passing it to downstream oracles.

**Impact:**

Any consumer quoting prices or fees involving an ERC-4626 vault as the quote token will receive values in underlying asset units rather than vault share units. This unit mismatch can lead to severe mispricing, failed trades, over- or under-collateralization, incorrect fee estimates, and potential financial loss or arbitrage opportunities when integrating with vault-based markets.

---


### Unhandled External Oracle and Vault Calls in CovenantCurator Causing Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `resolveOracle()`
- `getUpdateFee()`

**Description:**

CovenantCurator's core price-and-fee functions (resolveOracle, getQuote, getUpdateFee) perform external calls to ERC-4626 vaults (convertToAssets) and to IPriceOracle implementations without any error handling or input validation. Because these calls assume the external contracts will always succeed, a malicious or buggy vault or oracle can revert or consume excessive gas, causing every dependent view or pure function in CovenantCurator to revert and preventing any price or fee queries for the affected asset pair.

**Root Cause:**

The contract makes unchecked external calls to untrusted contracts (vaults and price oracles) without try/catch wrappers, keccak-gas restrictions, or sanity checks on the returned values. Additionally, resolveOracle only unwraps the base vault token, leaving other vault-based arguments unvalidated.

**Impact:**

A malicious vault's convertToAssets or a misbehaving oracle's getQuote/getUpdateFee implementation can deliberately revert, triggering a cascading denial-of-service across all CovenantCurator price and fee lookup methods. This disrupts downstream contracts, front-end UIs, and automated strategies relying on these price feeds, effectively rendering the protocol unable to fetch or display token prices and update fees.

---


### Silent and Unbounded Decimal Fallbacks in TokenData Causing Mis-scaling

**Severity:** QA  

**Affected Contract(s):**
- `TokenData`

**Affected Function(s):**
- `_assetDecimals()`
- `assetDecimals()`

**Description:**

The TokenData contract's decimal lookup logic (_assetDecimals and assetDecimals) relies on unvalidated fallback behaviors rather than explicit error handling or input checks. When retrieving an ERC-20 token's decimals via SafeMetadata.tryGetDecimals or from stored state, the code:  
 1) Silently defaults to 18 decimals on failure or missing data,  
 2) Returns zero decimals if an external call succeeds but returns 0, and  
 3) Accepts any uint8 from the token (including values >18) without enforcing expected precision bounds.  
These fallback paths apply regardless of whether the token address is non-contract, zero, or malicious.

**Root Cause:**

The functions assetDecimals and _assetDecimals lack input validation, bounds checks, or error signaling. They unconditionally use 'success ? decimals : 18' for failures, do not verify non-zero or <=18 values after a successful call, and do not check that the asset address is a valid ERC-20 contract.

**Impact:**

Downstream consumers (pricing, normalization, accounting, collateral calculations) may treat token amounts with incorrect precision-overestimating balances by up to 1012x for 6-decimal tokens, using zero decimals, or handling >18 decimals unexpectedly. This can lead to mispricing, accounting errors, financial discrepancies, failed transactions, and exploitable economic arbitrage.

---


### Unchecked and Inconsistent Oracle Resolution in CovenantCurator getUpdateFee

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `getUpdateFee()`

**Description:**

The CovenantCurator getUpdateFee function determines which price oracle to query by calling resolveOracle, then forwards the base and quote tokens (or their unwrapped forms) to the oracle's getUpdateFee. However, three related issues in this logic undermine its reliability and correctness: 1) when no dedicated oracle is registered and fallbackOracle is unset, resolveOracle reverts rather than returning a default fee; 2) resolveOracle only unwraps ERC-4626 vault tokens for the base asset, not the quote, so fee calls may receive a vault address instead of the underlying asset; and 3) unwrapping the base vault may cause base and quote to become identical before the base==quote check in getUpdateFee, allowing callers to bypass fees.

These flaws collectively enable unexpected reverts or fee bypasses depending on the input asset pair.

**Root Cause:**

resolveOracle and getUpdateFee perform unchecked branching and external calls without thorough parameter validation or consistent ERC-4626 unwrap handling. There is no safe default when no oracle is configured, unwrapping logic only covers the base token, and the base==quote feebypass check occurs after unwrapping, leading to unintended zerofee paths.

**Impact:**

Callers of getUpdateFee may experience denial-of-service (unexpected reverts) when querying unconfigured asset pairs, incorrect fee calculations or oracle call failures when passing a vault token as quote, and fee bypasses (zero fees) for certain vault/underlying combinations. This can disrupt pricefeed updates, lead to lost oracleservice revenue, and undermine downstream feedependent logic.

---


### Unbounded Token Metadata and Decimal Handling in getInitMarketInfo Leading to Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `getInitMarketInfo()`

**Description:**

The getInitMarketInfo function in LatentSwapLogic constructs market metadata by: 1) querying token.decimals() and using the result in exponentiation (10**decimals) and downcasting to uint8, and 2) performing external staticcalls to token.name()/token.symbol() without gas or length limits before concatenating returned strings. Because it lacks any validation or caps on returned decimals or string length, a malicious token can return extreme decimals (>=77) to trigger arithmetic overflows or excessive exponentiation, or return excessively large or expensive metadata strings to exhaust gas during concatenation. In both scenarios, getInitMarketInfo will revert or run out-of-gas, blocking market initialization and data retrieval.

**Root Cause:**

getInitMarketInfo performs unchecked exponentiation (10**baseDecimals) and unchecked downcasts for decimals without bounding baseDecimals, and invokes dynamic string.concat on unbounded-length name/symbol data from untrusted tokens with no gas or size checks. These operations assume well-behaved metadata and ignore that token contracts can return arbitrary values or lengths.

**Impact:**

A malicious or misconfigured token can force getInitMarketInfo to revert or run out of gas, resulting in a denial-of-service for any caller attempting to initialize or query market information for that token. This prevents clients-both on-chain and off-chain-from retrieving essential market parameters, effectively locking users out of interacting with affected markets until the underlying token contract behavior is corrected.

---


### Unchecked External Calls in Preview and Quote Functions Leading to Denial-of-Service and Fee Manipulation

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`
- `LatentSwapLEX`

**Affected Function(s):**
- `previewSwap()`
- `quoteRedeem()`
- `quoteSwap()`

**Description:**

Multiple read-only and preview entry points across the protocol delegate critical pricing and fee computations to untrusted, caller-specified contracts without any validation, gas limiting, or error handling. Specifically, previewSwap, quoteRedeem, and quoteSwap accept external contract addresses from user-supplied parameters and directly staticcall or invoke IPriceOracle methods on them. Because these are unchecked calls, a malicious or faulty contract can revert, consume excessive gas, or return arbitrary fee values, causing the host function to revert or misbehave.

**Root Cause:**

The preview and quote functions fetch or forward external contract addresses from untrusted calldata and perform unchecked external calls (staticcall or direct interface invocations) without validating the target address against on-chain configuration, enforcing gas stipends, or wrapping calls in try/catch. Returned fee values and quote data are used unbounded in subsequent logic.

**Impact:**

An attacker can deploy or specify a malicious LEX or oracle contract to force previewSwap, quoteRedeem, or quoteSwap to revert or exhaust gas, resulting in a denial-of-service for users and dependent front-ends. Additionally, by returning arbitrarily large fee values, a malicious oracle can inflate fee estimates, leading to user overpayment or blocked transactions due to insufficient msg.value.

---


### previewMint Trusts Caller-Supplied MarketParams Allowing Oracle Spoofing

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`

**Affected Function(s):**
- `previewMint()`

**Description:**

The previewMint function uses the MarketParams provided in calldata (mintParams.marketParams) rather than the on-chain stored MarketParams (idToMarketParams). An attacker can supply a malicious lex address in the calldata, causing previewMint to call quoteMint on an attacker-controlled contract and return arbitrary tokenPrices instead of genuine oracle prices.

**Root Cause:**

previewMint reads all its MarketParams (including the lex address) from the untrusted calldata struct instead of fetching and trusting the canonical on-chain MarketParams mapping.

**Impact:**

An attacker can spoof oracle prices by pointing quoteMint to a malicious contract, leading to incorrect token price previews, protocol fee miscalculations, and potential downstream loss of funds or financial abuse in minting operations.

---


### Input Validation and Identity Case Handling in Adapter Quote Previews

**Severity:** QA  

**Affected Contract(s):**
- `BaseAdapter`
- `CrossAdapter`

**Affected Function(s):**
- `previewGetQuotes()`
- `_previewGetQuote()`

**Description:**

The adapter previewGetQuotes entry points fail to validate caller-supplied inputs and do not properly handle identity (same-token) quote requests. Specifically, BaseAdapter.previewGetQuotes forwards inAmount, base, and quote directly to _previewGetQuote without checking that base and quote are non-zero and distinct. CrossAdapter._previewGetQuote, via ScaleUtils.getDirectionOrRevert, does not recognize the base==quote case and explicitly reverts. Together, these flaws allow invalid parameters or legitimate same-token queries to either produce silent zero quotes, inconsistent results, or unexpected reverts.

**Root Cause:**

Both adapters lack proper input validation and branching for edge cases: BaseAdapter does not enforce non-zero or distinct base/quote addresses, and CrossAdapter's directional logic omits an identity-swap branch and reverts on base==quote.

**Impact:**

Callers can supply address(0) or duplicate addresses and receive misleading zero quotes or trigger reverts. Automated strategies and UI components that assume same-token quotes should be no-ops or return inAmount will break. This undermines the reliability of price previews, can lead to denial-of-service in quoting logic, and may disrupt downstream routing and trading workflows.

---


### Unbounded Arithmetic in SqrtPriceMath Leads to Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `LatentMath`
- `SqrtPriceMath`

**Affected Function(s):**
- `getMarketStateFromLiquidityAndDebt()`
- `getNextSqrtPriceFromAmount1()`

**Description:**

Both SqrtPriceMath.getNextSqrtPriceFromAmount0 (used by LatentSwapLogic.getMarketStateFromLiquidityAndDebt) and SqrtPriceMath.getNextSqrtPriceFromAmount1 perform arithmetic without appropriate bounds checks or saturation logic. In the removal branch, getNextSqrtPriceFromAmount0 uses a strict require to guard against depleting all liquidity but does not clamp or saturate at the lower price boundary, so extreme inputs revert. In the addition branch, getNextSqrtPriceFromAmount1 computes a large quotient and adds it to sqrtPX96 under Solidity 0.8's checked overflow rules, causing an overflow revert for certain high amounts or low liquidity scenarios.

**Root Cause:**

Lack of input validation and fallback logic in SqrtPriceMath: getNextSqrtPriceFromAmount0 relies on a require to prevent underflow without providing a saturation path, and getNextSqrtPriceFromAmount1 performs a checked addition on potentially unbounded values without an unchecked block or pre-bound checks.

**Impact:**

A malicious or misconfigured caller can supply extreme token amounts or manipulate liquidity parameters to trigger these revert conditions, causing any functions that compute or update prices using these methods (e.g., getMarketStateFromLiquidityAndDebt) to revert. This results in a denial-of-service for on-chain market state updates and quote operations under edge-case scenarios.

---


### Non-Deterministic Symbol Fallback in TokenData._assetSymbol

**Severity:** QA  

**Affected Contract(s):**
- `TokenData`

**Affected Function(s):**
- `_assetSymbol()`

**Description:**

When no manual override (_symbol) is set for a token, TokenData._assetSymbol performs an uncached staticcall to the token's own symbol() via SafeMetadata.tryGetSymbol. A malicious ERC-20 can return different symbol values based on read-only EVM context (e.g., gasleft(), blockhash). Because TokenData never caches the first result, successive calls within the same block or transaction can yield different symbols, violating expected consistency.

**Root Cause:**

Fallback to the token's symbol() with no caching or validation allows a malicious token contract to return context-dependent, non-deterministic values.

**Impact:**

Downstream logic or UIs relying on assetSymbol can behave unpredictably or be misled. In systems that use the symbol as a key-e.g., mappings, registries, or conditional flows-an attacker could exploit inconsistent symbols to bypass checks, spoof assets, or corrupt data.

---


### Missing Edge-Case Validation in _calcRatio Leading to Mispricing and Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `_calcRatio()`
- `calcRatio()`

**Description:**

The internal _calcRatio function in LatentSwapLogic lacks critical input validations for two key edge cases: zero-price conditions and identity (base==quote) swaps. Because these cases aren't handled explicitly, invalid intermediate values can propagate through arithmetic routines, resulting in either a returned price of zero or an outright revert when the pair of assets should yield a unit ratio.

**Root Cause:**

_calcRatio branches based on asset types but omits: 1) a check that lastSqrtPriceX96 is non-zero before invoking Math.mulDiv in the non-BASE/non-BASE branch; 2) an explicit base==quote shortcut that returns a 1:1 ratio. As a result, zero or uninitialized price data flows through _synthToDex/_dexToSynth unchecked, and identity swaps fall through to routines that either underflow, overflow, or deliberately revert.

**Impact:**

Under certain uninitialized or edge conditions, callers to calcRatio may receive a price of zero-leading to mispricing, erroneous routing or financial loss-or encounter a revert on identity swaps (particularly when swapping the BASE asset against itself), causing denial-of-service for simple, legitimate quote operations.

---


### Off-by-One Duration Labeling Bug

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `getInitMarketInfo()`

**Description:**

The function computes `months = debtDuration / 30 days` and `years = debtDuration / 365 days`. It then uses `if (months < 12)` to decide whether to label the duration in months ("nM") or years ("nY"). For durations in the range [360 days, 365 days), `months` equals 12 so the code takes the years branch, but `years` is 0 (floored), producing the label "0Y" instead of the expected "12M" (or a mixed months+days format).

**Root Cause:**

Branching logic uses separate floor divisions by 30 days and 365 days without aligning their cut-off: durations of 12x30 days are treated as >=12 months, yet dividing by 365 days floors to 0 years.

**Impact:**

Durations just under one year are mislabeled as "0Y" in the user interface, causing confusion and undermining confidence in displayed terms. While not directly exploitable on-chain, it degrades UX and could mislead users about loan terms.

---


### Perpetual Dust from Explicit Clamp in Negative-Interest Debt Decay

**Severity:** QA  

**Affected Contract(s):**
- `DebtMath`

**Affected Function(s):**
- `accrueInterestLnRate()`

**Description:**

When applying negative continuous interest in DebtMath.accrueInterestLnRate, any nonzero debt amount that underflows to zero is forcibly clamped to one unit. This prevents small debts from ever reaching zero under deflationary interest, creating perpetual "dust" balances that cannot be fully extinguished.

**Root Cause:**

In the negativeinterest branch of accrueInterestLnRate, after computing updatedAmount_ = _amount.mulDiv(RAY, updateFactor), the code checks `if (updatedAmount_ == 0 && _amount > 0) updatedAmount_ = 1`. This hardcoded clamp treats an underflowed zero result as one, conflating a legitimate zero balance with a minimal one-unit residual.

**Impact:**

Tiny debt positions never fully repay under negative rates, leaving borrowers with an irreducible balance of 1 unit. This breaks the expected behavior of deflationary interest, leads to stuck 'dust' balances, complicates accounting and settlement logic, and may prevent full closure of debt positions.

---


### Zero Default Pause Address Leads to Unpauseable Markets

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`

**Affected Function(s):**
- `setDefaultPauseAddress()`

**Description:**

Because setDefaultPauseAddress allows the zero address, any markets created after setting the default pause address to zero will have their authorizedPauseAddress set to address(0). The pause/unpause entry point (setMarketPause) requires msg.sender to equal that address, so no one can pause or unpause these new markets.

**Root Cause:**

Missing input validation in setDefaultPauseAddress permits assigning address(0) to _defaultPauseAddress.

**Impact:**

New markets become permanently locked in whatever pause state they are created in, disabling any pause controls and risking unmanageable or frozen market behavior.

---


### Zero-amount Protocol Fee Collection Allowed

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`

**Affected Function(s):**
- `collectProtocolFee()`

**Description:**

The function intends to reject zero-amount fee requests, but only checks the raw input before capping it to the accrued fee. When accruedFees is zero and a positive amountRequested is supplied, the code caps amountRequested to zero, performs a zero-value safeTransfer (allowed by SafeERC20), and emits a CollectProtocolFee event. This violates the requirement to reject zero-amount collections.

**Root Cause:**

Missing post-cap validation: there is no check after capping amountRequested to accruedFees to revert when the resulting amount is zero.

**Impact:**

Callers can trigger zero-amount transfers and event emissions, causing misleading accounting, potential event spam, and unnecessary gas usage. It also breaks the protocol's invariant of rejecting zero-amount requests.

---


### Unchecked Division Operations Across LatentSwapLogic and LatentMath Leading to Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `LatentMath`
- `LatentSwapLogic`

**Affected Function(s):**
- `computeRedeem()`
- `_calcRatio()`
- `_calculateTokenPrices()`
- `getInitMarketInfo()`
- `_getDebtPriceDiscount()`
- `_calculateMarketState()`
- `_readBasePriceAndCalculateLiqRatio / readBasePriceAndCalculateLiqRatio()`
- `computeLiquidity()`
- `_readBasePriceAndCalculateLiqRatio()`
- `getDebtPriceDiscount()`

**Description:**

Multiple functions in the LatentSwapLogic library and its supporting LatentMath module perform division or subtraction operations without enforcing critical input invariants (non-zero denominators and correct parameter ordering). This lack of validation allows callers or misconfigured pools to trigger division-by-zero or underflow panics, resulting in pervasive denial-of-service across core swap, mint, redeem, price calculation, and market initialization flows.

**Root Cause:**

Absence of require() statements or equivalent guards to enforce that denominators derived from external state or user inputs (e.g., edgeSqrtPriceX96_A/B, currentSqrtPriceX96, targetXvsL, supplyAmounts, limMaxSqrtPriceX96) are strictly greater than zero and that ordered pairs satisfy B > A before subtraction. The libraries assume these preconditions are met externally but fail to enforce them internally.

**Impact:**

An attacker or misconfigured environment can supply zero or inverted values to any of the affected functions, causing immediate reverts. This can block swaps (_calcRatio, _calculateTokenPrices), prevent liquidity redemptions (computeRedeem -> computeLiquidity), halt price and liquidity ratio queries (_readBasePriceAndCalculateLiqRatio, readBasePriceAndCalculateLiqRatio), disrupt debt price discount calculations (getDebtPriceDiscount), and deny all market initialization or state updates (_calculateMarketState, getInitMarketInfo). The result is a complete denial-of-service for end-users and potential griefing attacks.

---


### Unchecked Duration Parameter Leads to Denial-of-Service in DebtMath

**Severity:** QA  

**Affected Contract(s):**
- `DebtMath`

**Affected Function(s):**
- `calculateApproxExponentialUpdate()`
- `accrueInterestLnRate()`

**Description:**

Several functions in the DebtMath library accept a duration parameter (_duration) and use it as a divisor in arithmetic operations without validating that the value is non-zero. This affects both the core calculation function calculateApproxExponentialUpdate and the interest accrual wrapper accrueInterestLnRate (and by extension accrueInterest). As a result, passing a zero duration will trigger a division-by-zero revert.

**Root Cause:**

The library assumes callers will supply a positive duration but lacks any internal guard (e.g., require(_duration > 0)) before performing `... / _duration`. No precondition is enforced on this parameter in either calculateApproxExponentialUpdate or its callers.

**Impact:**

An attacker or misconfigured caller can pass _duration = 0 to any public interest accrual function (accrueInterest, accrueInterestLnRate), causing an immediate revert. This blocks all interest accrual operations and any downstream logic depending on successful accrual, resulting in a denial-of-service against core lending functionality.

---


### Missing Zero-Denominator and Input Bounds Checks Across Multiple Math Modules Leading to Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `Various Adapters (e.g., UniswapV3Adapter)`
- `SaturatingMath`
- `LatentSwapLogic`
- `Uint512`
- `LatentMath`

**Affected Function(s):**
- `_getQuote()`
- `saturatingMulDiv()`
- `saturatingMulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding)()`
- `_squareUnsafe()`
- `sqrt512()`
- `get_XvsL()`

**Description:**

Various modules in the protocol perform arithmetic operations (division, mulmod, squaring, shifts) on inputs that can be zero, inverted, or out of bounds without any internal validation. This affects adapter quote functions (_getQuote), the saturatingMulDiv function (both base and rounding-aware overloads), the LatentSwapLogic's unchecked squaring routine (_squareUnsafe), the Uint512 sqrt512 calculation, and the LatentMath get_XvsL ratio computation. In each case, missing require-style guards or bounds checks allow denominators to be zero or arithmetic shifts to produce zero, triggering division-by-zero or unintended overflows.

**Root Cause:**

All affected functions assume upstream inputs satisfy non-zero or bounded preconditions but fail to enforce these invariants internally. No require(_denominator > 0) or require(input within valid range) checks are present before division, mulmod, unchecked arithmetic, or bit shifts.

**Impact:**

An attacker or misconfigured caller can supply zero or extreme values to any of these functions, causing immediate reverts or silent overflows. This leads to cascading denial-of-service across swap quotes, swap execution, liquidity operations, price calculations, and market initialization routines. Unexpected behavior-like silent saturation, zero outputs, or panics-undermines protocol availability, correctness, and reliability.

---


### Potential Typo in Event Emission for Curator Updates

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`

**Affected Function(s):**
- `setEnabledCurator()`

**Description:**

The `setEnabledCurator` function updates the enabled status of a curator but emits an event named `UpdateEnabledOracle`. This suggests a mismatch between the function's intent (curators) and the event name (oracles), likely due to a typo or copy-paste error.

**Root Cause:**

A curatorspecific event (e.g., `UpdateEnabledCurator`) was not defined or used; instead, the oracle event `UpdateEnabledOracle` is incorrectly emitted in the curator function.

**Impact:**

Consumers of these events (offchain services, UIs, or other contracts) will misclassify or ignore curator status changes, leading to incorrect state tracking or UI displays.

---


### Unchecked Recursion in resolveOracle Can Cause Denial-of-Service

**Severity:** QA  

**Affected Contract(s):**
- `CovenantCurator`

**Affected Function(s):**
- `resolveOracle()`

**Description:**

The resolveOracle function recursively unwraps ERC-4626 vault tokens via the resolvedVaults mapping without any cycle detection or recursion depth limits. An owner or malicious vault can introduce a mapping cycle (including self-mapping), causing resolveOracle to recurse indefinitely until stack overflow or an out-of-gas error. This leads to view calls reverting and non-view operations failing.

**Root Cause:**

No cycle detection or recursion depth limit when resolveOracle follows resolvedVaults mappings to unwrap vault tokens.

**Impact:**

Critical functions that rely on resolveOracle-especially non-view entrypoints like updatePriceFeeds-can be Denial-of-Service'd, halting price updates and disrupting on-chain operations dependent on price feeds.

---


### Systematic Undercharging from Truncating Integer Divisions in Financial Calculations

**Severity:** QA  

**Affected Contract(s):**
- `DebtMath`
- `LatentMath`

**Affected Function(s):**
- `calculateLinearAccrual()`
- `get_XvsL()`

**Description:**

Multiple library functions perform chained or saturating integer multiplications and divisions that floor any fractional remainders without tracking or compensating for the dropped "dust." Because there is no rounding-up option or mechanism to carry forward fractional portions, repeated calls or sequential divisions systematically undercalculate accrued interest, ratios, and other financial metrics.

**Root Cause:**

Use of integer (floor) division in financial math routines (saturatingMulDiv, Math.mulDiv, and plain "/") without any rounding-up logic, remainder tracking, or compensating adjustments leads to cumulative truncation errors.

**Impact:**

Over time or across large volumes, these small per-operation truncations compound into measurable revenue losses, undercharged interest, mispriced positions, systemic accounting drift, and subtle arbitrage opportunities.

---


### Miner/Validator Bias and Non-Determinism in Protocol Fee Rounding

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`
- `LatentSwapLEX`

**Affected Function(s):**
- `_calculateMarketState()`
- `quoteMint()`

**Description:**

The protocol uses block.prevrandao and block.timestamp as sources of randomness when deciding whether to round small protocol fees up by one unit in the _calculateMarketState function (invoked both in core swaps and in the quoteMint preview path). Since both of these block attributes are known to and can be influenced by the block proposer within consensus limits, the proposer can systematically bias the rounding outcome in its favor. Additionally, this pseudo-random rounding compromises the determinism of the view-only quoteMint function, causing clients to receive inconsistent fee and output estimates across blocks.

**Root Cause:**

Reliance on miner/validatorcontrolled block attributes (block.prevrandao and block.timestamp) as the sole source of randomness for critical feerounding decisions, without an unbiased commitment or oracle scheme. The same logic runs in the preview path, breaking view determinism.

**Impact:**

A block proposer can iterate through timestamp values (and exploit knowledge of prevrandao) to force excessive roundups of small protocol fees, extracting additional revenue over time and undermining fairness. Simultaneously, clients using quoteMint may observe varying quotes for identical inputs across different blocks, leading to UX disruptions and potential financial losses.

---


### Miner Manipulation of Timestamp-based Validation

**Severity:** QA  

**Affected Contract(s):**
- `PythOracle`

**Affected Function(s):**
- `_previewFetchPriceStruct()`

**Description:**

The oracle uses block.timestamp to validate whether a price is too stale or ahead-of-time based on on-chain constants. Since block.timestamp can be manipulated by miners within a consensus-defined window (~900s), they can cause valid prices to be rejected or stale prices to pass these checks.

**Root Cause:**

Reliance on block.timestamp for critical time-based validation with acceptance windows smaller than potential miner timestamp drift.

**Impact:**

A miner can skew the timestamp to reject fresh price updates or accept stale ones, allowing them to influence price-dependent on-chain logic, potentially leading to mispricing attacks or protocol insolvency.

---


### Unchecked Numeric Casts Leading to Wrap-Around and DoS

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLEX`
- `DebtMath`
- `LatentSwapLogic`

**Affected Function(s):**
- `initMarket()`
- `accrueInterest()`
- `_calculateMarketState()`

**Description:**

The protocol performs multiple unchecked numeric type conversions throughout its core logic, allowing inputs outside the target type's range to either wrap around or revert execution. These cases include casting from uint8 to int8 (wrap-around), from uint256 to int256 (overflow revert), and from uint256 to uint160 (overflow revert). Without proper validation or saturation, these operations can lead to incorrect market parameters, mispriced assets, or outright Denial-of-Service under valid but extreme conditions.

**Root Cause:**

Missing boundary checks prior to casting larger or unsigned integer types into smaller or signed integer types, causing unintended wrap-around or runtime reverts when values exceed the destination type's limits.

**Impact:**

1. Mispricing and Financial Loss: An unchecked uint8->int8 conversion in initMarket can wrap decimals beyond the signed range, producing negative or incorrect scaling factors and resulting in mispriced markets or market insolvency.
2. Denial-of-Service via Signed Overflow: Casting a large discount price (uint256) to int256 in accrueInterest without ensuring it <=2^255-1 will revert on overflow, halting interest accrual and blocking borrowing/repayment flows.
3. Denial-of-Service via Unsigned Overflow: Converting a uint256 liquidity value to uint160 in _calculateMarketState without bounds checking will revert if the value exceeds 2^160-1, preventing minting, redemption, swaps, and state queries under high-liquidity scenarios.

---


### Unbounded scaleDecimals Causes Exponentiation Overflow in `_readBasePriceAndCalculateLiqRatio`

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `_readBasePriceAndCalculateLiqRatio()`

**Description:**

The `_readBasePriceAndCalculateLiqRatio` function computes `scaledLiquidityConcentrationX96` by exponentiating 10 to the power of the absolute value of `scaleDecimals`. If `scaleDecimals` is large (e.g., >77) or negative with large magnitude, the exponentiation `10 ** uint8(abs(scaleDecimals))` can overflow `uint256`, causing a revert. Because there is no bounds checking on the magnitude of `scaleDecimals` when the market is initialized, an attacker or misconfiguration can set `scaleDecimals` outside a safe range and trigger a denial-of-service.

**Root Cause:**

Lack of validation on the `scaleDecimals` parameter during market initialization allows arbitrarily large exponents in `10 ** uint8(abs(scaleDecimals))`, leading to overflow.

**Impact:**

A malicious or misconfigured `scaleDecimals` beyond safe bounds can cause exponentiation and subsequent multiplication to overflow, reverting price calculations and effectively disabling swaps, mints, and redemptions (denial-of-service).

---


### Zero Output Mint via Floor Rounding

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `_calcMint()`

**Description:**

Because both _synthToDex and _dexToSynth use floor rounding without any minimum-output checks, very small baseTokenAmountIn values can result in zero DEX liquidity and thus zero synthetic token outputs. Users depositing tiny amounts of base token end up receiving no aTokens or zTokens and incur a loss without any revert or warning.

**Root Cause:**

Application of Math.Rounding.Floor in both conversion steps (_synthToDex and _dexToSynth) combined with the absence of a check that minted outputs are nonzero allows small inputs to collapse silently to zero.

**Impact:**

An attacker or benign user can deposit small base token amounts and receive zero synthetic tokens, effectively losing their funds while the contract does not revert.

---


### Improper Return Data Length Check in SafeMetadata.tryGetDecimals

**Severity:** QA  

**Affected Contract(s):**
- `SafeMetadata`

**Affected Function(s):**
- `tryGetDecimals()`

**Description:**

The function tryGetDecimals uses staticcall to invoke decimals() on an ERC20 token and only verifies that the returned data length is at least 32 bytes. It then decodes the first 32 bytes as a uint256 and casts it to uint8. A malicious token can override decimals() to return a dynamic type (e.g., string) or any longer data, causing staticcall to succeed and return >=32 bytes. The first 32 bytes of that data can be an attacker-controlled offset or value under 255, allowing the attacker to spoof the decimal count.

**Root Cause:**

The code enforces encodedDecimals.length >= 32 instead of requiring exactly 32 bytes for the static-type-encoded return, allowing nonstandard return data to pass the check.

**Impact:**

An attacker can deploy a malicious token that returns dynamic or oversized data for decimals(), spoofing any uint8-decimal <=255. This can lead to incorrect token amount normalization, balance miscalculations, pricing errors, or financial losses in dependent contracts or dApps.

---


### Asymmetric Rounding in accrueInterestLnRate

**Severity:** QA  

**Affected Contract(s):**
- `DebtMath`

**Affected Function(s):**
- `accrueInterestLnRate()`

**Description:**

The function uses two different multiplication/division routines for positive vs. negative interest rates. For _lnRate >= 0 it calls SaturatingMath.saturatingMulDiv (which applies its own rounding and saturation behavior). For _lnRate < 0 it calls Math.mulDiv (which floors the result) and then clamps any nonzero results that underflow to zero back up to 1. This asymmetry causes interest accrual to round differently than interest decay, introducing a bias over time.

**Root Cause:**

Using saturatingMulDiv with its internal rounding for positive rates and using floor division (mulDiv) plus a clamp for negative rates leads to inconsistent rounding policies across the two branches.

**Impact:**

Over many accrual/decay cycles, the rounding bias can accumulate, leading to systematic over- or under-valuation of debt balances. This mispricing may be exploitable by borrowers or lenders optimizing around rounding edges.

---


### Exponentiation Overflow Leading to DOS

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `_readBasePriceAndCalculateLiqRatio()`

**Description:**

The function computes 10**uint8(scaleDecimals) (and 10**uint8(-scaleDecimals)) without validating `scaleDecimals`. If |scaleDecimals| >= 78, this exponentiation overflows uint256 under Solidity 0.8+ and reverts the transaction, allowing an attacker to cause a denial-of-service by passing a large `scaleDecimals` through public/external entry points that lack bounds checks.

**Root Cause:**

Missing range validation on `scaleDecimals` before doing unchecked exponentiation, leading to overflow and revert.

**Impact:**

An attacker can force the function to revert, blocking pricing operations and halting functionality of the swap logic (denial-of-service).

---


### Unrestricted Market Creation in Covenant

**Severity:** QA  

**Affected Contract(s):**
- `Covenant`

**Affected Function(s):**
- `createMarket()`

**Description:**

The createMarket function is publicly callable by any address and lacks ownership or role-based access control. Attackers can invoke it to create new markets with arbitrary parameters and IDs, leading to spammed markets or hijacked market identifiers.

**Root Cause:**

Missing onlyOwner or similar modifier on createMarket; no caller-based authorization is enforced beyond parameter validation.

**Impact:**

Attackers can flood the protocol with unauthorized markets, exhaust resources, confuse users, and potentially front-run or seize specific market IDs, resulting in denial of service and degraded platform integrity.

---


### Potential Denial of Service via Malformed Dynamic String

**Severity:** QA  

**Affected Contract(s):**
- `SafeMetadata`

**Affected Function(s):**
- `_tryStringOrBytes32()`

**Description:**

The function unconditionally decodes any returned bytes of length >= 64 as a dynamic string using abi.decode. A malicious token can craft a payload whose length prefix is excessively large or inconsistent with the actual data, forcing the decoder to allocate huge memory or read out-of-bounds, leading to out-of-gas, OOM, or revert.

**Root Cause:**

Lack of bounds checking or structural validation on the dynamic string payload before calling abi.decode.

**Impact:**

A malicious token contract can cause SafeMetadata (and any caller) to revert or run out of gas, resulting in a denial-of-service when metadata is fetched.

---


### Zero-Denominator in saturatingMulDiv Returns Max Instead of Revert

**Severity:** QA  

**Affected Contract(s):**
- `SaturatingMath`

**Affected Function(s):**
- `saturatingMulDiv()`

**Description:**

The function saturatingMulDiv allows callers to supply a denominator of 0. Instead of reverting on division by zero, it unconditionally takes the branch high >= denominator (true for denominator == 0) and returns uint256.max. No require or revert guard is present.

**Root Cause:**

Missing explicit check for denominator == 0 before applying saturating logic. The high >= denominator check is too lax when denominator is zero.

**Impact:**

Callers can receive an unintended uint256.max result rather than a revert, potentially leading to silent failures, incorrect accounting, or overflow-related exploits when integrating this function in higher-level protocols.

---


### No Vulnerability: Safe Casting in initMarket

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLEX`

**Affected Function(s):**
- `initMarket()`

**Description:**

Both synthDecimals and quoteDecimals originate from the same source (the quote token's decimals) and thus always match. Casting identical uint8 values to int8 then subtracting yields zero, so scaleDecimals is always 0. There's no path to produce a negative or out-of-range scaleDecimals.

**Root Cause:**

Although uint8->int8 conversion can wrap for values >127, both values are equal, so their difference cannot overflow.

**Impact:**

No impact; scaleDecimals is always zero, and no incorrect negative scaling can occur.

---


### Missing Swap Fee on Full and Undercollateralized Redemptions

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `_calcRedeem()`

**Description:**

The `_calcRedeem` function applies the `swapFee` only in the partial collateralized branch. In the full-redemption branch (when both `aTokenAmountIn` and `zTokenAmountIn` equal their supplies) and the under-collateralized/zero-liquidity branch (when `marketState.underCollateralized` is true or `marketState.liquidity` is 0), it returns `amountOut` directly without applying the fee discount. Users can thus bypass fees by redeeming all liquidity or redeeming while under-collateralized.

**Root Cause:**

Fee calculation (`amountOut.percentMul(PERCENTAGE_FACTOR - swapFee)`) is only executed in the partial redemption branch; the other branches return the gross amount without discount.

**Impact:**

Attackers can avoid paying swap fees entirely by performing full redemptions or redeeming when the pool is under-collateralized or has zero liquidity, resulting in lost protocol revenue and imbalance of reserves.

---


### Zero-output Exact-in Swap for Non-base Asset Allowed

**Severity:** QA  

**Affected Contract(s):**
- `ValidationLogic`

**Affected Function(s):**
- `checkSwapOutputs()`

**Description:**

The function checkSwapOutputs fails to revert when amountCalculated==0 for exact-in swaps involving a non-base assetIn, and a zero or lower amountLimit, thereby allowing a swap that burns the user's input without any output.

**Root Cause:**

The conditional block only reverts on zero output for non-exact-in swaps or when assetIn is BASE, omitting the case isExactIn==true && assetIn!=BASE.

**Impact:**

Users can execute exact-in swaps of non-base assets with a zero or non-positive amountLimit, losing their input tokens with no output received.

---


### quoteSwap Returns Cumulative Protocol Fee Instead of Incremental Swap Fee

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLEX`

**Affected Function(s):**
- `quoteSwap()`

**Description:**

The quoteSwap function returns the entire accruedProtocolFee computed by swapLogic-which represents the total protocol fees accumulated since the last onchain update-rather than isolating the fee attributable to the single swap. When isExactIn is true, this causes the sum of amountCalculated, protocolFees, and oracleUpdateFee to exceed the user's input, breaking the expected accounting invariant.

**Root Cause:**

quoteSwap directly returns currentState.accruedProtocolFee (a cumulative fee since the last onchain update) instead of calculating the difference between the new accruedProtocolFee and the prior onchain accruedProtocolFee to obtain the incremental fee for the specific swap.

**Impact:**

Users receive incorrect quoted amounts, leading to under or overcharging in swaps, broken accounting invariants, potential loss of funds or degraded trust in swap pricing.

---


### Improper Handling and Validation of External Token Decimals

**Severity:** QA  

**Affected Contract(s):**
- `TokenData`

**Affected Function(s):**
- `_assetDecimals()`

**Description:**

The TokenData._assetDecimals function relies on an untrusted external staticcall to fetch token decimals via SafeMetadata.tryGetDecimals(), but fails to properly guard, validate, or constrain this input. This single flaw enables multiple exploitation vectors-decimal values above the protocol's intended maximum, fluctuating/malicious decimal returns, and gas-exhaustion attacks-impacting all downstream arithmetic and protocol operations that depend on consistent, bounded decimal values.

**Root Cause:**

_Unguarded external call and lack of validation or safeguards on the decimals() output:_
1. No bounds checking or clamping: raw uint8 values up to 255 are accepted, bypassing the intended 18-decimal maximum.
2. No consistency enforcement or caching: tokens can return different values per call.
3. No gas limit on staticcall: full remaining gas is forwarded, allowing malicious consumption.

**Impact:**

- Decimal values above 18 break normalization routines, leading to overflow/underflow, incorrect price or balance calculations, and potential fund loss.
- Fluctuating decimals allow attackers to skew share balances or withdrawal amounts, enabling asset drain.
- Gas exhaustion in decimals() causes reverts in _assetDecimals and all higher-level functions, enabling denial-of-service.

---


### Compounded Upward Rounding Bias in _calcRatio

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `_calcRatio()`

**Description:**

The internal function `_calcRatio` in LatentSwapLogic computes conversion rates by chaining two assetconversion steps-`_synthToDex(..., Rounding.Ceil)` followed by `_dexToSynth(..., Rounding.Ceil)`. Both steps use ceiling rounding, causing each division to round up to the nearest integer. Because each rounding-up introduces a small positive error, performing them sequentially without any corrective mechanism leads to a net upward bias in the computed price.

**Root Cause:**

Both conversion functions apply `Math.Rounding.Ceil` independently on division operations, but neither step compensates for the excess introduced by the prior rounding. The compounded effect of two ceiling rounds yields a final result strictly greater than the true DEX price.

**Impact:**

An attacker can exploit this rounding bias by performing self-swaps or back-to-back synth<->DEX swaps. Each execution extracts the accumulated rounding surplus, allowing the attacker to pocket small gains on every trade. Over multiple operations, these gains accumulate, draining value from the protocol or its users.

---


### Upward Bias and Non-Reciprocity Due to Consecutive Ceiling Rounding

**Severity:** QA  

**Affected Contract(s):**
- `LatentSwapLogic`

**Affected Function(s):**
- `_calculateTokenPrices()`
- `calcRatio()`

**Description:**

The contract applies two successive ceil-based rounding operations during conversion between synthetic and DEX token amounts. This introduces a systematic upward bias in both the synthetic token prices and the computed swap ratios, violating reciprocal rate assumptions.

**Root Cause:**

Both `_synthToDex` and `_dexToSynth` unconditionally use Math.Rounding.Ceil for their division results. Back-to-back use of ceil rounding in `calcRatio` and `_calculateTokenPrices` cumulatively inflates values.

**Impact:**

Arbitrageurs can exploit the bias to extract risk-free profit by buying off- chain (or on other markets) at fair prices and selling on-chain at overstated synthetic prices, or by repeatedly swapping back and forth to drain value due to non-reciprocal rates.

---


### Systematic Over-Burn from Double +1 Rounding Bias in computeRedeem

**Severity:** QA  

**Affected Contract(s):**
- `LatentMath`

**Affected Function(s):**
- `computeRedeem()`

**Description:**

The computeRedeem function in LatentMath applies two unconditional "+1" adjustments-first to the token shortfall (remZamt/remAamt) and then to the computed liquidity delta (remLiq). Underlying floor-based routines (computeMint and computeLiquidity) already produce conservative, rounded-down values, so the extra increments consistently overshoot the actual minimum liquidity required. As a result, every redeem operation burns one or more additional liquidity tokens beyond what is strictly necessary.

**Root Cause:**

A simplistic hard-coded rounding approach introduces two independent "+1" fudge factors on already floor-rounded values, without conditional checks or formal precision guarantees. This double adjustment causes an off-by-one (or more) bias in the liquidity burn calculation.

**Impact:**

Users systematically lose liquidity on each redemption, receiving fewer underlying tokens or paying higher implicit fees. Over repeated or large redemptions, these small discrepancies accumulate into a material capital inefficiency, effectively transferring value from the user to the protocol.

---

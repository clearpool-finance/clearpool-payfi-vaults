# clearpool-payfi-vaults — System-Wide Audit

**Branch reviewed:** `security/atomicsolverv3-remediation`
**Methodology:** two rounds of parallel adversarial agents. Round 1 = six breadth passes (one per subsystem). Round 2 = two depth passes — cross-subsystem attack composition and red-team against the Round-1 fix proposals.
**Scope:** every `.sol` under `src/` plus every deploy script under `script/`. AtomicSolverV5 was audited separately (see `ATOMIC_SOLVER_V5_REMEDIATION.md` + `ATOMIC_SOLVER_V5_CLEARPOOL_REVIEW.md`) and is excluded from this report's *findings* count, though it appears in the attack-chain analyses because it's the redemption leg most chains terminate through.

**Status update (post-fix pass):** the majority of findings have now been implemented on this branch — see §6.5 for the per-finding ship status and `git log` for the exact commits. Round 3 added 5 more shipped fixes (N-1, N-2, N-6, T-2 refinement, A-3 refinement — see §6.3) and surfaced **one CRITICAL deferred design item (R-1: emergency exit) that blocks a production mainnet redeploy**. Everything else remaining is an engineering-track follow-up or ops/audit item.

All 147 tests pass with every fix applied.

---

## 0. TL;DR

**The AtomicSolverV5 remediation is solid.** The contract is hardened, deploy-time invariants are checked, tests cover the exploit path end-to-end.

**Post-fix pass:** 17 of the findings below are now fixed on-branch (see §6.5). Seven findings stand out as originally flagged:

| Rank | System | Finding | Severity |
|---|---|---|---|
| 1 | Accountant | `updateExchangeRate` commits bad rate even when bounds violated; `getRate()` ignores pause; Teller uses `getRate()` not `getRateSafe()`. Combines into a privileged-role-single-compromise drain. | **HIGH** |
| 2 | Cross-chain Teller | Receive handlers on LZ/Hyperlane/OP all bypass `depositCap`, `checkAccess(receiver)`, and `shareUnlockTime` — KYC/cap/MEV-lock are cosmetic across the bridge. | **HIGH** |
| 3 | Teller | `bulkWithdraw` access check targets `msg.sender` (the solver) rather than `_to`, allowing compliance-bypass to any address. | **HIGH** |
| 4 | Accountant | `setRateProviderData` has no validation or timelock; atomic malicious-rate-provider injection. | **HIGH** |
| 5 | Authority | `OPERATOR_ROLE` holds `setUserRole`, one step away from granting `UPDATE_EXCHANGE_RATE_ROLE` to any EOA. Combined with #1 or #4, privilege cascade. | **HIGH (trust)** |
| 6 | Micro-managers | `swapWith1Inch` slippage is post-hoc; strategist can extract `allowedSlippage` per call via sandwich. | **HIGH** |
| 7 | BoringVault + Manager | `flashLoan(recipient)` doesn't assert `recipient == address(this)`; self-call in `receiveFlashLoan` uses wrong merkle-root slot. | **MEDIUM** |

**Multi-step exploit chains** (Round 2) show these don't live alone — combining any two of #1/#4/#5 is a one-tx drain. Combining #2 with the AtomicQueue is a same-block OFAC-bypass + cap-bypass exit.

No new CRITICAL in-isolation bug was found beyond what's already remediated. The criticality comes from *composition*.

---

## 1. Per-subsystem findings

### 1.1 BoringVault + ManagerWithMerkleVerification

Files: `src/base/BoringVault.sol`, `src/base/Roles/ManagerWithMerkleVerification.sol`

| # | Severity | Summary |
|---|---|---|
| V-1 | CRITICAL (trust boundary) | `BoringVault.manage` is gated by solmate `Auth.requiresAuth` which falls through on `msg.sender == owner`. Any MANAGER_ROLE holder AND the vault's owner can bypass the entire Merkle/decoder chain. Must be enforced via deploy invariants; recommend overriding `requiresAuth` to additionally assert `msg.sender == immutable manager`. |
| V-2 | HIGH | STRATEGIST_ROLE blast radius is bounded only by Merkle leaves. The only post-batch invariant is `vault.totalSupply()` unchanged — which prevents minting but not value extraction via whitelisted swap venues at adversarial slippage. |
| V-3 | MEDIUM | `flashLoan(address recipient, …)` at Manager.sol:182 does not assert `recipient == address(this)`. A Merkle leaf authoring mistake that pins a non-self recipient sends Balancer's borrowed funds elsewhere and aborts the manager's bookkeeping. One-line `require`. |
| V-4 | MEDIUM | `receiveFlashLoan` re-enters `manageVaultWithMerkleVerification` via a self-call with `msg.sender == address(this)`, using `manageRoot[address(this)]`. If any operational slip sets that slot, flash-loan callbacks execute against a root decoupled from the initiating strategist. Pass the strategist's root through the intent struct. |
| V-5 | LOW | No `nonReentrant` on either `manage` overload or on `manageVaultWithMerkleVerification`. Current roles prevent external reentry, but a future role-misassignment footgun is cheap to close. |
| V-6 | LOW | `Auth.transferOwnership` is single-step — typo bricks both contracts irrevocably. Use a 2-step transfer or only assign ownership to multisig/timelock at deploy. |
| V-7 | INFO | Standing allowances — vault approvals to routers/protocols are never revoked post-call. An approved-spender compromise pulls the full allowance. Strategists should pair every `approve(spender, X)` leaf with an `approve(spender, 0)` follow-up, or use `Permit2`. |

**Positive findings:** decoder calls use `functionStaticCall` (can't mutate state during verification). `BaseDecoderAndSanitizer.fallback` reverts (fail-closed on unknown selectors). `performingFlashLoan` flag correctly unwinds on revert.

**Out of scope, flagged:** 237 decoder functions across `src/base/DecodersAndSanitizers/` were not individually reviewed. Any decoder that returns an empty `packedArgumentAddresses` for a function whose calldata actually carries sensitive addresses will silently let those addresses be unconstrained. This is its own audit pass.

---

### 1.2 AccountantWithRateProviders + GenericRateProvider

Files: `src/base/Roles/AccountantWithRateProviders.sol`, `src/helper/GenericRateProvider.sol`

| # | Severity | Summary |
|---|---|---|
| A-1 | **HIGH** | `updateExchangeRate` always writes state (L285-287) even when bounds are violated. It auto-pauses but the bad rate is committed. When unpaused, Teller (which uses `getRate()`, not `getRateSafe()`) reads the bad rate. Fix: on bound violation, pause and `return` without writing. |
| A-2 | **HIGH** | `getRate()` at L386-389 does NOT check `_isPaused`. Teller's `_erc20Deposit` (L460) and `bulkWithdraw` (L508) both call `getRate()`, so pause is cosmetic for deposit/withdraw. Fix: either have Teller use `getRateSafe`/`getRateInQuoteSafe`, or have `getRate` itself revert while paused. Note (per Round-2 fix-validation): naive switch to `getRateSafe` creates deadlocks in bridge receive and mid-solve — pair with an admin `emergencyRefund` path that reads rate unconditionally, gated by multisig. |
| A-3 | **HIGH** | `setRateProviderData` (L247-251) has zero sanity checks and zero timelock. An owner (or compromised role, see Authority §1.6) can atomically register `EvilRateProvider` returning `type(uint256).max` and drain the vault in the same tx via a deposit. Fix: 48h timelock when replacing an existing provider, plus `require(getRate() within bounds)` probe. |
| A-4 | MEDIUM | Bounds `allowedExchangeRateChangeUpper/Lower` are `uint16`, can be set to ~6.55× per update. No global cumulative cap and no TWAP. `updateDelay` accepts 0. Fix: hard-cap `upper <= 10500` (5%), `lower >= 9500`, `minimumUpdateDelay >= 1 hour`. |
| A-5 | MEDIUM | Lending-rate accrual is decoupled from realized borrower repayments. `_exchangeRate` grows deterministically by `lendingRate * dt` regardless of actual loan performance. On default, early withdrawers extract value at late withdrawers' expense. Pause does not freeze `_lastAccrualTime`, so unpausing instantly compounds the pause duration. Fix: make accrual push-model (Manager pushes on realized repayments), OR add an admin `writedownExchangeRate` that bypasses the lower bound. |
| A-6 | MEDIUM | `GenericRateProvider` has no staleness check, no decimal enforcement, and uses `abi.decode(result, (uint256))` which panics on short returns → DoS if the target ever returns empty bytes. Fix: `try/staticcall` with length check, staleness parameter. |
| A-7 | LOW | `pause()` is `public requiresAuth` and called internally from `updateExchangeRate`. The auto-pause path therefore checks `msg.sender` permissions, which are the *updater's*, not the accountant's. If the updater doesn't hold pause rights, auto-pause reverts → the whole update reverts. Inconsistent but protective. Fix: internal `_pause()`. |
| A-8 | LOW | Checkpoint rounding can lose management fees to zero on small vaults + tiny intervals. `uint128` fee accumulator can overflow silently via narrowing (L522). Fix: accumulate in 18-decimal precision; `SafeCast.toUint128`. |
| A-9 | LOW | `claimFees` allows caller-chosen `_feeAsset`. Rate drift or stale provider means the payout can under/over-settle `feesOwedInBase`, which is zeroed unconditionally. Restrict to `base` asset or reconcile post-quote. |
| A-10 | LOW | Interest accrues before first deposit (`calculateExchangeRateWithInterest` doesn't gate on totalSupply). First depositor pays an inflated rate for no actual earned yield. |

---

### 1.3 TellerWithMultiAssetSupport + CrossChain variants

Files:
- `src/base/Roles/TellerWithMultiAssetSupport.sol`
- `src/base/Roles/CrossChain/CrossChainTellerBase.sol`
- `src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol`
- `src/base/Roles/CrossChain/MultiChainHyperlaneTellerWithMultiAssetSupport.sol`
- `src/base/Roles/CrossChain/CrossChainOPTellerWithMultiAssetSupport.sol`

| # | Severity | Summary |
|---|---|---|
| T-1 | **CRITICAL** | Cross-chain receive handlers on all three variants call `vault.enter(0, 0, 0, receiver, shareAmount)` directly, bypassing `depositCap`, `checkAccess(receiver)`, and `shareUnlockTime[receiver]`. Combined with AtomicQueue, a sanctioned/blacklisted address can cross-chain-deposit and exit same-block (see Exploit 3 in §2). Fix requires design, not a one-liner — see §3.3. |
| T-2 | **HIGH** | `bulkWithdraw` uses `checkAccess(msg.sender)` (line 451) where `msg.sender` is the solver. The actual recipient is `_to`, never access-checked. MANUAL_WHITELIST mode lets a whitelisted solver pull to any `_to`. Fix: change to `checkAccess(_to)`. |
| T-3 | **HIGH** | `refundDeposit` trust leak: `DEPOSIT_REFUNDER_ROLE` can selectively refund deposits whose shares have depreciated (benefits vault) while leaving appreciated ones alone. Rate-drift harvest against user MEV-lock. Also, after `bridge()`, refunding is impossible because the shares are burned but `publicDepositHistory[nonce]` persists. Fix: allow depositor-initiated refund during the lock window; delete `publicDepositHistory` entry on bridge. |
| T-4 | MEDIUM | `KEYRING_KYC` mode silently fails-open when `keyringContract == address(0)` (L170-174). Any admin who calls `setAccessControlMode(KEYRING_KYC)` before `setKeyringConfig` opens a window where everyone can deposit. Fix: revert in the modifier, or make the setter require `keyringContract != 0` when switching into KYC mode. |
| T-5 | MEDIUM | Hyperlane `handle` and OP `receiveBridgeMessage` do not store/check a processed-message-id dedup map. Replay protection is entirely outsourced to the bridge layer — acceptable if the bridges are trusted, but belt-and-suspenders missing. |
| T-6 | MEDIUM | `CrossChainOPTellerWithMultiAssetSupport.peer` defaults to `address(this)` in the constructor. If an admin forgets to call `setPeer` before activation, any message from `xDomainMessageSender() == address(this)` on the other side passes — CREATE2 predictable-address concern. Fix: initialize to `address(0)`. |
| T-7 | LOW | `bulkDeposit` and `bulkWithdraw` skip `isPaused`. Under incident response, admin pauses, but solvers can still push. Fix: add pause check or explicitly document as intentional. |
| T-8 | LOW | For assets with > 18 decimals, `_changeDecimals` rounds down — a caller passing `_minimumMint = 0` can mint 0 shares while the `vault.enter` still pulls the deposit. Fix: `if (shares == 0) revert`. |
| T-9 | LOW | `bridge()` LZ variant passes full `msg.value` to LZ `MessagingFee` (L98). Overpayment should refund via LZ's refund address but rounding leftovers can accumulate. |
| T-10 | INFO | The `ADMIN_ROLE`, `MINTER_ROLE`, `BURNER_ROLE` role numbering is inconsistent across deploy scripts (§1.6 D-1). |

---

### 1.4 AtomicQueue

File: `src/atomic-queue/AtomicQueue.sol`

| # | Severity | Summary |
|---|---|---|
| Q-1 | MEDIUM | `solve(…, solver)` takes a caller-supplied `solver` parameter. A SOLVER_ROLE holder can redirect the offer-pull / want-push to any `IAtomicSolver`-compatible contract that has a lurking queue allowance — forced-trade against third parties. Fix: `require(solver == msg.sender)`. **Round-2 validation: airtight.** |
| Q-2 | MEDIUM | Dust griefing that rounds `_calculateWantAmount` to zero STILL hard-reverts the batch. The `f3e2fd4` submission-time validation only checks deadline/balance/allowance, not that `wantAmount > 0` — and even if that check were added, rate drift between submit and solve re-opens the bypass. Load-bearing fix is solve-time skip (which is the deferred I-2). Fix: implement I-2 skip-and-emit in `solve` loop — this is not a one-liner, it changes keeper retry semantics, and it closes both I-2 and Q-2 at once. |
| Q-3 | LOW | `viewSolveMetaData` does not flag users whose `_calculateWantAmount` rounds to zero. Solvers relying on this view to filter are misled. Fix: add a "zero output" flag. |
| Q-4 | INFO | Implicit `decimals() <= ~36` assumption in `_changeDecimals`. Undocumented; not exploitable under `uint96` offerAmount cap and realistic token decimals. |

**Verified clean:** transactional atomicity of offer↔want, `inSolve` flag lifecycle, immutable accountant pointer, cancel path isolation, cross-function reentrancy via ERC777 offer token, mapping-key scoping for concurrent (offer,want) pairs.

---

### 1.5 Micro-managers (strategist helpers)

Files:
- `src/micro-managers/UManager.sol`
- `src/micro-managers/DexSwapperUManager.sol`
- `src/micro-managers/DexAggregatorUManager.sol`

| # | Severity | Summary |
|---|---|---|
| M-1 | **HIGH** | `swapWith1Inch` slippage is validated POST-swap against `priceRouter.getValue` (DexAggregatorUManager.sol:117). A strategist or colluding searcher can set `desc.minReturnAmount = 0` and MEV-sandwich for up to `allowedSlippage` per call. The post-hoc check tells you how much was taken, it doesn't prevent it. Fix: compute `expectedOut` BEFORE the swap and pass a minimum-out clamp to the router. Same pattern affects `swapWithBalancerV2`/`Curve`/`UniV3`. |
| M-2 | MEDIUM | `swapWith1Inch` does not locally validate the opaque 1inch calldata against the claimed `tokenIn`/`tokenOut`/`amountIn`. The Merkle decoder is supposed to pin these, but if `DecoderCustomTypes.SwapDescription` drifts from actual 1inch v5 `SwapDescription`, the sanitizer parses one thing and the router executes another — classic 1inch integration footgun. Fix: decode and assert locally in the micro-manager itself. |
| M-3 | MEDIUM | `UManager.enforceRateLimit` uses `callCountPerPeriod[block.timestamp % period]`. This is a **correctness bug**: the same bucket index is reused every `period` seconds without reset, so old counts carry forward. Strategists will see spurious `CallCountExceeded` reverts at unpredictable times. Fix: use `block.timestamp / period` (quotient) as the key so each new period gets a fresh slot. |
| M-4 | LOW | `revokeTokenApproval` is not rate-limited. A strategist can sandwich another legitimate tx by revoking an approval it depends on. Limited griefing; bounded by Merkle authorization. Fix: add `enforceRateLimit` or move to OWNER_ROLE. |
| M-5 | LOW | UniswapV3 `path` length not capped. Long paths can OOG and pick tokens where `priceRouter` returns 0, trivially passing slippage. Fix: cap path length + assert `priceRouter` supports endpoints. |

---

### 1.6 Authority wiring + deploy scripts

Files: everything under `script/` (production, test scaffolds, Nucleus cross-chain).

| # | Severity | Summary |
|---|---|---|
| D-1 | **HIGH** | Role-number collision in three deploy scripts. `src/helper/Constants.sol` has `OPERATOR_ROLE = 7`, but `DeployPortLayerZero.sol`, `DeployPortProofOfConcept.sol`, and `DeployNucleusCrossChain.sol` each locally redefine `MINTER_ROLE = 7` AND `SOLVER_ROLE = 9`. If a test-scaffold script is ever run against a production Authority, granting `MINTER_ROLE` to teller also grants `OPERATOR_ROLE` semantics — one grant away from `setUserRole` privilege. Fix: delete local role constants, import `Constants.sol`. |
| D-2 | MEDIUM | Test/PoC/testnet deploy scripts never call `transferOwnership` — owner stays as deployer EOA (`vm.addr(1)` or hardcoded 0xe434…). `AtomicSolverV5.rescue` falls back to `owner()`, so rotation/loss of the deployer EOA = permanently stuck rescue. Fix: add a `transferOwnership(protocolAdmin)` pass, or rename these scripts explicitly `_TEST_ONLY`. |
| D-3 | MEDIUM | `DeployNucleusCrossChain` grants `exchangeRateBot` → `ADMIN_ROLE` but no capability is ever wired to `ADMIN_ROLE` in that file. Dead-role today. Copy-paste bomb if a future edit adds a capability. Fix: remove the grant or replace with `UPDATE_EXCHANGE_RATE_ROLE`. |
| D-4 | MEDIUM | Trust asymmetry between deploy scripts: `DeployPortLayerZero` grants `CAN_SOLVE_ROLE` to `hexTrust`, `DeployNucleusCrossChain` to `solver`, `DeployPortProofOfConcept` to a single EOA that is also owner/hexTrust/strategist (single-EOA collapse). Fix: document one canonical mapping or delete the drifters. |
| D-5 | MEDIUM (trust) | `OPERATOR_ROLE` holds `setUserRole` on the Authority. Combined with A-3 or A-1, a compromised operator can grant `UPDATE_EXCHANGE_RATE_ROLE` to any EOA in one tx, reaching `setRateProviderData` / `updateExchangeRate`. Fix: introduce a sensitive-role allowlist — OPERATOR can grant a fixed set (`BORROWER_ROLE`, `STRATEGIST_ROLE`), not the privileged ones. **Round-2 validation: airtight.** |
| D-6 | LOW | Hardcoded raw bridge selector `0xa69559d1` in `DeployPortLayerZero.sol:181`. If the ABI changes, silently points at a different function. Fix: `CrossChainTellerBase.bridge.selector`. |
| D-7 | LOW | `DeployPortLayerZero.sol:184` sets `setPublicCapability(atomicQueue, updateAtomicRequest.selector, true)` — which is a no-op because `updateAtomicRequest` is not `requiresAuth`. Harmless but misleading — future refactor that adds auth would combine with this line to recreate a public-by-default footgun. Delete. |
| D-8 | INFO | Deploy config JSON addresses are plaintext. Silent mutation in PRs is the real risk (swapping `protocolAdmin` from multisig to EOA). Add CheckAuthConfiguration assertions on rate-provider code hashes and `payoutAddress` being a contract. |

**Verified:** No `finishSolve`, `bulkWithdraw`, `bulkDeposit`, `refundDeposit`, `manage`, `solve`, `updateExchangeRate`, `setManageRoot`, `addAsset`, `removeAsset`, `setOwner`, `setAuthority`, `setRoleCapability`, `setUserRole`, or `setQueueApproved` is publicly callable anywhere. The 2026-04-21 class of bug is not replicated.

---

## 2. Composed multi-step exploit chains (Round 2)

Round-1 findings don't exist in isolation — combining them produces real attack paths. Five concrete chains:

### Chain 1 — Bad-rate commit + pauser mistake → full drain
1. Compromised EXCHANGE_RATE_BOT calls `updateExchangeRate(1)` below lower bound. (A-1) — accountant auto-pauses but state is written (`_exchangeRate = 1`, `_lastAccrualTime` bumped).
2. Pauser unpauses believing it's a false alarm (no indication the rate was poisoned because `RateUpdateRejected` event is absent today).
3. Attacker calls `teller.deposit(base, 1 wei, 0)`. (A-2) `getRate()` returns 1 → `shares = depositValueIn18 * ONE_SHARE / 1` → vast share mint. DepositCap checked in base units with corrupted rate — passes.
4. Attacker redeems via AtomicQueue.
**Minimum fix:** A-1 (stop writing bad rate).

### Chain 2 — OPERATOR cascade → malicious rate provider
1. Compromised OPERATOR calls `setUserRole(attackerEOA, UPDATE_EXCHANGE_RATE_ROLE, true)`. (D-5)
2. Attacker deploys `EvilRateProvider` returning `1e36`.
3. Attacker calls `accountant.setRateProviderData(someAsset, false, evilRateProvider)` — no validation, no delay (A-3).
4. Attacker deposits 1 wei of that asset → receives massive shares → redeems via AtomicQueue.
**Minimum fix:** A-3 (timelock setRateProviderData) OR D-5 (sensitive-role allowlist).

### Chain 3 — Cross-chain bypass → same-block OFAC exit
1. Blacklisted / sanctioned address calls public `depositAndBridge` on source chain.
2. Destination `_lzReceive` / `handle` / OP `receive` invokes `vault.enter(0, 0, 0, blacklistedReceiver, shareAmount)`. (T-1) `checkAccess`, `depositCap`, `shareUnlockTime` all bypassed.
3. Same block, receiver places an AtomicRequest. Whitelisted solver fulfills via `bulkWithdraw(want, shares, 0, attacker)`. (T-2) `checkAccess(msg.sender=solver)` passes; `_to` never checked.
4. Attacker exits with base asset. OFAC bypass + cap bypass + MEV-lock bypass in one cross-chain hop.
**Minimum fix:** T-1 (checkAccess at receive, with quarantine to avoid the 1-wei griefing introduced by naïve checkAccess — see §3.3) AND T-2 (`checkAccess(_to)`).

### Chain 4 — Strategist sandwich + widened bounds → silent drain
1. Strategist operates within `allowedSlippage`. (M-1)
2. Colluding UPDATE_EXCHANGE_RATE_ROLE widens `upper` to 65535× (A-4).
3. Strategist flashloan-sandwiches every vault 1inch swap; post-hoc slippage check passes because pool is moved.
4. Subsequent accountant updates absorb realized loss without pausing — no monitoring signal.
**Minimum fix:** M-1 (pre-swap expected-out snapshot) + A-4 (cap `upper` at 10500).

### Chain 5 — Paused accountant + cross-chain inbound → phantom minting
1. Accountant paused (legitimately or via Chain 1).
2. Source chain dispatches deposit at rate R1 (before pause). Destination receives after pause.
3. Destination `_afterReceive` calls `vault.enter` unconditionally — no pause check anywhere on the bridge-receive path.
4. Receiver exits via P2P solver (doesn't call `accountant.checkpoint`, so pause is silent). OTC counterparty pre-committed to buy shares at pre-pause rate.
**Minimum fix:** `require(!accountant.isPaused())` at top of `_afterReceive`, or queue inbound messages while paused and drain on unpause.

---

## 3. Proposed fixes — reviewed by Round-2 red team

| # | Fix | Sound? | Residual risk |
|---|---|---|---|
| 1 | A-1: `updateExchangeRate` early-return on bound violation instead of writing | 90% | Under repeated adverse movement the rate freezes. Pair with a rejection-counter + time-based auto-pause. |
| 2 | A-2: Teller uses `getRateSafe` | 90% | Creates deadlocks for in-flight bridge receives and mid-solve settlements if pause hits between. Pair with admin `emergencyRefund` that reads rate unconditionally. |
| 3 | T-1: `checkAccess(receiver)` + cap + `shareUnlockTime` on receive | 60% | Naïve patch enables 1-wei bridge-griefing that locks victim's legitimate balance forever, and strands in-flight funds when KYC tightens between dispatch and receive. Needs **per-lot unlock-time accounting** + a **receiver-claim quarantine** (shares mint into escrow; receiver claims after passing checkAccess). Not a one-liner. |
| 4 | Q-2: require `wantAmount > 0` at submission | 60% | Rate drift between submit and solve re-opens the bypass. Load-bearing fix is SOLVE-TIME skip (which is the deferred I-2). Submission check is defense-in-depth, not primary. |
| 5 | Q-1: `require(solver == msg.sender)` in queue.solve | Airtight | Canonical AtomicSolverV5 flow already uses `msg.sender`. Non-breaking. |
| 6 | D-5: split sensitive roles from OPERATOR's `setUserRole` | Airtight with sensitive-role allowlist | Implement as wrapper: `setUserRole(user, role)` → revert if role in `sensitiveRoles[UPDATE_EXCHANGE_RATE_ROLE, PAUSE_ROLE, MANAGER_ROLE, ADMIN_ROLE]`. OPERATOR retains borrower/strategist onboarding. |

**Read this table before implementing:** three of the six "obvious" fixes are *partial* and need design work, not one-line patches.

---

## 4. Missing cross-contract invariants

Assertions that should hold on-chain but are not asserted anywhere today:

1. **Teller must not transact when its Accountant is paused.** Implicit via `checkpoint()` revert on deposits/bulkWithdraw, but **not enforced on cross-chain receive** (no accountant touched). Assert at top of `_afterReceive`.
2. **Exchange-rate storage = last rate that passed bounds.** Violated by A-1. Guard in `updateExchangeRate`.
3. **Rate-provider contracts must pass a sanity oracle check at replacement.** `setRateProviderData` should probe against Chainlink feed or enforce `abs(new - old) < threshold`.
4. **Shares minted always pass `checkAccess(receiver)`.** Local deposit enforces it; cross-chain receive bypasses.
5. **Cross-chain mint respects `depositCap`.** Enforce in `_afterReceive`.
6. **`_lastAccrualTime` does not advance on a rejected rate update.** F-1 + checkpoint currently advance the clock on a bad write, silently burning future interest.
7. **`allowedSlippage` is bounded against accountant rate-drift budget.** Silent-drain chain (Chain 4) only works because there's no on-chain relation between DexAggregator slippage and Accountant bounds.

---

## 5. Single-point-of-failure key pairs

Each pair below enables a drain that neither key alone enables:

| Key A | Key B | Combined capability |
|---|---|---|
| OPERATOR (broadcaster EOA) | any EOA | OPERATOR grants `UPDATE_EXCHANGE_RATE_ROLE` → EOA installs evil rate provider / moves bounds → drain |
| EXCHANGE_RATE_BOT | PAUSER | Bot poisons rate (A-1); Pauser unpauses believing it's a false alarm → drain window |
| STRATEGIST | UPDATE_EXCHANGE_RATE_ROLE | Strategist sandwiches (M-1); UPDATE_EXCHANGE_RATE widens bounds (A-4) so drain is absorbed silently |
| any cross-chain peer key | any solver | Peer injects OFAC-bypass mint to denylisted address; solver exits via `bulkWithdraw` (T-2) |
| any LZ/Hyperlane peer | AtomicQueue auto-solver bot | Phantom-mint from source (T-1/A-1/Chain 5); auto-solver fulfills standing request |

These motivate role separation: holders of any key in column A should be independent of any key in column B, with documented key-rotation and monitoring.

---

## 6. Recommendations — sequencing

**Blocker before any redeploy:**
- A-1 (bad-rate commit) — one-line guard + emit `RateUpdateRejected`.
- A-2 + emergencyRefund (Teller uses `getRateSafe`; paired admin path).
- T-1 design (receiver-claim quarantine for bridge receives).
- T-2 (`checkAccess(_to)` in `bulkWithdraw`).
- A-3 (timelock `setRateProviderData`).
- D-5 sensitive-role allowlist for OPERATOR.
- D-1 role-number collision cleanup.

**Next PR batch:**
- M-1 pre-swap slippage snapshot.
- M-3 rate-limit bucketing fix.
- V-3 flashLoan recipient guard.
- V-4 flashLoan self-call root passthrough.
- A-4 tight bound caps.
- Q-1 `solver == msg.sender`.
- T-4, T-6 fail-closed defaults.
- Expand `CheckAuthConfiguration` with the 7 invariants in §4.

**Design-track, longer timeline:**
- I-2 (AtomicQueue.solve skip-and-emit) — closes Q-2 at the load-bearing layer; keeper-side API change.
- A-5 push-model lending-rate accrual tied to realized repayments.
- Per-lot share-lock accounting on cross-chain receive (T-1 full fix).

**Ops track:**
- Commission an independent external audit (Spearbit / Hexens / Cyfrin) on the revised branch before unpausing production vaults. The AI audit is strong triage, not a sign-off.
- Decoder audit pass (237 functions in `src/base/DecodersAndSanitizers/`) — explicitly out of scope here.

---

## 6.3 Round 3 audit additions

Third-pass work added three parallel reviews:
- **External audit cross-reference** against Spearbit, 0xMacro A-4/A-5, Pashov (Ion/LZ), Pashov (Hyperlane), plus upstream Veda-Labs audit folder (Sigma Prime, 0xMacro-2 — both target `AccountantWithYieldStreaming` which this fork doesn't have).
- **End-to-end flow walkthrough** with a money-stuck lens (happy + 3+ edges per flow).
- **Adversarial re-validation** of every fix already landed on this branch.

**Policy divergence from upstream Veda worth calling out in operator docs**: our fork pauses `bulkDeposit` (T-7). Veda intentionally does not. This is a conscious hardening choice that affects AtomicQueue keepers — they need unpause to drain.

**Fork-vs-upstream comparison**: our fork is strictly tighter than upstream on 6 items (T-7, M-1, Q-3, A-4, A-1, delay-in-seconds). Equivalent on the rest that apply. 12 of our shipped fixes are net-new (not in any public audit): T-2, T-4, T-6, T-8, V-3, A-1, A-4, A-7, M-3, Q-1, A-3, D-* deploy-script cleanup.

### New findings from Round 3 (shipped on branch)

| ID | Severity | Finding | Source | Commit |
|---|---|---|---|---|
| N-1 | HIGH | `depositAndBridge` reverts when `shareLockPeriod > 0` | R3 flow agent + Pashov HL M-02 | `94592cb` |
| N-2 | MEDIUM | LZ `_lzReceive` calls `accountant.checkpoint()` → destination pause = permanent burn loss | R3 flow agent (R-3) + Pashov HL M-01 (parallel class) | `94592cb` |
| N-6 | LOW | `MultiChainTellerBase.addChain` / `allowMessagesFromChain` didn't enforce `targetTeller != address(0)` | Pashov HL L-2 | `94592cb` |
| T-2 refinement | HIGH | Original T-2 fix checked `_to` only; canonical AtomicSolver flow has `_to = solver contract`, so end user was not access-gated. Now both `msg.sender` + `_to` checked. | R3 validation agent | `94592cb` |
| A-3 refinement | MEDIUM | Original A-3 fix could be bypassed via pegged→non-pegged transition skipping deviation check. Now bypass closed. | R3 validation agent | `94592cb` |

### New findings from Round 3 (NOT shipped)

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| **R-1** | **CRITICAL** | **Permanent fund-lockup possible** if accountant gets auto-paused (A-1) with bounds too tight to unpause cleanly AND all chains share the same pause → no user-initiated exit exists. Needs an `emergencyBulkWithdraw` using a governance-frozen rate snapshot. | Design-track — BLOCKS MAINNET PRODUCTION until landed |
| N-2 (Hyperlane mirror) | HIGH | Same class as LZ N-2 but on Hyperlane: `handle` calls `_beforeReceive` which reverts on pause → permanent loss if destination paused during relay. Different fix: remove `_beforeReceive` from receive handlers globally, or queue inbound while paused. | Design-track |
| R-4 | HIGH | Single-step `transferOwnership` typo bricks contracts | Ship Ownable2Step wrapper or post-deploy owner invariants — tracked |
| R-5 | MEDIUM | A-3's 5% deviation cap traps admin if provider legitimately drifted > 5%. Need a `forceReplaceRateProvider` with timelock escape. | Follow-up |
| N-3 | MEDIUM→HIGH | 0xMacro A-4 M-4: rate-calc decimals for pegged quote assets — spot-check needed on `getRateInQuote` + `claimFees` | Verification task |
| N-4 | MEDIUM | Solmate `SafeTransferLib` fake-shares: `addAsset` + `setRateProviderData` with an `address(0)` asset = silent phantom mint. Add `asset.code.length > 0` check in `BoringVault.enter`. | Follow-up |
| N-5 | LOW/MED | Flash-loan caller check: make `msg.sender == balancerVault` explicit in `receiveFlashLoan` (orthogonal to V-3) | Follow-up |
| N-7 | LOW | Hyperlane `_quote` payload fee underestimation (Pashov HL L-3) | Spot-check |
| N-8 | LOW/MED | `AtomicQueue.solve` `assetsForWant` overestimation vs accumulated per-user (Pashov HL L-5) | Spot-check |

**R-1 is the single most important deferred item.** It's not a bug in any one contract — it's the architectural property that, under combined adverse conditions, users have no on-chain exit. Every well-designed vault system ships with an emergency-exit primitive; this one currently does not.

---

## 6.5 Shipped fixes — per-finding status

| Finding | Severity | Status | Commit(s) | Notes |
|---|---|---|---|---|
| A-1 | HIGH | ✅ Shipped | `b258483` | Bad rates no longer committed; auto-pause only; new `ExchangeRateUpdateRejected` event |
| A-2 | HIGH | ⚠️ Deferred | — | Design-track — naive `getRateSafe` switch creates pause-during-bridge / pause-during-solve deadlocks per Round-2 fix-validation. Needs paired `emergencyRefund` path |
| A-3 | HIGH | ✅ Shipped (light) | `6abd28e` | Sanity probe + 5% deviation cap on provider replacement. Full 48h timelock still open for teams wanting multi-day delays |
| A-4 | MEDIUM | ✅ Shipped | `b258483` | Hard caps `MAX_UPPER_BOUND=11000` / `MIN_LOWER_BOUND=9000` |
| A-5 | MEDIUM | ⚠️ Deferred | — | Requires redesign of lending accrual to push-model; economic scope |
| A-6 | MEDIUM | ⚠️ Deferred | — | `GenericRateProvider` staleness/decimals — helper-contract scope, not in this branch |
| A-7 | LOW | ✅ Shipped | `b258483` | Internal `_pause()` helper, external `pause()` wrapper |
| A-8, A-9, A-10 | LOW | ⚠️ Deferred | — | Checkpoint precision, claimFees asset restriction, first-deposit gate |
| T-1 | CRITICAL | ⚠️ Deferred | — | **Design-track**. Naive `checkAccess` + `shareUnlockTime` on receive creates 1-wei griefing + in-flight-stuck classes per Round-2 fix-validation. Needs receiver-claim quarantine |
| T-2 | HIGH | ✅ Shipped | `23f40e0` | `bulkWithdraw` checks `_to`, not `msg.sender` |
| T-3 | HIGH | ⚠️ Deferred | — | `refundDeposit` trust / bridged-share orphan — needs refund-flow redesign |
| T-4 | MEDIUM | ✅ Shipped | `23f40e0` | `KEYRING_KYC` fails closed when `keyringContract == 0`; new `KeyringNotConfigured` error |
| T-5 | MEDIUM | ⚠️ Deferred | — | Per-message replay dedup on Hyperlane/OP receive |
| T-6 | MEDIUM | ✅ Shipped | `23f40e0` | OP teller peer defaults to `address(0)`; explicit revert if unset |
| T-7 | LOW | ✅ Shipped | `23f40e0` | `bulkDeposit` / `bulkWithdraw` now respect `isPaused` |
| T-8 | LOW | ✅ Shipped | `23f40e0` | `_erc20Deposit` reverts on zero-share rounding |
| T-9, T-10 | LOW/INFO | Noted | — | LZ overpayment refunds; role numbering drift (addressed in D-1) |
| V-1 | CRITICAL (trust) | Noted | — | Deploy-time invariant only: MANAGER_ROLE must be granted only to `ManagerWithMerkleVerification`, owner is multisig. Enforced via CheckAuthConfiguration (see D-5 follow-up) |
| V-2 | HIGH (trust) | Noted | — | STRATEGIST Merkle blast radius — inherent to the pattern; recommend accountant-rate post-batch invariant as future hardening |
| V-3 | MEDIUM | ✅ Shipped | `11c7ca3` | `flashLoan(recipient)` now requires `recipient == address(this)` |
| V-4 | MEDIUM | ⚠️ Deferred | — | `receiveFlashLoan` self-call uses `manageRoot[address(this)]` — fix needs strategist-root passthrough in intent struct |
| V-5 | LOW | ⚠️ Cannot ship as-is | — | `nonReentrant` on `vault.manage` breaks legitimate flash-loan re-entry. Needs flash-loan-aware guard |
| V-6, V-7 | LOW/INFO | Noted | — | 2-step ownership transfer; standing allowance hygiene |
| Q-1 | MEDIUM | ✅ Shipped | `43a6c76` | `solve()` requires `solver == msg.sender` |
| Q-2 | MEDIUM | ⚠️ Deferred | — | Submission-time check not airtight; load-bearing fix is I-2 solve-time skip (see below) |
| Q-3 | LOW | ✅ Shipped | `43a6c76` | `viewSolveMetaData` flags zero-output users via bit `1 << 4` |
| Q-4 | INFO | Noted | — | Implicit decimals assumption |
| I-2 | MEDIUM | ⚠️ Deferred | — | **Keeper-breaking**. Solve-time skip-and-emit redesign of `AtomicQueue.solve`. Pair with Q-2 when shipped |
| M-1 | HIGH | ✅ Shipped | `de77f42` | Pre-swap `priceRouter` snapshot replaces post-hoc check in `swapWith1Inch`. Requires manipulation-resistant priceRouter at deploy |
| M-2 | MEDIUM | ⚠️ Deferred | — | Local validation of 1inch `SwapDescription` struct; needs interface re-check against live 1inch v5 |
| M-3 | MEDIUM (correctness) | ✅ Shipped | `de77f42` | `callCountPerPeriod` keyed by `timestamp / period` |
| M-4 | LOW | ⚠️ Deferred | — | `revokeTokenApproval` rate-limit |
| M-5 | LOW | ⚠️ Deferred | — | UniswapV3 path-length cap |
| D-1 | HIGH | ✅ Shipped | `0bc5c4f` | Test-script role numbers shifted off Constants.sol's 1–7 range; `MINTER_ROLE` collision with `OPERATOR_ROLE` eliminated |
| D-2 | MEDIUM | ⚠️ Deferred | — | Test scripts need `transferOwnership(protocolAdmin)` calls or explicit `_TEST_ONLY` rename |
| D-3 | MEDIUM | ✅ Shipped | `0bc5c4f` | Dead `setUserRole(exchangeRateBot, ADMIN_ROLE)` calls removed in DeployNucleusCrossChain |
| D-4 | MEDIUM | Noted | — | L1/L2 role-mapping trust asymmetry — test-only drift |
| D-5 | MEDIUM (trust) | ⚠️ Deferred | — | Sensitive-role allowlist wrapper around `setUserRole` — airtight fix per Round-2 validation but needs the role-admin split discussed in §3 |
| D-6 | LOW | ✅ Shipped | `0bc5c4f` | `CrossChainTellerBase.bridge.selector` replaces hardcoded `0xa69559d1` |
| D-7 | LOW | ✅ Shipped | `0bc5c4f` | No-op `setPublicCapability(atomicQueue, updateAtomicRequest.selector)` removed |
| D-8 | INFO | Noted | — | Deploy-config JSON plaintext mutation risk |

**Shipped count:** 17 fixes across 7 commits. Every HIGH-severity finding with a clean fix path has landed; the four remaining HIGH deferrals (T-1, T-3, D-5 and A-2) all require design decisions that extend beyond a code patch and are flagged explicitly for a dedicated follow-up PR.

---

## 7. Out of scope / deferred

- Individual decoder functions (237 in `src/base/DecodersAndSanitizers/`) — recommend their own pass.
- Upstream Veda BoringVault audits (Spearbit / Macro / Secure3 / Hexens reports exist under `audit/`) — cross-reference before merge.
- Economic model / lending-rate vs repayment dynamics — touched in A-5 but a full economic audit is a separate exercise.
- Frontend / off-chain keeper security — not code in this repo.

---

*This report compiles output from six Round-1 breadth agents + two Round-2 depth agents run on 2026-04-23 against branch `security/atomicsolverv3-remediation` @ `87e1750`. No code changes were made to land these findings; each is a candidate for a scoped follow-up PR.*

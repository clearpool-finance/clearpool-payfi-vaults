# AtomicSolverV3 — Hack Report Validation & Remediation Plan

**Source report:** `hack-report.md.pdf` (2026-04-21, adversarial AI audit)
**Target contract:** `src/atomic-queue/AtomicSolverV3.sol` (pragma 0.8.22)
**Reviewed commit:** `54b670d` (post `e137ca9` "Finish solve must be private")
**Status of findings:** All 12 findings validated against source. See per-finding table.

---

## 1. Validation summary

| ID  | Severity | Title                                                                 | Line(s) in src | Valid? | Currently patched? |
|-----|----------|-----------------------------------------------------------------------|----------------|--------|--------------------|
| C-1 | CRITICAL | Direct `finishSolve` call drains pre-approvals                         | 101–123        | ✅ Yes | ⚠️ Partial (config-only, see §3.1) |
| H-1 | HIGH     | Missing `nonReentrant` contradicts NatSpec (ERC777 reentrancy)         | 52, 73, 94–99  | ✅ Yes | ❌ No              |
| H-2 | HIGH     | `safeApprove` without zero-reset breaks permanently on USDT            | 160, 194       | ✅ Yes | ❌ No              |
| H-3 | HIGH     | Fee-on-transfer `want` → approval overcommits contract balance         | 151+160, 188+194 | ✅ Yes | ❌ No              |
| M-1 | MEDIUM   | CEI violation in `_redeemSolve` (`bulkWithdraw` before `safeTransferFrom`) | 188 vs 191  | ✅ Yes | ❌ No              |
| M-2 | MEDIUM   | Authority misconfig is single point of failure                         | —              | ✅ Yes | ⚠️ Partial (see §3.1) |
| M-3 | MEDIUM   | Zero-address owner not guarded in constructor                          | 45             | ✅ Yes | ❌ No              |
| M-4 | MEDIUM   | `wantApprovalAmount` unbounded vs `bulkWithdraw` proceeds              | 185–188        | ✅ Yes | ❌ No              |
| L-1 | LOW      | Unused `eETH` / `weETH` constants                                       | 19–20          | ✅ Yes | ❌ No              |
| L-2 | LOW      | `AlreadyInSolveContext` error declared but never emitted                | 37             | ✅ Yes | ❌ No              |
| I-1 | INFO     | No token recovery mechanism                                             | —              | ✅ Yes | ❌ No              |
| I-2 | INFO     | Batch failure isolation depends on `AtomicQueue`                        | —              | ✅ Yes (queue hard-reverts on any user)| ❌ No |

All line numbers refer to `src/atomic-queue/AtomicSolverV3.sol`; the report's `sc.sol` numbering is ~3 off (the report appears to have been generated against a stripped copy without the license header).

---

## 2. What the team already shipped (`e137ca9` — "Finish solve must be private")

The commit **did not modify the contract**. It only changed deployment/authority wiring:

- `script/ConfigureAtomicRoles.s.sol`: replaced `authority.setPublicCapability(atomicSolver, finishSolve.selector, true)` with `authority.setRoleCapability(QUEUE_ROLE, atomicSolver, finishSolve.selector, true)`.
- `script/deploy/single/06_DeployRolesAuthority.s.sol`: granted `OPERATOR_ROLE` the ability to call `setRoleCapability` / `setUserRole` on `rolesAuthority`, and added `UPDATE_EXCHANGE_RATE_ROLE` + `PAUSER_ROLE` to `config.operator`.
- `script/CheckAuthConfiguration.s.sol` + `test/AtomicSolverAuthRegression.t.sol`: new regression that encodes the exact exploit calldata (`runData = (P2P, victim, 0, max)`, direct `finishSolve` by a non-queue EOA) and asserts it **reverts** with `UNAUTHORIZED`.

### Why this fixes C-1 (narrowly)

Before: `setPublicCapability(atomicSolver, finishSolve.selector, true)` meant `requiresAuth` let *anybody* call `finishSolve`. The attacker then trivially bypassed the one in-contract check by supplying `initiator = address(atomicSolverV3)` in calldata.

After: `finishSolve` is reachable only by addresses holding `QUEUE_ROLE`. Only `config.atomicQueue` holds that role, and `AtomicQueue.solve()` only calls back into the solver it was invoked from — which it only gets to via `p2pSolve` / `redeemSolve`, both of which are themselves `requiresAuth`-gated to trusted solver bots.

### Why this fix is **not sufficient on its own**

It closes the specific exploit path *but leaves the contract dependent on a correct off-chain authority config*. Any future misconfiguration — a second queue accidentally granted `QUEUE_ROLE`, a wildcard role, a compromised `ConfigureAtomicRoles` script — re-opens the drain. There is **no in-contract invariant** asserting "finishSolve can only run inside an active solve()". That is what M-2 calls out, and that is what the dead `AlreadyInSolveContext` error (L-2) was *supposed* to guard. Treat the current fix as a hotfix and schedule §3.1 as the real remediation.

---

## 3. Remediation plan

Severity-ordered. Each entry states the bug, the fix, *why* the fix works, and notes.

### 3.1. [C-1 / M-2 / L-2] Add in-contract solve-context lock (defense-in-depth)

**Bug.** `finishSolve` has no on-chain proof it was reached via a legitimate `p2pSolve` → `queue.solve()` → `queue.finishSolve()` callback. Security rests entirely on authority wiring.

**Fix (with current pragma 0.8.22 / EVM shanghai).** Add a 1-slot reentrancy/context lock and an `ALREADY_SET` check around the outer solve functions; require it to be *set* in `finishSolve`. This activates the already-declared `AlreadyInSolveContext` error (L-2 gone for free).

```solidity
// new storage — place next to other state
uint256 private _inSolveContext; // 0 = idle, 1 = inside a solve

error AtomicSolverV3___NotInSolveContext();

modifier inSolveContext() {
    require(_inSolveContext == 0, AtomicSolverV3___AlreadyInSolveContext());
    _inSolveContext = 1;
    _;
    _inSolveContext = 0;
}

function p2pSolve(...) external requiresAuth inSolveContext { ... }
function redeemSolve(...) external requiresAuth inSolveContext { ... }

function finishSolve(...) external requiresAuth {
    if (_inSolveContext != 1) revert AtomicSolverV3___NotInSolveContext();
    if (initiator != address(this)) revert AtomicSolverV3___WrongInitiator();
    ...
}
```

**Why it works.** `finishSolve` can now only succeed while a solve is in flight. Even if the authority ever grants `finishSolve` to an attacker role, they still cannot call `finishSolve` *directly* — `_inSolveContext == 0` outside a solve. The only way to reach the body is through `p2pSolve`/`redeemSolve` → `queue.solve()` → callback, which is the intended path.

**Gas optimisation (recommended).** If upgrading to Solidity 0.8.24+ and `evm_version = cancun` is on the table, switch to transient storage (EIP-1153):

```solidity
uint256 transient _inSolveContext;
```

Transient slots are written by `tstore` and cleared at tx end, so the refund is immediate and there is no 20k/5k cold/warm SSTORE cost. With 0.8.22 + shanghai you pay one `SSTORE 1` + one `SSTORE 0` per solve; the `SSTORE 0` refund ≈ 4.8k gas, so net overhead is roughly 17k per call — acceptable. If that is not acceptable, upgrade the toolchain.

**Why not just "trust the Authority".** (M-2.) Auth contracts in this codebase are mutable by `OPERATOR_ROLE`, which this very commit just expanded. Defense-in-depth in the callee is the standard mitigation for any "privileged callback" pattern — see solmate's own `Auth` docs, the Compound Comet `allowFrom` pattern, and the Seaport/Conduit flow that originally inspired this design.

### 3.2. [H-1] Add `nonReentrant` to `p2pSolve` and `redeemSolve`

**Bug.** NatSpec on `finishSolve` (lines 94–99) says *"nonReentrant is not needed because the above solve functions have the nonReentrant modifier"* — but neither `p2pSolve` nor `redeemSolve` actually has it. With ERC777-style tokens whose `transfer*` hooks can call back into the solver (or with ERC-4626 rebasing shares that call their asset), an attacker-aligned token can re-enter the solver mid-flow and corrupt `want`/`offer` accounting across users in the batch.

**Fix.**

```solidity
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";

contract AtomicSolverV3 is IAtomicSolver, Auth, ReentrancyGuard { ... }

function p2pSolve(...) external requiresAuth inSolveContext nonReentrant { ... }
function redeemSolve(...) external requiresAuth inSolveContext nonReentrant { ... }
```

…and delete the NatSpec block that made the false claim.

**Why it works.** Solmate's `ReentrancyGuard` uses a dedicated 1-slot `locked` flag with the same lifecycle as our context lock. The two guards are cheap when combined (two SSTOREs, both refunded). The lock covers the case where the *same* token is both `offer` and `want`, or where a maliciously-crafted rate provider triggers a callback inside `bulkWithdraw`.

**Note.** `inSolveContext` from 3.1 already prevents reentry into `finishSolve`, but `nonReentrant` is still needed on the outer functions because the reentry surface also includes the ERC20 `transfer`/`transferFrom`/`approve` calls themselves (ERC777 hooks run *before* state clearing).

### 3.3. [H-2] `safeApprove` without zero-reset → USDT permanent DoS

**Bug.** Solmate's `SafeTransferLib.safeApprove` (line 97 of `SafeTransferLib.sol`) calls the token's `approve(spender, amount)` directly with no prior zero-reset. USDT's non-standard `approve` reverts when `allowance(owner, spender) > 0 && amount > 0`. Any solve that leaves residual allowance (a partial queue fill, a revert after approve, a token upgrade) bricks every subsequent USDT solve until the contract is redeployed.

**Fix.** Reset to zero before every non-zero approve. Apply in both `_p2pSolve` (after line 154) and `_redeemSolve` (after line 191):

```solidity
// p2pSolve
want.safeTransferFrom(solver, address(this), wantApprovalAmount);
offer.safeTransfer(solver, offerReceived);
want.safeApprove(queue, 0);                     // NEW — USDT compatibility
want.safeApprove(queue, wantApprovalAmount);

// redeemSolve
teller.bulkWithdraw(want, offerReceived, minimumAssetsOut, solver);
want.safeTransferFrom(solver, address(this), wantApprovalAmount);
want.safeApprove(queue, 0);                     // NEW
want.safeApprove(queue, wantApprovalAmount);
```

**Why it works.** `approve(spender, 0)` unconditionally succeeds on USDT regardless of prior allowance, so the subsequent `approve(spender, X)` always begins from a zero baseline.

**Alternative.** If moving to OpenZeppelin's `SafeERC20`, use `forceApprove` instead — it performs the zero-reset internally and is the canonical pattern post-2022. Do not mix the two libraries.

### 3.4. [H-3] Fee-on-transfer `want` token → approval overcommit

**Bug.** In `_p2pSolve`, line 154 pulls `wantApprovalAmount` from the solver but FoT tokens (PAXG, some rebase forks) debit a fee, so the contract only holds `wantApprovalAmount - fee`. Line 160 then approves the queue for the **gross** amount. The queue's batched `transferFrom` will attempt to pull more than the contract holds, reverting — and because batches are not isolated (I-2), this griefs every user past the shortfall point.

**Fix.** Reconcile with the actual received balance:

```solidity
uint256 balBefore = want.balanceOf(address(this));
want.safeTransferFrom(solver, address(this), wantApprovalAmount);
uint256 actual = want.balanceOf(address(this)) - balBefore;
// ... existing offer.safeTransfer ...
want.safeApprove(queue, 0);
want.safeApprove(queue, actual);
```

Apply the same pattern in `_redeemSolve`.

**Why it works.** The approval now reflects ground truth. If the queue requires exactly `wantApprovalAmount` and the FoT fee leaves us short, the queue-side `transferFrom` reverts cleanly for that batch — which is better than a partial settlement that silently underpays users.

**Caveat.** If the queue's downstream logic hard-asserts `allowance == wantApprovalAmount`, the solver must pad the pull by `ceil(wantApprovalAmount / (1 - feeBps))` before approving. Verify against `AtomicQueue._transferFrom` behaviour before shipping. A simpler policy: explicitly disallow FoT `want` tokens at config time (the Teller already maintains an asset allowlist).

### 3.5. [M-1] CEI violation in `_redeemSolve`

**Bug.** Line 188 calls `teller.bulkWithdraw(...)` (external) before line 191's `safeTransferFrom(solver, this, ...)`. If the teller is ever upgraded to a malicious or buggy implementation it can reenter the solver before state settles. Current teller is trusted, but the ordering is fragile.

**Fix.** Pull the solver's contribution first, then do the bulk withdrawal:

```solidity
// _redeemSolve, reordered
want.safeTransferFrom(solver, address(this), wantApprovalAmount);  // EFFECT on solver
teller.bulkWithdraw(want, offerReceived, minimumAssetsOut, solver);  // EXTERNAL
want.safeApprove(queue, 0);
want.safeApprove(queue, wantApprovalAmount);
```

**Why it works.** Classic CEI: finish all balance changes the solver is responsible for before handing control to an external contract. Combined with `nonReentrant` (3.2), the teller callback cannot touch any state that hasn't already been written.

**Note.** `bulkWithdraw` still sends proceeds to `solver` rather than `address(this)`; that is the protocol design and stays unchanged. The reorder only moves *our* pull earlier.

### 3.6. [M-3] Guard zero-address owner

**Fix.** Two lines in the constructor:

```solidity
constructor(address _owner, Authority _authority) Auth(_owner, _authority) {
    require(_owner != address(0), "AtomicSolverV3: zero owner");
}
```

**Why.** Solmate's `Auth` does not validate `_owner`; deploying with `address(0)` permanently bricks `setOwner` / `setAuthority` because only the current owner can change them and `address(0)` cannot sign. Cheap insurance against a typo in a deployment config.

### 3.7. [M-4] Assert `bulkWithdraw` proceeds cover `wantApprovalAmount`

**Bug.** A price sandwich around the teller's exchange rate can make `bulkWithdraw` return less than the queue demanded, leaving the solver underwater on every solve they run until the next rate update. Today the failure is implicit (some later token op runs out of balance); it should be explicit.

**Fix.** `teller.bulkWithdraw` returns `assetsOut`. Capture it and assert:

```solidity
uint256 assetsReceived = teller.bulkWithdraw(want, offerReceived, minimumAssetsOut, solver);
if (wantApprovalAmount > assetsReceived) {
    revert AtomicSolverV3___SolveMaxAssetsExceeded(wantApprovalAmount, assetsReceived);
}
```

(Reusing the existing error is fine; alternatively add `AtomicSolverV3___RedeemProceedsShortfall`.)

**Why.** The solver should fail *loud and early* — before the downstream `approve`/`transferFrom` leaves dangling allowance. Pairs naturally with the existing `minimumAssetsOut` check inside `bulkWithdraw`: that check guards the *solver's* slippage; this check guards the *users'* fill quality.

### 3.8. [L-1] Remove unused `eETH` / `weETH` constants

**Fix.** Delete lines 19–20. They are hardcoded mainnet addresses that also make the contract look mainnet-specific on block explorers, which is misleading on Plume/Arb/etc.

### 3.9. [L-2] Resolved automatically by 3.1

The `AlreadyInSolveContext` error on line 37 becomes live inside the `inSolveContext` modifier added in §3.1. No further action.

### 3.10. [I-1] Add restricted token rescue

**Fix.**

```solidity
function rescue(ERC20 token, uint256 amount, address to) external requiresAuth {
    require(to != address(0), "zero to");
    token.safeTransfer(to, amount);
}
```

**Why.** Stuck tokens (wrong-chain airdrops, leftover dust, buggy FoT rounding) need a way out without a contract migration. Gated by `requiresAuth` so only the owner role can call. **Do not** add an unrestricted rescue — that re-introduces the C-1 class of bug. Consider emitting an event for off-chain monitoring.

**Audit note.** Some auditors prefer a timelock on rescue, on the grounds that it can also be abused to pull user allowances. Since this solver holds only its own transient inventory (not user funds directly — users approve the *queue*, not the solver), a timelock is overkill here. Document the risk model.

### 3.11. [I-2] Batch failure isolation

**Bug.** `AtomicQueue` hard-reverts on the first failing user in a batch (lines 231–233, 265, 270 of `AtomicQueue.sol`). A single user's expired request, zero-offer, revoked allowance, or FoT shortfall griefs every user behind them.

**Fix (queue-side, not solver-side).** Wrap the per-user body in a `try`/`catch` pattern or skip-and-emit:

```solidity
// AtomicQueue.sol, inside the solve loop
for (uint256 i; i < users.length; ++i) {
    AtomicRequest storage request = userAtomicRequest[users[i]][offer][want];
    if (request.inSolve) { emit UserSkipped(users[i], "repeated"); continue; }
    if (block.timestamp > request.deadline) { emit UserSkipped(users[i], "deadline"); continue; }
    if (request.offerAmount == 0) { emit UserSkipped(users[i], "zero"); continue; }
    // ... existing happy path
}
```

**Why.** Skipping is strictly better than reverting for batch-style settlement: the solver still wants to serve the other 99 users in the batch, and the misbehaving user's request remains in the queue to be retried or cleaned up. Mirrors Gnosis Safe's `MultiSend` semantics (which does revert) vs. 0x's `RFQ batch fill` (which skips) — use the latter here.

**Caveat.** This is a breaking change for off-chain keepers who rely on all-or-nothing batch semantics. Stage it behind a `strict` flag or ship a V2 queue.

---

## 4. Shipping order (suggested)

1. **Now (blocking):** 3.1 + 3.2 + 3.3 + 3.4 + 3.5. Pack into one new solver (AtomicSolverV4) and migrate the QUEUE_ROLE off the old one. These are the only five that have an *exploitable* or *DoS* path.
2. **Next deploy:** 3.6, 3.7, 3.10, 3.8, 3.9. Polish and operational hygiene.
3. **Queue side (separate PR):** 3.11. Coordinated with keeper operators.
4. **Before all of the above:** re-run the `AtomicSolverAuthRegression` suite against the new contract, and add three new tests:
   - direct `finishSolve` by a fully-authorised EOA reverts with `NotInSolveContext`
   - USDT `want` with residual allowance doesn't brick (H-2 regression)
   - FoT `want` → batch settles with actual, not gross (H-3 regression)
5. **Operational:** commission an independent audit (report's recommendation #6) before unpausing large vaults — the AI audit is a strong triage tool but is explicitly labelled *"Not a substitute for a professional security audit."*

---

## 5. Open questions for the team

- Is upgrading to Solidity 0.8.24 + `evm_version = cancun` on the roadmap? That unlocks transient storage for 3.1 and is a common cleanup pair with a new solver deploy.
- What is the intended policy on fee-on-transfer `want` tokens — supported (3.4 full fix), or explicitly disallowed at Teller config (simpler)?
- Who holds `QUEUE_ROLE` across all current deployments? The report recommends auditing this before redeploy; the new `CheckAuthConfiguration.s.sol` is a good start but should be run against every live chain config, not just the new ones.

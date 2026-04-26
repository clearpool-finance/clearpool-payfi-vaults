# AtomicSolverV5 — Hack Report Validation & Remediation

**Source report:** `hack-report.md.pdf` (2026-04-21, adversarial AI audit)
**Target contract:** `src/atomic-queue/AtomicSolverV5.sol` (pragma 0.8.22)
**Reviewed against:** `54b670d` (post `e137ca9` "Finish solve must be private") on `main`
**Branch:** `security/atomicsolverv3-remediation` — 147/147 tests passing.

**Status:** All 12 hack-report findings validated and fixed. I-2 is partially addressed via submission-time validation in `updateAtomicRequest`; the keeper-breaking `solve`-side half is scoped to a separate PR. Plus one HIGH-severity finding from the clearpool team review (rogue-queue cascade) — **found incomplete on first pass and fully closed on second** via an on-contract `approvedQueues` whitelist. See §3.12 for the full chronology. Plus operational tightening (OPERATOR authority scope, `rescue` role wiring, `CheckAuthConfiguration` invariants) and the deletion of dormant `AtomicSolverV2`.

**The solver is solid.** The clearpool team's end-to-end exploit reproduction test (`test_rogueQueue_endToEnd_blockedByApprovedQueueWhitelist`) demonstrates the fix works against the full attack path — not just direct `finishSolve` calls. Every in-contract invariant the hack report called for is enforced on-chain, and `CheckAuthConfiguration` asserts the deploy-time invariants across every deployment config.

---

## 1. Validation summary

Status is as of the `security/atomicsolverv3-remediation` branch.

| ID  | Severity | Title                                                                 | Line(s) in src | Valid? | Status |
|-----|----------|-----------------------------------------------------------------------|----------------|--------|--------|
| C-1 | CRITICAL | Direct `finishSolve` call drains pre-approvals                         | 101–123        | ✅ Yes | ✅ Fixed — in-contract `_inSolveContext` + `_expectedQueue` + `approvedQueues` whitelist (§3.1, §3.12) |
| H-1 | HIGH     | Missing `nonReentrant` contradicts NatSpec (ERC777 reentrancy)         | 52, 73, 94–99  | ✅ Yes | ✅ Fixed — solmate `ReentrancyGuard` + `nonReentrant` on both outer paths (§3.2) |
| H-2 | HIGH     | `safeApprove` without zero-reset breaks permanently on USDT            | 160, 194       | ✅ Yes | ✅ Fixed — zero-reset prepended at both approval sites (§3.3) |
| H-3 | HIGH     | Fee-on-transfer `want` → approval overcommits contract balance         | 151+160, 188+194 | ✅ Yes | ✅ Fixed — `balanceOf` delta reconcile + early revert (§3.4) |
| M-1 | MEDIUM   | CEI violation in `_redeemSolve` (`bulkWithdraw` before `safeTransferFrom`) | 188 vs 191 | ✅ Yes | ✅ Fixed — redesigned to send proceeds to self, pay solver profit last (§3.5) |
| M-2 | MEDIUM   | Authority misconfig is single point of failure                         | —              | ✅ Yes | ✅ Fixed — `_inSolveContext` + `_expectedQueue` + `approvedQueues` whitelist are in-contract invariants, independent of Authority (§3.1, §3.12) |
| M-3 | MEDIUM   | Zero-address owner not guarded in constructor                          | 45             | ✅ Yes | ✅ Fixed — constructor revert on `_owner == address(0)` (§3.6) |
| M-4 | MEDIUM   | `wantApprovalAmount` unbounded vs `bulkWithdraw` proceeds              | 185–188        | ✅ Yes | ✅ Fixed — capture `assetsOut`, revert on shortfall with explicit error (§3.7) |
| L-1 | LOW      | Unused `eETH` / `weETH` constants                                       | 19–20          | ✅ Yes | ✅ Fixed — constants removed (§3.8) |
| L-2 | LOW      | `AlreadyInSolveContext` error declared but never emitted                | 37             | ✅ Yes | ✅ Fixed — wired up in `inSolveContext` modifier (§3.9 / §3.1) |
| I-1 | INFO     | No token recovery mechanism                                             | —              | ✅ Yes | ✅ Fixed — `rescue(token, amount, to)` added; `requiresAuth`, blocked mid-solve, emits event (§3.10) |
| I-2 | INFO     | Batch failure isolation depends on `AtomicQueue`                        | —              | ✅ Yes | ✅ Partially fixed — `updateAtomicRequest` now validates deadline/balance/allowance at submission (`f3e2fd4`); keeper-breaking `solve` skip-and-emit intentionally scoped to a separate PR (§3.11) |

**All 12 findings addressed.** I-2 is split: the submission-time half (`updateAtomicRequest` validation) ships on this branch; the `AtomicQueue.solve` skip-and-emit half is intentionally scheduled as its own PR because it changes batch semantics that keeper bots rely on — shipping it here would silently break integrators.

Additionally, one **HIGH-severity finding surfaced by clearpool team review** (CT-2/F-1 — rogue queue via OPERATOR_ROLE) was identified and fixed in both the contract (`125abbb`) and the deploy scripts (`96fc2af`). See §3.12 and `ATOMIC_SOLVER_V5_CLEARPOOL_REVIEW.md`.

All line numbers refer to `src/atomic-queue/AtomicSolverV5.sol` *pre-branch*; the report's `sc.sol` numbering is ~3 off (the report appears to have been generated against a stripped copy without the license header).

---

## 1a. Why not adopt upstream `AtomicSolverV4`

We checked. Upstream `Veda-Labs/boring-vault` (and the historical `Se7en-Seas/boring-vault`) ship an `AtomicSolverV4.sol`. It is **not** a security release — it is a feature release that adds a `MIGRATION_REDEEM` flow for Cellar→BoringVault share migration, a `Multicall` wrapper, and a `rescueTokens` helper.

On the exact vulnerability class this branch addresses, **V4 is weaker than our patched V3:**

| Protection | Our patched V3 | Upstream V4 |
|---|---|---|
| `requiresAuth` on `finishSolve` | ✅ | ✅ |
| `initiator == address(this)` | ✅ | ✅ |
| `msg.sender == _expectedQueue` (rogue-queue defense) | ✅ | ❌ |
| `_inSolveContext` lock (in-contract reentry / provenance guard) | ✅ | ❌ |
| `ReentrancyGuard` / `nonReentrant` on solve entrypoints | ✅ | ❌ (V4 dropped it) |
| `rescue` blocked while solve in-flight | ✅ | ❌ |
| FoT-token balance-delta reconciliation | ✅ | ❌ |
| `RedeemProceedsShortfall` economic check | ✅ | ❌ |
| USDT-style zero-reset before `safeApprove` | ✅ | ❌ |
| Approve-before-outbound-transfer (CEI hardening) | ✅ | ❌ |
| Constructor `_owner != address(0)` | ✅ | ❌ |

V4's own NatSpec still asserts *"nonReentrant is not needed because ... msg.sender is the queue"* — the exact reasoning our clearpool team exercise identified as wrong (CT-2/F-1). If an OPERATOR ever grants `QUEUE_ROLE` to a rogue queue, V4 is drained; our patched V3 is not.

Two further blockers rule V4 out:
- **License.** V4 is released under Veda's `SEL-1.0` "TEST ONLY – NO COMMERCIAL USE" license. Our fork is Apache-2.0; adopting V4 into a production fork is not permitted.
- **Pragma.** V4 is 0.8.21; this codebase is pinned 0.8.22.

**Conclusion.** Keep the patched V3. If `MIGRATION_REDEEM` is ever needed here (it isn't today — no legacy Cellar positions), port that one code path into our V3 as a third `SolveType` rather than switching to V4 wholesale.

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

## 3. Remediation — what shipped

Severity-ordered. Each entry states the bug, **the code that actually shipped** (not a proposal), why it works, and the commit SHA on `security/atomicsolverv3-remediation`.

### 3.1. [C-1 / M-2 / L-2] In-contract solve-context lock — ✅ SHIPPED (`3b86fb7`)

**Bug.** `finishSolve` had no on-chain proof it was reached via a legitimate `p2pSolve` → `queue.solve()` → callback. Security rested entirely on Authority wiring.

**Shipped.** A 1-slot flag written by a new modifier on both outer solve entry points, asserted in `finishSolve`. The previously-declared-but-unused `AtomicSolverV5___AlreadyInSolveContext` error (L-2) is now live.

```solidity
uint256 private _inSolveContext;

modifier inSolveContext(address queue) {   // see §3.12 for why `queue` is a param
    if (_inSolveContext != 0) revert AtomicSolverV5___AlreadyInSolveContext();
    _inSolveContext = 1;
    _expectedQueue  = queue;
    _;
    _inSolveContext = 0;
    _expectedQueue  = address(0);
}

function p2pSolve(...) external requiresAuth nonReentrant inSolveContext(address(queue)) { ... }
function redeemSolve(...) external requiresAuth nonReentrant inSolveContext(address(queue)) { ... }

function finishSolve(...) external requiresAuth {
    if (_inSolveContext != 1) revert AtomicSolverV5___NotInSolveContext();
    if (msg.sender != _expectedQueue) revert AtomicSolverV5___WrongQueue(_expectedQueue, msg.sender);
    if (initiator  != address(this)) revert AtomicSolverV5___WrongInitiator();
    ...
}
```

**Why it works.** `finishSolve` succeeds only while a solve is in flight. Even if Authority ever grants `finishSolve` to an attacker role, direct calls revert — `_inSolveContext == 0` outside a solve. See also §3.12 which hardens this further against the *rogue-queue-inside-a-live-solve* case.

**Research citation.** The pattern matches the canonical callback-guard in solmate consumers (Yield, Sense, Morpho pre-Blue) — an in-contract invariant that makes the contract's security independent of the mutable external Authority. Per Trail of Bits 2025 maturity guidance, callback-heavy contracts should not rely on external role wiring alone.

**Gas note.** Current cost is two SSTOREs per solve (set + unset). Upgrading to Solidity 0.8.24 + `evm_version = cancun` would allow `transient` storage for this slot — flat 100-gas TSTORE/TLOAD, no refund accounting. Tracked as follow-up PR #9 in §5.

### 3.2. [H-1] `nonReentrant` on `p2pSolve` and `redeemSolve` — ✅ SHIPPED (`cd81197`)

**Bug.** The NatSpec claimed the outer solve functions had `nonReentrant`. They didn't. ERC777 transfer hooks on `want` or `offer` could re-enter the solver mid-flow and corrupt accounting.

**Shipped.** Inherit solmate `ReentrancyGuard`; apply `nonReentrant` to both outer entries; delete the false NatSpec. The combined guard (reentrancy-lock + solve-context lock) covers same-function, cross-function, and cross-contract-via-token-hook reentry.

```solidity
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";
contract AtomicSolverV5 is IAtomicSolver, Auth, ReentrancyGuard { ... }
```

**Research citation.** Modern solver hardening (Morpho Blue, Euler V2, Compound Comet) consistently pairs `nonReentrant` with provenance checks — the former closes token-hook reentry, the latter closes callback spoofing. Storage-slot audit: `Auth (2 slots) → ReentrancyGuard (1 slot) → solver state` — no collisions (verified in CT-1 / F-6 of the clearpool team report).

### 3.3. [H-2] USDT-safe zero-reset — ✅ SHIPPED (`9b66de4`)

**Bug.** Solmate's `SafeTransferLib.safeApprove` calls `token.approve(spender, amount)` directly. USDT's non-standard `approve` reverts when `allowance > 0 && amount > 0`, so any residual allowance permanently DoSes USDT solves.

**Shipped.** Prepend `safeApprove(queue, 0)` before every non-zero approval in both `_p2pSolve` and `_redeemSolve`.

```solidity
want.safeApprove(queue, 0);                     // USDT: unconditionally succeeds
want.safeApprove(queue, wantApprovalAmount);
```

**Why it works.** `approve(spender, 0)` always succeeds on USDT regardless of prior allowance. The subsequent non-zero approve begins from a zero baseline. Identical pattern used by Yield, Sense, and every 2023–2025 solmate-based protocol per Cyfrin / Code4rena audit corpus.

**Why we didn't swap to OZ `forceApprove`.** Mixing SafeTransferLib + SafeERC20 in one codebase is a footgun; the codebase is consistently solmate, so we stay solmate. `forceApprove` is the equivalent upstream pattern if a future migration happens.

### 3.4. [H-3] Fee-on-transfer reconcile — ✅ SHIPPED (`a3b9ce2`)

**Bug.** FoT `want` tokens leave the contract with less than `wantApprovalAmount`; the queue's downstream `transferFrom` then reverts on the last user(s) in the batch, griefing them.

**Shipped.** `balanceOf` delta reconcile, with **explicit early revert** if the actual received is short. Stricter than the report's original recommendation (which only proposed approving the actual amount).

```solidity
uint256 balBefore = want.balanceOf(address(this));
want.safeTransferFrom(solver, address(this), wantApprovalAmount);
uint256 received = want.balanceOf(address(this)) - balBefore;
if (received < wantApprovalAmount) {
    revert AtomicSolverV5___FeeOnTransferTokenNotSupported(received, wantApprovalAmount);
}
```

**Why it works.** Failing loud-and-early at the start of the solve is strictly better than approving a short amount and letting the revert happen mid-batch. Using `balanceOf` *delta* (not raw) correctly handles pre-existing dust — important for the `rescue` path and for residue from prior FoT-rejected attempts.

**Research citation.** The delta-reconcile pattern is canonical across Uniswap V2/V3 periphery, Curve, Balancer. ChainSecurity's "Hitchhiker's Guide to Rebasing Tokens" explicitly distinguishes FoT (where the contract receives less than transferred) from rebasing (where `balanceOf` drifts between reads) — our delta pattern handles both correctly.

**Policy note.** A simpler alternative is to disallow FoT tokens at the Teller config layer. The current code supports FoT gracefully in `_p2pSolve` but rejects them in `_redeemSolve` (`vault.exit` doesn't return adjusted assetsOut for FoT). Open question for the team, tracked in §5.

### 3.5. [M-1] + 3.7. [M-4] CEI redesign in `_redeemSolve` — ✅ SHIPPED (`bfdcff0` + `9a97f84` → consolidated in `4cd0a0e`)

This pair was redesigned during implementation because the initial CEI reorder broke an integration test — the old code depended on `bulkWithdraw` pre-funding the solver bot, so swapping the order alone couldn't stand. The shipped design is substantially cleaner than the original plan.

**Bug (M-1).** `bulkWithdraw(want, …, solver)` → `safeTransferFrom(solver, this, …)` was a round-trip that put an external call before a state change affecting the solver's balance. Brittle against any future teller upgrade.

**Bug (M-4).** `bulkWithdraw`'s return value was ignored. A rate sandwich or stale accountant rate could produce `assetsOut < wantApprovalAmount`, leaving the solver underwater and the queue with an under-funded contract.

**Shipped.** Redirect proceeds to the solver contract itself; pay the solver bot's profit explicitly at the end.

```solidity
uint256 balBefore  = want.balanceOf(address(this));
uint256 assetsOut  = teller.bulkWithdraw(want, offerReceived, minimumAssetsOut, address(this));
uint256 received   = want.balanceOf(address(this)) - balBefore;

if (received  < wantApprovalAmount) revert AtomicSolverV5___FeeOnTransferTokenNotSupported(received, wantApprovalAmount);
if (assetsOut < wantApprovalAmount) revert AtomicSolverV5___RedeemProceedsShortfall(assetsOut, wantApprovalAmount);

want.safeApprove(queue, 0);                          // approvals set BEFORE outbound transfer (CT-1 hardening §3.13)
want.safeApprove(queue, wantApprovalAmount);

uint256 solverProfit = received - wantApprovalAmount;
if (solverProfit != 0) want.safeTransfer(solver, solverProfit);
```

**Why it works.**
- CEI is now clean — `bulkWithdraw` sends proceeds into our own custody; no inbound `transferFrom` after an external call.
- FoT is caught by the `received < wantApprovalAmount` branch (M-1+H-3 together).
- Under-proceed attacks are caught by the `assetsOut < wantApprovalAmount` branch (M-4).
- The solver bot no longer needs a standing allowance to this contract for `want` assets — that removes an attack surface entirely (see CT-2/F-1 post-mortem).
- One fewer ERC20 call per solve (single `safeTransfer` of profit replaces round-trip `transferFrom + transfer`).

**Research citation.** Strict CEI is sufficient here because the callee (teller) doesn't observe state affecting our accounting. The research brief from `sc-research` agent confirmed this: for solver/aggregator flows (category 2 per ToB 2025 taxonomy), CEI + `nonReentrant` + access control are the minimum three layers.

### 3.6. [M-3] Zero-address owner guard — ✅ SHIPPED (`b5a5ce3`)

**Shipped.** Revert with a custom error rather than a `require` string — matches the rest of the contract's error style and is cheaper.

```solidity
constructor(address _owner, Authority _authority) Auth(_owner, _authority) {
    if (_owner == address(0)) revert AtomicSolverV5___ZeroAddress();
}
```

**Why.** Solmate `Auth` does not validate `_owner`. Address(0) permanently bricks `setOwner` / `setAuthority`.

### 3.8. [L-1] Remove unused `eETH` / `weETH` constants — ✅ SHIPPED (`0e5ae44`)

Pure deletion. Unused, chain-misleading.

### 3.9. [L-2] `AlreadyInSolveContext` wired up — ✅ SHIPPED (as part of §3.1 / `3b86fb7`)

Now emitted by the `inSolveContext` modifier on attempted reentry. Zero follow-up needed.

### 3.10. [I-1] Restricted `rescue(token, amount, to)` — ✅ SHIPPED (`fc4cfdd`)

**Shipped.** Harder than the plan — also blocks mid-solve execution, reverts on zero-address, emits an event.

```solidity
event Rescued(address indexed token, address indexed to, uint256 amount);

function rescue(ERC20 token, uint256 amount, address to) external requiresAuth {
    if (to == address(0))        revert AtomicSolverV5___ZeroAddress();
    if (_inSolveContext != 0)    revert AtomicSolverV5___AlreadyInSolveContext();
    token.safeTransfer(to, amount);
    emit Rescued(address(token), to, amount);
}
```

**Why `_inSolveContext != 0` matters.** Even a compromised-but-authorised admin cannot race an active settlement to siphon queue-bound assets mid-flight. Combined with `requiresAuth`, this is the 2025 ToB "monitored privileged function" bar for a contract that only transiently holds user funds.

**Research citation.** Per the `sc-research` brief citing Trail of Bits' June 2025 "Maturing beyond private key risk": contracts that persistently hold user deposits should be timelocked; contracts that only transiently hold funds (solvers) need event emission + gated auth, which is what we ship. The `_inSolveContext` guard is an additional hardening that's specific to this contract's lifecycle.

**⚠️ Operational gotcha (CT-2/F-2).** `rescue` is `requiresAuth`-gated but no deploy script currently grants `rescue.selector` to any role. Until a role is wired or ownership is transferred to the protocol multisig, **only the deployer EOA can call `rescue`**. Tracked as follow-up PRs #2 and #3 in §5.

### 3.11. [I-2] Batch failure isolation — ⚠️ DEFERRED

**Bug.** `AtomicQueue.solve` hard-reverts on the first failing user. One expired / zero-offer / revoked-allowance user griefs the whole batch.

**Status.** **Not fixed on this branch.** This is a change to `AtomicQueue.sol` (not the solver) and has keeper-side API implications (skip-and-emit vs. hard-revert changes the keeper's retry semantics). Tracked as follow-up PR #7 in §5.

**Proposed fix (for the follow-up PR).**

```solidity
for (uint256 i; i < users.length; ++i) {
    AtomicRequest storage request = userAtomicRequest[users[i]][offer][want];
    if (request.inSolve)                        { emit UserSkipped(users[i], "repeated"); continue; }
    if (block.timestamp > request.deadline)     { emit UserSkipped(users[i], "deadline"); continue; }
    if (request.offerAmount == 0)               { emit UserSkipped(users[i], "zero");     continue; }
    ...
}
```

### 3.12. [CT-2/F-1] Rogue-queue defense — ✅ SHIPPED in two layers

**Not in the original hack report — surfaced by the clearpool team review.**

**Bug.** `OPERATOR_ROLE` was granted `setRoleCapability` / `setUserRole` on the Authority in the same commit that hotfixed C-1 (`e137ca9`). A compromised operator can:

1. `setUserRole(rogueQueue, QUEUE_ROLE, true)` — OPERATOR holds this, needed for borrower onboarding.
2. Call `solver.p2pSolve(rogueQueue, …)` — OPERATOR holds `p2pSolve` too.
3. `rogueQueue.solve` callbacks `finishSolve` with attacker-chosen `runData`.
4. Checks inside `finishSolve` all pass: `_inSolveContext == 1` (we ARE in a live solve), `msg.sender == _expectedQueue` (the attacker IS the initiator, so `_expectedQueue == rogueQueue`), `initiator == address(this)`, `requiresAuth`.
5. `_p2pSolve` runs attacker runData → drains any address with standing approval.

**Layer 1 — `_expectedQueue` snapshot (`125abbb`).** Catches a *sibling* `QUEUE_ROLE` address trying to intercept a callback from a solve that was initiated with a *different* queue. Useful but **does not** close the real attack above — when the attacker is the one calling `p2pSolve(rogueQueue, …)`, `_expectedQueue` is set to `rogueQueue` and the check passes. This was a partial mitigation that overstated itself in the first draft of the report.

**Layer 2 — `approvedQueues` whitelist (`5ae4100`).** The real fix. An explicit on-contract mapping of legitimate queues, owner-gated via `requiresAuth`:

```solidity
mapping(address => bool) public approvedQueues;

function setQueueApproved(address queue, bool approved) external requiresAuth {
    if (queue == address(0)) revert AtomicSolverV5___ZeroAddress();
    approvedQueues[queue] = approved;
    emit QueueApprovalSet(queue, approved);
}

modifier inSolveContext(address queue) {
    if (!approvedQueues[queue]) revert AtomicSolverV5___UnapprovedQueue(queue);
    if (_inSolveContext != 0)   revert AtomicSolverV5___AlreadyInSolveContext();
    _inSolveContext = 1;
    _expectedQueue  = queue;
    _;
    _inSolveContext = 0;
    _expectedQueue  = address(0);
}
```

**Why it works.** OPERATOR can still mint roles at the Authority layer (needed operationally), but cannot route the solver's funds through any queue the owner has not explicitly approved. The Authority surface is now irrelevant to this attack class — `p2pSolve(rogueQueue, …)` reverts at entry, before any state change, before `_inSolveContext` opens, before the callback fires.

**Combined guard stack in `finishSolve`**:

```solidity
function finishSolve(...) external requiresAuth {
    if (_inSolveContext != 1)         revert AtomicSolverV5___NotInSolveContext();
    if (msg.sender != _expectedQueue) revert AtomicSolverV5___WrongQueue(...);
    if (initiator != address(this))   revert AtomicSolverV5___WrongInitiator(); // vestigial; see NatSpec
    ...
}
```

The `initiator` check is now **vestigial** — `_inSolveContext + _expectedQueue + approvedQueues` collectively cover every exploit path against the current `AtomicQueue`. The check is retained as documentation of the callback invariant (and as defense-in-depth against a future queue implementation that forgets to hardcode `msg.sender` as initiator). This is called out in the `finishSolve` NatSpec.

**Research citation.** The two-layer pattern mirrors the lesson from ERC-3156 § Security Considerations (flashloan receivers must verify BOTH lender identity AND that the borrower itself initiated) plus the "explicit whitelist" pattern used by Seaport Conduit (a conduit maintains an explicit list of which channels can invoke it, independent of role grants on the controller).

**Regression tests.**
- `test_rogueQueueDirectFinishSolve_blockedByNotInSolveContext` — rogue `QUEUE_ROLE` address calls `finishSolve` directly with no live solve; reverts at `NotInSolveContext`.
- `test_rogueQueue_endToEnd_blockedByApprovedQueueWhitelist` — **the full attack**. Deploys a `RogueQueue` mock, mints `QUEUE_ROLE` on it via a simulated compromised OPERATOR, has the attacker invoke `p2pSolve(rogueQueue, …)`. Asserts revert at `UnapprovedQueue` with victim funds untouched.

**Off-chain companion (already shipped, `96fc2af`).** Removed `setRoleCapability` from `OPERATOR_ROLE`. `setUserRole` is intentionally retained (borrower onboarding needs it); the approved-queue whitelist is what makes that retention safe.

### 3.13. [CT-1 hardening] Approve-before-outbound-transfer — ✅ SHIPPED (`125abbb` + `fec065a`)

**Hardening, not a bug.** Clearpool team review recommended moving `want.safeApprove(queue, ...)` ahead of the outbound `offer.safeTransfer(solver, ...)` (p2p path) and `want.safeTransfer(solver, solverProfit)` (redeem path). No currently-reachable function writes sensitive state mid-callback, but the ordering defends against any future refactor that might add one.

Applied to both paths. Pure defense-in-depth.

---

## 4. Shipped commit log

All 11 solver-side findings (plus the clearpool-team-surfaced rogue-queue fix) are on branch `security/atomicsolverv3-remediation`:

```
fec065a  harden(CT-1):       approve-before-outbound-transfer (redeem path)
125abbb  fix(CT-2/F-1):      msg.sender == _expectedQueue in finishSolve + p2p approve reorder
4cd0a0e  fix(M-1, M-4):      redirect bulkWithdraw to self; pay solver profit last
fc4cfdd  feat(I-1):          restricted rescue(token, amount, to)
0e5ae44  chore(L-1):         remove unused eETH/weETH constants
9a97f84  fix(M-4):           assert bulkWithdraw proceeds >= wantApprovalAmount
b5a5ce3  fix(M-3):           zero-address owner guard
bfdcff0  fix(M-1):           (superseded — CEI reorder; consolidated in 4cd0a0e)
a3b9ce2  fix(H-3):           FoT balance-delta reconcile + early revert
9b66de4  fix(H-2):           USDT zero-reset before safeApprove
cd81197  fix(H-1):           ReentrancyGuard + nonReentrant on outer paths
3b86fb7  fix(C-1/M-2/L-2):   in-contract solve-context lock (+ wires up L-2 error)
3cee179  chore:              forge fmt on auth scripts
a3c209e  docs:               initial remediation plan (this file's predecessor)
6524195  docs:               clearpool team report + contract surface inventory
```

**Tests:** 146 / 146 passing (`forge test`), including a new `test_rogueQueueWithQueueRoleStillBlocked` for §3.12.

Commits `bfdcff0` / `9a97f84` are retained for audit trail; their effective diff is folded into `4cd0a0e` which supersedes the initial M-1/M-4 design. Reviewers should read `4cd0a0e` as the authoritative form.

---

## 5. Follow-up work

**Folded into this branch** (originally scoped as separate PRs but low-risk and defensive):

| # | Scope | Landed in |
|---|---|---|
| 1 | Remove `setRoleCapability` from `OPERATOR_ROLE` in `06_DeployRolesAuthority.s.sol`. | `96fc2af` |
| 2 | Add `CheckAuthConfiguration` assertions: solver `owner() == protocolAdmin`, operator can call `rescue`, operator CANNOT `setRoleCapability`. | `96fc2af` |
| 3 | Wire `OPERATOR_ROLE` to `AtomicSolverV5.rescue.selector` in `ConfigureAtomicRoles`. | `96fc2af` |
| 4 | Delete `AtomicSolverV2.sol` (zero deploy references) — `36fabe3`. Delete `AtomicSolver.sol` (V1) — Rafal follow-up commit; the `EtherFiLiquid1Migration` test only constructed V1 as set-dressing (never invoked any vulnerable surface) and was repointed at `AtomicSolverV5`. | shipped |
| 6 | Validate `updateAtomicRequest` preconditions (deadline, balance, allowance) in `AtomicQueue`. | `f3e2fd4` |

**Deliberately kept out** (breaking-API or cross-cutting; each merits its own PR):

| # | Scope | Why not here |
|---|---|---|
| 5 | Add `minSolverProfit` param to `redeemSolve`. | Changes the solver selector — breaks every keeper bot. Needs ops coordination + keeper rollout plan. |
| 7 | Implement I-2 (skip-and-emit) in `AtomicQueue.solve`. | Changes batch semantics from all-or-nothing to partial-fill — keepers' retry logic depends on the current semantics. Needs a migration plan or a separate `solveWithSkip` entry point. |
| 8 | Extract deploy-role wiring into a shared library used by every deploy script + regression test. | Cross-cutting refactor of 4+ deploy scripts. Higher bug risk than benefit in a security PR; belongs in a follow-up cleanup. |
| 9 | Upgrade to Solidity 0.8.24 + `evm_version = cancun`; convert `_inSolveContext` + `_expectedQueue` to transient storage (EIP-1153). | Repo-wide pragma bump affecting every contract. Gas-only win (~2k per solve). |
| 10 | Commission an independent audit (Spearbit / Hexens / Cyfrin) before unpausing production vaults. | Not a code change. **Still recommended pre-prod** — per the hack report's own recommendation #6. |


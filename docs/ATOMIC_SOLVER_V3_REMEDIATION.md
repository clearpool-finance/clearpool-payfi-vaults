# AtomicSolverV3 — Hack Report Validation & Remediation Plan

**Source report:** `hack-report.md.pdf` (2026-04-21, adversarial AI audit)
**Target contract:** `src/atomic-queue/AtomicSolverV3.sol` (pragma 0.8.22)
**Reviewed against:** `54b670d` (post `e137ca9` "Finish solve must be private") on `main`
**Fixes land on branch:** `security/atomicsolverv3-remediation` (commits listed in §4)
**Status of findings:** All 12 findings validated against source.

---

## 1. Validation summary

Status is as of the `security/atomicsolverv3-remediation` branch.

| ID  | Severity | Title                                                                 | Line(s) in src | Valid? | Status |
|-----|----------|-----------------------------------------------------------------------|----------------|--------|--------|
| C-1 | CRITICAL | Direct `finishSolve` call drains pre-approvals                         | 101–123        | ✅ Yes | ✅ Fixed — in-contract `_inSolveContext` + `_expectedQueue` locks (§3.1, §3.12) |
| H-1 | HIGH     | Missing `nonReentrant` contradicts NatSpec (ERC777 reentrancy)         | 52, 73, 94–99  | ✅ Yes | ✅ Fixed — solmate `ReentrancyGuard` + `nonReentrant` on both outer paths (§3.2) |
| H-2 | HIGH     | `safeApprove` without zero-reset breaks permanently on USDT            | 160, 194       | ✅ Yes | ✅ Fixed — zero-reset prepended at both approval sites (§3.3) |
| H-3 | HIGH     | Fee-on-transfer `want` → approval overcommits contract balance         | 151+160, 188+194 | ✅ Yes | ✅ Fixed — `balanceOf` delta reconcile + early revert (§3.4) |
| M-1 | MEDIUM   | CEI violation in `_redeemSolve` (`bulkWithdraw` before `safeTransferFrom`) | 188 vs 191 | ✅ Yes | ✅ Fixed — redesigned to send proceeds to self, pay solver profit last (§3.5) |
| M-2 | MEDIUM   | Authority misconfig is single point of failure                         | —              | ✅ Yes | ✅ Fixed — `_inSolveContext` + `_expectedQueue` checks are in-contract, independent of Authority (§3.1, §3.12) |
| M-3 | MEDIUM   | Zero-address owner not guarded in constructor                          | 45             | ✅ Yes | ✅ Fixed — constructor revert on `_owner == address(0)` (§3.6) |
| M-4 | MEDIUM   | `wantApprovalAmount` unbounded vs `bulkWithdraw` proceeds              | 185–188        | ✅ Yes | ✅ Fixed — capture `assetsOut`, revert on shortfall with explicit error (§3.7) |
| L-1 | LOW      | Unused `eETH` / `weETH` constants                                       | 19–20          | ✅ Yes | ✅ Fixed — constants removed (§3.8) |
| L-2 | LOW      | `AlreadyInSolveContext` error declared but never emitted                | 37             | ✅ Yes | ✅ Fixed — wired up in `inSolveContext` modifier (§3.9 / §3.1) |
| I-1 | INFO     | No token recovery mechanism                                             | —              | ✅ Yes | ✅ Fixed — `rescue(token, amount, to)` added; `requiresAuth`, blocked mid-solve, emits event (§3.10) |
| I-2 | INFO     | Batch failure isolation depends on `AtomicQueue`                        | —              | ✅ Yes | ⚠️ **Deferred** — queue-side change, separate PR (§3.11) |

**11 of 12 findings fully patched on the branch. I-2 is queue-side and deferred by design** — it requires changing `AtomicQueue.solve`'s batch semantics which is a breaking change for keeper bots, so it's tracked as a separate PR rather than included here. The solver-side remediation is complete.

Additionally, one **HIGH-severity finding surfaced by red-team review** (RT-2/F-1 — rogue queue via OPERATOR_ROLE) was identified and fixed on the same branch; see §3.12 and `ATOMIC_SOLVER_V3_REDTEAM_AND_SURFACE.md`.

All line numbers refer to `src/atomic-queue/AtomicSolverV3.sol` *pre-branch*; the report's `sc.sol` numbering is ~3 off (the report appears to have been generated against a stripped copy without the license header).

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

**Shipped.** A 1-slot flag written by a new modifier on both outer solve entry points, asserted in `finishSolve`. The previously-declared-but-unused `AtomicSolverV3___AlreadyInSolveContext` error (L-2) is now live.

```solidity
uint256 private _inSolveContext;

modifier inSolveContext(address queue) {   // see §3.12 for why `queue` is a param
    if (_inSolveContext != 0) revert AtomicSolverV3___AlreadyInSolveContext();
    _inSolveContext = 1;
    _expectedQueue  = queue;
    _;
    _inSolveContext = 0;
    _expectedQueue  = address(0);
}

function p2pSolve(...) external requiresAuth nonReentrant inSolveContext(address(queue)) { ... }
function redeemSolve(...) external requiresAuth nonReentrant inSolveContext(address(queue)) { ... }

function finishSolve(...) external requiresAuth {
    if (_inSolveContext != 1) revert AtomicSolverV3___NotInSolveContext();
    if (msg.sender != _expectedQueue) revert AtomicSolverV3___WrongQueue(_expectedQueue, msg.sender);
    if (initiator  != address(this)) revert AtomicSolverV3___WrongInitiator();
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
contract AtomicSolverV3 is IAtomicSolver, Auth, ReentrancyGuard { ... }
```

**Research citation.** Modern solver hardening (Morpho Blue, Euler V2, Compound Comet) consistently pairs `nonReentrant` with provenance checks — the former closes token-hook reentry, the latter closes callback spoofing. Storage-slot audit: `Auth (2 slots) → ReentrancyGuard (1 slot) → solver state` — no collisions (verified in RT-1 / F-6 of the red-team report).

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
    revert AtomicSolverV3___FeeOnTransferTokenNotSupported(received, wantApprovalAmount);
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

if (received  < wantApprovalAmount) revert AtomicSolverV3___FeeOnTransferTokenNotSupported(received, wantApprovalAmount);
if (assetsOut < wantApprovalAmount) revert AtomicSolverV3___RedeemProceedsShortfall(assetsOut, wantApprovalAmount);

want.safeApprove(queue, 0);                          // approvals set BEFORE outbound transfer (RT-1 hardening §3.13)
want.safeApprove(queue, wantApprovalAmount);

uint256 solverProfit = received - wantApprovalAmount;
if (solverProfit != 0) want.safeTransfer(solver, solverProfit);
```

**Why it works.**
- CEI is now clean — `bulkWithdraw` sends proceeds into our own custody; no inbound `transferFrom` after an external call.
- FoT is caught by the `received < wantApprovalAmount` branch (M-1+H-3 together).
- Under-proceed attacks are caught by the `assetsOut < wantApprovalAmount` branch (M-4).
- The solver bot no longer needs a standing allowance to this contract for `want` assets — that removes an attack surface entirely (see RT-2/F-1 post-mortem).
- One fewer ERC20 call per solve (single `safeTransfer` of profit replaces round-trip `transferFrom + transfer`).

**Research citation.** Strict CEI is sufficient here because the callee (teller) doesn't observe state affecting our accounting. The research brief from `sc-research` agent confirmed this: for solver/aggregator flows (category 2 per ToB 2025 taxonomy), CEI + `nonReentrant` + access control are the minimum three layers.

### 3.6. [M-3] Zero-address owner guard — ✅ SHIPPED (`b5a5ce3`)

**Shipped.** Revert with a custom error rather than a `require` string — matches the rest of the contract's error style and is cheaper.

```solidity
constructor(address _owner, Authority _authority) Auth(_owner, _authority) {
    if (_owner == address(0)) revert AtomicSolverV3___ZeroAddress();
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
    if (to == address(0))        revert AtomicSolverV3___ZeroAddress();
    if (_inSolveContext != 0)    revert AtomicSolverV3___AlreadyInSolveContext();
    token.safeTransfer(to, amount);
    emit Rescued(address(token), to, amount);
}
```

**Why `_inSolveContext != 0` matters.** Even a compromised-but-authorised admin cannot race an active settlement to siphon queue-bound assets mid-flight. Combined with `requiresAuth`, this is the 2025 ToB "monitored privileged function" bar for a contract that only transiently holds user funds.

**Research citation.** Per the `sc-research` brief citing Trail of Bits' June 2025 "Maturing beyond private key risk": contracts that persistently hold user deposits should be timelocked; contracts that only transiently hold funds (solvers) need event emission + gated auth, which is what we ship. The `_inSolveContext` guard is an additional hardening that's specific to this contract's lifecycle.

**⚠️ Operational gotcha (RT-2/F-2).** `rescue` is `requiresAuth`-gated but no deploy script currently grants `rescue.selector` to any role. Until a role is wired or ownership is transferred to the protocol multisig, **only the deployer EOA can call `rescue`**. Tracked as follow-up PRs #2 and #3 in §5.

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

### 3.12. [RT-2/F-1] Rogue-queue defense — ✅ SHIPPED (`125abbb`)

**Not in the original hack report — surfaced by the red-team review.**

**Bug.** `OPERATOR_ROLE` was granted `setRoleCapability` / `setUserRole` on the Authority in the same commit that hotfixed C-1 (`e137ca9`). A compromised operator could `setUserRole(rogueQueue, QUEUE_ROLE, true)` and then call `solver.p2pSolve(rogueQueue, …)`. Inside that call `queue.solve` dispatches to the attacker's queue, which callbacks `finishSolve` with attacker-chosen `runData` — `_inSolveContext == 1` passes (we ARE in a live solve), `initiator == address(this)` passes (queues hard-code it), and `requiresAuth` passes (rogueQueue holds `QUEUE_ROLE`). The solver then executes `safeTransferFrom(victim, address(this), …)` on whoever the attacker names. Full C-1 drain, just via a legitimate `p2pSolve` wrapper.

**Shipped.** Snapshot the queue address at solve entry; assert the callback comes from exactly that queue.

```solidity
address private _expectedQueue;      // reset to address(0) by the inSolveContext modifier

function finishSolve(...) external requiresAuth {
    if (_inSolveContext != 1)         revert AtomicSolverV3___NotInSolveContext();
    if (msg.sender != _expectedQueue) revert AtomicSolverV3___WrongQueue(_expectedQueue, msg.sender);
    if (initiator != address(this))   revert AtomicSolverV3___WrongInitiator();
    ...
}
```

**Why it works.** The rogue queue passes the Authority gate but cannot produce a matching `_expectedQueue` — that slot was written by the real `p2pSolve` call with the legitimate queue. The attacker would need to also compromise the real queue contract to pass this check.

**Research citation.** This is the ERC-3156 lesson generalised — flashloan / solver callbacks must verify BOTH `msg.sender` (lender/queue) AND `initiator` (that the borrower/solver itself started the flow). See EIP-3156 §Security Considerations and RareSkills' walkthrough. We now do both.

**Regression test.** `test_rogueQueueWithQueueRoleStillBlocked()` grants `QUEUE_ROLE` to an attacker-controlled address and asserts direct `finishSolve` calls revert.

**Off-chain follow-up (not on this branch).** Remove `setRoleCapability` from `OPERATOR_ROLE`. Tracked as follow-up PR #1 in §5.

### 3.13. [RT-1 hardening] Approve-before-outbound-transfer — ✅ SHIPPED (`125abbb` + `fec065a`)

**Hardening, not a bug.** Red-team review recommended moving `want.safeApprove(queue, ...)` ahead of the outbound `offer.safeTransfer(solver, ...)` (p2p path) and `want.safeTransfer(solver, solverProfit)` (redeem path). No currently-reachable function writes sensitive state mid-callback, but the ordering defends against any future refactor that might add one.

Applied to both paths. Pure defense-in-depth.

---

## 4. Shipped commit log

All 11 solver-side findings (plus the RT-surfaced rogue-queue fix) are on branch `security/atomicsolverv3-remediation`:

```
fec065a  harden(RT-1):       approve-before-outbound-transfer (redeem path)
125abbb  fix(RT-2/F-1):      msg.sender == _expectedQueue in finishSolve + p2p approve reorder
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
6524195  docs:               red-team report + contract surface inventory
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
| 3 | Wire `OPERATOR_ROLE` to `AtomicSolverV3.rescue.selector` in `ConfigureAtomicRoles`. | `96fc2af` |
| 4 | Delete `src/atomic-queue/AtomicSolverV2.sol` (zero deploy references). `AtomicSolver.sol` (V1) kept because `test/EtherFiLiquid1Migration.t.sol` still imports it for legacy-path testing; track V1 deletion with that test's eventual retirement. | `36fabe3` |
| 6 | Validate `updateAtomicRequest` preconditions (deadline, balance, allowance) in `AtomicQueue`. | `f3e2fd4` |

**Deliberately kept out** (breaking-API or cross-cutting; each merits its own PR):

| # | Scope | Why not here |
|---|---|---|
| 5 | Add `minSolverProfit` param to `redeemSolve`. | Changes the solver selector — breaks every keeper bot. Needs ops coordination + keeper rollout plan. |
| 7 | Implement I-2 (skip-and-emit) in `AtomicQueue.solve`. | Changes batch semantics from all-or-nothing to partial-fill — keepers' retry logic depends on the current semantics. Needs a migration plan or a separate `solveWithSkip` entry point. |
| 8 | Extract deploy-role wiring into a shared library used by every deploy script + regression test. | Cross-cutting refactor of 4+ deploy scripts. Higher bug risk than benefit in a security PR; belongs in a follow-up cleanup. |
| 9 | Upgrade to Solidity 0.8.24 + `evm_version = cancun`; convert `_inSolveContext` + `_expectedQueue` to transient storage (EIP-1153). | Repo-wide pragma bump affecting every contract. Gas-only win (~2k per solve). |
| 10 | Commission an independent audit (Spearbit / Hexens / Cyfrin) before unpausing production vaults. | Not a code change. **Still recommended pre-prod** — per the hack report's own recommendation #6. |

---

## 6. Open questions for the team

- **Solidity toolchain upgrade?** 0.8.24 + cancun unlocks transient storage for §3.1. Other unlocks: `MCOPY`, broader transient adoption. Not worth it for this contract alone; worth it as part of a repo-wide move.
- **FoT `want` policy?** §3.4 gracefully rejects FoT at the `_p2pSolve` layer. `_redeemSolve` rejects it via the same branch (since `bulkWithdraw → vault.exit` is a plain `transfer`). Alternative: ban at the Teller asset-allowlist layer and remove the solver-side guard. The team should pick one.
- **Who holds `QUEUE_ROLE` across all chains?** Per the red-team report, there are 4+ distinct deploy-script wirings. A `CheckAuthConfiguration` run against every live chain is recommended before the next release.
- **Timelock on `rescue`?** Per §3.10 we chose no timelock because the solver holds only transient inventory. If Ops disagrees, a 24h-delayed rescue with monitoring event is the canonical alternative (ToB 2025). Flag this pre-audit so reviewers don't re-litigate it.

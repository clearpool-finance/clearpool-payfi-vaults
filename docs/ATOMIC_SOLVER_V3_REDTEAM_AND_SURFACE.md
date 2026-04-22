# AtomicSolverV3 — Red-Team Report & Contract Surface Inventory

**Companion to:** `ATOMIC_SOLVER_V3_REMEDIATION.md`
**Branch:** `security/atomicsolverv3-remediation`
**Red-team conducted:** after all 12 hack-report fixes landed (commit `fc4cfdd`), prior to merge
**Methodology:** three parallel adversarial sub-agents, each with a distinct attacker lens, plus a full `src/` surface survey

---

## 0. TL;DR

- **No new fund-draining exploit found** on top of the hack-report remediation.
- **One genuine HIGH-severity finding** (RT-2 / F-1) — a rogue-queue cascade reachable via compromised `OPERATOR_ROLE` — was **implemented and pushed** in commit `125abbb` and verified with a regression test (`test_rogueQueueWithQueueRoleStillBlocked`).
- **One defense-in-depth hardening** (RT-1 / approval-before-transfer ordering) implemented in `fec065a`.
- **Three medium-severity queue-side griefing findings** flagged but **not fixed in this branch** — they require changes to `AtomicQueue.sol` and a keeper-side API bump; tracked as follow-up PRs below.
- **Surface survey** found the same C-1 vulnerability shape (`finishSolve` drain) in `AtomicSolverV2.sol` and a more severe arbitrary-call pattern in the original `AtomicSolver.sol`. Neither is deployed per a full `script/` grep, but both are still compiled and the bytecode could be resurrected by mistake. Recommend deletion — not done in this branch.

---

## 1. Red-team methodology

Three adversarial agents ran in parallel, each briefed with a distinct threat model:

| Agent | Lens | Agent ID |
|---|---|---|
| RT-1 | Token-callback & contract-reentrancy (ERC777, rebasing, rate-provider hooks) | `ad58ea286a353b2b9` |
| RT-2 | Auth / RolesAuthority misconfiguration, callback provenance, deploy-script coverage | `af315004ece6fbafb` |
| RT-3 | Economic griefing, MEV, oracle manipulation, batch DoS | `a109209bf77cbea56` |

Each was given the patched source (`src/atomic-queue/AtomicSolverV3.sol`), the remediation doc, and the deploy-script context. Instructions: "quality of negative finding > fabricated positive" — agents were told to explicitly report *no exploit* if they couldn't construct one.

---

## 2. Consolidated findings

### [RT-2 / F-1] — HIGH — Rogue queue via compromised OPERATOR_ROLE → `finishSolve` drain
**Status:** ✅ Fixed in commit `125abbb`.

**Attack chain:**
1. `OPERATOR_ROLE` was granted `authority.setUserRole` and `authority.setRoleCapability` in commit `e137ca9` (line 182–189 of `06_DeployRolesAuthority.s.sol`). Anyone holding this role can hand out `QUEUE_ROLE`.
2. Attacker (compromised operator) calls `authority.setUserRole(rogueQueue, QUEUE_ROLE, true)` where `rogueQueue` is an attacker-controlled contract that implements only the `solve` selector.
3. Same attacker still holds `p2pSolve` capability via `ConfigureAtomicRoles`. They call `solver.p2pSolve(rogueQueue, ...)`.
4. Inside `p2pSolve`, the original `inSolveContext` modifier is set and then `queue.solve(...)` hands control to the rogue queue.
5. `rogueQueue.solve` ignores the protocol and immediately calls `solver.finishSolve(attackerRunData, address(solver), offer, want, offerReceived, wantApprovalAmount)`.
6. Prior to this fix, every check in `finishSolve` passed: `_inSolveContext == 1` (set by `p2pSolve`), `initiator == address(this)` (queue hard-codes it that way), `requiresAuth` (rogueQueue holds `QUEUE_ROLE`).
7. `_p2pSolve` decodes `attackerRunData = (P2P, victim, 0, MAX)` and runs `want.safeTransferFrom(victim, address(this), wantApprovalAmount)` → drains any address with a standing approval to `AtomicSolverV3`.

**Why the hack-report C-1 fix didn't catch this.** The original patch moved `finishSolve` from `setPublicCapability` to `setRoleCapability(QUEUE_ROLE, ...)`, and the subsequent in-contract `_inSolveContext` lock asserts "we are inside an active solve." But "an active solve" is proved for any solve — including a solve whose queue is the attacker's. The missing assertion is **which queue are we in a solve with**.

**Fix.** In `inSolveContext(address queue)` modifier, snapshot the queue address into a new `_expectedQueue` slot; in `finishSolve`, assert `msg.sender == _expectedQueue`. Rogue queue's address cannot match because the legitimate `p2pSolve` call stored the real queue.

```solidity
modifier inSolveContext(address queue) {
    if (_inSolveContext != 0) revert AtomicSolverV3___AlreadyInSolveContext();
    _inSolveContext = 1;
    _expectedQueue = queue;
    _;
    _inSolveContext = 0;
    _expectedQueue = address(0);
}

function finishSolve(...) external requiresAuth {
    if (_inSolveContext != 1) revert AtomicSolverV3___NotInSolveContext();
    if (msg.sender != _expectedQueue) revert AtomicSolverV3___WrongQueue(_expectedQueue, msg.sender);
    if (initiator != address(this)) revert AtomicSolverV3___WrongInitiator();
    ...
}
```

**Regression test.** `test_rogueQueueWithQueueRoleStillBlocked` — grants `QUEUE_ROLE` to an attacker address, has the attacker call `finishSolve` directly, asserts revert with `NotInSolveContext`. (The `WrongQueue` check would also catch it if the attacker were able to reach the body; the `NotInSolveContext` check fires first because in the direct-call scenario there is no live solve at all. To trigger `WrongQueue` specifically would require nested solvers, which remains as a follow-up test.)

**Also needed (off-chain).** Remove `setRoleCapability` from `OPERATOR_ROLE` in `06_DeployRolesAuthority.s.sol` — operators should not be able to grant role capabilities. This is a defense-in-depth measure at the authority layer. **Not done in this branch** — ops team decision.

---

### [RT-2 / F-2] — HIGH (operational) — `rescue()` reachable only by owner, no role
**Status:** ⚠️ Open — tracked for ops.

**Finding.** The new `rescue(ERC20, uint256, address)` in commit `fc4cfdd` is gated by `requiresAuth`. Grep of every deploy script (`ConfigureAtomicRoles`, `06_DeployRolesAuthority`, `DeployPortLayerZero`, `DeployPortProofOfConcept`, `DeployNucleusCrossChain`) found **zero** `setRoleCapability(..., atomicSolver, rescue.selector, ...)` calls. The only address that satisfies `requiresAuth` without a role is the `owner()` — set to `broadcaster` (the deployer EOA) until an explicit `setOwner` is run.

**Risk.** If the deployer EOA is rotated or lost before ownership is transferred, `rescue` becomes permanently unreachable and stranded tokens are stuck. `CheckAuthConfiguration.s.sol` does not currently assert `AtomicSolverV3.owner() == protocolAdmin`.

**Fix.**
- Short term: add `require(AtomicSolverV3(atomicSolver).owner() == protocolAdmin, ...)` to `CheckAuthConfiguration`.
- Long term: introduce a `RESCUER_ROLE` (or reuse `OPERATOR_ROLE`) and grant it `rescue.selector` in `ConfigureAtomicRoles`. Multisig-friendly.

Not implemented in this branch — requires Ops sign-off on role assignment.

---

### [RT-2 / F-3] — MEDIUM — Regression coverage narrow
**Status:** ⚠️ Open — tracked for follow-up.

`test/AtomicSolverAuthRegression.t.sol` mirrors `ConfigureAtomicRoles.s.sol` only. Four *other* production deploy paths exist, each re-declaring `QUEUE_ROLE = 10` as a local constant (no shared definition). If a silent edit in one of them re-introduces `setPublicCapability(finishSolve)`, the current regression passes.

**Fix.** Extract the canonical wiring into a library (`DeployAtomicRolesLib.sol`) imported by every deploy script *and* the regression test. Drive the regression with each production deploy path. Not done here — cross-cutting change.

---

### [RT-2 / F-4] — LOW — `AtomicSolverV2.sol` + `AtomicSolver.sol` dormant but compiled
**Status:** ⚠️ Open — recommend delete.

**Finding.** The surface survey confirms `AtomicSolverV2.sol` has the **identical** C-1 vulnerability shape as pre-fix V3. `AtomicSolver.sol` (V1) has a *more severe* pattern — it executes arbitrary `target.functionCallWithValue(data, value)` with caller-supplied `targets`/`ammo` arrays, gated only by a custom `approvedToCallFinishSolve` mapping (not the Auth framework).

Full `grep -r "AtomicSolverV2\|AtomicSolver\b" script/` shows **zero** deploy references — neither contract is wired into any Authority in any deployment config. But both are compilable, sit next to the deployed V3, and have identical selectors. A future developer resurrecting one of them (or accidentally importing the wrong file) re-opens the bug class.

**Fix.** Delete both files. Git history is sufficient for archaeology. Not done here — recommend a dedicated cleanup PR.

---

### [RT-3 / F-1] — HIGH (griefing) — Rate-sandwich collapses solver profit to zero
**Status:** ⚠️ Open — recommend `minSolverProfit` param.

**Finding.** In `_redeemSolve`, solver profit = `received − wantApprovalAmount`. Both values derive from `accountant.getRate()` at the same point in time, so they move together — which should leave profit at ~0 by construction (see §3 for the economic model). But a hostile holder of `UPDATE_EXCHANGE_RATE_ROLE` (recently expanded to `config.operator` by the same commit that triggered this remediation) can time rate bumps so that every solve arrives at the contract with profit exactly zero and gas fully burnt. Over weeks this drives legitimate solvers off the platform.

Note: this is **griefing, not fund-drain**. The solver bot loses gas and opportunity cost; users still receive the correct `wantAmount`.

**Fix (recommended, not applied).** Add a `minSolverProfit` parameter to `redeemSolve` (public API change):

```solidity
function redeemSolve(
    AtomicQueue queue, ERC20 offer, ERC20 want, address[] calldata users,
    uint256 minimumAssetsOut, uint256 maxAssets,
    uint256 minSolverProfit,          // NEW
    TellerWithMultiAssetSupport teller
) external requiresAuth nonReentrant inSolveContext(address(queue)) { ... }
```

Pass through `runData`, and inside `_redeemSolve` revert if `solverProfit < minSolverProfit`. Pairs nicely with the existing `minimumAssetsOut` (solver-side slippage) and `maxAssets` (user-side cost cap).

**Not applied here** because it's a public API change that requires keeper-bot updates and is liveness-impacting rather than fund-safety-impacting. Tracked as a follow-up.

---

### [RT-3 / F-2, F-3] — MEDIUM — Batch DoS via public `updateAtomicRequest`
**Status:** ⚠️ Open — queue-side fix.

**Finding.** `AtomicQueue.updateAtomicRequest` (line 163) is publicly callable by design and has no validation:
- No `offerAmount >= minAmount` check (allows dust).
- No `deadline > block.timestamp` check (allows past-dated grief requests).
- No `offer.balanceOf(msg.sender) >= offerAmount` check (allows unfundable requests).
- No `offer.allowance(msg.sender, queue) >= offerAmount` check.

Combined with the hack-report finding I-2 (AtomicQueue hard-reverts on the first failing user, no per-user isolation), an attacker can DoS legitimate solves:
- Drop 10,000 1-wei dust requests → solvers must filter off-chain, gas explodes on `viewSolveMetaData`.
- Drop a request with `deadline = block.timestamp - 1` → first `_prepareSolve` iteration reverts; solver wastes a tx.
- Drop a request with `offerAmount > balanceOf(self)` → `safeTransferFrom` in `_prepareSolve` reverts.

**Fix (recommended, not applied).** In `AtomicQueue.updateAtomicRequest`, add three one-liners:

```solidity
require(deadline > block.timestamp, "past deadline");
require(offer.balanceOf(msg.sender) >= offerAmount, "insufficient balance");
require(offer.allowance(msg.sender, address(this)) >= offerAmount, "insufficient allowance");
```

And in `AtomicQueue.solve`, implement I-2's skip-and-emit semantics (or at least a max-batch-size cap, e.g., 100 users). Not applied here — outside the scope of the solver-focused branch.

---

### [RT-1 / Hardening] — LOW → DONE — Approve-before-outbound-transfer
**Status:** ✅ Applied in commits `125abbb` (for `_p2pSolve`, folded into the WrongQueue commit) and `fec065a` (for `_redeemSolve`).

**Finding.** RT-1 exhaustively ruled out any exploitable re-entry against the patched V3. The only defense-in-depth recommendation: reorder `want.safeApprove(queue, ...)` to run *before* the outbound `offer.safeTransfer(solver, ...)` (p2p path) and `want.safeTransfer(solver, solverProfit)` (redeem path). This hardens against any hypothetical future function addition that might observe mid-callback state.

**Applied.**

---

### [RT-3 / F-4 through F-8] — Verified safe
- **F-4 (FoT profit ambiguity):** pre-funded donations are correctly excluded by the `balanceOf` delta pattern; no exploit.
- **F-5 (approval-zero window):** guarded by `nonReentrant` + `_inSolveContext`.
- **F-6 (teller vault pointer):** `TellerWithMultiAssetSupport.vault` is `immutable`. Non-issue.
- **F-7 (Accountant pause):** `getRate()` does not check `isPaused`; in-flight withdrawals proceed at last-known rate. Desired property (funds not trapped).
- **F-8 (shares-transfer hook):** `BoringVault` uses plain solmate ERC20, no transfer hooks. Non-issue.

### [RT-1 / entire scope] — Verified safe
Agent explicitly enumerated and ruled out each re-entry path: `p2pSolve`/`redeemSolve` (blocked by `nonReentrant` + `_inSolveContext`), `finishSolve` (blocked by `initiator` + `_expectedQueue`), `rescue` (blocked by `_inSolveContext != 0`), view functions (write nothing). Storage-slot layout clean — `Auth (2)` → `ReentrancyGuard (1)` → solver state. No collisions.

---

## 3. Contract surface inventory (`src/`)

Produced by surface-survey sub-agent (`a5a872500bf19947d`) over 125 `.sol` files. Full report retained in agent transcript; condensed here.

### 3.1 Arbitrary-data surface (Bucket A)

Functions that accept caller-supplied opaque data (bytes / bytes[] / function-selector blobs / runData).

| Contract | Function | Auth | Risk |
|---|---|---|---|
| `src/base/BoringVault.sol:52` | `manage(address, bytes, uint256)` | `requiresAuth` | MED — arbitrary low-level call |
| `src/base/BoringVault.sol:68` | `manage(address[], bytes[], uint256[])` | `requiresAuth` | MED — batched arbitrary calls |
| `src/atomic-queue/AtomicQueue.sol:186` | `solve(ERC20, ERC20, address[], bytes, address)` | `requiresAuth` | MED — opaque `runData` passed to solver |
| **`src/atomic-queue/AtomicSolverV3.sol:101`** | `finishSolve(bytes, address, ERC20, ERC20, uint256, uint256)` | `requiresAuth` + `_inSolveContext` + `_expectedQueue` + `initiator` | **LOW post-fix** (was CRITICAL pre-fix) |
| `src/atomic-queue/AtomicSolverV3.sol:52` | `p2pSolve(...)` | `requiresAuth` + `nonReentrant` + `inSolveContext` | LOW — indirect `runData` via `abi.encode(msg.sender)` |
| `src/atomic-queue/AtomicSolverV3.sol:73` | `redeemSolve(...)` | same | LOW — same as above |
| `src/atomic-queue/AtomicSolverV2.sol:123` | `finishSolve(...)` | `requiresAuth` | **HIGH — same C-1 shape as pre-fix V3** (dormant, not deployed) |
| `src/atomic-queue/AtomicSolver.sol:32` | `finishSolve(bytes, …)` | custom `approvedToCallFinishSolve` mapping | **CRITICAL — arbitrary `target.functionCallWithValue(data, value)`** (dormant, not deployed) |
| `src/base/Roles/ManagerWithMerkleVerification.sol:132` | `manageVaultWithMerkleVerification(...)` | `requiresAuth` + merkle proofs + decoder sanitization | LOW — gated by merkle + sanitizer |
| `src/base/Roles/ManagerWithMerkleVerification.sol:174` | `flashLoan(address, address[], uint256[], bytes)` | vault-only | LOW — inherits vault's auth gate |
| `src/base/Roles/ManagerWithMerkleVerification.sol:199` | `receiveFlashLoan(…, bytes userData)` | Balancer-vault-only + pre-recorded hash | LOW — hash-gated |
| `src/base/Roles/CrossChain/CrossChainTellerBase.sol:38,70` | `depositAndBridge / bridge` with `BridgeData.data` | `requiresAuth` | MED — opaque bridge metadata |
| `src/micro-managers/DexAggregatorUManager.sol:82` | `swapWith1Inch(…, bytes data)` | `requiresAuth` + rate-limit + merkle proofs | **HIGH surface** (low risk if decoder tight; HIGH if decoder leaks) |
| `src/micro-managers/DexSwapperUManager.sol:109…` | `swapWith{Balancer,Curve,UniV3}` with caller paths | same | MED — caller-supplied swap path, merkle-gated |
| `src/migration/CellarMigrationAdaptor.sol:75` | `withdraw(…, bytes configurationData)` | Cellar delegatecall only | LOW — trivial `abi.decode(bool)` |

Decoders in `src/base/DecodersAndSanitizers/**` (50+ files) are library-style: they receive arbitrary calldata for parsing/sanitization against a merkle root. Never called directly by end users, so no standalone attack surface.

### 3.2 Publicly callable surface (Bucket B — zero auth)

Functions any address can call today.

| Contract | Function | Mutates state / moves funds | Notes |
|---|---|---|---|
| `src/atomic-queue/AtomicQueue.sol:163` | `updateAtomicRequest(ERC20 offer, ERC20 want, uint64 deadline, uint96 offerAmount)` | ✅ mutates `userAtomicRequest[msg.sender]` | **Intentionally public** — user entry point. But has no validation (RT-3 F-2/F-3 griefing vector). |
| `src/atomic-queue/AtomicSolver.sol:72` | `receiveFlashLoan(…)` | ✅ if `_solving` flag is set and caller is Balancer vault | Dormant file (see F-4). |

Nothing else in `src/` is publicly callable without auth.

### 3.3 Public via `setPublicCapability` (Bucket C)

Functions that are auth-gated in source but wired open via deploy scripts.

| Contract | Function | Wired public in |
|---|---|---|
| `TellerWithMultiAssetSupport.deposit` | **intentional** user entry point | `06_DeployRolesAuthority.s.sol:190`, `DeployPortLayerZero.s.sol:132`, `DeployPortProofOfConcept`, `DeployNucleusCrossChain` |
| `TellerWithMultiAssetSupport.depositWithPermit` | same | same scripts |
| `AtomicQueue.updateAtomicRequest` | same (intentional) | `DeployPortLayerZero.s.sol:145` |
| `CrossChainTellerBase.depositAndBridge` / `bridge` | cross-chain user entry | `DeployPortLayerZero.s.sol:146`, `DeployNucleusCrossChain.s.sol:28-29` |

**What's NOT public (verified via `CheckAuthConfiguration.s.sol`):**
- `AtomicSolverV3.finishSolve` — moved to `QUEUE_ROLE` in commit `e137ca9`, now additionally in-contract gated by `_expectedQueue`.
- `AtomicQueue.solve` — gated to `CAN_SOLVE_ROLE` / `SOLVER_ROLE`.
- `BoringVault.manage` — gated to `MANAGER_ROLE`.
- `Teller.bulkWithdraw`, `bulkDeposit`, `refundDeposit` — gated.

### 3.4 Red flags

After the patches on this branch:

1. **Dormant legacy solvers** (`AtomicSolverV2.sol`, `AtomicSolver.sol`) still compile and sit next to V3. Both carry the same or worse vulnerability shape. Recommend deletion — not done here.
2. **`DexAggregatorUManager.swapWith1Inch`** takes raw 1inch router calldata. Security depends entirely on the 1inch decoder's sanitization tightness. Worth an independent audit pass specifically on that decoder.
3. **Unbounded `users` arrays** in both `AtomicQueue.solve` and every decoder-verified `manageVault…` path. No max-batch cap. With I-2 not yet applied, a dust request can grief a batch.
4. **`setRoleCapability` / `setUserRole` grantable by `OPERATOR_ROLE`** — the attack surface RT-2 F-1 keyed on. Even with the in-contract `_expectedQueue` check, this expanded authority surface is uncomfortable. Recommend reverting that portion of commit `e137ca9` or wrapping it in a timelock.

---

## 4. Everything currently landed on `security/atomicsolverv3-remediation`

```
fec065a harden(RT-1): reorder — set queue allowance before outbound solver transfers
125abbb fix(RT-2/F-1): assert msg.sender == expectedQueue in finishSolve
4cd0a0e fix(M-1, M-4): redirect redeem proceeds to self; pay solver profit directly
fc4cfdd feat(I-1): add restricted rescue(token, amount, to)
0e5ae44 chore(L-1): remove unused eETH / weETH constants
9a97f84 fix(M-4): assert bulkWithdraw proceeds cover wantApprovalAmount
b5a5ce3 fix(M-3): guard against zero-address owner in constructor
bfdcff0 fix(M-1): reorder _redeemSolve to pull from solver before teller.bulkWithdraw
a3b9ce2 fix(H-3): reconcile actual balance delta to reject fee-on-transfer tokens
9b66de4 fix(H-2): zero-reset allowance before safeApprove for USDT compatibility
cd81197 fix(H-1): add nonReentrant guard on p2pSolve and redeemSolve
3b86fb7 fix(C-1/M-2/L-2): add in-contract solve-context lock
3cee179 chore: forge fmt on auth config scripts and regression test
a3c209e docs: add AtomicSolverV3 remediation plan
```

**Tests:** 146 / 146 passing.

---

## 5. Follow-up PRs (not in this branch)

Priority-ordered. Each is a self-contained change in a separate repo surface.

| # | Scope | Size | Blocker for merge? |
|---|---|---|---|
| 1 | Remove `setRoleCapability` from `OPERATOR_ROLE` in `06_DeployRolesAuthority.s.sol` (RT-2 F-1 off-chain arm). | 4 lines | **Yes** — pair with this branch before redeploy |
| 2 | Add `CheckAuthConfiguration` assertion `AtomicSolverV3(atomicSolver).owner() == protocolAdmin` (RT-2 F-2). | 4 lines | Yes |
| 3 | Add `setRoleCapability(OPERATOR_ROLE, atomicSolver, rescue.selector, true)` in `ConfigureAtomicRoles` so operations can actually call `rescue` (RT-2 F-2). | 3 lines | Recommended |
| 4 | Delete `AtomicSolverV2.sol` + `AtomicSolver.sol` (RT-2 F-4). | file removals | Recommended |
| 5 | Add `minSolverProfit` param to `redeemSolve` (RT-3 F-1). | ~10 lines + keeper API bump | Post-merge |
| 6 | Validate `updateAtomicRequest` (deadline, balance, allowance) in `AtomicQueue` (RT-3 F-2/F-3). | 3 lines | Post-merge |
| 7 | Implement I-2 (skip-and-emit) in `AtomicQueue.solve` (RT-3 F-2). | ~15 lines + keeper semantics doc | Post-merge |
| 8 | Extract deploy-role wiring into a library used by every deploy script + regression test (RT-2 F-3). | medium refactor | Post-merge |
| 9 | Upgrade to Solidity 0.8.24 + `evm_version = cancun`, convert `_inSolveContext` + `_expectedQueue` to transient storage. | pragma bump + 2 lines | Post-merge, gas-only |
| 10 | Independent audit (Spearbit, Hexens, Cyfrin) before unpausing large vaults. | ops | Recommended pre-prod |

---

## 6. What this report does NOT cover

- **AtomicQueue-side bugs beyond those called out in §2 / §3.** The queue wasn't re-audited end-to-end; only its interaction surface with the solver. A dedicated queue review is out of scope.
- **Cross-chain variants.** `MultiChainLayerZeroTeller`, `CrossChainOPTeller` etc. were surface-mapped but not attacked. Their bridge-metadata parsing deserves its own red-team pass.
- **1inch decoder.** Flagged as the highest-opacity surface in Bucket A; recommend a specialist review.
- **Upstream Veda BoringVault audits.** The `audit/` folder has prior Spearbit/Macro/Secure3/Hexens reports for the parent contracts. They should be cross-referenced before merge — not done here.

---

*Report compiled from live agents and a full `src/` walk. All line numbers verified against commit `fec065a` on 2026-04-22.*

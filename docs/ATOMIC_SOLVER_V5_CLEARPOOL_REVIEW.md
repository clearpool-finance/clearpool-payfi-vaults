# AtomicSolverV5 — Clearpool Team Report & Contract Surface Inventory

**Companion to:** `ATOMIC_SOLVER_V5_REMEDIATION.md`
**Branch:** `security/atomicsolverv3-remediation`
**Clearpool team conducted:** after all 12 hack-report fixes landed (commit `fc4cfdd`), prior to merge
**Methodology:** three parallel adversarial sub-agents, each with a distinct attacker lens, plus a full `src/` surface survey

---

## 0. TL;DR

- **No new fund-draining exploit found** on top of the hack-report remediation.
- **One genuine HIGH-severity finding** (CT-2 / F-1) — a rogue-queue cascade reachable via compromised `OPERATOR_ROLE` — required **two iterations** to close fully:
  - Iteration 1 (`125abbb`): `_expectedQueue` snapshot. Catches a sibling queue intercepting a callback from a solve started with a different queue. **Incomplete** — does not help when the attacker is the one calling `p2pSolve(rogueQueue, …)` (`_expectedQueue` is set to the rogue queue, so `msg.sender == _expectedQueue` passes).
  - Iteration 2 (`5ae4100`): on-contract `approvedQueues` whitelist gated by `requiresAuth`. This closes the real attack — `p2pSolve` reverts at entry with `UnapprovedQueue` before any state change.
  - Off-chain tightening (`96fc2af`): removed `setRoleCapability` from `OPERATOR_ROLE`.
  - Regressions: `test_rogueQueueDirectFinishSolve_blockedByNotInSolveContext` (direct call) and `test_rogueQueue_endToEnd_blockedByApprovedQueueWhitelist` (full exploit reproduction through `p2pSolve` → `RogueQueue.solve` → `finishSolve`).
- **One defense-in-depth hardening** (CT-1 / approval-before-transfer ordering) implemented in `fec065a`.
- **Operational finding CT-2/F-2** (`rescue()` only callable by deployer EOA) fixed in `96fc2af`: `OPERATOR_ROLE` now holds `rescue.selector` and `CheckAuthConfiguration` asserts ownership is on `protocolAdmin`.
- **Dormant legacy V2 solver deleted** (`36fabe3`). **V1 also deleted** in the Rafal-follow-up commit; the migration test was migrated to construct `AtomicSolverV5` instead (the production solver).
- **Queue-side griefing finding CT-3/F-2+F-3** partially fixed at submission time (`f3e2fd4`): `updateAtomicRequest` now rejects past deadlines, insufficient balance, insufficient allowance. The full fix (batch-failure isolation I-2) requires changing `AtomicQueue.solve` semantics — keeper-breaking — and remains a follow-up.
- **CT-3/F-1 rate-sandwich griefing** remains a follow-up (`minSolverProfit` param) because it changes the solver selector and needs keeper coordination.

---

## 1. Clearpool team methodology

Three adversarial agents ran in parallel, each briefed with a distinct threat model:

| Agent | Lens                                                                                | Agent ID            |
| ----- | ----------------------------------------------------------------------------------- | ------------------- |
| CT-1  | Token-callback & contract-reentrancy (ERC777, rebasing, rate-provider hooks)        | `ad58ea286a353b2b9` |
| CT-2  | Auth / RolesAuthority misconfiguration, callback provenance, deploy-script coverage | `af315004ece6fbafb` |
| CT-3  | Economic griefing, MEV, oracle manipulation, batch DoS                              | `a109209bf77cbea56` |

Each was given the patched source (`src/atomic-queue/AtomicSolverV5.sol`), the remediation doc, and the deploy-script context. Instructions: "quality of negative finding > fabricated positive" — agents were told to explicitly report _no exploit_ if they couldn't construct one.

---

## 2. Consolidated findings

### [CT-2 / F-1] — HIGH — Rogue queue via compromised OPERATOR_ROLE → `finishSolve` drain

**Status:** ✅ Fixed in two iterations. See chronology below — the first pass was incomplete and a review surfaced the gap.

**Attack chain:**

1. `OPERATOR_ROLE` was granted `authority.setUserRole` and `authority.setRoleCapability` in commit `e137ca9` (line 182–189 of `06_DeployRolesAuthority.s.sol`). Anyone holding this role can hand out `QUEUE_ROLE`.
2. Attacker (compromised operator) calls `authority.setUserRole(rogueQueue, QUEUE_ROLE, true)` where `rogueQueue` is an attacker-controlled contract that implements only the `solve` selector.
3. Same attacker still holds `p2pSolve` capability via `ConfigureAtomicRoles`. They call `solver.p2pSolve(rogueQueue, ...)`.
4. Inside `p2pSolve`, the `inSolveContext` modifier opens — `_inSolveContext = 1`, `_expectedQueue = rogueQueue` (the attacker-supplied queue).
5. `queue.solve(...)` dispatches to the rogue queue, which immediately calls `solver.finishSolve(attackerRunData, address(solver), offer, want, offerReceived, wantApprovalAmount)`.
6. Every check in `finishSolve` passes: `_inSolveContext == 1`, `msg.sender == _expectedQueue` (both are the rogue queue), `initiator == address(this)`, `requiresAuth` (rogueQueue holds `QUEUE_ROLE`).
7. `_p2pSolve` decodes `attackerRunData = (P2P, victim, 0, MAX)` and runs `want.safeTransferFrom(victim, address(this), wantApprovalAmount)` → drains any address with a standing approval to `AtomicSolverV5`.

**Why `_expectedQueue` alone is not enough.** The snapshot catches a sibling `QUEUE_ROLE` holder who tries to intercept a callback from a solve that was started with a DIFFERENT queue. It does not help here: the attacker is the one calling `p2pSolve(rogueQueue, …)`, so the snapshot is set to the rogue queue and the check trivially passes. This gap was missed in the first remediation pass (commit `125abbb`) and flagged by a code review. The initial wording of this report overstated the fix; it is now corrected.

#### Fix iteration 1 (commit `125abbb`) — partial

Snapshot the queue address at solve entry; assert `msg.sender == _expectedQueue` in `finishSolve`.

```solidity
modifier inSolveContext(address queue) {
    if (_inSolveContext != 0) revert AtomicSolverV5___AlreadyInSolveContext();
    _inSolveContext = 1;
    _expectedQueue = queue;
    _;
    _inSolveContext = 0;
    _expectedQueue = address(0);
}
```

**Value provided.** Blocks cross-solve interception: if two legitimate queues both hold `QUEUE_ROLE` and share a solver, queue B cannot steal a callback that queue A started. That's a useful invariant.

**Gap.** Does not block the case where the attacker starts the solve with a queue they control.

#### Fix iteration 2 (commit `5ae4100`) — full closure

Add an explicit on-contract whitelist of approved queues. Approvals are `requiresAuth`-gated (owner-only by default).

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
    ...
}
```

**Why it closes the real attack.** `p2pSolve(rogueQueue, …)` now reverts at the very top of the modifier, _before_ `_inSolveContext` opens, _before_ any state change, _before_ the callback fires. A compromised OPERATOR can still mint `QUEUE_ROLE` on any address — but cannot route the solver through that address without the owner first approving it via `setQueueApproved`. The Authority surface is now irrelevant to this attack class.

**Combined guard stack** (finishSolve now enforces four layers, in order):

1. `_inSolveContext == 1` — a solve is live.
2. `msg.sender == _expectedQueue` — the callback is from the queue that was used to open this solve.
3. `initiator == address(this)` — _vestigial_ in the current contract (documented as such in NatSpec). Retained as defense-in-depth against a future queue implementation that forgets to hardcode `msg.sender` as initiator.
4. `requiresAuth` — Authority layer.

Layer (3) is the original V3 check; it predates layers (1), (2), and the `approvedQueues` whitelist. With those three in place, it provides zero additional protection against any currently reachable attack.

**Regression tests.**

- `test_rogueQueueDirectFinishSolve_blockedByNotInSolveContext` — a rogue `QUEUE_ROLE` holder calls `finishSolve` directly with no live solve; reverts at `NotInSolveContext`.
- `test_rogueQueue_endToEnd_blockedByApprovedQueueWhitelist` — **the full CT-2/F-1 attack chain**. Deploys a `RogueQueue` mock, simulates a compromised OPERATOR that mints `QUEUE_ROLE` on it, has the attacker invoke `p2pSolve(rogueQueue, …)`. Asserts the call reverts with `UnapprovedQueue(rogueQueue)` and that victim funds / solver balance / attacker allowance are all unchanged.

**Off-chain companion (commit `96fc2af`).** Removed `setRoleCapability` from `OPERATOR_ROLE`. `setUserRole` is retained (borrower onboarding needs it); the approved-queue whitelist is what makes that retention safe.

---

### [CT-2 / F-2] — HIGH (operational) — `rescue()` reachable only by owner, no role

**Status:** ✅ Fixed in commit `96fc2af`.

**Finding.** The new `rescue(ERC20, uint256, address)` in commit `fc4cfdd` is gated by `requiresAuth`. Before this fix, no deploy script granted `rescue.selector` to any role, so only `AtomicSolverV5.owner()` could call it — defaulting to the deployer EOA until `setOwner` ran.

**Shipped fix (`96fc2af`).**

- `ConfigureAtomicRoles.s.sol`: `setRoleCapability(OPERATOR_ROLE, atomicSolver, bytes4(keccak256("rescue(address,uint256,address)")), true)`.
- `CheckAuthConfiguration.s.sol`: asserts `AtomicSolverV5(atomicSolver).owner() == protocolAdmin` AND `canCall(operator, atomicSolver, rescue.selector) == true`. Any future deploy that skips the ownership transfer or role wiring now fails the check instead of shipping.

---

### [CT-2 / F-3] — MEDIUM — Regression coverage narrow

**Status:** ⚠️ Open — tracked for follow-up.

`test/AtomicSolverAuthRegression.t.sol` mirrors `ConfigureAtomicRoles.s.sol` only. Four _other_ production deploy paths exist, each redeclaring `QUEUE_ROLE = 10` as a local constant (no shared definition). If a silent edit in one of them re-introduces `setPublicCapability(finishSolve)`, the current regression passes.

**Fix.** Extract the canonical wiring into a library (`DeployAtomicRolesLib.sol`) imported by every deploy script _and_ the regression test. Drive the regression with each production deploy path. Not done here — cross-cutting change.

---

### [CT-2 / F-4] — LOW — `AtomicSolverV2.sol` dormant but compiled

**Status:** ✅ V2 deleted (`36fabe3`). ✅ V1 deleted in the Rafal follow-up commit; migration test re-pointed at `AtomicSolverV5`.

**Finding.** `AtomicSolverV2.sol` had the **identical** C-1 vulnerability shape as pre-fix V3. `AtomicSolver.sol` (V1) has a _more severe_ pattern — it executes arbitrary `target.functionCallWithValue(data, value)` with caller-supplied `targets`/`ammo` arrays, gated only by a custom `approvedToCallFinishSolve` mapping (not the Auth framework).

**Shipped.** `AtomicSolverV2.sol` deleted — zero references anywhere in the repo (verified by `grep -r AtomicSolverV2 script/ test/`).

**V1 deleted.** Inspection showed the migration test only constructs `AtomicSolver` and never invokes any of its vulnerable surfaces (`finishSolve`, `doStuff`, `receiveFlashLoan`); it was test set-dressing, not under test. The test was repointed at `AtomicSolverV5` (the production solver, with the same `IAtomicSolver` interface) and `src/atomic-queue/AtomicSolver.sol` was removed. Trail of Bits "Maturing your smart contracts beyond private key risk" (June 2025) and the broader Spearbit / Cyfrin convention treat dormant code with critical-grade attack surfaces as audit-track footguns regardless of whether they're deployed — this closes the case.

---

### [CT-3 / F-1] — HIGH (griefing) — Rate-sandwich collapses solver profit to zero

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

### [CT-3 / F-2, F-3] — MEDIUM — Batch DoS via public `updateAtomicRequest`

**Status:** ⚠️ **Partially fixed** in commit `f3e2fd4`. Full fix (I-2) remains a follow-up.

**Finding.** `AtomicQueue.updateAtomicRequest` (line 163) is publicly callable by design and previously had no validation. Combined with the queue's all-or-nothing batch semantics (I-2), any bogus request could grief legitimate solves.

**Shipped (`f3e2fd4`) — submission-time validation.**

```solidity
if (offerAmount != 0) {
    if (deadline <= block.timestamp) revert AtomicQueue__PastDeadline(deadline, block.timestamp);
    uint256 bal = offer.balanceOf(msg.sender);
    if (bal < offerAmount) revert AtomicQueue__InsufficientOfferBalance(bal, offerAmount);
    uint256 allowance = offer.allowance(msg.sender, address(this));
    if (allowance < offerAmount) revert AtomicQueue__InsufficientOfferAllowance(allowance, offerAmount);
}
```

`offerAmount == 0` preserved as the canonical cancel path (no validation on cancel).

**Still open.** State can still change between `updateAtomicRequest` and `solve` (user transfers out, revokes allowance, deadline passes). The full fix requires I-2 skip-and-emit in `solve` itself — a keeper-breaking change deferred to a separate PR.

---

### [CT-1 / Hardening] — LOW → DONE — Approve-before-outbound-transfer

**Status:** ✅ Applied in commits `125abbb` (for `_p2pSolve`, folded into the WrongQueue commit) and `fec065a` (for `_redeemSolve`).

**Finding.** CT-1 exhaustively ruled out any exploitable re-entry against the patched V3. The only defense-in-depth recommendation: reorder `want.safeApprove(queue, ...)` to run _before_ the outbound `offer.safeTransfer(solver, ...)` (p2p path) and `want.safeTransfer(solver, solverProfit)` (redeem path). This hardens against any hypothetical future function addition that might observe mid-callback state.

**Applied.**

---

### [CT-3 / F-4 through F-8] — Verified safe

- **F-4 (FoT profit ambiguity):** pre-funded donations are correctly excluded by the `balanceOf` delta pattern; no exploit.
- **F-5 (approval-zero window):** guarded by `nonReentrant` + `_inSolveContext`.
- **F-6 (teller vault pointer):** `TellerWithMultiAssetSupport.vault` is `immutable`. Non-issue.
- **F-7 (Accountant pause):** `getRate()` does not check `isPaused`; in-flight withdrawals proceed at last-known rate. Desired property (funds not trapped).
- **F-8 (shares-transfer hook):** `BoringVault` uses plain solmate ERC20, no transfer hooks. Non-issue.

### [CT-1 / entire scope] — Verified safe

Agent explicitly enumerated and ruled out each re-entry path: `p2pSolve`/`redeemSolve` (blocked by `nonReentrant` + `_inSolveContext`), `finishSolve` (blocked by `initiator` + `_expectedQueue`), `rescue` (blocked by `_inSolveContext != 0`), view functions (write nothing). Storage-slot layout clean — `Auth (2)` → `ReentrancyGuard (1)` → solver state. No collisions.

---

## 3. Contract surface inventory (`src/`)

Produced by surface-survey sub-agent (`a5a872500bf19947d`) over 125 `.sol` files. Full report retained in agent transcript; condensed here.

### 3.1 Arbitrary-data surface (Bucket A)

Functions that accept caller-supplied opaque data (bytes / bytes[] / function-selector blobs / runData).

| Contract                                                   | Function                                                      | Auth                                                                | Risk                                                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `src/base/BoringVault.sol:52`                              | `manage(address, bytes, uint256)`                             | `requiresAuth`                                                      | MED — arbitrary low-level call                                                               |
| `src/base/BoringVault.sol:68`                              | `manage(address[], bytes[], uint256[])`                       | `requiresAuth`                                                      | MED — batched arbitrary calls                                                                |
| `src/atomic-queue/AtomicQueue.sol:186`                     | `solve(ERC20, ERC20, address[], bytes, address)`              | `requiresAuth`                                                      | MED — opaque `runData` passed to solver                                                      |
| **`src/atomic-queue/AtomicSolverV5.sol:101`**              | `finishSolve(bytes, address, ERC20, ERC20, uint256, uint256)` | `requiresAuth` + `_inSolveContext` + `_expectedQueue` + `initiator` | **LOW post-fix** (was CRITICAL pre-fix)                                                      |
| `src/atomic-queue/AtomicSolverV5.sol:52`                   | `p2pSolve(...)`                                               | `requiresAuth` + `nonReentrant` + `inSolveContext`                  | LOW — indirect `runData` via `abi.encode(msg.sender)`                                        |
| `src/atomic-queue/AtomicSolverV5.sol:73`                   | `redeemSolve(...)`                                            | same                                                                | LOW — same as above                                                                          |
| `src/atomic-queue/AtomicSolverV2.sol:123`                  | `finishSolve(...)`                                            | `requiresAuth`                                                      | **HIGH — same C-1 shape as pre-fix V3** (dormant, not deployed)                              |
| `src/atomic-queue/AtomicSolver.sol:32`                     | `finishSolve(bytes, …)`                                       | custom `approvedToCallFinishSolve` mapping                          | **CRITICAL — arbitrary `target.functionCallWithValue(data, value)`** (dormant, not deployed) |
| `src/base/Roles/ManagerWithMerkleVerification.sol:132`     | `manageVaultWithMerkleVerification(...)`                      | `requiresAuth` + merkle proofs + decoder sanitization               | LOW — gated by merkle + sanitizer                                                            |
| `src/base/Roles/ManagerWithMerkleVerification.sol:174`     | `flashLoan(address, address[], uint256[], bytes)`             | vault-only                                                          | LOW — inherits vault's auth gate                                                             |
| `src/base/Roles/ManagerWithMerkleVerification.sol:199`     | `receiveFlashLoan(…, bytes userData)`                         | Balancer-vault-only + pre-recorded hash                             | LOW — hash-gated                                                                             |
| `src/base/Roles/CrossChain/CrossChainTellerBase.sol:38,70` | `depositAndBridge / bridge` with `BridgeData.data`            | `requiresAuth`                                                      | MED — opaque bridge metadata                                                                 |
| `src/micro-managers/DexAggregatorUManager.sol:82`          | `swapWith1Inch(…, bytes data)`                                | `requiresAuth` + rate-limit + merkle proofs                         | **HIGH surface** (low risk if decoder tight; HIGH if decoder leaks)                          |
| `src/micro-managers/DexSwapperUManager.sol:109…`           | `swapWith{Balancer,Curve,UniV3}` with caller paths            | same                                                                | MED — caller-supplied swap path, merkle-gated                                                |
| `src/migration/CellarMigrationAdaptor.sol:75`              | `withdraw(…, bytes configurationData)`                        | Cellar delegatecall only                                            | LOW — trivial `abi.decode(bool)`                                                             |

Decoders in `src/base/DecodersAndSanitizers/**` (50+ files) are library-style: they receive arbitrary calldata for parsing/sanitization against a merkle root. Never called directly by end users, so no standalone attack surface.

### 3.2 Publicly callable surface (Bucket B — zero auth)

Functions any address can call today.

| Contract                               | Function                                                                            | Mutates state / moves funds                               | Notes                                                                                              |
| -------------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `src/atomic-queue/AtomicQueue.sol:163` | `updateAtomicRequest(ERC20 offer, ERC20 want, uint64 deadline, uint96 offerAmount)` | ✅ mutates `userAtomicRequest[msg.sender]`                | **Intentionally public** — user entry point. But has no validation (CT-3 F-2/F-3 griefing vector). |
| `src/atomic-queue/AtomicSolver.sol:72` | `receiveFlashLoan(…)`                                                               | ✅ if `_solving` flag is set and caller is Balancer vault | Dormant file (see F-4).                                                                            |

Nothing else in `src/` is publicly callable without auth.

### 3.3 Public via `setPublicCapability` (Bucket C)

Functions that are auth-gated in source but wired open via deploy scripts.

| Contract                                           | Function                         | Wired public in                                                                                                             |
| -------------------------------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `TellerWithMultiAssetSupport.deposit`              | **intentional** user entry point | `06_DeployRolesAuthority.s.sol:190`, `DeployPortLayerZero.s.sol:132`, `DeployPortProofOfConcept`, `DeployNucleusCrossChain` |
| `TellerWithMultiAssetSupport.depositWithPermit`    | same                             | same scripts                                                                                                                |
| `AtomicQueue.updateAtomicRequest`                  | same (intentional)               | `DeployPortLayerZero.s.sol:145`                                                                                             |
| `CrossChainTellerBase.depositAndBridge` / `bridge` | cross-chain user entry           | `DeployPortLayerZero.s.sol:146`, `DeployNucleusCrossChain.s.sol:28-29`                                                      |

**What's NOT public (verified via `CheckAuthConfiguration.s.sol`):**

- `AtomicSolverV5.finishSolve` — moved to `QUEUE_ROLE` in commit `e137ca9`, now additionally in-contract gated by `_expectedQueue`.
- `AtomicQueue.solve` — gated to `CAN_SOLVE_ROLE` / `SOLVER_ROLE`.
- `BoringVault.manage` — gated to `MANAGER_ROLE`.
- `Teller.bulkWithdraw`, `bulkDeposit`, `refundDeposit` — gated.

### 3.4 Red flags

After the patches on this branch:

1. **Dormant legacy solvers** (`AtomicSolverV2.sol`, `AtomicSolver.sol`) still compile and sit next to V3. Both carry the same or worse vulnerability shape. Recommend deletion — not done here.
2. **`DexAggregatorUManager.swapWith1Inch`** takes raw 1inch router calldata. Security depends entirely on the 1inch decoder's sanitization tightness. Worth an independent audit pass specifically on that decoder.
3. **Unbounded `users` arrays** in both `AtomicQueue.solve` and every decoder-verified `manageVault…` path. No max-batch cap. With I-2 not yet applied, a dust request can grief a batch.
4. **`setRoleCapability` / `setUserRole` grantable by `OPERATOR_ROLE`** — the attack surface CT-2 F-1 keyed on. Even with the in-contract `_expectedQueue` check, this expanded authority surface is uncomfortable. Recommend reverting that portion of commit `e137ca9` or wrapping it in a timelock.

---

## 4. Everything currently landed on `security/atomicsolverv3-remediation`

```
5ae4100   fix(CT-2/F-1 take 2): approvedQueues whitelist (closes the setUserRole gap)
f3e2fd4   fix(CT-3/F-2+F-3):   validate preconditions in updateAtomicRequest
96fc2af   fix(CT-2/F-1,F-2):   tighten OPERATOR authority + wire rescue role + check assertions
36fabe3   chore(CT-2/F-4):     delete dormant AtomicSolverV2
05b8f6c   docs:                collapse validation table to single status column
4715a87   docs:                refresh remediation doc to reflect shipped state
6524195   docs:                add clearpool team report + contract surface inventory (this file)
fec065a   harden(CT-1):        approve-before-outbound-transfer (redeem path)
125abbb   fix(CT-2/F-1):       msg.sender == _expectedQueue in finishSolve + p2p approve reorder
4cd0a0e   fix(M-1, M-4):       redirect bulkWithdraw proceeds to self; pay solver profit last
fc4cfdd   feat(I-1):           restricted rescue(token, amount, to)
0e5ae44   chore(L-1):          remove unused eETH / weETH constants
9a97f84   fix(M-4):            assert bulkWithdraw proceeds >= wantApprovalAmount (superseded by 4cd0a0e)
b5a5ce3   fix(M-3):            zero-address owner guard
bfdcff0   fix(M-1):            CEI reorder in _redeemSolve (superseded by 4cd0a0e)
a3b9ce2   fix(H-3):            FoT balance-delta reconcile + early revert
9b66de4   fix(H-2):            USDT zero-reset before safeApprove
cd81197   fix(H-1):            ReentrancyGuard + nonReentrant on outer paths
3b86fb7   fix(C-1/M-2/L-2):    in-contract solve-context lock (+ wires up L-2 error)
3cee179   chore:               forge fmt on auth scripts
a3c209e   docs:                initial remediation plan
```

**Tests:** 146 / 146 passing (`forge test`), including `test_rogueQueueWithQueueRoleStillBlocked` added for §2 / CT-2 F-1.

Commits `bfdcff0` and `9a97f84` are retained for audit trail but their effective diffs are folded into `4cd0a0e` which supersedes the initial M-1/M-4 design. Reviewers should read `4cd0a0e` as the authoritative form.

---

## 5. Follow-up status

**Folded into this branch** (low-risk defensive items originally scoped as follow-up PRs):

| #   | Scope                                                                                                                                           | Landed in                   |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| 1   | Remove `setRoleCapability` from `OPERATOR_ROLE` (CT-2 F-1 off-chain arm).                                                                       | `96fc2af`                   |
| 2   | `CheckAuthConfiguration`: `AtomicSolverV5.owner() == protocolAdmin`, operator can `rescue`, operator cannot `setRoleCapability`.                | `96fc2af`                   |
| 3   | Wire `OPERATOR_ROLE` to `rescue.selector` in `ConfigureAtomicRoles`.                                                                            | `96fc2af`                   |
| 4   | Delete `AtomicSolverV2.sol` (V2 in `36fabe3`); delete `AtomicSolver.sol` (V1 in Rafal follow-up); migration test repointed at `AtomicSolverV5`. | `36fabe3` + Rafal follow-up |
| 6   | Validate `updateAtomicRequest` (deadline, balance, allowance).                                                                                  | `f3e2fd4`                   |

**Deliberately kept out** (each merits its own PR):

| #   | Scope                                                                                 | Reason kept out                                                               |
| --- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| 5   | `minSolverProfit` param on `redeemSolve` (CT-3 F-1).                                  | Changes solver selector → breaks keeper bots. Needs rollout plan.             |
| 7   | I-2 skip-and-emit in `AtomicQueue.solve`.                                             | Changes batch semantics from all-or-nothing to partial-fill. Keeper-breaking. |
| 8   | Extract deploy-role wiring into shared library + drive regressions off it.            | Medium refactor of 4+ deploy scripts. Belongs in cleanup PR.                  |
| 9   | Solidity 0.8.24 + cancun, transient storage for `_inSolveContext` / `_expectedQueue`. | Repo-wide pragma bump. Gas-only.                                              |
| 10  | Independent audit (Spearbit / Hexens / Cyfrin).                                       | Not a code change. **Recommended pre-prod.**                                  |

---

## 6. What this report does NOT cover

- **AtomicQueue-side bugs beyond those called out in §2 / §3.** The queue wasn't re-audited end-to-end; only its interaction surface with the solver. A dedicated queue review is out of scope.
- **Cross-chain variants.** `MultiChainLayerZeroTeller`, `CrossChainOPTeller` etc. were surface-mapped but not attacked. Their bridge-metadata parsing deserves its own clearpool team pass.
- **1inch decoder.** Flagged as the highest-opacity surface in Bucket A; recommend a specialist review.
- **Upstream Veda BoringVault audits.** The `audit/` folder has prior Spearbit/Macro/Secure3/Hexens reports for the parent contracts. They should be cross-referenced before merge — not done here.

---

_Report compiled from live agents and a full `src/` walk. All line numbers verified against commit `fec065a` on 2026-04-22._

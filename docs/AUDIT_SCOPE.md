# Audit scope

- Repository: `clearpool-finance/clearpool-payfi-vaults`
- Commit: `aa0b157` (squash-merge of PR #8 onto `main`, 2026-04-30)
- Tests: 159/159 forge, mainnet-fork test passes, full deploy dry-run completes through `Auth invariants verified`
- Production bridge: LayerZero only. The OP and Hyperlane teller variants exist in the codebase but are not deployed and are not under audit.

## Background

On [date] a `setPublicCapability(AtomicSolverV3, finishSolve, true)` misconfig let anyone drain approvers of `AtomicSolverV3` (~$1.2M USDX). This branch closes the direct cause, every variant the team identified post-incident, and codifies deploy-time invariants so the same misconfig class cannot ship undetected.

50 commits, 41 files changed, +2,389 / −819 lines, 41 audit findings shipped (full ledger in `docs/SYSTEM_AUDIT.md` § 6.5).

## Files in audit scope

### Tier 1 — primary focus

- `src/atomic-queue/AtomicSolverV5.sol`
  - New file. Replaces `AtomicSolver.sol`, `AtomicSolverV2.sol`, and `AtomicSolverV3.sol` (all deleted).
  - Four checks on `finishSolve`: `requiresAuth`, `_inSolveContext == 1`, `msg.sender == _expectedQueue`, `approvedQueues[queue]`.
  - `nonReentrant` on `p2pSolve` and `redeemSolve`.
  - Fee-on-transfer reconcile via balance delta.
  - USDT zero-reset before approve.
  - `_redeemSolve` rewrite: proceeds go to the solver contract, not the solver bot. Solver profit is paid out at the end. Eliminates the standing solver→solver-contract allowance.
  - `rescue(token, amount)` with destination hard-coded to `owner()`.
  - Constructor rejects zero owner.

- `src/atomic-queue/AtomicQueue.sol`
  - `updateAtomicRequest` validates deadline, balance, and allowance at submission time (RT-3).
  - `solve` requires `solver == msg.sender` (Q-1).
  - `viewSolveMetaData` flags zero-output users via bit 4 (Q-3).
  - `_calculateWantAmount` uses `getRateSafe()` instead of `getRate()`.

- `src/base/Roles/AccountantWithRateProviders.sol`
  - `updateExchangeRate` no longer commits a bad rate on bound or delay violation. Rejects, auto-pauses, emits `ExchangeRateUpdateRejected` (A-1).
  - `setRateProviderData` enforces a 5% deviation cap when replacing an existing provider, including the pegged ↔ non-pegged transition (A-3).
  - Hard caps `MAX_UPPER_BOUND = 11000` (+10%) and `MIN_LOWER_BOUND = 9000` (-10%) on `updateUpper` / `updateLower` (A-4).
  - Internal `_pause()` so auto-pause paths don't need `PAUSER_ROLE` (A-7).

- `src/base/Roles/TellerWithMultiAssetSupport.sol`
  - New `isReceivePaused` flag with `pauseReceive` / `unpauseReceive` (N-2).
  - KEYRING_KYC fails closed when `keyringContract == address(0)` (T-4).
  - `bulkDeposit` and `bulkWithdraw` honor `isPaused` (T-7).
  - `bulkWithdraw` gates `msg.sender` and `_to`, plus `nonReentrant` (T-2).
  - `_erc20Deposit` uses `getRateSafe()` and rejects zero-share dust (T-8).

### Tier 2 — focused single-fix changes

- `src/base/Roles/ManagerWithMerkleVerification.sol` — flashloan callback rejects `recipient != address(this)` (V-3).
- `src/base/BoringVault.sol` — `enter` rejects assets with `code.length == 0` (N-4).
- `src/base/Roles/CrossChain/CrossChainTellerBase.sol` — `depositAndBridge` passes `shareLockPeriod = 0` (N-1); `_beforeReceive` checks `isReceivePaused` (N-2). Inherited by the LayerZero teller.
- `src/base/Roles/CrossChain/MultiChainTellerBase.sol` — `addChain` and `allowMessagesFromChain` reject zero `targetTeller` (N-6). Inherited by the LayerZero teller.
- `src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol` — removed `accountant.checkpoint()` from `_lzReceive` (N-2/R-3).

## Specific items the auditor should check

- The four checks on `finishSolve`. Verify each closes a distinct attack class, that none is dead code, and that `approvedQueues` is the only thing that closes the OPERATOR-grants-QUEUE_ROLE-on-rogue-queue cascade.
- `setQueueApproved` is owner-only. No role is granted that selector in the deploy scripts.
- `updateExchangeRate` reorder. The reject path must not write `_exchangeRate`, must not advance `_lastUpdateTimestamp`, and must not call `_checkpointInterestAndFees`. The accept path must checkpoint before writing.
- `setRateProviderData` deviation cap. Confirm the pegged-bypass is closed: registering `(true, address(0))` followed by `(false, inflatedProvider)` should fail at the deviation check.
- `_lzReceive` checkpoint removal. The fix relies on the next local op (`deposit`, `bulkWithdraw`, `_erc20Deposit`) calling `checkpoint()` itself. Verify accrual cannot be silently lost.
- `bulkWithdraw` `_to` check is partial. In the canonical solver flow `_to == solver` after M-1, so end-user KYC at this layer just checks the solver itself. Per-end-user compliance at the queue layer is open (documented as follow-up).

## Items deferred, documented in `SYSTEM_AUDIT.md` § 6

- **T-1**: cross-chain receive does not call `checkAccess(receiver)` or honor `depositCap`. A sanctioned address can hold bridged shares on the destination chain. Compliance class, not fund-loss. Design-track.
- **D-5**: `OPERATOR_ROLE` retains `setUserRole`. Bounded by A-3 and A-4 caps and Safe custody, but a RoleAdmin pattern is the cleaner long-term fix.
- **A-4**: per-call ±10% cap, not cumulative. Original prescription was ±5%. Production typically configures bounds at 0.3%, so ±10% is 33× operating envelope. Open for the auditor to weigh in.
- **R-1**: emergency-exit if accountant gets stuck paused. Pre-existing architectural property, not introduced by this branch.
- **V-4 / V-5**: closed practically by V-3's recipient pin.
- **A-5, A-6, A-8/9/10**: economic / scope / infra items.

## Files explicitly out of scope

- `src/base/Roles/CrossChain/CrossChainOPTellerWithMultiAssetSupport.sol` — OP bridge variant. Not deployed.
- `src/base/Roles/CrossChain/MultiChainHyperlaneTellerWithMultiAssetSupport.sol` — Hyperlane bridge variant. Not deployed.
- `src/micro-managers/*` (DexAggregator, DexSwapper, UManager) — not part of any production deploy.
- `src/base/DecodersAndSanitizers/*` — pre-existing decoder library, not changed.
- `lib/`, `node_modules/`, `test/Port/`, `test/EtherFiLiquid1Migration.t.sol` — third-party / framework / fixture.
- `script/Deploy{Nucleus,Port}*` — non-payfi deploy scripts that got noise cleanup but no security-affecting changes.

## Context for the auditor (not under audit)

These are useful for understanding how the in-scope contracts are deployed and validated, but are not subject to audit themselves.

### Deploy pipeline

- `script/CheckAuthConfiguration.s.sol` — deploy-time gate. Asserts:
  - 21 selectors that must not be public
  - `owner() == config.protocolAdmin` for all 7 core contracts
  - `AtomicSolverV5.approvedQueues(atomicQueue) == true`
  - Broadcaster does not retain `OPERATOR_ROLE` / `UPDATE_EXCHANGE_RATE_ROLE` / `PAUSER_ROLE` post-deploy
  - `extcodesize > 0` for `protocolAdmin`, `operator`, `exchangeRateBot`, and (when set) `strategist` and `pauser`
  - If this passes, the system is in the intended state.

- `script/ConfigureAtomicRoles.s.sol` — wires `OPERATOR_ROLE → rescue(address,uint256)` and calls `AtomicSolverV5.setQueueApproved(atomicQueue, true)`.
- `script/deploy/single/06_DeployRolesAuthority.s.sol` — removed the `OPERATOR_ROLE → setRoleCapability` grant (RT-2/F-1).
- `script/deploy/single/08_SetAuthorityAndTransferOwnerships.s.sol` — revokes broadcaster's `OPERATOR_ROLE` before `transferOwnership` (conditional on `broadcaster != config.operator`).
- `script/deploy/deployAll.s.sol` — pipeline ends at `Auth invariants verified`.

### Tests

- `test/RemediationGates.t.sol` — 13 negative tests for N-4, T-7, N-2 receive-pause split, A-3 deviation cap, A-4 bound caps. Includes an `ExposedCrossChainTeller` harness that exposes `_beforeReceive` for direct testing.
- `test/AtomicSolverAuthRegression.t.sol` — rewritten for V5. Includes a `RogueQueue` mock that runs the CT-2/F-1 attack end-to-end.
- `test/AccountantWithRateProviders.t.sol` — A-1 assertion flip; rejected updates must not commit.

## Companion documents

- `docs/SYSTEM_AUDIT.md` — per-finding shipped status, deferrals with rationale.
- `docs/ATOMIC_SOLVER_V5_REMEDIATION.md` — solver fix walk-through.
- `docs/PRE_AUDIT_CHECKLIST.md` — pre-merge gates and cross-chain remediation status.
- `docs/OPERATOR_RUNBOOK.md` — capability matrix, key custody, monitoring requirements.
- `docs/INTEGRATION.md` — integration surface.
- `docs/ATOMIC_SOLVER_V5_CLEARPOOL_REVIEW.md` — internal red-team report.

## Operational state

- V5 has not been deployed to production yet. `CheckAuthConfiguration` will reject the deploy if `operator` or `exchangeRateBot` are EOAs; both must migrate to Safes first.
- CreateX salts must be chosen per deployment. The existing X-Pool salts are mined on mainnet for V3; V5 needs new suffixes.
- The V3 `finishSolve` public-cap revocation has been verified live on mainnet (`isCapabilityPublic == false`, `doesRoleHaveCapability(QUEUE_ROLE=10, …) == true`) and on Flare. See `PRE_AUDIT_CHECKLIST.md`.
- Off-chain monitors (`IERC20.Approval`, `RolesAuthority.UserRoleUpdated`, `AtomicSolverV5.QueueApprovalSet`, `Rescued`) are documented in `OPERATOR_RUNBOOK.md` and need to be wired before broad TVL onboarding.

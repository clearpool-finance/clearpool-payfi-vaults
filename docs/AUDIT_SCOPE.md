# Audit scope

- Repository: `clearpool-finance/clearpool-payfi-vaults`
- Commit: `aa0b157`
- Tests: 159/159 forge, mainnet-fork test passes, full deploy dry-run completes through `Auth invariants verified`
- Production bridge: LayerZero only. The OP and Hyperlane teller variants exist in the codebase but are not deployed and are not under audit.

## Files in audit scope

Nine files. Tier 1 are the substantively rewritten contracts; Tier 2 are focused single-fix changes.

### Tier 1

- `src/atomic-queue/AtomicSolverV5.sol`
  - Four checks on `finishSolve`: `requiresAuth`, `_inSolveContext == 1`, `msg.sender == _expectedQueue`, `approvedQueues[queue]`.
  - `nonReentrant` on `p2pSolve` and `redeemSolve`.
  - Fee-on-transfer reconcile via balance delta.
  - USDT zero-reset before approve.
  - `_redeemSolve`: proceeds go to the solver contract, not the solver bot. Solver profit is paid out at the end. Eliminates the standing solver→solver-contract allowance.
  - `rescue(token, amount)` with destination hard-coded to `owner()`.
  - Constructor rejects zero owner.

- `src/atomic-queue/AtomicQueue.sol`
  - `updateAtomicRequest` validates deadline, balance, and allowance at submission time.
  - `solve` requires `solver == msg.sender`.
  - `viewSolveMetaData` flags zero-output users via bit 4.
  - `_calculateWantAmount` uses `getRateSafe()` instead of `getRate()`.

- `src/base/Roles/AccountantWithRateProviders.sol`
  - `updateExchangeRate` rejects bound or delay violations without committing the new rate. Auto-pauses and emits `ExchangeRateUpdateRejected`.
  - `setRateProviderData` enforces a 5% deviation cap when replacing an existing provider, including the pegged ↔ non-pegged transition.
  - Hard caps `MAX_UPPER_BOUND = 11000` (+10%) and `MIN_LOWER_BOUND = 9000` (-10%) on `updateUpper` / `updateLower`.
  - Internal `_pause()` so auto-pause paths don't need `PAUSER_ROLE`.

- `src/base/Roles/TellerWithMultiAssetSupport.sol`
  - New `isReceivePaused` flag with `pauseReceive` / `unpauseReceive`.
  - KEYRING_KYC fails closed when `keyringContract == address(0)`.
  - `bulkDeposit` and `bulkWithdraw` honor `isPaused`.
  - `bulkWithdraw` gates `msg.sender` and `_to`, plus `nonReentrant`.
  - `_erc20Deposit` uses `getRateSafe()` and rejects zero-share dust.

### Tier 2

- `src/base/Roles/ManagerWithMerkleVerification.sol` — flashloan callback rejects `recipient != address(this)`.
- `src/base/BoringVault.sol` — `enter` rejects assets with `code.length == 0`.
- `src/base/Roles/CrossChain/CrossChainTellerBase.sol` — `depositAndBridge` passes `shareLockPeriod = 0`; `_beforeReceive` checks `isReceivePaused`. Inherited by the LayerZero teller.
- `src/base/Roles/CrossChain/MultiChainTellerBase.sol` — `addChain` and `allowMessagesFromChain` reject zero `targetTeller`. Inherited by the LayerZero teller.
- `src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol` — removed `accountant.checkpoint()` from `_lzReceive`.

## Specific items the auditor should check

- The four checks on `finishSolve`. Verify each closes a distinct attack class, that none is dead code, and that `approvedQueues` is the only thing that closes the OPERATOR-grants-QUEUE_ROLE-on-rogue-queue cascade.
- `setQueueApproved` is owner-only. No role is granted that selector in the deploy scripts.
- `updateExchangeRate` reorder. The reject path must not write `_exchangeRate`, must not advance `_lastUpdateTimestamp`, and must not call `_checkpointInterestAndFees`. The accept path must checkpoint before writing.
- `setRateProviderData` deviation cap. Confirm the pegged-bypass is closed: registering `(true, address(0))` followed by `(false, inflatedProvider)` should fail at the deviation check.
- `_lzReceive` checkpoint removal. The fix relies on the next local op (`deposit`, `bulkWithdraw`, `_erc20Deposit`) calling `checkpoint()` itself. Verify accrual cannot be silently lost.
- `bulkWithdraw` `_to` check is partial. In the canonical solver flow `_to == solver`, so end-user KYC at this layer just checks the solver itself. Per-end-user compliance at the queue layer is open (documented as follow-up).

## Open items not in this branch

- **T-1**: cross-chain receive does not call `checkAccess(receiver)` or honor `depositCap`.
- **D-5**: `OPERATOR_ROLE` retains `setUserRole`. Bounded by the deviation and bound caps and Safe custody.
- **A-4 cap level**: per-call ±10% cap, not cumulative. ±5% is open for the auditor to weigh in.
- **R-1**: emergency-exit if accountant gets stuck paused. Pre-existing architectural property.

## Files explicitly out of scope

- `src/base/Roles/CrossChain/CrossChainOPTellerWithMultiAssetSupport.sol` — OP bridge variant. Not deployed.
- `src/base/Roles/CrossChain/MultiChainHyperlaneTellerWithMultiAssetSupport.sol` — Hyperlane bridge variant. Not deployed.
- `src/micro-managers/*` — not part of any production deploy.
- `src/base/DecodersAndSanitizers/*` — pre-existing decoder library.
- `lib/`, `node_modules/`, `test/Port/`, `test/EtherFiLiquid1Migration.t.sol` — third-party / framework / fixture.
- `script/Deploy{Nucleus,Port}*` — non-payfi deploy scripts.

## Context for the auditor (not under audit)

### Deploy pipeline

- `script/CheckAuthConfiguration.s.sol` — deploy-time gate. Asserts:
  - 21 selectors that must not be public
  - `owner() == config.protocolAdmin` for all 7 core contracts
  - `AtomicSolverV5.approvedQueues(atomicQueue) == true`
  - Broadcaster does not retain `OPERATOR_ROLE` / `UPDATE_EXCHANGE_RATE_ROLE` / `PAUSER_ROLE` post-deploy
  - `extcodesize > 0` for `protocolAdmin`, `operator`, `exchangeRateBot`, and (when set) `strategist` and `pauser`

  If this passes, the system is in the intended state.

- `script/ConfigureAtomicRoles.s.sol` — wires `OPERATOR_ROLE → rescue(address,uint256)` and calls `AtomicSolverV5.setQueueApproved(atomicQueue, true)`.
- `script/deploy/single/06_DeployRolesAuthority.s.sol` — `OPERATOR_ROLE` does not hold `setRoleCapability` on the authority.
- `script/deploy/single/08_SetAuthorityAndTransferOwnerships.s.sol` — revokes broadcaster's `OPERATOR_ROLE` before `transferOwnership` (conditional on `broadcaster != config.operator`).
- `script/deploy/deployAll.s.sol` — pipeline ends at `Auth invariants verified`.

### Tests

- `test/RemediationGates.t.sol` — 13 negative tests covering the receive-pause split, rate-provider deviation cap, bound caps, non-contract asset rejection, and `bulkDeposit` pause.
- `test/AtomicSolverAuthRegression.t.sol` — `RogueQueue` mock, three regression tests covering direct `finishSolve`, full attack via rogue queue blocked by `approvedQueues`, and the original wiring.
- `test/AccountantWithRateProviders.t.sol` — assertions verify rejected exchange-rate updates do not commit.

## Companion documents

- `docs/SYSTEM_AUDIT.md` — per-finding shipped status, deferrals with rationale.
- `docs/PRE_AUDIT_CHECKLIST.md` — pre-merge gates and cross-chain status.
- `docs/OPERATOR_RUNBOOK.md` — capability matrix, key custody, monitoring requirements.
- `docs/INTEGRATION.md` — integration surface.

## Operational state

- V5 has not been deployed to production yet. `CheckAuthConfiguration` rejects the deploy if `operator` or `exchangeRateBot` are EOAs; both must migrate to Safes first.
- CreateX salts must be chosen per deployment.
- Off-chain monitors (`IERC20.Approval`, `RolesAuthority.UserRoleUpdated`, `AtomicSolverV5.QueueApprovalSet`, `Rescued`) are documented in `OPERATOR_RUNBOOK.md` and need to be wired before broad TVL onboarding.

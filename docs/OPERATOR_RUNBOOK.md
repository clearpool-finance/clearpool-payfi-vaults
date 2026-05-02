# Operator runbook — AtomicSolverV5

Operational policy for anyone holding a key against a clearpool-payfi-vaults deployment. Companion to `PRE_AUDIT_CHECKLIST.md` (deploy-time gates) and `SYSTEM_AUDIT.md` (per-finding shipped status).

## 1. Approval ceiling

Borrowers and any wallet that submits an `AtomicRequest` MUST NOT grant `type(uint256).max` allowance to `AtomicSolverV5`. The contract-side fixes (whitelisted queues, `_inSolveContext`, USDT zero-reset) close every known on-chain pivot, but a compromised solve key can still push solves through a legitimate queue, and an unbounded approval would let it sweep the approver's full balance. Bounded approvals cap the blast radius of any future compromise to a single batch.

### Per-deployment ceiling

Set a ceiling = **110% of the largest expected single-batch solve in USD**, rounded up to a whole-token amount. Examples:

| Deployment              | Largest expected batch | Ceiling per approver      |
| ----------------------- | ---------------------- | ------------------------- |
| X-Pool (USDT/USDC/USDX) | $X                     | 1.1 × $X / token decimals |
| Ola — PayFi (USDC)      | $Y                     | 1.1 × $Y                  |

(Fill in actual numbers per deployment before going live.)

If a batch ever needs to exceed the ceiling, ops top up the approval for that batch only and revoke immediately after. Re-approval is cheap; an unbounded standing approval is a permanent liability.

### Enforcement layer

Not on-chain — the solver can't tell what the operator considers "expected batch size." Enforced by:

1. **Onboarding** — every borrower / supplier that integrates with the queue receives this policy and a sample approval transaction with a bounded value.
2. **Off-chain monitor** — subscribe to `IERC20.Approval(_, atomicSolver, value)` for every supported asset on every chain. Alert if `value == type(uint256).max` or `value > ceiling`. Triage within one business day; reach the approver and have them re-approve with the bounded amount. **Caveat**: `Approval` is _not_ emitted by EIP-2612 `permit` paths or Permit2-style off-chain signature flows — those grant allowance via signature without on-chain `approve`. If the queue's integration ever accepts permit-based approvals, add a parallel signature monitor (or require all approvals to go through on-chain `approve` in the borrower onboarding doc).
3. **Pre-deployment revocation sweep** — on every chain that previously held an `AtomicSolverV3`, confirm prior approvals have been revoked **before** announcing V5. Cross-chain status table lives in `PRE_AUDIT_CHECKLIST.md`.

## 2. Key custody

Every key that holds a role-mutating or solve-grade capability MUST live behind a multisig (Safe) or, for low-volume signers, a hardware wallet behind a Safe module. The deploy script's `CheckAuthConfiguration` halts the pipeline if `protocolAdmin`, `operator`, or `exchangeRateBot` is an EOA, but custody discipline is broader than that single check.

Below table is derived from the actual role-capability wiring in
`script/deploy/single/06_DeployRolesAuthority.s.sol` and `script/ConfigureAtomicRoles.s.sol`.
**Every selector listed under "Capabilities" is wired to that role on-chain.** If a key
holds multiple roles, the union of capabilities applies — the operator address in
particular is granted three roles simultaneously.

| Key                                          | Roles held                                                                | Capabilities                                                                                                                                                                                                                                                                                                                                                                        | Required custody                                                                                                                                                                                                        |
| -------------------------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `protocolAdmin`                              | OWNER (every core contract) + `UPDATE_EXCHANGE_RATE_ROLE` + `PAUSER_ROLE` | Owns BoringVault, Manager, Accountant, Teller, AtomicQueue, AtomicSolverV5, RolesAuthority. Owner = ultimate authority over `setRoleCapability`, `setUserRole`, `setOwner`, `setAuthority`, every selector in the system. Plus the rate-bot and pauser surfaces below.                                                                                                              | Safe ≥ 2-of-3, ideally 3-of-5. Single-key compromise = total compromise.                                                                                                                                                |
| `operator` (`config.operator`)               | `OPERATOR_ROLE` + `UPDATE_EXCHANGE_RATE_ROLE` + `PAUSER_ROLE`             | OPERATOR: `setUserRole`, `p2pSolve`, `redeemSolve`, `rescue`, `Manager.setManageRoot`. UPDATE_EXCHANGE_RATE: see exchangeRateBot row. PAUSER: see pauser row. **Compound blast radius** — a compromised operator can install a rate provider, widen bounds, push a stale rate, and then drain via solve in the same tx.                                                             | Safe ≥ 2-of-3, with a human-approval module on `setUserRole` and `setManageRoot`. CheckAuthConfiguration enforces `extcodesize > 0`.                                                                                    |
| `exchangeRateBot` (`config.exchangeRateBot`) | `UPDATE_EXCHANGE_RATE_ROLE`                                               | `Accountant.updateExchangeRate`, `setLendingRate`, `setMaxLendingRate`, `setManagementFeeRate`, `setRateProviderData` (install rate provider!), `updateUpper` / `updateLower` (widen bounds!), `updateDelay`, `setDepositCap` on Teller, `updateManualWhitelist`/`updateContractWhitelist` on Teller, plus `p2pSolve` / `redeemSolve` on AtomicSolverV5 and `solve` on AtomicQueue. | Hardware-backed Safe. Hot-signing rate updates is acceptable cadence-wise, but the same key holds rate-provider replacement and solve, so treat as a high-value key. CheckAuthConfiguration enforces `extcodesize > 0`. |
| `strategist`, `additionalStrategists[i]`     | `STRATEGIST_ROLE`                                                         | `Manager.manageVaultWithMerkleVerification` (Merkle-gated strategy execution), `p2pSolve` / `redeemSolve` on AtomicSolverV5, `solve` on AtomicQueue, `updateManualWhitelist` / `updateContractWhitelist` on Teller. The Merkle root binds _which_ targets are reachable — so root rotation (only OPERATOR + Owner) is the meta-control.                                             | Hardware key behind a Safe. Rotation on signer change. CheckAuthConfiguration enforces `extcodesize > 0` if `config.strategist != address(0)`.                                                                          |
| `pauser` (`config.pauser`)                   | `PAUSER_ROLE`                                                             | `pause` / `unpause` on Teller, Accountant, Manager. Cannot move funds, but a compromised pauser can stall the protocol.                                                                                                                                                                                                                                                             | Hardware key or 1-of-N Safe — fast incident response is the priority. CheckAuthConfiguration enforces `extcodesize > 0` if `config.pauser != address(0)`.                                                               |
| `broadcaster` (deployer EOA)                 | NONE post-deploy                                                          | Step 06 grants `OPERATOR_ROLE` for wiring; step 08 revokes it before `transferOwnership`. CheckAuthConfiguration asserts `!doesUserHaveRole(broadcaster, OPERATOR_ROLE)` post-deploy.                                                                                                                                                                                               | EOA acceptable (used only during the deploy broadcast).                                                                                                                                                                 |

### Custody-related controls already on-chain

- `CheckAuthConfiguration` reverts the deploy if `protocolAdmin`, `operator`, `exchangeRateBot`, `strategist` (when set), or `pauser` (when set) has zero code (added 2026-04-30).
- `CheckAuthConfiguration` asserts the deployer EOA does not retain `OPERATOR_ROLE` / `UPDATE_EXCHANGE_RATE_ROLE` / `PAUSER_ROLE` post-deploy. Step 08 explicitly revokes these before `transferOwnership`.
- `OPERATOR_ROLE` cannot grant itself `setRoleCapability` on the authority (RT-2 / F-1 closed).
- `AtomicSolverV5.approvedQueues` is a per-deployment whitelist; even a compromised `OPERATOR_ROLE` cannot redirect solves to a queue it has not pre-whitelisted via `setQueueApproved`. `setQueueApproved` is owner-only — no role is granted that selector.
- `AtomicSolverV5.rescue(token, amount)` always sends to `owner()`. A compromised hot key can trigger rescue but cannot pick the destination — funds always land at the protocolAdmin Safe.
- `AtomicQueue` and Teller `bulkWithdraw`/`bulkDeposit` use `getRateSafe()` — a paused accountant blocks every solve and bulk path automatically (closes the stale-rate window after A-1's auto-pause fires).

### Rotation

- `protocolAdmin` Safe signers — annual rotation OR within 7 days of any signer leaving the org, whichever comes first.
- `strategist`, `exchangeRateBot` — rotate on suspicion; otherwise annually.
- `pauser` — no fixed cadence; rotate on personnel change only.

Rotation is `setUserRole(oldKey, ROLE, false)` + `setUserRole(newKey, ROLE, true)` from the `protocolAdmin` Safe. Test on a non-mainnet deployment first.

## 3. Event monitors

Set alerts on `RolesAuthority` and `AtomicSolverV5` (full list in `PRE_AUDIT_CHECKLIST.md` § "Ongoing monitoring"):

- `RolesAuthority.UserRoleUpdated`, `RolesAuthority.PublicCapabilityUpdated`
- `AtomicSolverV5.QueueApprovalSet`, `AtomicSolverV5.Rescued`
- The off-chain approval monitor from § 1 above.

Anything that fires without a matching ops ticket → halt onboarding, re-run `CheckAuthConfiguration` against live state, and triage before resuming.

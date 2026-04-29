# Operator runbook — AtomicSolverV5

Operational policy for anyone holding a key against a clearpool-payfi-vaults deployment. Companion to `PRE_AUDIT_CHECKLIST.md` (deploy-time gates) and `SYSTEM_AUDIT.md` (per-finding shipped status).

## 1. Approval ceiling

Borrowers and any wallet that submits an `AtomicRequest` MUST NOT grant `type(uint256).max` allowance to `AtomicSolverV5`. The 2026-04-21 incident's blast radius was bounded by exactly one victim's pre-approval — anyone with an unbounded approval to V3 was drainable. The contract-side fixes (whitelisted queues, `_inSolveContext`, USDT zero-reset) close every known on-chain pivot, but a compromised solve key can still push solves through a legitimate queue, and an unbounded approval would let it sweep the approver's full balance.

### Per-deployment ceiling

Set a ceiling = **110% of the largest expected single-batch solve in USD**, rounded up to a whole-token amount. Examples:

| Deployment | Largest expected batch | Ceiling per approver |
|---|---|---|
| X-Pool (USDT/USDC/USDX) | $X | 1.1 × $X / token decimals |
| Ola — PayFi (USDC) | $Y | 1.1 × $Y |

(Fill in actual numbers per deployment before going live.)

If a batch ever needs to exceed the ceiling, ops top up the approval for that batch only and revoke immediately after. Re-approval is cheap; an unbounded standing approval is a permanent liability.

### Enforcement layer

Not on-chain — the solver can't tell what the operator considers "expected batch size." Enforced by:

1. **Onboarding** — every borrower / supplier that integrates with the queue receives this policy and a sample approval transaction with a bounded value.
2. **Off-chain monitor** — subscribe to `IERC20.Approval(_, atomicSolver, value)` for every supported asset on every chain. Alert if `value == type(uint256).max` or `value > ceiling`. Triage within one business day; reach the approver and have them re-approve with the bounded amount.
3. **Pre-deployment revocation sweep** — on every chain that previously held a vulnerable `AtomicSolverV3`, confirm pre-incident approvals have been revoked **before** announcing V5. Cross-chain status table lives in `PRE_AUDIT_CHECKLIST.md`.

## 2. Key custody

Every key that holds a role-mutating or solve-grade capability MUST live behind a multisig (Safe) or, for low-volume signers, a hardware wallet behind a Safe module. The deploy script's `CheckAuthConfiguration` halts the pipeline if `protocolAdmin`, `operator`, or `exchangeRateBot` is an EOA, but custody discipline is broader than that single check.

| Key | Role / capabilities | Required custody |
|---|---|---|
| `protocolAdmin` | Owner of every core contract (BoringVault, Manager, Accountant, Teller, AtomicQueue, AtomicSolverV5, RolesAuthority) | Safe (≥ 2-of-3, ideally 3-of-5) |
| `operator` (`OPERATOR_ROLE`) | `setUserRole`, `p2pSolve`, `redeemSolve`, `rescue` on AtomicSolverV5 | Safe; `setUserRole` should be guarded by a Safe module that requires at least one human approval |
| `exchangeRateBot` (`UPDATE_EXCHANGE_RATE_ROLE`) | `updateExchangeRate` on Accountant + `p2pSolve` / `redeemSolve` | Hardware key (Ledger / Fireblocks / equiv.). Hot-signing is acceptable for rate updates but the same key can solve, so treat it like a solve key. |
| `strategist` (`STRATEGIST_ROLE`) | `manage` on BoringVault (Merkle-verified strategy execution) | Hardware key behind a Safe; rotation policy below |
| `pauser` | `pause` on Teller / Accountant | Hardware key, low-quorum Safe (1-of-N is acceptable for fast incident response) |

### Custody-related controls already on-chain

- `CheckAuthConfiguration` reverts the deploy if `protocolAdmin`, `operator`, or `exchangeRateBot` has zero code (added 2026-04-30).
- `OPERATOR_ROLE` cannot grant itself `setRoleCapability` on the authority (RT-2 / F-1 closed).
- `AtomicSolverV5.approvedQueues` is a per-deployment whitelist; even a compromised `OPERATOR_ROLE` cannot redirect solves to a queue it has not pre-whitelisted via `setQueueApproved`.
- `rescue()` on `AtomicSolverV5` falls back to `owner()` if the role is unwired — the `protocolAdmin` Safe is the always-present escape hatch.

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

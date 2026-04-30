# Pre-audit Checklist — `security/atomicsolverv3-remediation`

Branch tip: `aae8854` (plus this commit). Tracks the action items raised during external pre-merge review against what's actually shipped.

## Pre-deployment

| #   | Item                                                  | Status                         | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --- | ----------------------------------------------------- | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Mainnet-fork test for `EtherFiLiquid1Migration.t.sol` | **Closed (2026-04-30)**        | `forge test --match-path test/EtherFiLiquid1Migration.t.sol --fork-url $MAINNET_RPC_URL` → `[PASS] testMigration() (gas: 4828771)`. Confirms V1↔V5 migration path is intact against live mainnet state.                                                                                                                                                                                                                                                                             |
| 2   | Full deploy script dry-run on a fork                  | **Closed (2026-04-30)**        | Ran `forge script script/deploy/deployAll.s.sol --sig 'run(string)' eth-hex-payfi-layerzero.json --rpc-url $MAINNET_RPC_URL --fork-block-number 24777141`. All 12 stages logged in order, ending with `Auth invariants verified`. Fork at the block immediately before the mar-31 mainnet broadcast so deterministic CreateX salts don't collide; deterministic addresses produced match the live deployment 1:1, confirming the script + assertion set passes on production state. |
| 3   | Approval ceiling policy                               | **Closed (2026-04-30)**        | Documented in `OPERATOR_RUNBOOK.md` § 1: 110%-of-batch ceiling, off-chain `Approval` monitor, pre-deployment revocation sweep. Per-deployment $-amounts get filled in before each chain rollout. Not codified on-chain (the solver can't infer "expected batch size") — risk is from external approvers, mitigated at integration + monitoring layer.                                                                                                                               |
| 4   | OPERATOR / `exchangeRateBot` key custody              | **Closed (2026-04-30)**        | `CheckAuthConfiguration` now reverts the deploy if `protocolAdmin`, `operator`, or `exchangeRateBot` is an EOA (zero code). Custody policy + rotation cadence in `OPERATOR_RUNBOOK.md` § 2.                                                                                                                                                                                                                                                                                         |
| 5   | Independent external audit                            | **Open — out of branch scope** | Documented as follow-up #10 in `SYSTEM_AUDIT.md`. Recommended scope: queue whitelist (`AtomicSolverV5.approvedQueues` + `inSolveContext` modifier), `_redeemSolve` rewrite (commit `4cd0a0e`), and the cross-chain receive path (T-1 deferred design item). Engagement should land before significant TVL is onboarded.                                                                                                                                                             |

## Codified post-deployment gates (already in `CheckAuthConfiguration.s.sol`)

`forge script script/CheckAuthConfiguration.s.sol --sig "run(string)" <deployFile> --rpc-url <RPC>` runs all of these:

- `isCapabilityPublic(atomicSolver, finishSolve)` MUST be false
- `isCapabilityPublic(atomicSolver, p2pSolve)` MUST be false
- `isCapabilityPublic(atomicSolver, redeemSolve)` MUST be false
- `isCapabilityPublic(atomicQueue, solve)` MUST be false
- `isCapabilityPublic(boringVault, manage)` (single + batch) MUST be false
- `isCapabilityPublic(teller, bulkWithdraw / bulkDeposit / refundDeposit)` MUST be false
- `canCall(canary_EOA, atomicSolver, finishSolve)` MUST be false
- `canCall(canary_EOA, atomicSolver, p2pSolve)` MUST be false ← **added in this commit**
- `canCall(canary_EOA, atomicSolver, redeemSolve)` MUST be false ← **added in this commit**
- `doesUserHaveRole(atomicQueue, QUEUE_ROLE)` MUST be true
- `doesUserHaveRole(atomicSolver, SOLVER_ROLE)` MUST be true
- `canCall(atomicQueue, atomicSolver, finishSolve)` MUST be true
- `canCall(atomicSolver, atomicQueue, solve)` MUST be true
- `canCall(atomicSolver, teller, bulkWithdraw)` MUST be true
- `AtomicSolverV5(atomicSolver).approvedQueues(atomicQueue)` MUST be true
- `BoringVault.owner() == protocolAdmin`, same for accountant / manager / teller / atomicQueue / atomicSolver / rolesAuthority
- `canCall(operator, atomicSolver, rescue)` MUST be true
- `canCall(operator, rolesAuthority, setRoleCapability)` MUST be false
- `protocolAdmin` is a contract (multisig), not an EOA
- `operator` is a contract (Safe), not an EOA ← **added 2026-04-30**
- `exchangeRateBot` is a contract (Safe / hardware-backed wallet), not an EOA ← **added 2026-04-30**

If any of those fail, the script reverts and the deployment pipeline halts.

## Smoke test (do once, before opening to TVL)

Manual end-to-end on the live deployment:

1. Grant a **bounded** approval (NOT unlimited) to `AtomicSolverV5` from a single test wallet — pick the per-deployment ceiling from item 3.
2. Submit one tiny `AtomicRequest` via the queue.
3. Solver (with `SOLVER_ROLE`) calls `redeemSolve` (or `p2pSolve`) with this single user.
4. Verify post-conditions:
   - User got their `want` token.
   - `IERC20(want).balanceOf(atomicSolver) == 0`.
   - `IERC20(want).allowance(solver_bot, atomicSolver) == 0` (the bounded approval was consumed).
   - No leftover allowance from `solver` to `queue` (`safeApprove` zero-reset closes the window — covered by H-2 fix in `9b66de4`).

## Ongoing monitoring (off-chain)

Set alerts on `RolesAuthority` and `AtomicSolverV5`:

- `RolesAuthority.UserRoleUpdated(user, role, enabled)` — any new user gaining `QUEUE_ROLE` or any existing holder being granted an unexpected role must trigger immediate review. The [date] incident's pre-condition was a misconfigured capability that sat unwatched for 73 days.
- `RolesAuthority.PublicCapabilityUpdated(target, sig, enabled=true)` — should never fire for any of the selectors enumerated in the post-deploy gates above. If it does, halt operations and re-run `CheckAuthConfiguration`.
- `AtomicSolverV5.QueueApprovalSet(queue, approved)` — any whitelist change to `approvedQueues` should be tied to a documented ops ticket. Unannounced approvals = follow up immediately.
- `AtomicSolverV5.Rescued(token, to, amount)` — sweep events should match a known operator action; surface them to whoever owns incident response.

## Sequence to follow before audit kickoff

1. Run the fork tests + dry-run pipeline (items 1+2 above) on a clean fork — fix anything they surface.
2. Land items 3+4 in the operator runbook (separate doc / ops issue tracker).
3. Confirm V3 approvals revoked on every chain that previously held the vulnerable solver.
4. Open the audit engagement.

## Cross-chain remediation status

| Chain              | V3 `finishSolve` public-cap revoked?                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | V5 deployed? |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| Ethereum mainnet   | ✅ verified live (2026-04-30): `isCapabilityPublic(solver, finishSolve) == false`, `doesRoleHaveCapability(QUEUE_ROLE=10, solver, finishSolve) == true`, queue's role bitmap = `0x0400` (bit 10). Authority `0x670b8C56Da44A934A169DCb2dA750aB3dd4a6e13`, solver `0x5B3A41826A28b6a8ed1c5F5d6052D9dB85428d59`, queue `0x5Cf9EE4F9f967E983ee6928FDbF2F12e27Eec6A8`. Selector `finishSolve(bytes,address,address,address,uint256,uint256)` = `0x2ddd62ce`. Wired by `e137ca9` config + executed on-chain pre-this-branch. | not yet      |
| Flare (chainId 14) | ✅ verified live: `isCapabilityPublic(solver, finishSolve) == false`; `doesRoleHaveCapability(QUEUE_ROLE=10, solver, finishSolve) == true`. Authority `0xE3d4a420cA5f43aDEeb55D876dE53E73dd471bE1`, solver `0xCB0cd11dB50eb3cE4572E6134E524A9E17BeaBf5`. Safe batch executed from `0x8095862139a3f623a64cec84eb8cE82359317419`.                                                                                                                                                                                         | not yet      |

V5 deploys (with all the in-contract hardening — `_inSolveContext`, `_expectedQueue`, `approvedQueues`, FoT reconcile, USDT zero-reset, etc.) supersede V3 when ready. Until V5 lands, the V3 deployments are protected by the `setRoleCapability(QUEUE_ROLE, …)` config on every chain — verify with the on-chain queries above for any chain not yet listed.

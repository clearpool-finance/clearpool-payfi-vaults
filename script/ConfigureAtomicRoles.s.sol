// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { BaseScript } from "./Base.s.sol";
import { ConfigReader } from "./ConfigReader.s.sol";

contract ConfigureAtomicRoles is BaseScript {
    // Role constants
    uint8 public constant SOLVER_ROLE = 9;
    uint8 public constant QUEUE_ROLE = 10;

    // Addresses (will be overridden by deployWithConfig)
    address public rolesAuthority;
    address public boringVault;
    address public teller;
    address public atomicQueue;
    address public atomicSolver;

    function run() public broadcast {
        _configure();
    }

    function deployWithConfig(ConfigReader.Config memory config) public broadcast returns (address) {
        // Set addresses from config
        rolesAuthority = config.rolesAuthority;
        boringVault = config.boringVault;
        teller = config.teller;
        atomicQueue = config.atomicQueue;
        atomicSolver = config.atomicSolver;

        // Run configuration
        _configure();
        return address(0);
    }

    function _configure() internal {
        RolesAuthority authority = RolesAuthority(rolesAuthority);

        // SECURITY: the audited ConfigureAtomicRoles at this commit marked solve / finishSolve / bulkWithdraw
        // as PUBLIC capabilities, which dismantles the solver-only access model (heavy adversarial review:
        // no roleless drain of vault collateral, but public finishSolve is a latent solver-balance sweep and
        // public solve enables forced-trade/MEV). We replace all three public capabilities with strict
        // role-gating. This is a DEPLOY-CONFIG change only — the audited contract bytecode is untouched.

        // === ROLE ASSIGNMENTS ===
        authority.setUserRole(atomicQueue, QUEUE_ROLE, true);
        authority.setUserRole(atomicSolver, SOLVER_ROLE, true);

        // === ROLE-GATED CAPABILITIES (was setPublicCapability) ===
        // solve: SOLVER_ROLE only — AtomicSolverV3 is the sole caller of AtomicQueue.solve
        authority.setRoleCapability(
            SOLVER_ROLE, atomicQueue, bytes4(keccak256("solve(address,address,address[],bytes,address)")), true
        );

        // finishSolve: QUEUE_ROLE only — AtomicQueue is the sole legitimate caller. Role-gating to the queue
        // IS the protection (the audited V3 initiator check is caller-supplied; we cannot patch the source,
        // so we ensure only the queue can ever reach finishSolve).
        authority.setRoleCapability(
            QUEUE_ROLE, atomicSolver, bytes4(keccak256("finishSolve(bytes,address,address,address,uint256,uint256)")), true
        );

        // bulkWithdraw: SOLVER_ROLE only — AtomicSolverV3 is the actual caller during redeem-solve
        authority.setRoleCapability(SOLVER_ROLE, teller, TellerWithMultiAssetSupport.bulkWithdraw.selector, true);

        // WHITELIST THE ATOMIC SOLVER: under MANUAL_WHITELIST the teller gates bulkWithdraw via checkAccess(msg.sender),
        // and the redeem-solve path calls teller.bulkWithdraw FROM the AtomicSolver. Without this, user withdrawals
        // (updateAtomicRequest -> redeemSolve) revert. Runs here (post-solver-deploy), not in TellerSetup where the
        // solver address isn't known yet.
        address[] memory solverWl = new address[](1);
        solverWl[0] = atomicSolver;
        TellerWithMultiAssetSupport(teller).updateContractWhitelist(solverWl, true);

        // NOTE: AtomicSolverV3.p2pSolve / redeemSolve are intentionally left owner-only (no role granted) for
        // this test deploy — safe, as verified. The trusted withdrawal operators (BO + Nara) get a dedicated
        // OPERATOR role at production hand-off, not a public/blanket grant.
        // Dropped vs the original script: the dead QUEUE_ROLE->teller.bulkWithdraw grant and the unused
        // SOLVER_ROLE->BoringVault.manage grants (manage flows through MANAGER_ROLE = the manager contract).
    }
}

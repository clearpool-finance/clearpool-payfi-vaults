// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { AtomicSolverV3 } from "src/atomic-queue/AtomicSolverV3.sol";
import { BaseScript } from "./Base.s.sol";
import { ConfigReader } from "./ConfigReader.s.sol";
import "./../src/helper/Constants.sol";

/// @notice Post-deploy invariant check script. Run after `deployAll.s.sol` on every chain.
/// @dev Added in response to the 2026-04-20 incident: a `setPublicCapability(atomicSolver,
///      finishSolve.selector, true)` misconfig let anyone drain approvers of AtomicSolverV3.
///      A single `require(!isCapabilityPublic(solver, finishSolve.selector))` here would have
///      caught it at deploy time. Extend the assertion list whenever new roles/capabilities
///      are added to ConfigureAtomicRoles.s.sol.
///
/// Invocation (forge script, read-only — no broadcast needed):
///   forge script script/CheckAuthConfiguration.s.sol \
///     --sig "run(string)" <deployFile> --rpc-url <RPC>
contract CheckAuthConfiguration is BaseScript {
    uint8 public constant QUEUE_ROLE = 10;

    address private constant CANARY_EOA = 0x00000000000000000000000000000000DeaDBeef;

    bytes4 private constant FINISH_SOLVE_SELECTOR =
        bytes4(keccak256("finishSolve(bytes,address,address,address,uint256,uint256)"));
    bytes4 private constant P2P_SOLVE_SELECTOR =
        bytes4(keccak256("p2pSolve(address,address,address,address[],uint256,uint256)"));
    bytes4 private constant REDEEM_SOLVE_SELECTOR =
        bytes4(keccak256("redeemSolve(address,address,address,address[],uint256,uint256,address)"));
    bytes4 private constant QUEUE_SOLVE_SELECTOR = bytes4(keccak256("solve(address,address,address[],bytes,address)"));
    bytes4 private constant MANAGE_SINGLE_SELECTOR = bytes4(keccak256("manage(address,bytes,uint256)"));
    bytes4 private constant MANAGE_BATCH_SELECTOR = bytes4(keccak256("manage(address[],bytes[],uint256[])"));

    function run(string memory deployFile) public {
        ConfigReader.Config memory config =
            ConfigReader.toConfig(vm.readFile(string.concat(CONFIG_PATH_ROOT, deployFile)), getChainConfigFile());
        _check(config);
    }

    function deployWithConfig(ConfigReader.Config memory config) public returns (address) {
        _check(config);
        return address(0);
    }

    function _check(ConfigReader.Config memory config) internal view {
        RolesAuthority authority = RolesAuthority(config.rolesAuthority);

        // === NEGATIVE ASSERTIONS — selectors that must NEVER be publicly callable ===
        //
        // `finishSolve` decodes a caller-supplied `solver` address from runData and then
        // calls `safeTransferFrom(solver, address(this), amount)`. Publicly callable =
        // anyone-drains-anyone-who-approved. This is the 2026-04-20 incident.
        require(
            !authority.isCapabilityPublic(config.atomicSolver, FINISH_SOLVE_SELECTOR),
            "CheckAuth: atomicSolver.finishSolve MUST NOT be public"
        );
        require(
            !authority.canCall(CANARY_EOA, config.atomicSolver, FINISH_SOLVE_SELECTOR),
            "CheckAuth: atomicSolver.finishSolve MUST NOT be anon-callable"
        );
        require(
            !authority.isCapabilityPublic(config.atomicSolver, P2P_SOLVE_SELECTOR),
            "CheckAuth: atomicSolver.p2pSolve MUST NOT be public"
        );
        require(
            !authority.isCapabilityPublic(config.atomicSolver, REDEEM_SOLVE_SELECTOR),
            "CheckAuth: atomicSolver.redeemSolve MUST NOT be public"
        );
        require(
            !authority.isCapabilityPublic(config.atomicQueue, QUEUE_SOLVE_SELECTOR),
            "CheckAuth: atomicQueue.solve MUST NOT be public"
        );
        require(
            !authority.isCapabilityPublic(config.boringVault, MANAGE_SINGLE_SELECTOR),
            "CheckAuth: boringVault.manage (single) MUST NOT be public"
        );
        require(
            !authority.isCapabilityPublic(config.boringVault, MANAGE_BATCH_SELECTOR),
            "CheckAuth: boringVault.manage (batch) MUST NOT be public"
        );
        require(
            !authority.isCapabilityPublic(config.teller, TellerWithMultiAssetSupport.bulkWithdraw.selector),
            "CheckAuth: teller.bulkWithdraw MUST NOT be public"
        );
        require(
            !authority.isCapabilityPublic(config.teller, TellerWithMultiAssetSupport.bulkDeposit.selector),
            "CheckAuth: teller.bulkDeposit MUST NOT be public"
        );
        require(
            !authority.isCapabilityPublic(config.teller, TellerWithMultiAssetSupport.refundDeposit.selector),
            "CheckAuth: teller.refundDeposit MUST NOT be public"
        );

        // === POSITIVE ASSERTIONS — the intended legitimate call paths MUST work ===
        require(
            authority.doesUserHaveRole(config.atomicQueue, QUEUE_ROLE), "CheckAuth: atomicQueue must hold QUEUE_ROLE"
        );
        require(
            authority.canCall(config.atomicQueue, config.atomicSolver, FINISH_SOLVE_SELECTOR),
            "CheckAuth: QUEUE must be able to call finishSolve"
        );
        require(
            authority.doesUserHaveRole(config.atomicSolver, SOLVER_ROLE),
            "CheckAuth: atomicSolver must hold SOLVER_ROLE"
        );
        require(
            authority.canCall(config.atomicSolver, config.atomicQueue, QUEUE_SOLVE_SELECTOR),
            "CheckAuth: SOLVER must be able to call queue.solve"
        );
        require(
            authority.canCall(config.atomicSolver, config.teller, TellerWithMultiAssetSupport.bulkWithdraw.selector),
            "CheckAuth: SOLVER must be able to bulkWithdraw via teller"
        );

        // === STRUCTURAL SANITY ===
        // Ownership should be on the protocolAdmin multisig, not the deployer EOA.
        require(
            RolesAuthority(config.rolesAuthority).owner() == config.protocolAdmin,
            "CheckAuth: authority owner must equal protocolAdmin"
        );
        // AtomicSolverV3 ownership: rescue() falls back to `owner()` if no role is wired.
        // Until setOwner(protocolAdmin) has been run, only the deployer EOA can rescue.
        // See RT-2 / F-2 in docs/ATOMIC_SOLVER_V3_REDTEAM_AND_SURFACE.md.
        require(
            AtomicSolverV3(config.atomicSolver).owner() == config.protocolAdmin,
            "CheckAuth: atomicSolver owner must equal protocolAdmin"
        );
        // OPERATOR_ROLE must be able to call rescue() — otherwise stuck tokens
        // can only be swept by the (potentially rotated / lost) deployer EOA.
        require(
            authority.canCall(
                config.operator, config.atomicSolver, bytes4(keccak256("rescue(address,uint256,address)"))
            ),
            "CheckAuth: operator must be able to call rescue on atomicSolver"
        );
        // OPERATOR_ROLE must NOT hold setRoleCapability on the authority itself — that
        // combination enables the rogue-queue cascade (RT-2 / F-1).
        require(
            !authority.canCall(config.operator, config.rolesAuthority, RolesAuthority.setRoleCapability.selector),
            "CheckAuth: operator MUST NOT hold setRoleCapability on authority (rogue-queue risk)"
        );
        // protocolAdmin should be a contract (Safe), not an EOA. Any EOA-held governance
        // key is a single-point-of-failure pivot.
        uint256 adminSize;
        address admin = config.protocolAdmin;
        assembly {
            adminSize := extcodesize(admin)
        }
        require(adminSize > 0, "CheckAuth: protocolAdmin must be a contract (multisig), not an EOA");
    }
}

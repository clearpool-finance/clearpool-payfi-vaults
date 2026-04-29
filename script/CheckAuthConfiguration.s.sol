// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { AtomicSolverV5 } from "src/atomic-queue/AtomicSolverV5.sol";
import { BaseScript } from "./Base.s.sol";
import { ConfigReader } from "./ConfigReader.s.sol";
import "./../src/helper/Constants.sol";

/// @notice Post-deploy invariant check script. Run after `deployAll.s.sol` on every chain.
/// @dev Added in response to the 2026-04-20 incident: a `setPublicCapability(atomicSolver,
///      finishSolve.selector, true)` misconfig let anyone drain approvers of AtomicSolverV5.
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
            !authority.canCall(CANARY_EOA, config.atomicSolver, P2P_SOLVE_SELECTOR),
            "CheckAuth: atomicSolver.p2pSolve MUST NOT be anon-callable"
        );
        require(
            !authority.canCall(CANARY_EOA, config.atomicSolver, REDEEM_SOLVE_SELECTOR),
            "CheckAuth: atomicSolver.redeemSolve MUST NOT be anon-callable"
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
        // Audit R-4: assert ownership of EVERY core contract has been transferred to the
        // protocolAdmin multisig. Solmate `Auth.transferOwnership` is single-step, so a
        // typo in `08_SetAuthorityAndTransferOwnerships.s.sol` could brick a contract with
        // the deployer EOA as owner. These checks run post-deploy and fail the pipeline if
        // any single transferOwnership was missed or typoed.
        require(
            RolesAuthority(config.rolesAuthority).owner() == config.protocolAdmin,
            "CheckAuth: authority owner must equal protocolAdmin"
        );
        require(
            BoringVault(payable(config.boringVault)).owner() == config.protocolAdmin,
            "CheckAuth: boringVault owner must equal protocolAdmin"
        );
        require(
            AccountantWithRateProviders(config.accountant).owner() == config.protocolAdmin,
            "CheckAuth: accountant owner must equal protocolAdmin"
        );
        require(
            ManagerWithMerkleVerification(config.manager).owner() == config.protocolAdmin,
            "CheckAuth: manager owner must equal protocolAdmin"
        );
        require(
            TellerWithMultiAssetSupport(config.teller).owner() == config.protocolAdmin,
            "CheckAuth: teller owner must equal protocolAdmin"
        );
        require(
            AtomicQueue(config.atomicQueue).owner() == config.protocolAdmin,
            "CheckAuth: atomicQueue owner must equal protocolAdmin"
        );
        // AtomicSolverV5 ownership: rescue() falls back to `owner()` if no role is wired.
        require(
            AtomicSolverV5(config.atomicSolver).owner() == config.protocolAdmin,
            "CheckAuth: atomicSolver owner must equal protocolAdmin"
        );
        // The CT-2/F-1 fix relies on AtomicSolverV5's in-contract approvedQueues whitelist.
        // If ConfigureAtomicRoles is skipped or fails to call setQueueApproved, every solve
        // will silently revert with UnapprovedQueue in production. Gate at deploy-time.
        require(
            AtomicSolverV5(config.atomicSolver).approvedQueues(config.atomicQueue),
            "CheckAuth: atomicQueue must be whitelisted on atomicSolver (setQueueApproved)"
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
        // Governance + hot-key custody: every key that holds a solve-grade or
        // role-mutating capability must be a contract (Safe / hardware-backed
        // smart wallet), not a raw EOA. Any EOA-held key is a single-point-of-
        // failure pivot. OPERATOR_ROLE holds setUserRole + p2pSolve + redeemSolve;
        // exchangeRateBot holds UPDATE_EXCHANGE_RATE_ROLE which also carries
        // p2pSolve + redeemSolve. A compromised hot key with solve capabilities
        // can still push solves through legitimate (whitelisted) queues even
        // after the rogue-queue cascade is closed.
        require(_isContract(config.protocolAdmin), "CheckAuth: protocolAdmin must be a contract, not an EOA");
        require(_isContract(config.operator), "CheckAuth: operator must be a contract (Safe), not an EOA");
        require(
            _isContract(config.exchangeRateBot),
            "CheckAuth: exchangeRateBot must be a contract (Safe / hardware-backed), not an EOA"
        );
    }

    function _isContract(address a) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(a)
        }
        return size > 0;
    }
}

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
/// @dev Added in response to the [date] incident: a `setPublicCapability(atomicSolver,
///      finishSolve.selector, true)` misconfig let anyone drain approvers of AtomicSolverV5.
///      A single `require(!isCapabilityPublic(solver, finishSolve.selector))` here would have
///      caught it at deploy time. Extend the assertion list whenever new roles/capabilities
///      are added to ConfigureAtomicRoles.s.sol or 06_DeployRolesAuthority.s.sol.
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
    bytes4 private constant RESCUE_SELECTOR = bytes4(keccak256("rescue(address,uint256)"));
    bytes4 private constant SET_QUEUE_APPROVED_SELECTOR = bytes4(keccak256("setQueueApproved(address,bool)"));
    bytes4 private constant SET_MANAGE_ROOT_SELECTOR = bytes4(keccak256("setManageRoot(address,bytes32)"));
    bytes4 private constant MANAGE_VAULT_MERKLE_SELECTOR =
        bytes4(keccak256("manageVaultWithMerkleVerification(bytes32[][],address[],bytes[],uint256[])"));

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
        // The [date] incident was a single `setPublicCapability(solver, finishSolve, true)`
        // misconfig. The same class — public-cap on any role-mutating, fund-moving, or rate-
        // affecting selector — would have similar blast radius. Maintain this list as a
        // mirror of every selector that appears in `setRoleCapability(...)` calls across
        // 06_DeployRolesAuthority.s.sol and ConfigureAtomicRoles.s.sol.

        // Solver entry points
        _requireNotPublic(authority, config.atomicSolver, FINISH_SOLVE_SELECTOR, "atomicSolver.finishSolve");
        _requireNotPublic(authority, config.atomicSolver, P2P_SOLVE_SELECTOR, "atomicSolver.p2pSolve");
        _requireNotPublic(authority, config.atomicSolver, REDEEM_SOLVE_SELECTOR, "atomicSolver.redeemSolve");
        _requireNotPublic(authority, config.atomicSolver, RESCUE_SELECTOR, "atomicSolver.rescue");
        _requireNotPublic(authority, config.atomicSolver, SET_QUEUE_APPROVED_SELECTOR, "atomicSolver.setQueueApproved");

        // Queue
        _requireNotPublic(authority, config.atomicQueue, QUEUE_SOLVE_SELECTOR, "atomicQueue.solve");

        // Vault / Manager
        _requireNotPublic(authority, config.boringVault, MANAGE_SINGLE_SELECTOR, "boringVault.manage(single)");
        _requireNotPublic(authority, config.boringVault, MANAGE_BATCH_SELECTOR, "boringVault.manage(batch)");
        _requireNotPublic(authority, config.manager, SET_MANAGE_ROOT_SELECTOR, "manager.setManageRoot");
        _requireNotPublic(
            authority, config.manager, MANAGE_VAULT_MERKLE_SELECTOR, "manager.manageVaultWithMerkleVerification"
        );

        // Teller
        _requireNotPublic(
            authority, config.teller, TellerWithMultiAssetSupport.bulkWithdraw.selector, "teller.bulkWithdraw"
        );
        _requireNotPublic(
            authority, config.teller, TellerWithMultiAssetSupport.bulkDeposit.selector, "teller.bulkDeposit"
        );
        _requireNotPublic(
            authority, config.teller, TellerWithMultiAssetSupport.refundDeposit.selector, "teller.refundDeposit"
        );

        // Accountant — every selector wired to UPDATE_EXCHANGE_RATE_ROLE in step 06.
        // A public-cap on any of these gives anyone the same blast radius as a compromised
        // exchangeRateBot — install a malicious rate provider, widen bounds, push a stale
        // rate, drain via the queue's stale-rate quote.
        _requireNotPublic(
            authority,
            config.accountant,
            AccountantWithRateProviders.updateExchangeRate.selector,
            "accountant.updateExchangeRate"
        );
        _requireNotPublic(
            authority,
            config.accountant,
            AccountantWithRateProviders.setRateProviderData.selector,
            "accountant.setRateProviderData"
        );
        _requireNotPublic(
            authority, config.accountant, AccountantWithRateProviders.updateUpper.selector, "accountant.updateUpper"
        );
        _requireNotPublic(
            authority, config.accountant, AccountantWithRateProviders.updateLower.selector, "accountant.updateLower"
        );
        _requireNotPublic(
            authority, config.accountant, AccountantWithRateProviders.updateDelay.selector, "accountant.updateDelay"
        );
        _requireNotPublic(
            authority,
            config.accountant,
            AccountantWithRateProviders.setLendingRate.selector,
            "accountant.setLendingRate"
        );
        _requireNotPublic(
            authority,
            config.accountant,
            AccountantWithRateProviders.setMaxLendingRate.selector,
            "accountant.setMaxLendingRate"
        );
        _requireNotPublic(
            authority,
            config.accountant,
            AccountantWithRateProviders.setManagementFeeRate.selector,
            "accountant.setManagementFeeRate"
        );

        // Canary anon-callable checks for the historically-misconfigured selectors. Note: these
        // only catch a stray role grant TO the specific canary EOA (effectively never), and
        // are kept primarily for symmetry with the public-cap negative — the real defense
        // is the `isCapabilityPublic` check above plus the off-chain UserRoleUpdated monitor
        // documented in PRE_AUDIT_CHECKLIST.md and OPERATOR_RUNBOOK.md.
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

        // QUEUE_ROLE exclusivity: solmate RolesAuthority does not expose role-holder
        // enumeration, so we cannot iterate every holder on-chain. The only addresses
        // we KNOW should hold QUEUE_ROLE are the configured atomicQueue. Verifying
        // exclusivity is delegated to the off-chain `RolesAuthority.UserRoleUpdated`
        // monitor (see OPERATOR_RUNBOOK.md § 3) which alerts on every grant. The
        // in-contract `approvedQueues` whitelist below is the second layer that
        // bounds the blast radius even if a stray QUEUE_ROLE holder slips in.

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
            authority.canCall(config.operator, config.atomicSolver, RESCUE_SELECTOR),
            "CheckAuth: operator must be able to call rescue on atomicSolver"
        );
        // OPERATOR_ROLE must NOT hold setRoleCapability on the authority itself — that
        // combination enables the rogue-queue cascade (RT-2 / F-1).
        require(
            !authority.canCall(config.operator, config.rolesAuthority, RolesAuthority.setRoleCapability.selector),
            "CheckAuth: operator MUST NOT hold setRoleCapability on authority (rogue-queue risk)"
        );

        // The deployer EOA (broadcaster) is granted OPERATOR_ROLE in step 06 so the deploy
        // script can finish wiring; step 08 must revoke it before transferOwnership. If the
        // revoke is skipped, the deployer keeps setUserRole + p2pSolve + redeemSolve + rescue
        // + setManageRoot forever — a permanent single-EOA pivot the ownership transfer
        // cannot reach. This assertion catches that class of script regression.
        //
        // Skipped when broadcaster == config.operator (legacy single-EOA deployments
        // where the deploy key IS the configured operator). The `_isContract(config.operator)`
        // check below separately refuses to ship that topology to production, so the
        // broadcaster-equals-operator case can never reach a production deploy.
        if (broadcaster != config.operator) {
            require(
                !authority.doesUserHaveRole(broadcaster, OPERATOR_ROLE),
                "CheckAuth: deployer EOA must not retain OPERATOR_ROLE post-deploy"
            );
            require(
                !authority.doesUserHaveRole(broadcaster, UPDATE_EXCHANGE_RATE_ROLE),
                "CheckAuth: deployer EOA must not retain UPDATE_EXCHANGE_RATE_ROLE post-deploy"
            );
            require(
                !authority.doesUserHaveRole(broadcaster, PAUSER_ROLE),
                "CheckAuth: deployer EOA must not retain PAUSER_ROLE post-deploy"
            );
        }

        // Hot-key custody: every key that holds a solve-grade or role-mutating capability
        // must have code (Safe / hardware-backed smart wallet), not be a raw EOA.
        // Caveat: extcodesize > 0 is satisfied by any contract — it cannot prove "multisig"
        // or "≥2-of-N threshold". A single-owner proxy or (post-Pectra) an EIP-7702
        // delegated EOA both pass. This is a best-effort gate; combine with the explicit
        // Safe-address allow-list documented in OPERATOR_RUNBOOK.md § 2.
        // OPERATOR_ROLE holds setUserRole + p2pSolve + redeemSolve + rescue + setManageRoot;
        // exchangeRateBot holds UPDATE_EXCHANGE_RATE_ROLE which carries setRateProviderData
        // (install a rate provider!) + updateUpper / updateLower (widen bounds!) + p2pSolve
        // / redeemSolve / queue.solve. A compromised hot key with these capabilities can
        // still push solves through legitimate (whitelisted) queues even after the rogue-
        // queue cascade is closed.
        require(_isContract(config.protocolAdmin), "CheckAuth: protocolAdmin must have code (Safe), not be an EOA");
        require(_isContract(config.operator), "CheckAuth: operator must have code (Safe), not be an EOA");
        require(_isContract(config.exchangeRateBot), "CheckAuth: exchangeRateBot must have code, not be an EOA");
        // Strategist holds STRATEGIST_ROLE → manageVaultWithMerkleVerification, p2pSolve,
        // redeemSolve, queue.solve. Same drain-class via the solver path as the operator.
        if (config.strategist != address(0)) {
            require(_isContract(config.strategist), "CheckAuth: strategist must have code, not be an EOA");
        }
        if (config.pauser != address(0)) {
            // Pauser blast radius is bounded (pause/unpause only) but still benefits from a
            // multisig — single EOA can stall the protocol with one keystroke.
            require(_isContract(config.pauser), "CheckAuth: pauser must have code, not be an EOA");
        }
    }

    function _requireNotPublic(
        RolesAuthority authority,
        address target,
        bytes4 selector,
        string memory label
    )
        internal
        view
    {
        require(
            !authority.isCapabilityPublic(target, selector), string.concat("CheckAuth: ", label, " MUST NOT be public")
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

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { BaseScript } from "./../../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader, IAuthority } from "../../ConfigReader.s.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import "./../../../src/helper/Constants.sol";

/**
 * Update `rolesAuthority` and transfer ownership from deployer EOA to the
 * protocol.
 */
contract SetAuthorityAndTransferOwnerships is BaseScript {
    using StdJson for string;

    function run() public {
        deploy(getConfig());
    }

    function deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require config Values
        require(address(config.boringVault).code.length != 0, "boringVault must have code");
        require(address(config.manager).code.length != 0, "manager must have code");
        require(address(config.teller).code.length != 0, "teller must have code");
        require(address(config.accountant).code.length != 0, "accountant must have code");
        require(address(config.boringVault) != address(0), "boringVault");
        require(address(config.manager) != address(0), "manager");
        require(address(config.accountant) != address(0), "accountant");
        require(address(config.teller) != address(0), "teller");
        require(config.rolesAuthority != address(0), "rolesAuthority");
        require(config.protocolAdmin != address(0), "protocolAdmin");

        // Set Authority
        IAuthority(config.boringVault).setAuthority(config.rolesAuthority);
        IAuthority(config.accountant).setAuthority(config.rolesAuthority);
        IAuthority(config.manager).setAuthority(config.rolesAuthority);
        IAuthority(config.teller).setAuthority(config.rolesAuthority);
        IAuthority(config.rolesAuthority).setAuthority(config.rolesAuthority);

        // Revoke the deployer EOA's OPERATOR_ROLE before handing ownership to the
        // protocolAdmin Safe. 06_DeployRolesAuthority unconditionally grants broadcaster
        // OPERATOR_ROLE so the deploy script can finish wiring; if we leave it, the
        // deployer EOA permanently retains setUserRole / p2pSolve / redeemSolve / rescue
        // / setManageRoot — a single-EOA pivot that survives every owner transfer below.
        // Must run BEFORE transferOwnership(rolesAuthority) since setUserRole is
        // owner-callable.
        //
        // Skip the revoke when broadcaster == config.operator (legacy single-EOA
        // deployments where the deploy key IS the configured operator). In that case
        // there is no stray grant to remove — the broadcaster's role IS the operator's
        // role. CheckAuthConfiguration's `_isContract(config.operator)` check separately
        // refuses to ship that topology to production.
        if (broadcaster != config.operator) {
            RolesAuthority(config.rolesAuthority).setUserRole(broadcaster, OPERATOR_ROLE, false);
        }

        IAuthority(config.boringVault).transferOwnership(config.protocolAdmin);
        IAuthority(config.manager).transferOwnership(config.protocolAdmin);
        IAuthority(config.accountant).transferOwnership(config.protocolAdmin);
        IAuthority(config.teller).transferOwnership(config.protocolAdmin);
        IAuthority(config.rolesAuthority).transferOwnership(config.protocolAdmin);
        IAuthority(config.atomicQueue).transferOwnership(config.protocolAdmin);
        IAuthority(config.atomicSolver).transferOwnership(config.protocolAdmin);

        // Post Configuration Check
        require(IAuthority(config.boringVault).owner() == config.protocolAdmin, "boringVault");
        require(IAuthority(config.manager).owner() == config.protocolAdmin, "manager");
        require(IAuthority(config.accountant).owner() == config.protocolAdmin, "accountant");
        require(IAuthority(config.teller).owner() == config.protocolAdmin, "teller");
        require(IAuthority(config.atomicQueue).owner() == config.protocolAdmin, "atomicQueue");
        require(IAuthority(config.atomicSolver).owner() == config.protocolAdmin, "atomicSolver");
        if (broadcaster != config.operator) {
            require(
                !RolesAuthority(config.rolesAuthority).doesUserHaveRole(broadcaster, OPERATOR_ROLE),
                "broadcaster OPERATOR_ROLE not revoked"
            );
        }
    }
}

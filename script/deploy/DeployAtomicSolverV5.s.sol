// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { AtomicSolverV5 } from "../../src/atomic-queue/AtomicSolverV5.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BaseScript } from "../Base.s.sol";

contract DeployAtomicSolverV5 is BaseScript {
    bytes32 constant LEGACY_SALT = 0x9cae910c72debe007ee99d700000000000000000000000000000000000000001;

    /// @param saltOverride Per-vault CreateX salt. Pass bytes32(0) to use the legacy singleton
    ///        salt (single-vault chains). Multi-vault chains MUST pass a unique salt.
    function deployWithConfig(address rolesAuthority, bytes32 saltOverride) public broadcast returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPrivateKey);

        bytes memory creationCode = type(AtomicSolverV5).creationCode;
        bytes memory constructorArgs = abi.encode(owner, rolesAuthority);
        bytes32 salt = saltOverride != bytes32(0) ? saltOverride : LEGACY_SALT;

        return CREATEX.deployCreate3(salt, abi.encodePacked(creationCode, constructorArgs));
    }
}

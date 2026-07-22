// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { AtomicSolverV3 } from "../../src/atomic-queue/AtomicSolverV3.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BaseScript } from "../Base.s.sol";

contract DeployAtomicSolverV3 is BaseScript {
    function deployWithConfig(address rolesAuthority) public broadcast returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPrivateKey);

        bytes memory creationCode = type(AtomicSolverV3).creationCode;
        bytes memory constructorArgs = abi.encode(owner, rolesAuthority);
        // Per-vault unique salt (TradeVu) — avoids CREATE3 collision with the global constant.
        // Prefix history: 0xb0a1… = Black Opal (live), 0x7c00… = T-Pool (live), 0x7d00… = TradeVu.
        bytes32 salt = 0x7d00000000000000000000000000000000000000000000000000000000000008;

        return CREATEX.deployCreate3(salt, abi.encodePacked(creationCode, constructorArgs));
    }
}

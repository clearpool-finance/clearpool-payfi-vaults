// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { AtomicQueue } from "./../../src/atomic-queue/AtomicQueue.sol";
import { BaseScript } from "../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "../ConfigReader.s.sol";

using StdJson for string;

// Per-vault unique salt (Black Opal clone). The audited commit used a single global constant, which would
// collide with any prior deployment via the same CreateX. Salt only affects the CREATE3 address, not bytecode.
bytes32 constant SALT = 0xb0a1000000000000000000000000000000000000000000000000000000000007;

contract DeployAtomicQueue is BaseScript {
    function run() public broadcast returns (AtomicQueue atomicQueue) {
        // Need to pass config to get accountant
        ConfigReader.Config memory config = getConfig();

        // AtomicQueue @ Cantina commit: constructor(address _accountant, address _owner, Authority _authority).
        bytes memory creationCode = abi.encodePacked(
            type(AtomicQueue).creationCode, abi.encode(config.accountant, broadcaster, config.rolesAuthority)
        );

        atomicQueue = AtomicQueue(CREATEX.deployCreate3(SALT, creationCode));
    }

    function deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // The stale script passed only the accountant; the audited AtomicQueue ctor needs 3 args:
        // (accountant, owner, authority). owner = deployer EOA, authority = the deployed RolesAuthority.
        bytes memory creationCode = abi.encodePacked(
            type(AtomicQueue).creationCode, abi.encode(config.accountant, broadcaster, config.rolesAuthority)
        );

        return CREATEX.deployCreate3(SALT, creationCode);
    }
}

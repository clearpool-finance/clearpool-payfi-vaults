// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { AtomicQueue } from "./../../src/atomic-queue/AtomicQueue.sol";
import { BaseScript } from "../Base.s.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "../ConfigReader.s.sol";

using StdJson for string;

bytes32 constant SALT = 0x5bac910c72debe007ee99d700000000000000000000000000000000000000000;

contract DeployAtomicQueue is BaseScript {
    function run() public broadcast returns (AtomicQueue atomicQueue) {
        ConfigReader.Config memory config = getConfig();
        bytes memory creationCode = abi.encodePacked(
            type(AtomicQueue).creationCode,
            abi.encode(
                config.accountant,
                broadcaster, // owner
                config.rolesAuthority // authority
            )
        );
        bytes32 salt = config.atomicQueueSalt != bytes32(0) ? config.atomicQueueSalt : SALT;
        atomicQueue = AtomicQueue(CREATEX.deployCreate3(salt, creationCode));
    }

    function deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        bytes memory creationCode = abi.encodePacked(
            type(AtomicQueue).creationCode,
            abi.encode(
                config.accountant,
                broadcaster, // owner
                config.rolesAuthority // authority
            )
        );
        // Per-vault salt when set (multi-vault chains); legacy singleton SALT otherwise.
        bytes32 salt = config.atomicQueueSalt != bytes32(0) ? config.atomicQueueSalt : SALT;
        return CREATEX.deployCreate3(salt, creationCode);
    }
}

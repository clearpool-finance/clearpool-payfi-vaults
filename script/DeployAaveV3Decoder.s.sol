// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { Script, console2 } from "@forge-std/Script.sol";
import {
    AaveV3DecoderAndSanitizerImpl
} from "src/base/DecodersAndSanitizers/CustomDecoders/AaveV3DecoderAndSanitizerImpl.sol";

/**
 * Usage:
 * forge script script/deploy/DeployAaveV3Decoder.s.sol:DeployAaveV3Decoder \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --private-key $PRIVATE_KEY \
 *   --slow --verify
 *
 * Required env:
 *   PRIVATE_KEY   = 0x... (deployer)
 *   BORING_VAULT  = 0xYourVault (the vault this decoder is bound to)
 */
contract DeployAaveV3Decoder is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address boringVault = vm.envAddress("BORING_VAULT");

        vm.startBroadcast(pk);
        AaveV3DecoderAndSanitizerImpl dec = new AaveV3DecoderAndSanitizerImpl(boringVault);
        vm.stopBroadcast();

        console2.log("BoringVault:", boringVault);
        console2.log("AaveV3DecoderAndSanitizer deployed at:", address(dec));
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { ERC20TransferDecoderAndSanitizer } from
    "src/base/DecodersAndSanitizers/CustomDecoders/ERC20TransferDecoderAndSanitizer.sol";
import { Script, console2 } from "@forge-std/Script.sol";

/**
 * Usage:
 *
 * forge script script/deploy/DeployERC20TransferDecoder.s.sol:DeployERC20TransferDecoder \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --private-key $PRIVATE_KEY \
 *   --slow --verify
 *
 * Options to provide the boring vault address:
 *   - export BORING_VAULT=0xYourVault
 *   - or use --env BORING_VAULT=0xYourVault
 */
contract DeployERC20TransferDecoder is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address boringVault = vm.envAddress("BORING_VAULT");

        vm.startBroadcast(privateKey);

        ERC20TransferDecoderAndSanitizer decoder = new ERC20TransferDecoderAndSanitizer(boringVault);

        vm.stopBroadcast();

        console2.log("BoringVault:", boringVault);
        console2.log("ERC20TransferDecoderAndSanitizer deployed at:", address(decoder));
    }
}

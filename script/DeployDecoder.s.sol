// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { Script, console2 } from "@forge-std/Script.sol";
import {
    ERC20TransferDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/CustomDecoders/ERC20TransferDecoderAndSanitizer.sol";
import {
    AaveV3DecoderAndSanitizerImpl
} from "src/base/DecodersAndSanitizers/CustomDecoders/AaveV3DecoderAndSanitizerImpl.sol";
import {
    TellerDecoderAndSanitizerImpl
} from "src/base/DecodersAndSanitizers/CustomDecoders/TellerDecoderAndSanitizerImpl.sol";
import {
    AtomicQueueDecoderAndSanitizerImpl
} from "src/base/DecodersAndSanitizers/CustomDecoders/AtomicQueueDecoderAndSanitizerImpl.sol";
import {
    CompoundV3DecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/CustomDecoders/CompoundV3DecoderAndSanitizer.sol";
import {
    ClearpoolVaultDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/CustomDecoders/ClearpoolVaultDecoderAndSanitizer.sol";

/**
 * Usage:
 * DECODER_KIND=ERC20         forge script script/DeployDecoder.s.sol:DeployDecoder ...
 * DECODER_KIND=AAVE          forge script script/DeployDecoder.s.sol:DeployDecoder ...
 * DECODER_KIND=TELLER        forge script script/DeployDecoder.s.sol:DeployDecoder ...
 * DECODER_KIND=ATOMIC_QUEUE  forge script script/DeployDecoder.s.sol:DeployDecoder ...
 * DECODER_KIND=CLEARPOOL     forge script script/DeployDecoder.s.sol:DeployDecoder ...
 *
 * Required env:
 *   PRIVATE_KEY
 *   BORING_VAULT
 *   DECODER_KIND in { ERC20, AAVE, TELLER, ATOMIC_QUEUE, COMPOUND_V3, CLEARPOOL }
 */
contract DeployDecoder is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address boringVault = vm.envAddress("BORING_VAULT");
        string memory kind = vm.envString("DECODER_KIND");

        vm.startBroadcast(privateKey);

        if (_eq(kind, "ERC20")) {
            ERC20TransferDecoderAndSanitizer dec = new ERC20TransferDecoderAndSanitizer(boringVault);
            console2.log("ERC20TransferDecoderAndSanitizer deployed at:", address(dec));
        } else if (_eq(kind, "AAVE")) {
            AaveV3DecoderAndSanitizerImpl dec = new AaveV3DecoderAndSanitizerImpl(boringVault);
            console2.log("AaveV3DecoderAndSanitizer deployed at:", address(dec));
        } else if (_eq(kind, "TELLER")) {
            TellerDecoderAndSanitizerImpl dec = new TellerDecoderAndSanitizerImpl(boringVault);
            console2.log("TellerDecoderAndSanitizer deployed at:", address(dec));
        } else if (_eq(kind, "ATOMIC_QUEUE")) {
            AtomicQueueDecoderAndSanitizerImpl dec = new AtomicQueueDecoderAndSanitizerImpl(boringVault);
            console2.log("AtomicQueueDecoderAndSanitizer deployed at:", address(dec));
        } else if (_eq(kind, "COMPOUND_V3")) {
            CompoundV3DecoderAndSanitizer dec = new CompoundV3DecoderAndSanitizer(boringVault);
            console2.log("CompoundV3DecoderAndSanitizer deployed at:", address(dec));
        } else if (_eq(kind, "CLEARPOOL")) {
            ClearpoolVaultDecoderAndSanitizer dec = new ClearpoolVaultDecoderAndSanitizer(boringVault);
            console2.log("ClearpoolVaultDecoderAndSanitizer deployed at:", address(dec));
        } else {
            revert("Unsupported DECODER_KIND");
        }

        vm.stopBroadcast();
        console2.log("BoringVault:", boringVault);
        console2.log("Kind:", kind);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

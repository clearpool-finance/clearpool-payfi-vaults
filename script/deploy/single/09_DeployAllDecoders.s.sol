// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { BaseScript } from "../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { console } from "forge-std/console.sol";

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

/**
 * @title DeployAllDecoders
 * @notice Deploys all decoder and sanitizer contracts for the boring vault system
 *
 * Usage (standalone):
 *   forge script script/deploy/single/09_DeployAllDecoders.s.sol:DeployAllDecoders \
 *     --rpc-url <RPC_URL> --broadcast --verify \
 *     --sig "run(string)" "your-config.json"
 *
 * Or with interactive prompt:
 *   forge script script/deploy/single/09_DeployAllDecoders.s.sol:DeployAllDecoders \
 *     --rpc-url <RPC_URL> --broadcast --verify
 *
 * Required: boringVault must already be deployed and set in config
 */
contract DeployAllDecoders is BaseScript {
    struct DecoderAddresses {
        address erc20TransferDecoder;
        address aaveV3Decoder;
        address tellerDecoder;
        address atomicQueueDecoder;
        address compoundV3Decoder;
    }

    /// @notice Interactive run - prompts for config file
    function run() public {
        ConfigReader.Config memory config = getConfig();
        _runDeploy(config);
    }

    /// @notice Run with config file path - for CLI usage with --sig "run(string)"
    /// @param deployFile The config file name (e.g., "plume-l2-layerzero.json")
    function run(string memory deployFile) public {
        ConfigReader.Config memory config =
            ConfigReader.toConfig(vm.readFile(string.concat(CONFIG_PATH_ROOT, deployFile)), getChainConfigFile());
        _runDeploy(config);
    }

    /// @notice Deploy function following BaseScript pattern
    /// @dev Used when called standalone via run()
    function deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        require(config.boringVault != address(0), "boringVault address not set in config");
        require(config.boringVault.code.length != 0, "boringVault must be deployed first");
        DecoderAddresses memory decoders = _deployAllDecoders(config.boringVault);
        return decoders.erc20TransferDecoder;
    }

    /// @notice Deploy all decoders and return all addresses
    /// @dev Called from DeployAll script
    function deployAllDecoders(ConfigReader.Config memory config) public broadcast returns (DecoderAddresses memory) {
        require(config.boringVault != address(0), "boringVault address not set in config");
        require(config.boringVault.code.length != 0, "boringVault must be deployed first");
        return _deployAllDecoders(config.boringVault);
    }

    /// @dev Internal run helper with broadcast
    function _runDeploy(ConfigReader.Config memory config) internal broadcast {
        require(config.boringVault != address(0), "boringVault address not set in config");
        require(config.boringVault.code.length != 0, "boringVault must be deployed first");

        console.log("Deploying all decoders for BoringVault:", config.boringVault);
        console.log("Broadcaster:", broadcaster);
        console.log("---");

        DecoderAddresses memory decoders = _deployAllDecoders(config.boringVault);

        console.log("---");
        console.log("All decoders deployed successfully!");
    }

    /// @dev Internal deployment logic - no modifiers, pure deployment
    function _deployAllDecoders(address boringVault) internal returns (DecoderAddresses memory decoders) {
        // Deploy ERC20TransferDecoderAndSanitizer
        decoders.erc20TransferDecoder = address(new ERC20TransferDecoderAndSanitizer(boringVault));
        console.log("ERC20TransferDecoderAndSanitizer:", decoders.erc20TransferDecoder);

        // Deploy AaveV3DecoderAndSanitizerImpl
        decoders.aaveV3Decoder = address(new AaveV3DecoderAndSanitizerImpl(boringVault));
        console.log("AaveV3DecoderAndSanitizer:", decoders.aaveV3Decoder);

        // Deploy TellerDecoderAndSanitizerImpl
        decoders.tellerDecoder = address(new TellerDecoderAndSanitizerImpl(boringVault));
        console.log("TellerDecoderAndSanitizer:", decoders.tellerDecoder);

        // Deploy AtomicQueueDecoderAndSanitizerImpl
        decoders.atomicQueueDecoder = address(new AtomicQueueDecoderAndSanitizerImpl(boringVault));
        console.log("AtomicQueueDecoderAndSanitizer:", decoders.atomicQueueDecoder);

        // Deploy CompoundV3DecoderAndSanitizer
        decoders.compoundV3Decoder = address(new CompoundV3DecoderAndSanitizer(boringVault));
        console.log("CompoundV3DecoderAndSanitizer:", decoders.compoundV3Decoder);

        return decoders;
    }
}

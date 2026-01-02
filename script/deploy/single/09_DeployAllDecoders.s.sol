// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { BaseScript } from "../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { console } from "forge-std/console.sol";

import {
    ClearpoolVaultDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/CustomDecoders/ClearpoolVaultDecoderAndSanitizer.sol";

/**
 * @title DeployClearpoolDecoder
 * @notice Deploys the combined Clearpool decoder for the boring vault system
 * @dev The ClearpoolVaultDecoderAndSanitizer combines: AaveV3, CompoundV3, AtomicQueue, Teller, ERC20 Transfer
 *
 * Usage (standalone):
 *   forge script script/deploy/single/09_DeployAllDecoders.s.sol:DeployClearpoolDecoder \
 *     --rpc-url <RPC_URL> --broadcast --verify \
 *     --sig "run(string)" "your-config.json"
 *
 * Or with interactive prompt:
 *   forge script script/deploy/single/09_DeployAllDecoders.s.sol:DeployClearpoolDecoder \
 *     --rpc-url <RPC_URL> --broadcast --verify
 *
 * Required: boringVault must already be deployed and set in config
 */
contract DeployClearpoolDecoder is BaseScript {
    struct DecoderAddresses {
        address clearpoolDecoder;
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
        DecoderAddresses memory decoders = _deployClearpoolDecoder(config.boringVault);
        return decoders.clearpoolDecoder;
    }

    /// @notice Deploy Clearpool decoder and return address
    /// @dev Called from DeployAll script
    function deployAllDecoders(ConfigReader.Config memory config) public broadcast returns (DecoderAddresses memory) {
        require(config.boringVault != address(0), "boringVault address not set in config");
        require(config.boringVault.code.length != 0, "boringVault must be deployed first");
        return _deployClearpoolDecoder(config.boringVault);
    }

    /// @dev Internal run helper with broadcast
    function _runDeploy(ConfigReader.Config memory config) internal broadcast {
        require(config.boringVault != address(0), "boringVault address not set in config");
        require(config.boringVault.code.length != 0, "boringVault must be deployed first");

        console.log("Deploying Clearpool decoder for BoringVault:", config.boringVault);
        console.log("Broadcaster:", broadcaster);
        console.log("---");

        _deployClearpoolDecoder(config.boringVault);

        console.log("---");
        console.log("Clearpool decoder deployed successfully!");
    }

    /// @dev Internal deployment logic - deploys combined ClearpoolVaultDecoderAndSanitizer
    function _deployClearpoolDecoder(address boringVault) internal returns (DecoderAddresses memory decoders) {
        // Deploy ClearpoolVaultDecoderAndSanitizer (combines: AaveV3, CompoundV3, AtomicQueue, Teller, ERC20 Transfer)
        decoders.clearpoolDecoder = address(new ClearpoolVaultDecoderAndSanitizer(boringVault));
        console.log("ClearpoolVaultDecoderAndSanitizer:", decoders.clearpoolDecoder);

        return decoders;
    }
}

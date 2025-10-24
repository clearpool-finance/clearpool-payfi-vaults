// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import {
    AaveV3DecoderAndSanitizerImpl
} from "src/base/DecodersAndSanitizers/CustomDecoders/AaveV3DecoderAndSanitizerImpl.sol";
import { Deployer } from "src/helper/Deployer.sol";
import { MainnetAddresses } from "test/resources/MainnetAddresses.sol";
import { ContractNames } from "resources/ContractNames.sol";

import "@forge-std/Script.sol";
import "@forge-std/StdJson.sol";

/**
 *  source .env && forge script script/DeployDecoderAndSanitizer.s.sol:DeployDecoderAndSanitizerScript --with-gas-price
 * 30000000000 --slow --broadcast --etherscan-api-key $ETHERSCAN_KEY --verify
 * @dev Optionally can change `--with-gas-price` to something more reasonable
 */
contract DeployDecoderAndSanitizerScript is Script, ContractNames, MainnetAddresses {
    uint256 public privateKey;
    Deployer public deployer = Deployer(deployerAddress);

    address boringVault;

    function setUp() external {
        privateKey = vm.envUint("PRIVATE_KEY");
        boringVault = vm.envAddress("BORING_VAULT");
    }

    function run() external {
        bytes memory creationCode;
        bytes memory constructorArgs;
        vm.startBroadcast(privateKey);

        creationCode = type(AaveV3DecoderAndSanitizerImpl).creationCode;
        constructorArgs = abi.encode(boringVault);
        deployer.deployContract("AaveV3 Decoder And Sanitizer", creationCode, constructorArgs, 0);

        vm.stopBroadcast();
    }
}

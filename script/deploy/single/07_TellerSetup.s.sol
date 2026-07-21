// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ManagerWithMerkleVerification } from "./../../../src/base/Roles/ManagerWithMerkleVerification.sol";
import { BoringVault } from "./../../../src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "./../../../src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "./../../../src/base/Roles/AccountantWithRateProviders.sol";
import { BaseScript } from "../../Base.s.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";
import { CrossChainTellerBase } from "../../../src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";

contract TellerSetup is BaseScript {
    using Strings for address;
    using StdJson for string;

    function run() public virtual {
        deploy(getConfig());
    }

    function deploy(ConfigReader.Config memory config) public virtual override broadcast returns (address) {
        TellerWithMultiAssetSupport teller = TellerWithMultiAssetSupport(config.teller);

        // BACK-PORT (present in main, absent at this audited commit): set access-control mode + seed the manual
        // whitelist from config, so the deploy itself produces the KYC posture (no separate UI/cast step needed).
        // 0=DISABLED, 1=KEYRING_KYC, 2=MANUAL_WHITELIST.
        TellerWithMultiAssetSupport.AccessControlMode mode =
            TellerWithMultiAssetSupport.AccessControlMode(config.accessControlMode);
        teller.setAccessControlMode(mode);
        if (mode == TellerWithMultiAssetSupport.AccessControlMode.MANUAL_WHITELIST && config.initialWhitelist.length > 0)
        {
            teller.updateManualWhitelist(config.initialWhitelist, true);
        }

        // add the base asset by default for all configurations
        teller.addAsset(ERC20(config.base));

        // add the remaining assets specified in the assets array of config
        for (uint256 i; i < config.assets.length; ++i) {
            // add asset
            teller.addAsset(ERC20(config.assets[i]));

            // set the corresponding rate provider data
            // BACK-PORT (present in main, absent at this audited commit): read isPeggedToBase from the chain
            // config so stablecoins like USDT can be pegged 1:1 (isPeggedToBase=true, rateProvider=0x0),
            // matching the live Black Opal. The stale script hardcoded `false`, which would force a price feed.
            string memory rpKey = string(
                abi.encodePacked(".assetToRateProviderAndPriceFeed.", config.assets[i].toHexString(), ".rateProvider")
            );
            string memory peggedKey = string(
                abi.encodePacked(".assetToRateProviderAndPriceFeed.", config.assets[i].toHexString(), ".isPeggedToBase")
            );
            bool isPeggedToBase = getChainConfigFile().readBool(peggedKey);
            address rateProvider = getChainConfigFile().readAddress(rpKey);
            teller.accountant().setRateProviderData(ERC20(config.assets[i]), isPeggedToBase, rateProvider);
        }

        // BACK-PORT: set the deposit cap from config (human units, scaled by base decimals). The teller has no
        // "0 = unlimited" path, so an unset cap (0) blocks ALL deposits — this must be set at deploy time.
        uint256 scaledCap = config.depositCap * (10 ** uint256(config.boringVaultAndBaseDecimals));
        teller.setDepositCap(scaledCap);
    }
}

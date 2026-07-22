// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { AccountantWithRateProviders } from "./../../../src/base/Roles/AccountantWithRateProviders.sol";
import { BaseScript } from "./../../Base.s.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { ConfigReader } from "../../ConfigReader.s.sol";

contract DeployAccountantWithRateProviders is BaseScript {
    using StdJson for string;

    function run() public returns (address accountant) {
        return deploy(getConfig());
    }

    function deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Require Config Values
        // Fresh pool → start at NAV 1.0 == 1e18.
        //
        // The accountant stores `_exchangeRate` in a FIXED 18-decimal convention, independent of the base
        // asset's decimals: `getRateInQuote()` converts on read via `_changeDecimals(rate, 18, decimals)`.
        // Confirmed against live vaults — OvalFi (6-dec USDC base) stores 1e18, Black Opal (6-dec USDC)
        // stores 1.1181e18, T-Pool (18-dec USDX) stores 1e18.
        //
        // This previously read `10 ** boringVaultAndBaseDecimals`, which is correct ONLY by coincidence for an
        // 18-dec base (T-Pool/USDX). For a 6-dec base (USDC) it would have deployed NAV at 1e6 — one
        // trillionth of par — so it is pinned to 1e18 here for every base-decimals configuration.
        uint256 startingExchangeRate = 1e18;
        {
            require(config.boringVault.code.length != 0, "boringVault must have code");
            require(config.base.code.length != 0, "base must have code");
            require(config.accountantSalt != bytes32(0), "accountant salt must not be zero");
            require(config.boringVault != address(0), "boring vault address must not be zero");
            require(config.payoutAddress != address(0), "payout address must not be zero");
            require(config.base != address(0), "base address must not be zero");
            require(config.allowedExchangeRateChangeUpper > 1e4, "allowedExchangeRateChangeUpper");
            require(config.allowedExchangeRateChangeUpper <= 1.003e4, "allowedExchangeRateChangeUpper upper bound");
            require(config.allowedExchangeRateChangeLower <= 1e4, "allowedExchangeRateChangeLower");
            require(config.allowedExchangeRateChangeLower >= 0.997e4, "allowedExchangeRateChangeLower lower bound");
            require(config.minimumUpdateDelayInSeconds >= 3600, "minimumUpdateDelayInSeconds");
            require(config.managementFee < 1e4, "managementFee");
            require(startingExchangeRate == 1e18, "starting exchange rate must equal 1e18 (NAV 1.0)");
        }
        // Create Contract
        bytes memory creationCode = type(AccountantWithRateProviders).creationCode;
        AccountantWithRateProviders accountant;

        bytes memory params;
        {
            params = abi.encode(
                broadcaster,
                config.boringVault,
                config.payoutAddress,
                startingExchangeRate,
                config.base,
                config.allowedExchangeRateChangeUpper,
                config.allowedExchangeRateChangeLower,
                config.minimumUpdateDelayInSeconds,
                config.managementFee
            );
        }

        bytes memory initCode;
        {
            initCode = abi.encodePacked(creationCode, params);
        }

        {
            accountant = AccountantWithRateProviders(CREATEX.deployCreate3(config.accountantSalt, initCode));
        }

        _accountantStateCheck(accountant, config, startingExchangeRate);
        return address(accountant);
    }

    function _accountantStateCheck(
        AccountantWithRateProviders accountant,
        ConfigReader.Config memory config,
        uint256 startingExchangeRate
    )
        internal
    {
        {
            (
                address _payoutAddress,
                uint128 _feesOwedInBase,
                uint128 _totalSharesLastUpdate,
                uint96 _exchangeRate,
                uint16 _allowedExchangeRateChangeUpper,
                uint16 _allowedExchangeRateChangeLower,
                uint64 _lastUpdateTimestamp,
                bool _isPaused,
                uint32 _minimumUpdateDelayInSeconds,
                uint16 _managementFee
            ) = accountant.accountantState();

            // Post Deploy Checks
            require(_payoutAddress == config.payoutAddress, "payout address");
            require(_feesOwedInBase == 0, "fees owed in base");
            require(_totalSharesLastUpdate == 0, "total shares last update");
            require(_exchangeRate == startingExchangeRate, "exchange rate");
            require(
                _allowedExchangeRateChangeUpper == config.allowedExchangeRateChangeUpper,
                "allowed exchange rate change upper"
            );
            require(
                _allowedExchangeRateChangeLower == config.allowedExchangeRateChangeLower,
                "allowed exchange rate change lower"
            );
            require(_lastUpdateTimestamp == uint64(block.timestamp), "last update timestamp");
            require(_isPaused == false, "is paused");
            require(
                _minimumUpdateDelayInSeconds == config.minimumUpdateDelayInSeconds, "minimum update delay in seconds"
            );
            require(_managementFee == config.managementFee, "management fee");
            require(address(accountant.vault()) == config.boringVault, "vault");
            require(address(accountant.base()) == config.base, "base");
            require(accountant.decimals() == ERC20(config.base).decimals(), "decimals");
        }
    }
}

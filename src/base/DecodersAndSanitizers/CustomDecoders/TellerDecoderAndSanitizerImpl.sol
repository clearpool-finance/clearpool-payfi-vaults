// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * Minimal Teller decoder for deposit/redeem paths used by Manager.
 * Adjust function names/args to your actual Teller ABI.
 */
contract TellerDecoderAndSanitizerImpl is BaseDecoderAndSanitizer {
    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    // @desc deposit base asset into the vault via Teller
    // @note No asset restrictions - allows any supported asset
    function deposit(
        address, /*asset*/
        uint256, /*amount*/
        uint256 /*minShareOut*/
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        // No restrictions on asset
        addressesFound = abi.encodePacked();
    }
}

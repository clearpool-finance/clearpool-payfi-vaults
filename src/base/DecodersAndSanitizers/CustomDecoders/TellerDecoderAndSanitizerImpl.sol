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
    // @tag asset:address
    function deposit(
        address asset,
        uint256,
        /*amount*/
        uint256 /*minShareOut*/
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        // constrain the asset (base token)
        addressesFound = abi.encodePacked(asset);
    }

    // @desc redeem shares from the vault back to receiver
    // @tag receiver:address
    // @tag owner:address
    function redeem(
        uint256,
        /*shares*/
        address receiver,
        address owner
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        // constrain receiver/owner to your BoringVault address if desired (Manager will compare)
        addressesFound = abi.encodePacked(receiver, owner);
    }
}

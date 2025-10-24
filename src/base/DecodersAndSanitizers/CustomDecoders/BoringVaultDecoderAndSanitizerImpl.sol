// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * @notice Minimal decoder for BoringVault.manage(address target, bytes data, uint256 value)
 *         It returns the `target` so the Manager can enforce that it equals the allowlisted vault.
 */
contract BoringVaultDecoderAndSanitizerImpl is BaseDecoderAndSanitizer {
    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    // @desc Call the vault's manage entrypoint
    // @tag target:address:the contract to call from the vault
    // @tag data:bytes:encoded calldata for target
    // @tag value:uint256:eth value forwarded
    function manage(
        address target,
        bytes calldata,
        /* data */
        uint256 /* value */
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        // expose only the outer `target` for policy checks
        addressesFound = abi.encodePacked(target);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

/**
 * @title AtomicQueueDecoderAndSanitizerImpl
 * @notice Decoder for AtomicQueue withdrawal request operations
 * @dev Used by ManagerWithMerkleVerification to verify AtomicQueue calls
 */
contract AtomicQueueDecoderAndSanitizerImpl is BaseDecoderAndSanitizer {
    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    // @desc Submit atomic withdrawal request to exchange offer asset for want asset
    // @note No asset restrictions - allows any offer/want asset pair
    function updateAtomicRequest(
        ERC20, /*offer*/
        ERC20, /*want*/
        uint64, /*deadline*/
        uint96 /*offerAmount*/
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        // No restrictions on offer or want assets
        addressesFound = abi.encodePacked();
    }
}

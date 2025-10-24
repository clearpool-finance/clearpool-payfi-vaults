// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

/**
 * Minimal decoder/sanitizer for ERC20.transfer.
 * - Used by ManagerWithMerkleVerification to extract address arguments
 *   from calldata via functionStaticCall().
 * - Returns abi.encodePacked(to) so your leaf preimage:
 *   keccak256(abi.encodePacked(decoder, target, valueIsNonZero, selector, packedArgumentAddresses))
 *   matches the FE builder (packedArgumentAddresses = abi.encodePacked(payout)).
 *
 * NOTE: We intentionally DO NOT implement transferFrom or any other ERC20 fn.
 *       If a strategist tries to route those through this decoder, it will revert.
 */
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract ERC20TransferDecoderAndSanitizer is BaseDecoderAndSanitizer {
    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    /// @notice Decoder for ERC20.transfer(address to, uint256 amount)
    /// @dev Returns abi.encodePacked(to) — this is what the Merkle leaf includes.
    function transfer(address to, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(to);
    }

    // ─────────────────────────────── Guards
    // ───────────────────────────────

    /// @dev Explicitly block transferFrom (and any other function not implemented in Base).
    function transferFrom(address, address, uint256) external pure returns (bytes memory) {
        // Route to Base fallback revert with full calldata for visibility
        assembly {
            // function selector for BaseDecoderAndSanitizer__FunctionNotImplemented(bytes)
            // but easier: just revert with the same calldata so Base fallback catches it
            revert(0, 0)
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * @title TPoolBorrowDecoderAndSanitizer
 * @notice Minimal, clean strategy decoder for the Clearpool × HT Markets T-Pool borrower-draw vault.
 *         The only on-chain strategy action is the borrower drawing funds via ERC20 transfer, so the
 *         decoder exposes exactly one sanitizer plus the inherited approve:
 *           - transfer(address to, uint256): pins the recipient (so the merkle leaf binds the HT borrower)
 *           - approve(address spender, uint256): inherited from BaseDecoderAndSanitizer (pins the spender)
 *         Every other selector hits BaseDecoderAndSanitizer's fallback revert. No unpinned-recipient gaps.
 *         Repayments are direct transfers TO the vault and require no leaf at all.
 *         (Byte-for-byte the same logic as the fork-validated BlackOpalBorrowDecoderAndSanitizer; renamed
 *         for on-chain clarity since the recipient is pinned by the manage-root leaf, not the decoder.)
 */
contract TPoolBorrowDecoderAndSanitizer is BaseDecoderAndSanitizer {
    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    // @desc ERC20 transfer — recipient is pinned into the merkle leaf
    // @tag to:address
    function transfer(address to, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(to);
    }
}

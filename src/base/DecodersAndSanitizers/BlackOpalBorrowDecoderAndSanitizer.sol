// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * @title BlackOpalBorrowDecoderAndSanitizer
 * @notice Minimal, clean strategy decoder for the Black Opal borrower-draw vault.
 *         The only on-chain strategy action is the borrower drawing funds via ERC20 transfer,
 *         so the decoder exposes exactly two sanitizers:
 *           - transfer(address to, uint256): pins the recipient (so the merkle leaf binds the BO borrower)
 *           - approve(address spender, uint256): inherited from BaseDecoderAndSanitizer (pins the spender)
 *         Every other selector hits BaseDecoderAndSanitizer's fallback revert. No Compound/Comet/AtomicQueue
 *         surface, so there are no unpinned-recipient gaps. Repayments are direct transfers TO the vault and
 *         require no leaf at all.
 */
contract BlackOpalBorrowDecoderAndSanitizer is BaseDecoderAndSanitizer {
    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    // @desc ERC20 transfer — recipient is pinned into the merkle leaf
    // @tag to:address
    function transfer(address to, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(to);
    }
}

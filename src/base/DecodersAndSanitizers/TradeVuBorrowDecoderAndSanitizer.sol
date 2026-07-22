// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * @title TradeVuBorrowDecoderAndSanitizer
 * @notice Minimal, clean strategy decoder for the Clearpool × TradeVu borrower-draw vault.
 *         The only on-chain strategy action is the borrower drawing funds via ERC20 transfer, so the
 *         decoder exposes exactly one sanitizer plus the inherited approve:
 *           - transfer(address to, uint256): pins the recipient (so the merkle leaf binds the TradeVu borrower)
 *           - approve(address spender, uint256): inherited from BaseDecoderAndSanitizer (pins the spender)
 *         Every other selector hits BaseDecoderAndSanitizer's fallback revert. No unpinned-recipient gaps.
 *         Repayments are direct transfers TO the vault and require no leaf at all.
 *
 *         Management-fee claims deliberately do NOT go through here. `BoringVault.manage` is `requiresAuth`
 *         and solmate's Auth passes for `msg.sender == owner`, so the owner (the Clearpool Safe post-handover)
 *         claims fees with two direct calls — `vault.manage(USDC, approve(accountant, amt), 0)` then
 *         `vault.manage(accountant, claimFees(USDC), 0)` — with no root, proof or decoder involved. That is
 *         the path the live Ola vaults use (Plume tx 0x981b3871…), and the live Ola decoder likewise does not
 *         implement claimFees.
 *
 *         (Byte-for-byte the same logic as the fork-validated TPoolBorrowDecoderAndSanitizer and
 *         BlackOpalBorrowDecoderAndSanitizer; renamed for on-chain clarity.)
 */
contract TradeVuBorrowDecoderAndSanitizer is BaseDecoderAndSanitizer {
    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    // @desc ERC20 transfer — recipient is pinned into the merkle leaf
    // @tag to:address
    function transfer(address to, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(to);
    }
}

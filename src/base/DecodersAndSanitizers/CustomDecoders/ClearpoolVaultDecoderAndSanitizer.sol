// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { AaveV3DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/AaveV3DecoderAndSanitizer.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

/**
 * @title ClearpoolVaultDecoderAndSanitizer
 * @notice Combined decoder for Clearpool PayFi vaults supporting multiple protocols
 * @dev Includes: Aave V3, Compound V3, AtomicQueue, ERC20 Transfer, Teller
 */
contract ClearpoolVaultDecoderAndSanitizer is AaveV3DecoderAndSanitizer {
    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

    // ========================================= COMPOUND V3 (COMET) =========================================
    //
    // Security model: ManagerWithMerkleVerification builds each Merkle leaf from the
    // addresses THIS decoder returns (functionStaticCall -> packedArgumentAddresses).
    // Every execution-relevant address a function carries MUST be returned here, or it
    // is left unconstrained and a strategist can substitute it while reusing a valid proof.
    //
    // We deliberately expose only the self-directed Comet surface a vault actually needs,
    // mirroring the audited Seven Seas / Veda Labs CompoundV3DecoderAndSanitizer:
    //   - supply / withdraw : msg.sender (the vault) is always the account; no recipient
    //                         parameter exists, so only the asset is bound.
    //   - claim             : rewards are paid to `src`; both `comet` and `src` are bound.
    // The delegation variants (supplyTo, withdrawTo, withdrawFrom, transferFrom, claimTo,
    // supply/withdrawCollateral) are intentionally NOT implemented: a merkle-gated vault
    // has no legitimate use for routing funds to or from a third party, and exposing them
    // without binding their recipient/src was the missing-address vulnerability. Any such
    // call now falls through to BaseDecoderAndSanitizer's fallback and reverts.

    // @desc Supply base/collateral asset to Compound V3 Comet (credited to the vault)
    // @tag asset:address:the asset being supplied
    function supply(
        address asset,
        uint256 /*amount*/
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(asset);
    }

    // @desc Withdraw base/collateral asset from Compound V3 Comet (to the vault)
    // @tag asset:address:the asset being withdrawn
    function withdraw(
        address asset,
        uint256 /*amount*/
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(asset);
    }

    // @desc Transfer base asset (Compound V3 base transfer / ERC20 transfer)
    // @tag to:address:the recipient
    function transfer(
        address to,
        uint256 /*amount*/
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(to);
    }

    // @desc Claim rewards from Compound V3 via the CometRewards contract (paid to src)
    // @tag comet:address:the Comet market rewards are claimed from
    // @tag src:address:the account whose rewards are claimed (recipient of the payout)
    function claim(
        address comet,
        address src,
        bool /*shouldAccrue*/
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(comet, src);
    }

    // ========================================= ATOMIC QUEUE =========================================

    // @desc Submit atomic withdrawal request to exchange offer asset for want asset
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
        addressesFound = abi.encodePacked();
    }

    // ========================================= TELLER =========================================

    // @desc Deposit base asset into the vault via Teller
    function deposit(
        address, /*asset*/
        uint256, /*amount*/
        uint256 /*minShareOut*/
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked();
    }
}

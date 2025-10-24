// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { AaveV3DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/AaveV3DecoderAndSanitizer.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract AaveV3DecoderAndSanitizerImpl is AaveV3DecoderAndSanitizer {
    constructor(address boringVault) BaseDecoderAndSanitizer(boringVault) { }
}

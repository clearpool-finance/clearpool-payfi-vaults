# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Fork of [Se7en-Seas/boring-vault](https://github.com/Se7en-Seas/boring-vault) with Clearpool "Payfi" modifications. Implements the **Arctic Architecture** — a modular vault system where a minimal `BoringVault` delegates strategy, deposit/withdraw, and pricing logic to external contracts (Manager, Teller, Accountant).

## Build & Test Commands

```bash
forge build                                    # Compile
forge test                                     # Run all tests (uses mainnet fork)
forge test --match-path test/SomeTest.t.sol    # Single test file
forge test --match-test test_functionName -vvvv # Single test with stack traces
```

**Linting & formatting:**
```bash
make solhint        # or: solhint -w 0 'src/**/*.sol'
make slither        # or: slither src
make prettier       # Format non-Solidity files
forge fmt           # Format Solidity (uses foundry.toml [fmt] section)
```

**Deployment (JSON-config-driven):**
```bash
# Dry run against fork
make deployL1 file=deployment-config/somefile.json
make deployL2 file=deployment-config/somefile.json

# Live deploy with broadcast + verification
make live-deployL1 file=deployment-config/somefile.json
make live-deployL2 file=deployment-config/somefile.json

# Validate a live deployment
make checkL1 file=deployment-config/somefile.json
make checkL2 file=deployment-config/somefile.json
```

**Environment:** Copy `sample.env` to `.env` and add RPC URLs / keys. Tests require at least `MAINNET_RPC_URL` for fork testing.

## Architecture

### Core Contracts (src/base/)

| Contract | Role |
|----------|------|
| **BoringVault** | Minimal ERC20 vault. Holds assets, delegates all logic. Exposes `manage()` (strategist calls), `enter()`/`exit()` (deposit/withdraw). |
| **ManagerWithMerkleVerification** | Restricts strategies via per-strategist merkle trees. Each leaf encodes: decoder address, target, selector, whether ETH transfer is allowed, and sensitive address arguments. |
| **TellerWithMultiAssetSupport** | Handles multi-asset deposits/withdrawals with MEV protection (share lock period, deposit refund, AtomicQueue for withdrawals). |
| **AccountantWithRateProviders** | Share pricing via offchain exchange rates. Rate-limited and bound-limited updates; auto-pauses on deviation. |

### Payfi-Specific Changes (vs upstream BoringVault)

See `docs/CHANGES_PAYFI.md` for the full diff. Key additions:

- **Lending rate mechanism** on Accountant — auto-compounding interest that increases NAV in real-time. `getBorrowerRate()` = lending rate + management fee.
- **Access control modes** on Teller — `DISABLED` (0), `KEYRING_KYC` (1), `MANUAL_WHITELIST` (2). Separate `contractWhitelist` and `manualWhitelist`.
- **Deposit cap** on Teller.
- **AtomicQueue redesign** — removed user-set `atomicPrice`; all redemptions at current NAV via Accountant integration.

### Decoder & Sanitizer System (src/base/DecodersAndSanitizers/)

Each DeFi protocol integration has a dedicated decoder that extracts sensitive calldata arguments for merkle verification. ~50 protocol-specific decoders exist (Aave V3, Uniswap V3, Morpho, Pendle, LayerZero OFT, etc.). `BaseDecoderAndSanitizer` provides the fallback-revert base; protocol decoders inherit from it.

### Cross-Chain Tellers

`MultiChainLayerZeroTellerWithMultiAssetSupport`, `MultiChainHyperlaneTellerWithMultiAssetSupport`, and `CrossChainOPTellerWithMultiAssetSupport` extend the base Teller for bridged deposits/withdrawals. LayerZero uses a custom `OAppAuth` pattern in `src/base/Roles/CrossChain/OAppAuth/`.

### Deployment System

`script/deploy/deployAll.s.sol` orchestrates full vault deployment from a JSON config file. Individual steps live in `script/deploy/single/` (numbered 01-09). Deployment configs are in `deployment-config/` — one JSON per chain/vault. Uses CREATE3 (`src/helper/Deployer.sol`) for deterministic addresses.

## Key Patterns

- **Auth model:** solmate's `Auth` + `RolesAuthority`. Roles are numeric (uint8). Role constants defined in deployment scripts and test files.
- **Solidity version:** 0.8.22 across all contracts. Compiler: `optimizer_runs = 200`, `evm_version = shanghai`.
- **Import remappings:** `@solmate/`, `@forge-std/`, `@openzeppelin/`, `@ion-protocol/`, `@layerzerolabs/` — see `remappings.txt`.
- **Dependencies:** Git submodules in `lib/` (solmate, forge-std, openzeppelin-contracts, ion-protocol, createx, etc.) + npm packages for LayerZero (`@layerzerolabs/*`).
- **Test addresses:** `test/resources/MainnetAddresses.sol` has 200+ mainnet token/protocol addresses used across fork tests.

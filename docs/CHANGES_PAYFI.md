# Changes in Payfi Implementation

## AccountantWithRateProviders

- Added lending rate mechanism with auto-compounding
- Separated management fees from lending rates
- Added `checkpoint()` for interest accrual
- New `getBorrowerRate()` function

## TellerWithMultiAssetSupport

- Three access control modes (DISABLED, KEYRING_KYC, MANUAL_WHITELIST)
- Deposit cap implementation
- Enhanced whitelisting for contracts

## AtomicQueue

- Updated to use NAV-based pricing from AccountantWithRateProviders
- Removed atomicPrice in favor of dynamic NAV pricing

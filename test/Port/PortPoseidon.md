# Port Poseidon Proof of Concept

[`0xe43420E1f83530AAf8ad94e6904FDbdc3556Da2B`](https://poseidon-testnet.explorer.caldera.xyz/address/0xe43420E1f83530AAf8ad94e6904FDbdc3556Da2B) Is set as the Owner and Solver.

## Poseidon Deployment

* **BoringVault:** Deployed at address [`0xEcfd527e404A0611bd21cd84e50fA62dD4Ba0E97`](https://poseidon-testnet.explorer.caldera.xyz/address/0xEcfd527e404A0611bd21cd84e50fA62dD4Ba0E97?tab=contract). This contract is a vault with the name "Port Boring Vault" and symbol "PBV", having 18 decimals.
* **AccountantWithRateProviders:** Deployed at address [`0x0765A218F2Edc70cf98A0Ef7Daae8F993459D10D`](https://poseidon-testnet.explorer.caldera.xyz/address/0x0765A218F2Edc70cf98A0Ef7Daae8F993459D10D?tab=contract). This contract manages accounting and rate providers for the vault.
* **TellerWithMultiAssetSupport:** Deployed at address [`0x4bB9886F79FeFD50873A558982925CB99B9Aa195`](https://poseidon-testnet.explorer.caldera.xyz/address/0x4bB9886F79FeFD50873A558982925CB99B9Aa195?tab=contract). This contract facilitates deposits and withdrawals of multiple assets in the vault.
* **RolesAuthority:** Deployed at address [`0x32a94A87091979207BDdBf3b9e5E1D4dAb0c2375`](https://poseidon-testnet.explorer.caldera.xyz/address/0x32a94A87091979207BDdBf3b9e5E1D4dAb0c2375?tab=contract). This contract manages roles and permissions for interacting with other contracts in the system.
* **AtomicQueue:** Deployed at address [`0xd2f34CD75FD00b51faddF1e9fDf97128976Da82C`](https://poseidon-testnet.explorer.caldera.xyz/address/0xd2f34CD75FD00b51faddF1e9fDf97128976Da82C?tab=contract). This contract implements an atomic queue mechanism.
* **AtomicSolverV3:** Deployed at address [`0x7258CF8Fd4c11Dd5E460CCa6B55F0aa1135eEc59`](https://poseidon-testnet.explorer.caldera.xyz/address/0x7258CF8Fd4c11Dd5E460CCa6B55F0aa1135eEc59?tab=contract). This contract is responsible for solving atomic operations, with the deployer having initial control.

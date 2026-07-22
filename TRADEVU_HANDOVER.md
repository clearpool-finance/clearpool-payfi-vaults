# Clearpool × Tradevu — Tradevu Vault (Ethereum mainnet, AUDITED VER)

    Boring Vault:  0xaCF907a9183544aa5E0C4232c6730C2fd811409a (https://etherscan.io/address/0xaCF907a9183544aa5E0C4232c6730C2fd811409a#code)
    Manager:  0x8D90A520264b9493BdfA13BB50A2aFeC1433F6c9 (https://etherscan.io/address/0x8D90A520264b9493BdfA13BB50A2aFeC1433F6c9)
    Accountant:  0x015745aa47b4891609754e7b1Fe65c8A3CB510eE (https://etherscan.io/address/0x015745aa47b4891609754e7b1Fe65c8A3CB510eE)
    Teller (LayerZero):  0xD7EDfd54a24a207D40502da86ccbabEaE344D2Cd (https://etherscan.io/address/0xD7EDfd54a24a207D40502da86ccbabEaE344D2Cd)
    Roles Authority:  0xFA7938Fa9D3AE8E420668f70A954E2B7F8FEd833 (https://etherscan.io/address/0xFA7938Fa9D3AE8E420668f70A954E2B7F8FEd833)
    Atomic Queue:  0x7985a270905f13c250B999a90D61E6704b74404F (https://etherscan.io/address/0x7985a270905f13c250B999a90D61E6704b74404F)
    Atomic Solver:  0xbD1F0c761Bca4431FF18c46619B2CE437E28bC95 (https://etherscan.io/address/0xbD1F0c761Bca4431FF18c46619B2CE437E28bC95)
    Decoder:  0x6284e0118779cc4779e07ebd26e3e462f4a3c6c8 (https://etherscan.io/address/0x6284e0118779cc4779e07ebd26e3e462f4a3c6c8)

  Base asset: USDC (6-dec)
  Deposit cap: 5M.
  Fee: 0.5% (managementFee 50 bps, payout → Clearpool). NAV-based (start 1.0), KYC (manual whitelist).
  LP token: Tradevu / cpTV

  Lending rate: 0 at deploy — Clearpool sets 1500 (15%) from the Safe once funded.
  NAV bounds: +0.30% / 0% per update (min delay 1h). Any mark-down pauses the accountant by design.

#  Permission/roles

  Protocol Admin (Clearpool — owns all 7 contracts) - 0xE0308d5681afe01A8Ad1cC0b8c937Db699E204aF
  NAV / pause / withdrawals (Clearpool — UPDATE_EXCHANGE_RATE_ROLE, PAUSER_ROLE, owns Atomic Queue+Solver) - 0xE0308d5681afe01A8Ad1cC0b8c937Db699E204aF
  Borrower (Tradevu, STRATEGIST_ROLE) - 0xEFe513B1539EaBFAD0bC077e12eb991926a62d0b

  Deployer 0x03014C3cDaDD8a5A1D8EBa50e35212a53Ba3A504 — ZERO roles, owns nothing.

#  Manage root

  manageRoot[Tradevu] = 0x9d3d036340e37b9ec1d1631842d54796849bf26e59e795dafb441c143dfc8b32

  Single leaf (root == leaf, proof == []):
    keccak(decoder ‖ USDC ‖ false ‖ 0xa9059cbb ‖ Tradevu)
    = USDC.transfer(→ 0xEFe513B1539EaBFAD0bC077e12eb991926a62d0b, any amount)

  The borrower can move USDC ONLY to its own address. Repayment is a plain ERC20
  transfer to the vault and needs no role and no leaf.

#  Whitelist at deploy

  Manual (LPs):   0xf9B0445770341D88a77d384c5bEF582A27534865  (Cicada)
                  0x5898e09a4ac5798a93ee08356318299e00a7A837  (Cicada / testing)
                  0xE0308d5681afe01A8Ad1cC0b8c937Db699E204aF  (Clearpool Safe)
                  0x03014C3cDaDD8a5A1D8EBa50e35212a53Ba3A504  (deployer — removable)
  Contract:       0xbD1F0c761Bca4431FF18c46619B2CE437E28bC95  (Atomic Solver — required for withdrawals)

#  Runbook

  Set the rate (Safe):    accountant.setLendingRate(1500)         — owner-only, do once funded
  Claim fees (Safe):      vault.manage(USDC, approve(accountant, amt), 0)
                          vault.manage(accountant, claimFees(USDC), 0)
                          Needs idle USDC in the vault — time it with a repayment.
  Onboard an LP (Safe):   teller.updateManualWhitelist([addr], true)
  Withdrawals (Safe):     approve AtomicSolver for USDC + hold transient USDC, then redeemSolve.
                          The vault funds the exit via bulkWithdraw, leaving the operator ~whole.

#  Provenance

  Cantina-audited commit 3f87019c2e5f853e99b9f1dc6ba30fe7e8b16834. The audited contracts are
  unmodified — the only src/ addition is the borrow decoder, which is logic-identical to the
  T-Pool and Black Opal decoders. All 8 contracts Etherscan-verified.
  Branch deploy/tradevu-clearpool. 25/25 fork tests pass against this exact deployment.

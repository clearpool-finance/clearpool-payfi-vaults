// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";

/**
 * @notice Covers the rate mechanism Clearpool actually intends to use on Tradevu:
 *         deploy with lendingRate = 0, then `setLendingRate(1500)` once the vault is funded,
 *         after which NAV accrues automatically with no further transactions.
 *
 *         Also covers the gaps left by TradeVuForkValidation: pause/unpause, unsupported-asset
 *         deposits, and what happens when a fee claim is attempted without idle liquidity.
 */
contract TradeVuLendingRateFork is Test {
    address constant VAULT = 0xaCF907a9183544aa5E0C4232c6730C2fd811409a;
    address constant ACCOUNTANT = 0x015745aa47b4891609754e7b1Fe65c8A3CB510eE;
    address constant TELLER = 0xD7EDfd54a24a207D40502da86ccbabEaE344D2Cd;
    address constant ROLES_AUTHORITY = 0xFA7938Fa9D3AE8E420668f70A954E2B7F8FEd833;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant TRADEVU = 0xEFe513B1539EaBFAD0bC077e12eb991926a62d0b;
    address constant SAFE = 0xE0308d5681afe01A8Ad1cC0b8c937Db699E204aF;
    address constant CICADA = 0xf9B0445770341D88a77d384c5bEF582A27534865;
    address constant VARINDER = 0x5898e09a4ac5798a93ee08356318299e00a7A837; // test address, also whitelisted
    address constant DEV = 0x03014C3cDaDD8a5A1D8EBa50e35212a53Ba3A504;

    bytes4 constant APPROVE_SEL = 0x095ea7b3;
    bytes4 constant CLAIM_FEES_SEL = 0x15a0ea6a;

    uint8 constant UPDATE_EXCHANGE_RATE_ROLE = 4;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546");
    }

    // ------------------------------------------------- lending rate

    function test_deploysWithLendingRateZero() public view {
        (uint256 rate,) = _lendingInfo();
        assertEq(rate, 0, "starts at 0% as instructed; Clearpool sets 15% once funded");
        assertEq(AccountantWithRateProviders(ACCOUNTANT).getRate(), 1e18, "NAV flat at 1.0 until then");
        assertEq(AccountantWithRateProviders(ACCOUNTANT).getBorrowerRate(), 50, "0 lending + 50bps fee");
    }

    function test_ownerSetsLendingRateAndNavAccruesWithNoFurtherTxs() public {
        _seedVault(1_000_000e6);

        // Clearpool sets 15% once funded. setLendingRate has no role capability on the audited
        // branch, so this is the OWNER acting (the Clearpool Safe post-handover).
        address owner = AccountantWithRateProviders(ACCOUNTANT).owner();
        vm.prank(owner);
        AccountantWithRateProviders(ACCOUNTANT).setLendingRate(1500);

        assertEq(AccountantWithRateProviders(ACCOUNTANT).getBorrowerRate(), 1550, "15% to LPs + 0.5% fee");

        // ...and NAV climbs on its own. No updateExchangeRate calls anywhere in this test.
        vm.warp(block.timestamp + 365 days);
        assertApproxEqRel(AccountantWithRateProviders(ACCOUNTANT).getRate(), 1.15e18, 0.001e18, "NAV 1.0 -> ~1.15");
        assertApproxEqRel(
            AccountantWithRateProviders(ACCOUNTANT).getRateInQuote(ERC20(USDC)), 1.15e6, 0.001e18, "quoted in USDC"
        );
    }

    function test_navRoleAloneCannotSetLendingRate() public {
        // A role-4 holder that is NOT the owner: on the audited branch setLendingRate is owner-only.
        address navBot = address(0xB07);
        vm.prank(RolesAuthority(ROLES_AUTHORITY).owner());
        RolesAuthority(ROLES_AUTHORITY).setUserRole(navBot, UPDATE_EXCHANGE_RATE_ROLE, true);

        vm.prank(navBot);
        vm.expectRevert();
        AccountantWithRateProviders(ACCOUNTANT).setLendingRate(1500);

        // but it CAN push a manual NAV update
        vm.warp(block.timestamp + 3601);
        vm.prank(navBot);
        AccountantWithRateProviders(ACCOUNTANT).updateExchangeRate(1.001e18);
        assertEq(AccountantWithRateProviders(ACCOUNTANT).getRate(), 1.001e18, "role 4 can update NAV");
    }

    function test_lendingRateCannotExceedMax() public {
        address owner = AccountantWithRateProviders(ACCOUNTANT).owner();
        vm.prank(owner);
        vm.expectRevert("Lending rate exceeds maximum"); // maxLendingRate = 5000 (50%)
        AccountantWithRateProviders(ACCOUNTANT).setLendingRate(5001);
    }

    function test_depositAfterAccrualMintsFewerShares() public {
        _seedVault(1_000_000e6);
        address owner = AccountantWithRateProviders(ACCOUNTANT).owner();
        vm.prank(owner);
        AccountantWithRateProviders(ACCOUNTANT).setLendingRate(1500);
        vm.warp(block.timestamp + 365 days);

        uint256 amount = 115_000e6;
        deal(USDC, VARINDER, amount);
        vm.startPrank(VARINDER);
        ERC20(USDC).approve(VAULT, amount);
        uint256 shares = TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDC), amount, 0);
        vm.stopPrank();

        assertApproxEqRel(shares, 100_000e6, 0.001e18, "115k USDC at NAV ~1.15 mints ~100k cpTV");
    }

    function test_feesAccrueAlongsideInterestAndAreClaimable() public {
        _seedVault(1_000_000e6);
        address owner = AccountantWithRateProviders(ACCOUNTANT).owner();
        vm.prank(owner);
        AccountantWithRateProviders(ACCOUNTANT).setLendingRate(1500);
        vm.warp(block.timestamp + 365 days);

        // fee is 0.5% of the grown balance, so slightly above 5k on 1M
        uint256 owed = AccountantWithRateProviders(ACCOUNTANT).previewFeesOwed();
        assertApproxEqRel(owed, 5750e6, 0.02e18, "0.5% of ~1.15M");

        uint256 before = ERC20(USDC).balanceOf(SAFE);
        vm.startPrank(BoringVault(payable(VAULT)).owner());
        BoringVault(payable(VAULT)).manage(USDC, abi.encodeWithSelector(APPROVE_SEL, ACCOUNTANT, type(uint256).max), 0);
        BoringVault(payable(VAULT)).manage(ACCOUNTANT, abi.encodeWithSelector(CLAIM_FEES_SEL, USDC), 0);
        vm.stopPrank();

        assertApproxEqRel(ERC20(USDC).balanceOf(SAFE) - before, 5750e6, 0.02e18, "fees paid to the Safe");
    }

    // ------------------------------------------------- gaps

    function test_feeClaimRevertsWithoutIdleLiquidity() public {
        _seedVault(1_000_000e6);
        address owner = AccountantWithRateProviders(ACCOUNTANT).owner();
        vm.prank(owner);
        AccountantWithRateProviders(ACCOUNTANT).setLendingRate(1500);
        vm.warp(block.timestamp + 365 days);

        // drain the vault to simulate "fully drawn by the borrower".
        // NB: read the balance BEFORE vm.prank — an inlined call would consume the prank.
        uint256 vaultBal = ERC20(USDC).balanceOf(VAULT);
        vm.prank(owner);
        BoringVault(payable(VAULT)).manage(USDC, abi.encodeWithSelector(bytes4(0xa9059cbb), TRADEVU, vaultBal), 0);

        vm.startPrank(owner);
        BoringVault(payable(VAULT)).manage(USDC, abi.encodeWithSelector(APPROVE_SEL, ACCOUNTANT, type(uint256).max), 0);
        vm.expectRevert(); // TRANSFER_FROM_FAILED: nothing to pay the fee with
        BoringVault(payable(VAULT)).manage(ACCOUNTANT, abi.encodeWithSelector(CLAIM_FEES_SEL, USDC), 0);
        vm.stopPrank();
    }

    function test_pauseBlocksDepositsAndUnpauseRestores() public {
        deal(USDC, CICADA, 2000e6);

        vm.prank(SAFE);
        TellerWithMultiAssetSupport(TELLER).pause();

        vm.startPrank(CICADA);
        ERC20(USDC).approve(VAULT, 2000e6);
        vm.expectRevert();
        TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDC), 1000e6, 0);
        vm.stopPrank();

        vm.prank(SAFE);
        TellerWithMultiAssetSupport(TELLER).unpause();

        vm.prank(CICADA);
        uint256 shares = TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDC), 1000e6, 0);
        assertEq(shares, 1000e6, "deposits work again after unpause");
    }

    function test_unsupportedAssetDepositReverts() public {
        // only USDC was added via addAsset. DAI is used here rather than USDT because USDT's
        // non-standard approve() returns no bool and reverts inside solmate's ERC20 wrapper first.
        deal(DAI, CICADA, 1000e18);
        vm.startPrank(CICADA);
        ERC20(DAI).approve(VAULT, 1000e18);
        vm.expectRevert(TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__AssetNotSupported.selector);
        TellerWithMultiAssetSupport(TELLER).deposit(ERC20(DAI), 1000e18, 0);
        vm.stopPrank();
    }

    function test_varinderTestAddressCanDeposit() public {
        deal(USDC, VARINDER, 1e6);
        vm.startPrank(VARINDER);
        ERC20(USDC).approve(VAULT, 1e6);
        uint256 shares = TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDC), 1e6, 0);
        vm.stopPrank();
        assertEq(shares, 1e6, "1 USDC smoke test works from the whitelisted test address");
    }

    // ------------------------------------------------- helpers

    function _seedVault(uint256 amount) internal {
        deal(USDC, CICADA, amount);
        vm.startPrank(CICADA);
        ERC20(USDC).approve(VAULT, amount);
        TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDC), amount, 0);
        vm.stopPrank();
    }

    function _lendingInfo() internal view returns (uint256 rate, uint256 lastAccrual) {
        (rate, lastAccrual) = AccountantWithRateProviders(ACCOUNTANT).lendingInfo();
    }
}

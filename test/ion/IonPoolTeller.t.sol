// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { BoringVault } from "./../../src/base/BoringVault.sol";
import { EthPerWstEthRateProvider } from "./../../src/oracles/EthPerWstEthRateProvider.sol";
import { ETH_PER_STETH_CHAINLINK, WSTETH_ADDRESS } from "@ion-protocol/Constants.sol";
import { IonPoolSharedSetup } from "./IonPoolSharedSetup.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";

import { console2 } from "forge-std/console2.sol";

contract IonPoolTellerTest is IonPoolSharedSetup {
    using FixedPointMathLib for uint256;

    EthPerWstEthRateProvider ethPerWstEthRateProvider;

    function setUp() public override {
        super.setUp();

        WETH.approve(address(boringVault), type(uint256).max);
        WSTETH.approve(address(boringVault), type(uint256).max);
        EETH.approve(address(boringVault), type(uint256).max);
        USDC.approve(address(boringVault), type(uint256).max);
        WEETH.approve(address(boringVault), type(uint256).max);

        vm.startPrank(TELLER_OWNER);
        teller.addAsset(WETH);
        teller.addAsset(WSTETH);
        teller.addAsset(EETH);
        teller.addAsset(USDC);
        teller.addAsset(WEETH);
        teller.setDepositCap(type(uint256).max);
        vm.stopPrank();

        // Setup accountant

        ethPerWstEthRateProvider =
            new EthPerWstEthRateProvider(address(ETH_PER_STETH_CHAINLINK), address(WSTETH_ADDRESS), 1 days);
        bool isPeggedToBase = false;

        vm.prank(ACCOUNTANT_OWNER);
        accountant.setRateProviderData(
            ERC20(address(WSTETH_ADDRESS)), isPeggedToBase, address(ethPerWstEthRateProvider)
        );

        // Add rate provider data for other assets
        vm.startPrank(ACCOUNTANT_OWNER);

        // EETH - pegged to base (1:1 with WETH)
        accountant.setRateProviderData(
            EETH,
            true, // isPeggedToBase = true
            address(0) // No rate provider needed for pegged assets
        );

        // USDC - assuming pegged to base for testing (or provide actual rate provider)
        accountant.setRateProviderData(
            USDC,
            true, // isPeggedToBase = true (treating as 1:1 for test)
            address(0) // No rate provider needed
        );

        // WEETH - non-pegged, needs rate provider
        // You need to either deploy a WEETH rate provider or import existing one
        accountant.setRateProviderData(
            WEETH,
            false, // isPeggedToBase = false
            address(WEETH_RATE_PROVIDER) // Use the actual WEETH rate provider from IonPoolSharedSetup
        );

        vm.stopPrank();
    }

    function test_Deposit_BaseAsset() public {
        uint256 depositAmt = 100 ether;
        uint256 minimumMint = 100 ether;

        // base / deposit asset
        uint256 exchangeRate = accountant.getRateInQuoteSafe(WETH);

        uint256 shares = depositAmt.mulDivDown(1e18, exchangeRate);

        // mint amount = deposit amount * exchangeRate
        deal(address(WETH), address(this), depositAmt);
        teller.deposit(WETH, depositAmt, minimumMint);

        assertEq(exchangeRate, 1e18, "base asset exchange rate must be pegged");
        assertEq(boringVault.balanceOf(address(this)), shares, "shares minted");
        assertEq(WETH.balanceOf(address(this)), 0, "WSTETH transferred from user");
        assertEq(WETH.balanceOf(address(boringVault)), depositAmt, "WSTETH transferred to vault");
    }

    function test_Deposit_NewAsset() public {
        uint256 depositAmt = 100 ether;
        uint256 minimumMint = 100 ether;

        // Calculate expected shares using the NEW precise method
        uint256 assetRate = ethPerWstEthRateProvider.getRate(); // 1168351507043552686
        uint256 expectedShares = depositAmt.mulDivDown(assetRate, 1e18); // 116835150704355268600

        deal(address(WSTETH), address(this), depositAmt);
        teller.deposit(WSTETH, depositAmt, minimumMint);

        assertEq(boringVault.balanceOf(address(this)), expectedShares, "shares minted");
        assertEq(WSTETH.balanceOf(address(this)), 0, "WSTETH transferred from user");
        assertEq(WSTETH.balanceOf(address(boringVault)), depositAmt, "WSTETH transferred to vault");
    }

    function testPrecisionDifference() public {
        // Set a non-1.0 exchange rate to see precision loss
        vm.startPrank(ACCOUNTANT_OWNER);
        accountant.updateExchangeRate(1_000_001_234_567_890_000);
        accountant.unpause();
        vm.stopPrank();

        // Test USDC (6 decimals) - biggest precision difference
        uint256 usdcAmount = 1_000_000e6; // 1M USDC

        // Old method: Rate truncated to 6 decimals (1.000001)
        uint256 truncatedRate = accountant.getRateInQuoteSafe(USDC);
        console2.log("Truncated rate:", truncatedRate); // 1000001
        uint256 oldShares = usdcAmount.mulDivDown(1e18, truncatedRate);

        // New method: Full precision (1.000001234567890000)
        uint256 newShares = accountant.calculateSharesForAmount(USDC, usdcAmount);

        console2.log("Old shares (truncated):", oldShares);
        console2.log("New shares (precise):", newShares);

        // With higher precision rate, users get FEWER shares (correct behavior)
        // Old method gives TOO MANY shares due to truncation
        assertLt(newShares, oldShares, "New method should give fewer shares (correct amount)");

        // Calculate how many extra shares old method incorrectly gives
        uint256 extraShares = oldShares - newShares;
        console2.log("Extra shares from truncation error:", extraShares);
        assertGt(extraShares, 0, "Should have precision difference");
    }

    function testPrecisionImprovement() public {
        // Don't set exchange rate for first tests - keep at 1.0

        // Test 1: WETH (base asset, 18 decimals) at 1.0 rate
        uint256 wethAmount = 100e18;
        uint256 wethShares = accountant.calculateSharesForAmount(WETH, wethAmount);
        assertEq(wethShares, 100e18, "WETH should be 1:1 at rate 1.0");

        // Test 2: EETH (pegged to base, 18 decimals) at 1.0 rate
        uint256 eethAmount = 100e18;
        uint256 eethShares = accountant.calculateSharesForAmount(EETH, eethAmount);
        assertEq(eethShares, 100e18, "EETH pegged should be 1:1 at rate 1.0");

        // Test 3: WSTETH (non-pegged, 18 decimals, worth ~1.168 ETH)
        uint256 wstethAmount = 100e18;
        uint256 wstethRate = ethPerWstEthRateProvider.getRate(); // ~1.168e18
        uint256 expectedWstethShares = wstethAmount.mulDivDown(wstethRate, 1e18);
        uint256 wstethShares = accountant.calculateSharesForAmount(WSTETH, wstethAmount);
        assertEq(wstethShares, expectedWstethShares, "WSTETH should use rate provider");

        // NOW set exchange rate for USDC test
        vm.startPrank(ACCOUNTANT_OWNER);
        accountant.updateExchangeRate(1_000_001_234_567_890_000);
        accountant.unpause();
        vm.stopPrank();

        // Test 4: USDC precision improvement
        uint256 usdcAmount = 100e6;
        uint256 usdcShares = accountant.calculateSharesForAmount(USDC, usdcAmount);

        // Old way truncates rate
        uint256 oldRate = accountant.getRateInQuoteSafe(USDC); // 1000001
        uint256 oldShares = usdcAmount.mulDivDown(1e18, oldRate);

        // New method gives CORRECT (fewer) shares
        assertLt(usdcShares, oldShares, "New method prevents giving too many shares");

        // Test 5: Round-trip at 1.0 rate
        vm.startPrank(ACCOUNTANT_OWNER);
        accountant.updateExchangeRate(1e18); // Reset to 1.0
        accountant.unpause();
        vm.stopPrank();

        uint256 weethAmount = 50e18;
        uint256 weethSharesIn = accountant.calculateSharesForAmount(WEETH, weethAmount);
        uint256 weethAmountOut = accountant.calculateAmountForShares(WEETH, weethSharesIn);
        assertApproxEqAbs(weethAmountOut, weethAmount, 2, "Round trip should preserve value");
    }
}

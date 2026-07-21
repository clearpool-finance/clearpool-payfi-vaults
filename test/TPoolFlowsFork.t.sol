// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { AtomicSolverV3 } from "src/atomic-queue/AtomicSolverV3.sol";

/// Forks CURRENT mainnet (the LIVE, handed-over T-Pool) and exercises the flows the first
/// fork test skipped: full atomic withdrawal (updateAtomicRequest -> redeemSolve), NAV update
/// + deposit at non-par NAV, deposit-cap, and pause. deal() funds USDX (18-dec).
contract TPoolFlowsFork is Test {
    address constant VAULT = 0x6b860Ac820eA3b3eB2d41DA082D5b7A265C9511A;
    address constant ACCOUNTANT = 0x91783E0c9385046760a96c747852e9d197E070bb;
    address constant TELLER = 0x263791E325a83A04f8238967D112431C83638b57;
    address constant AQ = 0x91f3FD51505DEEE31725baa9395B9303F5e24e48;
    address constant AS = 0x0AA35955cBb796F3fFA3Fa8a0a9507aa15973E8A;
    address constant SAFE = 0xE0308d5681afe01A8Ad1cC0b8c937Db699E204aF; // owner + NAV + pauser
    address constant USDX = 0xf8750b54d86BE7aE9e32b4A0C826811198D63313;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // a non-supported asset

    address user = address(0xBEEF);
    address user2 = address(0xCAFE);

    // request redemption + solve for a set of users; returns each user's USDX received
    function _redeem(address[] memory users, uint256[] memory shares) internal {
        for (uint256 i; i < users.length; i++) {
            vm.startPrank(users[i]);
            ERC20(VAULT).approve(AQ, shares[i]);
            AtomicQueue(AQ).updateAtomicRequest(ERC20(VAULT), ERC20(USDX), uint64(block.timestamp + 2 days), uint96(shares[i]));
            vm.stopPrank();
        }
        deal(USDX, SAFE, 100_000_000e18);
        vm.prank(SAFE);
        ERC20(USDX).approve(AS, type(uint256).max);
        vm.prank(SAFE);
        AtomicSolverV3(AS).redeemSolve(
            AtomicQueue(AQ), ERC20(VAULT), ERC20(USDX), users, 0, type(uint256).max, TellerWithMultiAssetSupport(TELLER)
        );
    }

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        deal(USDX, who, amt);
        vm.startPrank(who);
        ERC20(USDX).approve(VAULT, amt);
        shares = TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDX), amt, 0);
        vm.stopPrank();
    }

    // THE key untested flow: user requests redemption via the queue, Safe(solver owner) solves it, user gets USDX back.
    function test_atomic_withdrawal_18dec() public {
        uint256 amt = 100_000e18;
        uint256 shares = _deposit(user, amt);
        assertEq(shares, amt, "1:1 deposit");

        // user lists shares for redemption to USDX
        vm.startPrank(user);
        ERC20(VAULT).approve(AQ, shares);
        AtomicQueue(AQ).updateAtomicRequest(ERC20(VAULT), ERC20(USDX), uint64(block.timestamp + 2 days), uint96(shares));
        vm.stopPrank();

        uint256 beforeBal = ERC20(USDX).balanceOf(user);
        uint256 supplyBefore = ERC20(VAULT).totalSupply();
        // OPERATIONAL PREREQ (runbook): the operator (Safe owns the solver) must approve the AtomicSolver for
        // the want asset + hold transient liquidity. In REDEEM the solver fronts USDX to the user, receives the
        // shares, then bulkWithdraws them against the vault — so the operator ends up ~whole and shares are burned.
        deal(USDX, SAFE, 200_000e18);
        uint256 opUsdxBefore = ERC20(USDX).balanceOf(SAFE);
        vm.prank(SAFE);
        ERC20(USDX).approve(AS, type(uint256).max);

        address[] memory users = new address[](1);
        users[0] = user;
        vm.prank(SAFE);
        AtomicSolverV3(AS).redeemSolve(
            AtomicQueue(AQ), ERC20(VAULT), ERC20(USDX), users, 0, type(uint256).max, TellerWithMultiAssetSupport(TELLER)
        );

        // 1) user redeemed 1:1 at NAV 1.0 — the 18-dec correctness check
        uint256 got = ERC20(USDX).balanceOf(user) - beforeBal;
        assertApproxEqAbs(got, amt, 1e12, "user redeemed ~100k USDX at NAV 1.0 (18-dec)");
        assertEq(ERC20(VAULT).balanceOf(user), 0, "user shares consumed");
        // 2) the redeemed shares are burned from supply (vault funded the exit)
        assertApproxEqAbs(supplyBefore - ERC20(VAULT).totalSupply(), shares, 1e12, "redeemed shares burned");
        // 3) operator is made ~whole (fronts USDX, recovers it by burning the shares) — net cost ~0
        uint256 opNet = opUsdxBefore - ERC20(USDX).balanceOf(SAFE);
        assertApproxEqAbs(opNet, 0, 1e12, "operator net ~0 (made whole via bulkWithdraw)");
    }

    // NAV bot (Safe holds role 4) raises NAV within the +0.3% bound, then a deposit mints fewer shares.
    function test_nav_update_and_deposit_at_new_nav() public {
        uint96 newRate = 1.002e18; // +0.2% (within the 10030/9970 = +/-0.3% bound)
        vm.prank(SAFE);
        AccountantWithRateProviders(ACCOUNTANT).updateExchangeRate(newRate);
        assertEq(AccountantWithRateProviders(ACCOUNTANT).getRateInQuote(ERC20(USDX)), newRate, "rate updated");

        uint256 amt = 100_000e18;
        uint256 shares = _deposit(user, amt);
        // shares = assets * 1e18 / rate  => 100k / 1.002 ~= 99,800
        assertApproxEqRel(shares, (amt * 1e18) / newRate, 1e15, "shares priced at new NAV");
        assertLt(shares, amt, "fewer shares at NAV>1");
    }

    // NAV move beyond the +/-0.3% bound must not silently apply (accountant pauses / rejects).
    function test_nav_out_of_bounds_is_rejected() public {
        vm.prank(SAFE);
        AccountantWithRateProviders(ACCOUNTANT).updateExchangeRate(1.05e18); // +5% >> 0.3% bound
        assertTrue(_isPaused(), "out-of-bounds NAV update pauses the accountant (does not apply)");
    }

    function test_deposit_cap_enforced() public {
        uint256 over = 51_000_000e18; // > 50M cap
        deal(USDX, user, over);
        vm.startPrank(user);
        ERC20(USDX).approve(VAULT, over);
        vm.expectRevert();
        TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDX), over, 0);
        vm.stopPrank();
    }

    function test_pause_blocks_deposit() public {
        vm.prank(SAFE); // Safe holds pauser role
        TellerWithMultiAssetSupport(TELLER).pause();
        deal(USDX, user, 1000e18);
        vm.startPrank(user);
        ERC20(USDX).approve(VAULT, 1000e18);
        vm.expectRevert();
        TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDX), 1000e18, 0);
        vm.stopPrank();
    }

    // a deposit of a non-supported asset (WETH) must revert — only USDX is added
    function test_unsupported_asset_deposit_reverts() public {
        deal(WETH, user, 10e18);
        vm.startPrank(user);
        ERC20(WETH).approve(VAULT, 10e18);
        vm.expectRevert();
        TellerWithMultiAssetSupport(TELLER).deposit(ERC20(WETH), 10e18, 0);
        vm.stopPrank();
    }

    // two users redeemed in a single solve — both paid correctly
    function test_multi_user_single_solve() public {
        uint256 a1 = 40_000e18;
        uint256 a2 = 25_000e18;
        uint256 s1 = _deposit(user, a1);
        uint256 s2 = _deposit(user2, a2);
        uint256 b1 = ERC20(USDX).balanceOf(user);
        uint256 b2 = ERC20(USDX).balanceOf(user2);
        address[] memory u = new address[](2);
        u[0] = user; u[1] = user2;
        uint256[] memory s = new uint256[](2);
        s[0] = s1; s[1] = s2;
        _redeem(u, s);
        assertApproxEqAbs(ERC20(USDX).balanceOf(user) - b1, a1, 1e12, "user1 redeemed 40k");
        assertApproxEqAbs(ERC20(USDX).balanceOf(user2) - b2, a2, 1e12, "user2 redeemed 25k");
    }

    // withdrawal at NAV != 1.0 pays out shares * rate (not 1:1)
    function test_withdrawal_at_nav_above_one() public {
        uint96 rate = 1.003e18; // +0.3% (max bound)
        vm.prank(SAFE);
        AccountantWithRateProviders(ACCOUNTANT).updateExchangeRate(rate);
        uint256 amt = 100_000e18;
        uint256 shares = _deposit(user, amt); // shares = 100k/1.003
        uint256 before = ERC20(USDX).balanceOf(user);
        address[] memory u = new address[](1); u[0] = user;
        uint256[] memory s = new uint256[](1); s[0] = shares;
        _redeem(u, s);
        // USDX out = shares * rate / 1e18  ~= back to ~100k (round trip at same NAV)
        uint256 got = ERC20(USDX).balanceOf(user) - before;
        assertApproxEqAbs(got, (shares * rate) / 1e18, 1e15, "redeemed at NAV 1.003 (shares*rate)");
    }

    // AccountantState = (address,uint128,uint128,uint96,uint16,uint16,uint64,bool,uint32,uint16); _isPaused is field 8
    function _isPaused() internal view returns (bool paused) {
        (bool ok, bytes memory d) = ACCOUNTANT.staticcall(abi.encodeWithSignature("accountantState()"));
        require(ok, "state");
        (,,,,,,, paused,,) = abi.decode(d, (address, uint128, uint128, uint96, uint16, uint16, uint64, bool, uint32, uint16));
    }
}

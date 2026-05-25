// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Authority, RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { AtomicSolverV5 } from "src/atomic-queue/AtomicSolverV5.sol";

/// @notice End-to-end fork test for the Blackopal LiquidStone II vault config
///         (eth-blackopal-ls2-layerzero.json). Deploys the full stack on a mainnet fork,
///         wires roles to mirror 06_DeployRolesAuthority + ConfigureAtomicRoles, and exercises
///         every operational flow: whitelist, deposit (USDC + USDT), NAV update, atomic
///         withdrawal request, redeem-solve, pause, and the bound/whitelist revert paths.
contract BlackOpalLS2E2ETest is Test {
    using SafeTransferLib for ERC20;

    // --- mainnet assets ---
    ERC20 constant USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 constant USDT = ERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    // --- config addresses (from eth-blackopal-ls2-layerzero.json) ---
    address constant NARA = 0xaB05c0DB9D26e96A9dcEDCAFCA23341316F6fe6F; // admin / NAV / pause / operator
    address constant BLACKOPAL = 0xe33Bda5ef29bDB93Ca9D841820f2042a22463220; // borrower / strategist

    // --- role ids (Constants.sol + ConfigureAtomicRoles) ---
    uint8 constant STRATEGIST_ROLE = 1;
    uint8 constant MANAGER_ROLE = 2;
    uint8 constant TELLER_ROLE = 3;
    uint8 constant UPDATE_EXCHANGE_RATE_ROLE = 4;
    uint8 constant SOLVER_ROLE = 5;
    uint8 constant PAUSER_ROLE = 6;
    uint8 constant OPERATOR_ROLE = 7;
    uint8 constant QUEUE_ROLE = 10;

    bytes4 constant SOLVE_SELECTOR = bytes4(keccak256("solve(address,address,address[],bytes,address)"));

    BoringVault vault;
    AccountantWithRateProviders accountant;
    TellerWithMultiAssetSupport teller;
    ManagerWithMerkleVerification manager;
    RolesAuthority authority;
    AtomicQueue queue;
    AtomicSolverV5 solver;

    address deployer = address(this);
    address alice = vm.addr(0xA11CE); // whitelisted depositor
    address mallory = vm.addr(0x4A110); // NOT whitelisted

    uint256 constant ONE_SHARE = 1e6; // 6-decimal vault
    uint256 constant START_RATE = 1e18; // 18-dec normalized

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // --- deploy core (params mirror the config) ---
        vault = new BoringVault(deployer, "Blackopal LiquidStone II", "naraOPAL_LS2", 6);
        accountant = new AccountantWithRateProviders(
            deployer,
            address(vault),
            NARA, // payout
            uint96(START_RATE),
            address(USDC), // base
            10_030, // upper +0.3%
            9970, // lower -0.3%
            3600, // delay
            0 // mgmt fee
        );
        teller = new TellerWithMultiAssetSupport(deployer, address(vault), address(accountant));
        manager = new ManagerWithMerkleVerification(deployer, address(vault), address(0));
        authority = new RolesAuthority(deployer, Authority(address(0)));
        queue = new AtomicQueue(address(accountant), deployer, authority);
        solver = new AtomicSolverV5(deployer, authority);

        // --- point everything at the authority ---
        vault.setAuthority(authority);
        accountant.setAuthority(authority);
        teller.setAuthority(authority);
        manager.setAuthority(authority);

        _wireRoles();

        // --- teller setup: assets + manual whitelist + cap ---
        teller.addAsset(USDC);
        teller.addAsset(USDT);
        accountant.setRateProviderData(USDT, true, address(0)); // USDT pegged to USDC
        teller.setShareLockPeriod(0);

        // MANUAL_WHITELIST mode (2)
        teller.setAccessControlMode(TellerWithMultiAssetSupport.AccessControlMode.MANUAL_WHITELIST);

        // solver is whitelisted as a CONTRACT (mirrors ConfigureAtomicRoles)
        address[] memory contracts = new address[](1);
        contracts[0] = address(solver);
        teller.updateContractWhitelist(contracts, true);

        // approve the queue on the solver (mirrors setQueueApproved)
        solver.setQueueApproved(address(queue), true);

        teller.setDepositCap(10_000_000 * ONE_SHARE);

        // alice is a manually-whitelisted depositor
        address[] memory users = new address[](1);
        users[0] = alice;
        teller.updateManualWhitelist(users, true);

        // fund alice
        deal(address(USDC), alice, 100_000e6);
        deal(address(USDT), alice, 100_000e6);
    }

    function _wireRoles() internal {
        // capability matrix (subset that the flows need, faithful to deploy scripts)
        authority.setRoleCapability(TELLER_ROLE, address(vault), BoringVault.enter.selector, true);
        authority.setRoleCapability(TELLER_ROLE, address(vault), BoringVault.exit.selector, true);
        authority.setRoleCapability(
            TELLER_ROLE, address(accountant), AccountantWithRateProviders.checkpoint.selector, true
        );

        // teller admin surface
        authority.setRoleCapability(OPERATOR_ROLE, address(teller), TellerWithMultiAssetSupport.addAsset.selector, true);
        authority.setRoleCapability(
            UPDATE_EXCHANGE_RATE_ROLE,
            address(accountant),
            AccountantWithRateProviders.updateExchangeRate.selector,
            true
        );
        authority.setRoleCapability(
            UPDATE_EXCHANGE_RATE_ROLE, address(teller), TellerWithMultiAssetSupport.updateManualWhitelist.selector, true
        );
        authority.setRoleCapability(PAUSER_ROLE, address(teller), TellerWithMultiAssetSupport.pause.selector, true);
        authority.setRoleCapability(PAUSER_ROLE, address(accountant), AccountantWithRateProviders.pause.selector, true);

        // solver flow
        authority.setRoleCapability(
            SOLVER_ROLE, address(teller), TellerWithMultiAssetSupport.bulkWithdraw.selector, true
        );
        // the AtomicSolver contract itself calls queue.solve — SOLVER_ROLE needs that cap
        authority.setRoleCapability(SOLVER_ROLE, address(queue), SOLVE_SELECTOR, true);
        authority.setRoleCapability(QUEUE_ROLE, address(solver), AtomicSolverV5.finishSolve.selector, true);
        authority.setRoleCapability(OPERATOR_ROLE, address(queue), SOLVE_SELECTOR, true);
        authority.setRoleCapability(OPERATOR_ROLE, address(solver), AtomicSolverV5.redeemSolve.selector, true);
        authority.setRoleCapability(STRATEGIST_ROLE, address(queue), SOLVE_SELECTOR, true);
        authority.setRoleCapability(STRATEGIST_ROLE, address(solver), AtomicSolverV5.redeemSolve.selector, true);

        // public deposit
        authority.setPublicCapability(address(teller), TellerWithMultiAssetSupport.deposit.selector, true);

        // user-role grants
        authority.setUserRole(address(teller), TELLER_ROLE, true);
        authority.setUserRole(address(queue), QUEUE_ROLE, true);
        authority.setUserRole(address(solver), SOLVER_ROLE, true);
        authority.setUserRole(NARA, UPDATE_EXCHANGE_RATE_ROLE, true);
        authority.setUserRole(NARA, PAUSER_ROLE, true);
        authority.setUserRole(NARA, OPERATOR_ROLE, true);
        authority.setUserRole(BLACKOPAL, STRATEGIST_ROLE, true);
        // deployer keeps admin via owner() for setup calls (addAsset/setRateProviderData/etc.)
        authority.setUserRole(deployer, OPERATOR_ROLE, true);
    }

    // ------------------------------------------------------------------
    // Deposit
    // ------------------------------------------------------------------

    function test_deposit_USDC() public {
        vm.startPrank(alice);
        USDC.safeApprove(address(vault), 10_000e6);
        uint256 shares = teller.deposit(USDC, 10_000e6, 0);
        vm.stopPrank();

        // 1:1 at start rate → 10,000 shares (6 dec)
        assertEq(shares, 10_000e6, "USDC deposit shares");
        assertEq(vault.balanceOf(alice), 10_000e6, "alice share balance");
        assertEq(USDC.balanceOf(address(vault)), 10_000e6, "vault USDC");
    }

    function test_deposit_USDT_pegged() public {
        vm.startPrank(alice);
        USDT.safeApprove(address(vault), 5000e6);
        uint256 shares = teller.deposit(USDT, 5000e6, 0);
        vm.stopPrank();

        assertEq(shares, 5000e6, "USDT deposit shares (pegged 1:1)");
        assertEq(USDT.balanceOf(address(vault)), 5000e6, "vault USDT");
    }

    function test_deposit_nonWhitelisted_reverts() public {
        deal(address(USDC), mallory, 1000e6);
        vm.startPrank(mallory);
        USDC.safeApprove(address(vault), 1000e6);
        vm.expectRevert(TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__NotWhitelisted.selector);
        teller.deposit(USDC, 1000e6, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // NAV update (exchange rate)
    // ------------------------------------------------------------------

    function test_updateNAV_revaluesShares() public {
        // alice deposits 10k USDC → 10k shares
        vm.startPrank(alice);
        USDC.safeApprove(address(vault), 10_000e6);
        teller.deposit(USDC, 10_000e6, 0);
        vm.stopPrank();

        skip(3601); // clear minimumUpdateDelay

        // Nara marks NAV up +0.2% (within ±0.3% bound)
        uint96 newRate = uint96((START_RATE * 10_020) / 10_000);
        vm.prank(NARA);
        accountant.updateExchangeRate(newRate);

        (,,, uint96 rate,,,,,,) = accountant.accountantState();
        assertEq(rate, newRate, "rate updated");

        // 10k shares now worth +0.2% more USDC
        uint256 rateNow = accountant.getRateSafe();
        assertEq(rateNow, newRate, "getRateSafe reflects NAV");
    }

    function test_updateNAV_outOfBounds_autoPauses() public {
        skip(3601);
        // +1% exceeds +0.3% upper bound → reject + auto-pause, rate NOT committed
        uint96 badRate = uint96((START_RATE * 10_100) / 10_000);
        vm.prank(NARA);
        accountant.updateExchangeRate(badRate);

        (,,, uint96 rate,,,, bool paused,,) = accountant.accountantState();
        assertEq(rate, uint96(START_RATE), "bad rate NOT committed");
        assertTrue(paused, "auto-paused on bound violation");
    }

    function test_updateNAV_downwardMark_allowed() public {
        skip(3601);
        // -0.2% (credit loss mark) is within the -0.3% lower bound
        uint96 downRate = uint96((START_RATE * 9980) / 10_000);
        vm.prank(NARA);
        accountant.updateExchangeRate(downRate);

        (,,, uint96 rate,,,, bool paused,,) = accountant.accountantState();
        assertEq(rate, downRate, "downward NAV mark committed");
        assertFalse(paused, "not paused for in-bounds downward mark");
    }

    // ------------------------------------------------------------------
    // Atomic withdrawal: request -> redeemSolve
    // ------------------------------------------------------------------

    function test_atomicWithdrawal_fullFlow() public {
        // 1. alice deposits 10k USDC
        vm.startPrank(alice);
        USDC.safeApprove(address(vault), 10_000e6);
        uint256 shares = teller.deposit(USDC, 10_000e6, 0);

        // 2. alice submits an atomic withdrawal request (sell shares for USDC)
        boringVaultApproveQueue(shares);
        queue.updateAtomicRequest(ERC20(address(vault)), USDC, uint64(block.timestamp + 1 days), uint96(shares));
        vm.stopPrank();

        uint256 aliceUsdcBefore = USDC.balanceOf(alice);

        // 3. Nara (operator) runs redeemSolve for alice
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(NARA);
        solver.redeemSolve(queue, ERC20(address(vault)), USDC, users, 0, type(uint256).max, teller);

        // 4. post-conditions
        assertEq(vault.balanceOf(alice), 0, "alice shares burned");
        uint256 received = USDC.balanceOf(alice) - aliceUsdcBefore;
        assertApproxEqAbs(received, 10_000e6, 1, "alice got ~10k USDC back");
        assertEq(USDC.balanceOf(address(solver)), 0, "no USDC stuck in solver");
        assertEq(vault.balanceOf(address(queue)), 0, "no shares stuck in queue");
    }

    function test_atomicWithdrawal_afterNAVUp_paysMore() public {
        // deposit
        vm.startPrank(alice);
        USDC.safeApprove(address(vault), 10_000e6);
        uint256 shares = teller.deposit(USDC, 10_000e6, 0);
        boringVaultApproveQueue(shares);
        queue.updateAtomicRequest(ERC20(address(vault)), USDC, uint64(block.timestamp + 1 days), uint96(shares));
        vm.stopPrank();

        // NAV +0.2%
        skip(3601);
        vm.prank(NARA);
        accountant.updateExchangeRate(uint96((START_RATE * 10_020) / 10_000));

        // fund the vault with the extra USDC needed to cover the +0.2% (borrower would normally repay)
        deal(address(USDC), address(vault), 11_000e6);

        uint256 before = USDC.balanceOf(alice);
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(NARA);
        solver.redeemSolve(queue, ERC20(address(vault)), USDC, users, 0, type(uint256).max, teller);

        uint256 received = USDC.balanceOf(alice) - before;
        assertApproxEqAbs(received, (10_000e6 * 10_020) / 10_000, 2, "alice got NAV-uplifted USDC");
    }

    // ------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------

    function test_pause_blocksDeposit() public {
        vm.prank(NARA);
        teller.pause();

        vm.startPrank(alice);
        USDC.safeApprove(address(vault), 1000e6);
        vm.expectRevert(TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__Paused.selector);
        teller.deposit(USDC, 1000e6, 0);
        vm.stopPrank();
    }

    function test_accountantPause_blocksSolve() public {
        vm.startPrank(alice);
        USDC.safeApprove(address(vault), 10_000e6);
        uint256 shares = teller.deposit(USDC, 10_000e6, 0);
        boringVaultApproveQueue(shares);
        queue.updateAtomicRequest(ERC20(address(vault)), USDC, uint64(block.timestamp + 1 days), uint96(shares));
        vm.stopPrank();

        // accountant paused → getRateSafe reverts → solve reverts
        vm.prank(NARA);
        accountant.pause();

        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(NARA);
        vm.expectRevert(AccountantWithRateProviders.AccountantWithRateProviders__Paused.selector);
        solver.redeemSolve(queue, ERC20(address(vault)), USDC, users, 0, type(uint256).max, teller);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function boringVaultApproveQueue(uint256 shares) internal {
        ERC20(address(vault)).safeApprove(address(queue), shares);
    }
}

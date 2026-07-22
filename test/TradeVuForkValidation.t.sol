// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { Test, stdError } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { TradeVuVaultDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/TradeVuVaultDecoderAndSanitizer.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { AtomicSolverV3 } from "src/atomic-queue/AtomicSolverV3.sol";

/**
 * @notice Fork validation for the Clearpool × TradeVu vault (cpTV, USDC, Ethereum).
 *
 *         Runs against a local anvil mainnet fork onto which `deployAll.s.sol` has already been broadcast
 *         with `deployment-config/eth-tradevu-clearpool.json`, so the addresses below are the real CREATE3
 *         addresses the mainnet deploy will produce.
 *
 *         Covers the two strategy paths (borrow, fee claim), the access-control posture, and the NAV bounds.
 */
contract TradeVuForkValidation is Test {
    // --- deployed system (CREATE3, deployer-independent) ---
    address constant VAULT = 0xaCF907a9183544aa5E0C4232c6730C2fd811409a;
    address constant MANAGER = 0x8D90A520264b9493BdfA13BB50A2aFeC1433F6c9;
    address constant ACCOUNTANT = 0x015745aa47b4891609754e7b1Fe65c8A3CB510eE;
    address constant TELLER = 0xD7EDfd54a24a207D40502da86ccbabEaE344D2Cd;
    address constant ROLES_AUTHORITY = 0xFA7938Fa9D3AE8E420668f70A954E2B7F8FEd833;
    address constant ATOMIC_QUEUE = 0x7985a270905f13c250B999a90D61E6704b74404F;
    address constant ATOMIC_SOLVER = 0xbD1F0c761Bca4431FF18c46619B2CE437E28bC95;

    // --- principals ---
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant TRADEVU = 0xEFe513B1539EaBFAD0bC077e12eb991926a62d0b; // borrower / strategist
    address constant SAFE = 0xE0308d5681afe01A8Ad1cC0b8c937Db699E204aF; // Clearpool admin Safe
    address constant CICADA = 0xf9B0445770341D88a77d384c5bEF582A27534865; // whitelisted LP
    address constant CICADA_2 = 0x5898e09a4ac5798a93ee08356318299e00a7A837; // whitelisted LP (2nd Cicada address)
    address constant DEV = 0x03014C3cDaDD8a5A1D8EBa50e35212a53Ba3A504; // deployer (pre-handover owner)

    bytes4 constant TRANSFER_SEL = 0xa9059cbb; // transfer(address,uint256)
    bytes4 constant APPROVE_SEL = 0x095ea7b3; // approve(address,uint256)
    bytes4 constant CLAIM_FEES_SEL = 0x15a0ea6a; // claimFees(address)

    TradeVuVaultDecoderAndSanitizer decoder;
    bytes32 borrowLeaf;
    bytes32 approveLeaf;
    bytes32 claimLeaf;
    bytes32 root;
    bytes32[][] proofs; // populated per-call

    address attacker = address(0xBAD);

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546");

        decoder = new TradeVuVaultDecoderAndSanitizer(VAULT);

        // The 3-leaf tree. Leaf = keccak(decoder ‖ target ‖ valueNonZero ‖ selector ‖ packedArgumentAddresses).
        borrowLeaf = keccak256(abi.encodePacked(address(decoder), USDC, false, TRANSFER_SEL, abi.encodePacked(TRADEVU)));
        approveLeaf =
            keccak256(abi.encodePacked(address(decoder), USDC, false, APPROVE_SEL, abi.encodePacked(ACCOUNTANT)));
        claimLeaf =
            keccak256(abi.encodePacked(address(decoder), ACCOUNTANT, false, CLAIM_FEES_SEL, abi.encodePacked(USDC)));

        root = _root3(borrowLeaf, approveLeaf, claimLeaf);

        // Same root for both strategists (borrower + Clearpool Safe), as specified.
        vm.startPrank(DEV);
        ManagerWithMerkleVerification(MANAGER).setManageRoot(TRADEVU, root);
        ManagerWithMerkleVerification(MANAGER).setManageRoot(SAFE, root);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- deposits

    function test_whitelistedDepositMintsAtPar() public {
        uint256 amount = 1_000_000e6; // 1M USDC
        deal(USDC, CICADA, amount);

        vm.startPrank(CICADA);
        ERC20(USDC).approve(VAULT, amount);
        uint256 shares = TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDC), amount, 0);
        vm.stopPrank();

        assertEq(shares, amount, "NAV 1.0 -> 1 USDC in = 1 cpTV out (both 6-dec)");
        assertEq(BoringVault(payable(VAULT)).balanceOf(CICADA), amount, "LP holds cpTV");
        assertEq(ERC20(USDC).balanceOf(VAULT), amount, "vault holds the USDC");
    }

    function test_nonWhitelistedDepositReverts() public {
        uint256 amount = 1000e6;
        deal(USDC, attacker, amount);

        vm.startPrank(attacker);
        ERC20(USDC).approve(VAULT, amount);
        vm.expectRevert(TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__NotWhitelisted.selector);
        TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDC), amount, 0);
        vm.stopPrank();
    }

    function test_depositAboveCapReverts() public {
        uint256 amount = 5_000_001e6; // cap is 5M
        deal(USDC, CICADA, amount);

        vm.startPrank(CICADA);
        ERC20(USDC).approve(VAULT, amount);
        vm.expectRevert();
        TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDC), amount, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- borrow / repay

    function test_borrowerCanDrawToItselfOnly() public {
        _seedVault(1_000_000e6);
        uint256 draw = 400_000e6;

        // allowed: USDC -> TradeVu. Measured as a delta: the borrower EOA already holds USDC on mainnet.
        uint256 borrowerBefore = ERC20(USDC).balanceOf(TRADEVU);
        _manage(TRADEVU, borrowLeaf, USDC, abi.encodeWithSelector(TRANSFER_SEL, TRADEVU, draw));
        assertEq(ERC20(USDC).balanceOf(TRADEVU) - borrowerBefore, draw, "borrower received the draw");
        assertEq(ERC20(USDC).balanceOf(VAULT), 600_000e6, "vault reduced by the draw");

        // denied: USDC -> anyone else (leaf mismatch)
        vm.expectRevert();
        _manage(TRADEVU, borrowLeaf, USDC, abi.encodeWithSelector(TRANSFER_SEL, attacker, draw));
    }

    function test_repayIsAPlainTransferNeedingNoRole() public {
        _seedVault(1_000_000e6);
        _manage(TRADEVU, borrowLeaf, USDC, abi.encodeWithSelector(TRANSFER_SEL, TRADEVU, 400_000e6));

        uint256 repay = 410_000e6; // principal + interest
        deal(USDC, TRADEVU, repay);
        vm.prank(TRADEVU);
        ERC20(USDC).transfer(VAULT, repay);

        assertEq(ERC20(USDC).balanceOf(VAULT), 1_010_000e6, "repayment lands in the vault, no role involved");
    }

    function test_nonStrategistCannotManage() public {
        _seedVault(1_000_000e6);
        vm.expectRevert();
        _manage(attacker, borrowLeaf, USDC, abi.encodeWithSelector(TRANSFER_SEL, attacker, 1e6));
    }

    // ---------------------------------------------------------------- fee claim (the new path)

    function test_safeCanClaimManagementFeesToPayoutAddress() public {
        _seedVault(1_000_000e6);

        // accrue a year of the 0.5% management fee
        vm.warp(block.timestamp + 365 days);
        uint256 owed = AccountantWithRateProviders(ACCOUNTANT).previewFeesOwed();
        assertApproxEqRel(owed, 5000e6, 0.01e18, "0.5% of 1M for one year ~= 5k USDC");

        uint256 payoutBefore = ERC20(USDC).balanceOf(SAFE);

        // leaf 2: vault approves the accountant; leaf 3: vault calls claimFees(USDC)
        _manage(SAFE, approveLeaf, USDC, abi.encodeWithSelector(APPROVE_SEL, ACCOUNTANT, type(uint256).max));
        _manage(SAFE, claimLeaf, ACCOUNTANT, abi.encodeWithSelector(CLAIM_FEES_SEL, USDC));

        uint256 received = ERC20(USDC).balanceOf(SAFE) - payoutBefore;
        assertApproxEqRel(received, 5000e6, 0.01e18, "fees landed at the payout address");
        assertEq(AccountantWithRateProviders(ACCOUNTANT).previewFeesOwed(), 0, "fees owed zeroed after claim");
    }

    /**
     * @notice The PRODUCTION fee-claim path, as used on the live Ola vaults.
     *
     *         `BoringVault.manage` is `requiresAuth`, and solmate's Auth passes for `msg.sender == owner`,
     *         so the owner claims fees with two direct `manage` calls — no Manager, no merkle root, no
     *         decoder. Confirmed against Plume tx 0x981b3871… : the Ola admin Safe called
     *         `vault.manage(asset, approve(accountant, max), 0)` (selector 0xf6e715d0) directly.
     *
     *         Post-handover the owner is the Clearpool Safe; here it is still the deployer.
     */
    function test_ownerCanClaimFeesDirectlyWithoutAnyRoot() public {
        _seedVault(1_000_000e6);
        vm.warp(block.timestamp + 365 days);

        uint256 payoutBefore = ERC20(USDC).balanceOf(SAFE);
        address owner = BoringVault(payable(VAULT)).owner();

        vm.startPrank(owner);
        BoringVault(payable(VAULT)).manage(
            USDC, abi.encodeWithSelector(APPROVE_SEL, ACCOUNTANT, type(uint256).max), 0
        );
        BoringVault(payable(VAULT)).manage(ACCOUNTANT, abi.encodeWithSelector(CLAIM_FEES_SEL, USDC), 0);
        vm.stopPrank();

        uint256 received = ERC20(USDC).balanceOf(SAFE) - payoutBefore;
        assertApproxEqRel(received, 5000e6, 0.01e18, "owner-direct claim pays out the same fees");
    }

    function test_nonOwnerCannotManageDirectly() public {
        _seedVault(1_000_000e6);
        vm.prank(attacker);
        vm.expectRevert();
        BoringVault(payable(VAULT)).manage(USDC, abi.encodeWithSelector(TRANSFER_SEL, attacker, 1e6), 0);

        // the borrower holds STRATEGIST_ROLE, which does NOT grant direct vault.manage
        vm.prank(TRADEVU);
        vm.expectRevert();
        BoringVault(payable(VAULT)).manage(USDC, abi.encodeWithSelector(TRANSFER_SEL, TRADEVU, 1e6), 0);
    }

    function test_bothCicadaAddressesAreWhitelisted() public view {
        assertTrue(
            TellerWithMultiAssetSupport(TELLER).manualWhitelist(CICADA), "Cicada LP 1 (0xf9B04457) whitelisted"
        );
        assertTrue(
            TellerWithMultiAssetSupport(TELLER).manualWhitelist(CICADA_2), "Cicada LP 2 (0x5898e09a) whitelisted"
        );
        assertFalse(TellerWithMultiAssetSupport(TELLER).manualWhitelist(TRADEVU), "borrower is not an LP");
    }

    function test_feeClaimCannotBeRedirected() public {
        _seedVault(1_000_000e6);
        vm.warp(block.timestamp + 365 days);

        // approving anyone other than the accountant is not in the tree
        vm.expectRevert();
        _manage(SAFE, approveLeaf, USDC, abi.encodeWithSelector(APPROVE_SEL, attacker, type(uint256).max));

        // and the vault cannot be made to transfer USDC to a non-TradeVu address
        vm.expectRevert();
        _manage(SAFE, borrowLeaf, USDC, abi.encodeWithSelector(TRANSFER_SEL, attacker, 1e6));
    }

    // ---------------------------------------------------------------- NAV bounds

    function test_navUpdateWithinUpperBoundApplies() public {
        _seedVault(1_000_000e6);
        vm.warp(block.timestamp + 3601); // clear minimumUpdateDelay

        uint96 newRate = 1.0009e18; // +0.09%, inside the +0.10% bound
        vm.prank(SAFE);
        AccountantWithRateProviders(ACCOUNTANT).updateExchangeRate(newRate);

        assertEq(AccountantWithRateProviders(ACCOUNTANT).getRate(), newRate, "NAV applied");
        (,,,,,,, bool paused,,) = AccountantWithRateProviders(ACCOUNTANT).accountantState();
        assertFalse(paused, "stayed unpaused");
    }

    function test_navUpdateAboveUpperBoundPauses() public {
        _seedVault(1_000_000e6);
        vm.warp(block.timestamp + 3601);

        vm.prank(SAFE);
        AccountantWithRateProviders(ACCOUNTANT).updateExchangeRate(1.02e18); // +2%, outside +0.10%

        (,,,,,,, bool paused,,) = AccountantWithRateProviders(ACCOUNTANT).accountantState();
        assertTrue(paused, "out-of-bounds NAV pauses the accountant");
    }

    function test_navMarkDownPauses() public {
        _seedVault(1_000_000e6);
        vm.warp(block.timestamp + 3601);

        vm.prank(SAFE);
        AccountantWithRateProviders(ACCOUNTANT).updateExchangeRate(0.99e18); // any decrease: lower bound is 10000

        (,,,,,,, bool paused,,) = AccountantWithRateProviders(ACCOUNTANT).accountantState();
        assertTrue(paused, "mark-down pauses -> deliberate circuit breaker");
    }

    function test_borrowerCannotTouchNavOrPause() public {
        vm.warp(block.timestamp + 3601);
        vm.prank(TRADEVU);
        vm.expectRevert();
        AccountantWithRateProviders(ACCOUNTANT).updateExchangeRate(1.0005e18);

        vm.prank(TRADEVU);
        vm.expectRevert();
        AccountantWithRateProviders(ACCOUNTANT).pause();
    }

    // ---------------------------------------------------------------- LP exit (atomic withdrawal)

    /**
     * @notice The LP exit path: LP files a request on the AtomicQueue, Clearpool solves it.
     * @dev    RUNBOOK: AtomicSolverV3 has no in-context auto-approve (that is a V5 feature), so the
     *         operator must (a) approve the solver for USDC and (b) hold transient USDC before calling
     *         `redeemSolve`. The vault then funds the exit via bulkWithdraw, making the operator ~whole.
     */
    function test_lpCanExitViaAtomicQueueSolvedByOperator() public {
        uint256 deposit = 100_000e6;
        _seedVault(deposit);

        // LP files the withdrawal request
        vm.startPrank(CICADA);
        BoringVault(payable(VAULT)).approve(ATOMIC_QUEUE, deposit);
        AtomicQueue(ATOMIC_QUEUE).updateAtomicRequest(
            ERC20(VAULT), ERC20(USDC), uint64(block.timestamp + 7 days), uint96(deposit)
        );
        vm.stopPrank();

        // operator (solver owner; the Clearpool Safe post-handover) funds + approves, then solves
        address operator = AtomicSolverV3(ATOMIC_SOLVER).owner();
        deal(USDC, operator, deposit);
        address[] memory users = new address[](1);
        users[0] = CICADA;

        uint256 lpUsdcBefore = ERC20(USDC).balanceOf(CICADA);
        uint256 opUsdcBefore = ERC20(USDC).balanceOf(operator);

        vm.startPrank(operator);
        ERC20(USDC).approve(ATOMIC_SOLVER, type(uint256).max);
        AtomicSolverV3(ATOMIC_SOLVER).redeemSolve(
            AtomicQueue(ATOMIC_QUEUE),
            ERC20(VAULT),
            ERC20(USDC),
            users,
            0,
            type(uint256).max,
            TellerWithMultiAssetSupport(TELLER)
        );
        vm.stopPrank();

        assertEq(ERC20(USDC).balanceOf(CICADA) - lpUsdcBefore, deposit, "LP redeemed 1:1 at NAV 1.0");
        assertEq(BoringVault(payable(VAULT)).balanceOf(CICADA), 0, "LP shares burned");
        assertApproxEqAbs(ERC20(USDC).balanceOf(operator), opUsdcBefore, 1, "operator net ~0 (vault funded the exit)");
    }

    function test_randomAddressCannotSolve() public {
        _seedVault(10_000e6);
        vm.startPrank(CICADA);
        BoringVault(payable(VAULT)).approve(ATOMIC_QUEUE, 10_000e6);
        AtomicQueue(ATOMIC_QUEUE).updateAtomicRequest(
            ERC20(VAULT), ERC20(USDC), uint64(block.timestamp + 7 days), uint96(10_000e6)
        );
        vm.stopPrank();

        address[] memory users = new address[](1);
        users[0] = CICADA;

        deal(USDC, attacker, 10_000e6);
        vm.startPrank(attacker);
        ERC20(USDC).approve(ATOMIC_SOLVER, type(uint256).max);
        vm.expectRevert(); // redeemSolve is role-gated, not public
        AtomicSolverV3(ATOMIC_SOLVER).redeemSolve(
            AtomicQueue(ATOMIC_QUEUE),
            ERC20(VAULT),
            ERC20(USDC),
            users,
            0,
            type(uint256).max,
            TellerWithMultiAssetSupport(TELLER)
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _seedVault(uint256 amount) internal {
        deal(USDC, CICADA, amount);
        vm.startPrank(CICADA);
        ERC20(USDC).approve(VAULT, amount);
        TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDC), amount, 0);
        vm.stopPrank();
    }

    /// @dev Executes a single leaf through the Manager, supplying that leaf's proof against the 3-leaf tree.
    function _manage(address caller, bytes32 leaf, address target, bytes memory data) internal {
        bytes32[][] memory p = new bytes32[][](1);
        p[0] = _proofFor(leaf);
        address[] memory decoders = new address[](1);
        decoders[0] = address(decoder);
        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes[] memory datas = new bytes[](1);
        datas[0] = data;
        uint256[] memory values = new uint256[](1);

        vm.prank(caller);
        ManagerWithMerkleVerification(MANAGER).manageVaultWithMerkleVerification(p, decoders, targets, datas, values);
    }

    /// @dev 3-leaf tree, padded to 4 by duplicating the last leaf. Layout: [borrow, approve] [claim, claim].
    function _root3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32) {
        return _hashPair(_hashPair(a, b), _hashPair(c, c));
    }

    function _proofFor(bytes32 leaf) internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        if (leaf == borrowLeaf) {
            proof[0] = approveLeaf;
            proof[1] = _hashPair(claimLeaf, claimLeaf);
        } else if (leaf == approveLeaf) {
            proof[0] = borrowLeaf;
            proof[1] = _hashPair(claimLeaf, claimLeaf);
        } else {
            proof[0] = claimLeaf;
            proof[1] = _hashPair(borrowLeaf, approveLeaf);
        }
    }

    function _hashPair(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }
}

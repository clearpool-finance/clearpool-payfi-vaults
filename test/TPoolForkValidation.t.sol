// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { TPoolBorrowDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/TPoolBorrowDecoderAndSanitizer.sol";

/// Validates the LIVE fork deploy (run against `anvil --fork-url mainnet` where deployAll already ran).
/// Funds USDX via `deal` and exercises: 18-dec deposit @ NAV 1.0 (1:1), and the 1-leaf manage-root
/// borrow — strategist can push USDX to the HT borrower ONLY, any other recipient reverts.
contract TPoolForkValidation is Test {
    // deployed on the anvil fork by deployAll (eth-tpool-clearpool-ht.json)
    address constant VAULT = 0x6b860Ac820eA3b3eB2d41DA082D5b7A265C9511A;
    address constant ACCOUNTANT = 0x91783E0c9385046760a96c747852e9d197E070bb;
    address constant TELLER = 0x263791E325a83A04f8238967D112431C83638b57;
    address constant MANAGER = 0x9150bBD82b35Dbf88940cbEc810F92af5965aD9d;
    address constant ADMIN = 0x03014C3cDaDD8a5A1D8EBa50e35212a53Ba3A504; // owner + NAV bot at launch
    address constant HT = 0x0e16E73Bc695547c6B4eb7FdCC49A63006053e47; // strategist / borrower
    address constant USDX = 0xf8750b54d86BE7aE9e32b4A0C826811198D63313;

    address user = address(0xBEEF);
    address attacker = address(0xBAD);

    function setUp() public {
        vm.createSelectFork("http://localhost:8545");
    }

    function test_deposit_18dec_par() public {
        uint256 amt = 250_000e18; // 250k USDX (18-dec)
        deal(USDX, user, amt);

        vm.startPrank(user);
        ERC20(USDX).approve(VAULT, amt);
        uint256 shares = TellerWithMultiAssetSupport(TELLER).deposit(ERC20(USDX), amt, 0);
        vm.stopPrank();

        assertEq(shares, amt, "NAV 1.0: 1 USDX -> 1 tUSDX (18-dec)");
        assertEq(ERC20(VAULT).balanceOf(user), amt, "user tUSDX balance");
        assertEq(ERC20(USDX).balanceOf(VAULT), amt, "vault holds the USDX");
        assertEq(AccountantWithRateProviders(ACCOUNTANT).getRateInQuote(ERC20(USDX)), 1e18, "rate 1:1");
    }

    function test_manageRoot_borrow_HT_only() public {
        // seed the vault with USDX (as if deposits happened)
        uint256 pool = 1_000_000e18;
        deal(USDX, VAULT, pool);

        // decoder identical in logic to the fork-validated BlackOpal decoder; pins transfer recipient
        TPoolBorrowDecoderAndSanitizer decoder = new TPoolBorrowDecoderAndSanitizer(VAULT);

        // 1-leaf tree: keccak(decoder, target=USDX, valueNonZero=false, transfer.selector, packed(HT))
        bytes4 sel = ERC20.transfer.selector;
        bytes32 leaf = keccak256(abi.encodePacked(address(decoder), USDX, false, sel, abi.encodePacked(HT)));
        bytes32 root = leaf; // single-leaf tree: root == leaf, proof == []

        vm.prank(ADMIN);
        ManagerWithMerkleVerification(MANAGER).setManageRoot(HT, root);

        // strategist (HT) draws 400k USDX to itself -> allowed
        uint256 draw = 400_000e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        address[] memory decoders = new address[](1);
        decoders[0] = address(decoder);
        address[] memory targets = new address[](1);
        targets[0] = USDX;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(sel, HT, draw);
        uint256[] memory values = new uint256[](1);

        vm.prank(HT);
        ManagerWithMerkleVerification(MANAGER).manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
        assertEq(ERC20(USDX).balanceOf(HT), draw, "HT borrower received the draw");
        assertEq(ERC20(USDX).balanceOf(VAULT), pool - draw, "vault reduced by draw");

        // strategist tries to send to a NON-HT address -> leaf mismatch -> revert
        bytes[] memory badData = new bytes[](1);
        badData[0] = abi.encodeWithSelector(sel, attacker, draw);
        vm.prank(HT);
        vm.expectRevert();
        ManagerWithMerkleVerification(MANAGER).manageVaultWithMerkleVerification(proofs, decoders, targets, badData, values);
    }

    function test_repay_is_plain_transfer_no_leaf() public {
        // repayment is a direct transfer TO the vault; needs no manage leaf
        deal(USDX, HT, 100_000e18);
        vm.prank(HT);
        ERC20(USDX).transfer(VAULT, 100_000e18);
        assertEq(ERC20(USDX).balanceOf(VAULT), 100_000e18, "vault received repayment");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { BoringVault } from "src/base/BoringVault.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { AtomicSolverV5, AtomicQueue } from "src/atomic-queue/AtomicSolverV5.sol";
import { MainnetAddresses } from "test/resources/MainnetAddresses.sol";

import "@forge-std/Script.sol";

contract DeployPortProofOfConceptScript is Script, MainnetAddresses {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // Audit D-1: shift local-only roles above Constants.sol's reserved 1–7 range.
    uint8 public constant MANAGER_ROLE = 2; // matches Constants.MANAGER_ROLE
    uint8 public constant ADMIN_ROLE = 12;
    uint8 public constant MINTER_ROLE = 13;
    uint8 public constant BURNER_ROLE = 14;
    uint8 public constant SOLVER_ROLE = 15;
    uint8 public constant QUEUE_ROLE = 10;
    uint8 public constant CAN_SOLVE_ROLE = 11;

    uint256 public ONE_SHARE;
    uint256 public privateKey;

    BoringVault public boringVault;
    TellerWithMultiAssetSupport public teller;
    AccountantWithRateProviders public accountant;
    RolesAuthority public rolesAuthority;
    AtomicQueue public atomicQueue;
    AtomicSolverV5 public atomicSolverV3;

    ERC20 public USDX = ERC20(0xe29f6fbc4CB3F01e2D38F0Aab7D8861285EE9C36);

    address public owner = 0xe43420E1f83530AAf8ad94e6904FDbdc3556Da2B;
    address public hexTrust = 0xe43420E1f83530AAf8ad94e6904FDbdc3556Da2B;
    address public solver = 0xe43420E1f83530AAf8ad94e6904FDbdc3556Da2B;

    function run() public {
        vm.startBroadcast(owner);

        /// @dev deploy
        /// Assign Hex Trust Manager role below

        boringVault = new BoringVault(owner, "Port Boring Vault", "PBV", 18);
        ONE_SHARE = 10 ** boringVault.decimals();

        accountant = new AccountantWithRateProviders(
            owner, address(boringVault), owner, 1e18, address(USDX), 1.001e4, 0.999e4, 1, 0
        );

        teller = new TellerWithMultiAssetSupport(owner, address(boringVault), address(accountant));

        rolesAuthority = new RolesAuthority(owner, Authority(address(0)));

        atomicQueue = new AtomicQueue(address(accountant), owner, rolesAuthority);

        atomicSolverV3 = new AtomicSolverV5(owner, rolesAuthority);
        atomicSolverV3.setQueueApproved(address(atomicQueue), true);

        /// @dev authority set up

        boringVault.setAuthority(rolesAuthority);
        accountant.setAuthority(rolesAuthority);
        teller.setAuthority(rolesAuthority);

        rolesAuthority.setRoleCapability(MINTER_ROLE, address(boringVault), BoringVault.enter.selector, true);
        rolesAuthority.setRoleCapability(BURNER_ROLE, address(boringVault), BoringVault.exit.selector, true);
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE,
            address(boringVault),
            bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))),
            true
        );
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.addAsset.selector, true
        );
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.removeAsset.selector, true
        );
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.bulkDeposit.selector, true
        );
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.bulkWithdraw.selector, true
        );
        rolesAuthority.setRoleCapability(
            ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.refundDeposit.selector, true
        );
        rolesAuthority.setRoleCapability(
            SOLVER_ROLE, address(teller), TellerWithMultiAssetSupport.bulkWithdraw.selector, true
        );
        rolesAuthority.setRoleCapability(
            CAN_SOLVE_ROLE, address(atomicSolverV3), AtomicSolverV5.p2pSolve.selector, true
        );
        rolesAuthority.setRoleCapability(QUEUE_ROLE, address(atomicSolverV3), AtomicSolverV5.finishSolve.selector, true);
        rolesAuthority.setRoleCapability(
            CAN_SOLVE_ROLE, address(atomicSolverV3), AtomicSolverV5.redeemSolve.selector, true
        );
        rolesAuthority.setRoleCapability(
            MINTER_ROLE, address(accountant), AccountantWithRateProviders.checkpoint.selector, true
        );
        rolesAuthority.setRoleCapability(
            SOLVER_ROLE, address(atomicQueue), bytes4(keccak256("solve(address,address,address[],bytes,address)")), true
        );

        rolesAuthority.setPublicCapability(address(teller), TellerWithMultiAssetSupport.deposit.selector, true);
        rolesAuthority.setPublicCapability(
            address(teller), TellerWithMultiAssetSupport.depositWithPermit.selector, true
        );

        rolesAuthority.setUserRole(address(this), ADMIN_ROLE, true);
        rolesAuthority.setUserRole(hexTrust, MANAGER_ROLE, true);
        rolesAuthority.setUserRole(address(teller), MINTER_ROLE, true);
        rolesAuthority.setUserRole(address(teller), BURNER_ROLE, true);
        rolesAuthority.setUserRole(address(atomicSolverV3), SOLVER_ROLE, true);
        rolesAuthority.setUserRole(address(atomicQueue), QUEUE_ROLE, true);
        rolesAuthority.setUserRole(solver, CAN_SOLVE_ROLE, true);

        /// @dev add assets

        teller.addAsset(USDX);

        /// @dev set rate provider

        accountant.setRateProviderData(USDX, true, address(0));

        vm.stopBroadcast();
    }
}

contract RemoveAssetsFromVaultScript is Script {
    address public owner = 0xe43420E1f83530AAf8ad94e6904FDbdc3556Da2B;
    ERC20 public USDX = ERC20(0xe29f6fbc4CB3F01e2D38F0Aab7D8861285EE9C36);

    function run() external {
        vm.startBroadcast(owner);

        /// @dev move assets in and out arbitrarily if caller has authority
        address target = address(USDX);
        bytes memory data = abi.encodeCall(ERC20.transfer, (owner, 8e18));
        uint256 value;
        BoringVault(payable(0xEcfd527e404A0611bd21cd84e50fA62dD4Ba0E97)).manage(target, data, value);

        vm.stopBroadcast();
    }
}

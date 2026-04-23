pragma solidity 0.8.22;

import { Script } from "@forge-std/Script.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { AtomicSolverV5 } from "src/atomic-queue/AtomicSolverV5.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import {
    MultiChainLayerZeroTellerWithMultiAssetSupport
} from "src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol";
import { CrossChainTellerBase } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { MainnetAddresses } from "test/resources/MainnetAddresses.sol";

contract DeployPortLayerZeroScript is Script, MainnetAddresses {
    // Roles
    // Audit D-1: the previous MINTER_ROLE=7 collided with Constants.sol's OPERATOR_ROLE=7.
    // If this test scaffold ever shared a RolesAuthority with production wiring, granting
    // MINTER_ROLE to the teller would also grant OPERATOR_ROLE — reaching setUserRole on
    // the authority itself. Shift all local-only roles above Constants.sol's reserved
    // range (1–7) to remove the collision class.
    uint8 public constant MANAGER_ROLE = 2; // matches Constants.MANAGER_ROLE
    uint8 public constant ADMIN_ROLE = 12;
    uint8 public constant MINTER_ROLE = 13;
    uint8 public constant BURNER_ROLE = 14;
    uint8 public constant SOLVER_ROLE = 15;
    uint8 public constant QUEUE_ROLE = 10;
    uint8 public constant CAN_SOLVE_ROLE = 11;

    // Chain constants
    uint32 public constant L1_EID = 30_101; // Ethereum mainnet
    uint32 public constant L2_EID = 30_111; // Optimism

    // Native token constant
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Mock LayerZero endpoint for testing
    address public constant MOCK_LZ_ENDPOINT = address(0x1234567890123456789012345678901234567890);
    address public lzEndpoint;

    // Test addresses
    address public owner;
    address public hexTrust;

    // L1 Contracts
    BoringVault public l1Vault;
    MultiChainLayerZeroTellerWithMultiAssetSupport public l1Teller;
    AccountantWithRateProviders public l1Accountant;
    RolesAuthority public l1Authority;
    AtomicQueue public l1AtomicQueue;
    AtomicSolverV5 public l1AtomicSolver;

    // L2 Contracts
    BoringVault public l2Vault;
    MultiChainLayerZeroTellerWithMultiAssetSupport public l2Teller;
    AccountantWithRateProviders public l2Accountant;
    RolesAuthority public l2Authority;
    AtomicQueue public l2AtomicQueue;
    AtomicSolverV5 public l2AtomicSolver;

    function run() public {
        run(vm.addr(1), vm.addr(2), MOCK_LZ_ENDPOINT);
    }

    function run(address _owner, address _hexTrust) public {
        run(_owner, _hexTrust, MOCK_LZ_ENDPOINT);
    }

    function run(address _owner, address _hexTrust, address _lzEndpoint) public {
        owner = _owner;
        hexTrust = _hexTrust;
        lzEndpoint = _lzEndpoint;

        vm.startBroadcast(owner);

        // Deploy L1 infrastructure
        _deployL1Infrastructure();

        // Deploy L2 infrastructure
        _deployL2Infrastructure();

        // Configure cross-chain
        _configureCrossChain();

        vm.stopBroadcast();
    }

    function _deployL1Infrastructure() internal {
        // Deploy L1 contracts
        l1Vault = new BoringVault(owner, "Port L1 Vault", "PL1V", 18);
        l1Accountant = new AccountantWithRateProviders(
            owner, address(l1Vault), owner, 1e18, address(WETH), 1.001e4, 0.999e4, 1, 0
        );
        l1Teller = new MultiChainLayerZeroTellerWithMultiAssetSupport(
            owner, address(l1Vault), address(l1Accountant), lzEndpoint
        );
        l1Authority = new RolesAuthority(owner, Authority(address(0)));
        l1AtomicQueue = new AtomicQueue(address(l1Accountant), owner, l1Authority);
        l1AtomicSolver = new AtomicSolverV5(owner, l1Authority);
        l1AtomicSolver.setQueueApproved(address(l1AtomicQueue), true);

        // Setup authorities
        l1Vault.setAuthority(l1Authority);
        l1Accountant.setAuthority(l1Authority);
        l1Teller.setAuthority(l1Authority);

        // Setup roles
        _setupRoles(l1Authority, address(l1Vault), address(l1Teller), address(l1AtomicSolver), address(l1AtomicQueue));

        // Add assets
        l1Teller.addAsset(WETH);
        l1Accountant.setRateProviderData(WETH, true, address(0));
    }

    function _deployL2Infrastructure() internal {
        // Deploy L2 contracts
        l2Vault = new BoringVault(owner, "Port L2 Vault", "PL2V", 18);
        l2Accountant = new AccountantWithRateProviders(
            owner, address(l2Vault), owner, 1e18, address(WETH), 1.001e4, 0.999e4, 1, 0
        );
        l2Teller = new MultiChainLayerZeroTellerWithMultiAssetSupport(
            owner, address(l2Vault), address(l2Accountant), lzEndpoint
        );
        l2Authority = new RolesAuthority(owner, Authority(address(0)));
        l2AtomicQueue = new AtomicQueue(address(l2Accountant), owner, l2Authority);
        l2AtomicSolver = new AtomicSolverV5(owner, l2Authority);
        l2AtomicSolver.setQueueApproved(address(l2AtomicQueue), true);

        // Setup authorities
        l2Vault.setAuthority(l2Authority);
        l2Accountant.setAuthority(l2Authority);
        l2Teller.setAuthority(l2Authority);

        // Setup roles
        _setupRoles(l2Authority, address(l2Vault), address(l2Teller), address(l2AtomicSolver), address(l2AtomicQueue));

        // Add assets
        l2Teller.addAsset(WETH);
        l2Accountant.setRateProviderData(WETH, true, address(0));
    }

    function _setupRoles(
        RolesAuthority authority,
        address vault,
        address teller,
        address atomicSolver,
        address atomicQueue
    )
        internal
    {
        // Vault capabilities
        authority.setRoleCapability(MINTER_ROLE, vault, BoringVault.enter.selector, true);
        authority.setRoleCapability(BURNER_ROLE, vault, BoringVault.exit.selector, true);
        authority.setRoleCapability(
            MANAGER_ROLE, vault, bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))), true
        );

        // Teller capabilities
        authority.setRoleCapability(ADMIN_ROLE, teller, TellerWithMultiAssetSupport.addAsset.selector, true);
        authority.setRoleCapability(ADMIN_ROLE, teller, TellerWithMultiAssetSupport.removeAsset.selector, true);
        authority.setRoleCapability(ADMIN_ROLE, teller, TellerWithMultiAssetSupport.bulkDeposit.selector, true);
        authority.setRoleCapability(ADMIN_ROLE, teller, TellerWithMultiAssetSupport.bulkWithdraw.selector, true);
        authority.setRoleCapability(SOLVER_ROLE, teller, TellerWithMultiAssetSupport.bulkWithdraw.selector, true);

        // AtomicSolver capabilities
        authority.setRoleCapability(CAN_SOLVE_ROLE, atomicSolver, AtomicSolverV5.p2pSolve.selector, true);
        authority.setRoleCapability(CAN_SOLVE_ROLE, atomicSolver, AtomicSolverV5.redeemSolve.selector, true);
        authority.setRoleCapability(QUEUE_ROLE, atomicSolver, AtomicSolverV5.finishSolve.selector, true);

        // User roles
        authority.setUserRole(owner, ADMIN_ROLE, true);
        authority.setUserRole(hexTrust, MANAGER_ROLE, true);
        authority.setUserRole(teller, MINTER_ROLE, true);
        authority.setUserRole(teller, BURNER_ROLE, true);
        authority.setUserRole(atomicSolver, SOLVER_ROLE, true);
        authority.setUserRole(atomicQueue, QUEUE_ROLE, true);
        authority.setUserRole(hexTrust, CAN_SOLVE_ROLE, true);

        // Public capabilities
        authority.setPublicCapability(teller, TellerWithMultiAssetSupport.deposit.selector, true);
        authority.setPublicCapability(teller, TellerWithMultiAssetSupport.depositWithPermit.selector, true);

        // Audit D-6: use the named selector instead of a hardcoded hex value. Previously
        // the selector was written as `bytes4 bridgeSelector = 0xa69559d1;` with a comment
        // noting "what's being called according to the error trace" — a future ABI change
        // would silently redirect the public capability to a different function.
        authority.setPublicCapability(teller, CrossChainTellerBase.bridge.selector, true);

        // Audit D-7: removed the no-op `setPublicCapability(atomicQueue, updateAtomicRequest.selector)`.
        // `updateAtomicRequest` is not `requiresAuth`, so this call had no effect anyway,
        // but reintroducing auth on the function in a future refactor would combine with
        // this line to recreate the public-by-default footgun.
    }

    function _configureCrossChain() internal {
        // Configure L1 to accept from L2
        l1Teller.setPeer(L2_EID, bytes32(uint256(uint160(address(l2Teller)))));
        l1Teller.addChain(
            L2_EID,
            true, // allowMessagesFrom
            true, // allowMessagesTo
            address(l2Teller), // targetTeller
            200_000, // messageGasLimit
            50_000 // minimumMessageGas
        );

        // Configure L2 to accept from L1
        l2Teller.setPeer(L1_EID, bytes32(uint256(uint160(address(l1Teller)))));
        l2Teller.addChain(
            L1_EID,
            true, // allowMessagesFrom
            true, // allowMessagesTo
            address(l1Teller), // targetTeller
            200_000, // messageGasLimit
            50_000 // minimumMessageGas
        );
    }
}

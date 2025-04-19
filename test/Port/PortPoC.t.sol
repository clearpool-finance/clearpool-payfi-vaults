// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import {Test, stdStorage, StdStorage, stdError} from "@forge-std/Test.sol";
import {BoringVault} from "src/base/BoringVault.sol";
import {DeployPortProofOfConceptScript} from "script/DeployPortProofOfConcept.s.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

/// @dev forge test --match-contract PortPoCTest
contract PortPoCTest is Test, DeployPortProofOfConceptScript {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    function setUp() external {
        uint256 forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(forkId);

        USDX = WETH;
        run();
    }

    function test_CanArbitrarilyRemoveFunds() external {
        uint256 amount = 100e18;
        deal(address(WETH), address(boringVault), amount);

        vm.startPrank(hexTrust);
        address target = address(WETH);
        bytes memory data = abi.encodeCall(ERC20.transfer, (hexTrust, amount));
        uint256 value;
        boringVault.manage(target, data, value);
        vm.stopPrank();
    }
}
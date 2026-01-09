// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { BaseScript } from "./Base.s.sol";
import { ConfigReader } from "./ConfigReader.s.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import "forge-std/console.sol";

/**
 * @title CreateRLOCMerkleRoot
 * @notice Script to generate and set merkle roots for RLOC vault strategists
 * @dev Supports:
 *      - ERC20 approve/transfer (unrestricted for borrowing)
 *      - Aave V3 supply/withdraw (fund diversion)
 *      - Compound V3 supply/withdraw (commented out, optional)
 *
 * Usage (reads from deployment config):
 *   source .env && forge script script/CreateRLOCMerkleRoot.s.sol:CreateRLOCMerkleRootScript \
 *     --rpc-url $RPC_URL --broadcast
 *
 * The script will prompt for the config file name (e.g., "eth-mainnet-l1-layerzero.json")
 */
contract CreateRLOCMerkleRootScript is BaseScript {
    // ========================== CONFIGURATION ==========================
    // These are loaded from the deployment config file

    // Vault addresses (from config)
    address public boringVault;
    address public managerAddress;
    address public decoderAndSanitizer;

    // Strategist addresses (from config)
    address[] public strategists;

    // Asset addresses
    address public vaultAsset;
    address public aaveAsset;

    // Protocol addresses (chain-specific)
    address public aaveV3Pool;

    // Compound V3 (optional, commented out by default)
    // address public compoundComet;

    // ========================== LEAF INDEX ==========================
    uint256 internal leafIndex = 0;

    // ========================== MAIN ==========================

    function run() public returns (address) {
        ConfigReader.Config memory config = getConfig();
        return deploy(config);
    }

    function deploy(ConfigReader.Config memory config) public override broadcast returns (address) {
        // Load addresses from config
        boringVault = config.boringVault;
        managerAddress = config.manager;
        decoderAndSanitizer = config.decoder;

        require(boringVault != address(0), "boringVault not set in config");
        require(managerAddress != address(0), "manager not set in config");
        require(decoderAndSanitizer != address(0), "decoder not set in config");

        // Load strategists from config
        strategists.push(config.strategist);
        for (uint256 i = 0; i < config.additionalStrategists.length; i++) {
            if (config.additionalStrategists[i] != address(0)) {
                strategists.push(config.additionalStrategists[i]);
            }
        }
        // Add protocolAdmin as strategist (for fund diversion rights)
        if (config.protocolAdmin != address(0)) {
            strategists.push(config.protocolAdmin);
        }

        // Set asset addresses based on chain
        _setupChainSpecificConfig(config);

        console.log("=== RLOC Merkle Root Generator ===");
        console.log("Chain ID:", block.chainid);
        console.log("Vault:", boringVault);
        console.log("Manager:", managerAddress);
        console.log("Decoder:", decoderAndSanitizer);
        console.log("Vault Asset:", vaultAsset);
        console.log("Aave Asset:", aaveAsset);
        console.log("Aave Pool:", aaveV3Pool);
        console.log("");

        // Generate merkle tree
        ManageLeaf[] memory leafs = new ManageLeaf[](32);
        leafIndex = 0;

        // Add ERC20 leaves for borrowing (unrestricted)
        _addBorrowingLeafs(leafs, vaultAsset);

        // Add Aave V3 leaves for fund diversion
        _addAaveV3Leafs(leafs, aaveAsset);

        // Uncomment to add Compound V3 leaves
        // _addCompoundV3Leafs(leafs, aaveAsset);

        // Trim leafs array to actual size
        ManageLeaf[] memory trimmedLeafs = new ManageLeaf[](leafIndex);
        for (uint256 i = 0; i < leafIndex; i++) {
            trimmedLeafs[i] = leafs[i];
        }

        // Generate merkle tree and get root
        bytes32[][] memory tree = _generateMerkleTree(trimmedLeafs);
        bytes32 root = tree[tree.length - 1][0];

        console.log("Generated Merkle Root:");
        console.logBytes32(root);
        console.log("");

        // Print all leaves for verification
        console.log("=== Merkle Leaves ===");
        for (uint256 i = 0; i < trimmedLeafs.length; i++) {
            console.log(i, ":", trimmedLeafs[i].description);
        }
        console.log("");

        // Set merkle root for each strategist
        ManagerWithMerkleVerification manager = ManagerWithMerkleVerification(managerAddress);

        console.log("=== Setting Merkle Roots ===");
        for (uint256 i = 0; i < strategists.length; i++) {
            address strategist = strategists[i];
            bytes32 currentRoot = manager.manageRoot(strategist);

            console.log("Strategist:", strategist);
            console.log("  Current root:");
            console.logBytes32(currentRoot);

            if (currentRoot == root) {
                console.log("  Status: Already set correctly");
            } else {
                console.log("  Setting new root...");
                manager.setManageRoot(strategist, root);
                console.log("  Status: Root updated");
            }
            console.log("");
        }

        console.log("=== COMPLETE ===");

        return managerAddress;
    }

    function _setupChainSpecificConfig(ConfigReader.Config memory config) internal {
        uint256 chainId = block.chainid;

        // Set vault asset from config base
        vaultAsset = config.base;

        if (chainId == 1) {
            // ETH Mainnet
            aaveAsset = config.base; // USDT supported on ETH mainnet Aave
            aaveV3Pool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
            // compoundComet = 0x3Afdc9BCA9213A35503b077a6072F3D0d5AB0840; // USDT Comet
        } else if (chainId == 8453) {
            // Base Mainnet - vault uses USDC which Aave supports
            aaveAsset = config.base; // USDC
            aaveV3Pool = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
            // compoundComet = 0xb125E6687d4313864e53df431d5425969c15Eb2F; // USDC Comet
        } else {
            revert("Unsupported chain - add Aave pool address for this chain");
        }
    }

    // ========================== VERIFY ROOT ==========================

    function verifyRoot() external {
        ConfigReader.Config memory config = getConfig();

        managerAddress = config.manager;
        require(managerAddress != address(0), "manager not set in config");

        // Load strategists
        strategists.push(config.strategist);
        for (uint256 i = 0; i < config.additionalStrategists.length; i++) {
            if (config.additionalStrategists[i] != address(0)) {
                strategists.push(config.additionalStrategists[i]);
            }
        }
        if (config.protocolAdmin != address(0)) {
            strategists.push(config.protocolAdmin);
        }

        console.log("=== Verify Merkle Roots ===");
        console.log("Manager:", managerAddress);
        console.log("");

        ManagerWithMerkleVerification manager = ManagerWithMerkleVerification(managerAddress);

        for (uint256 i = 0; i < strategists.length; i++) {
            address strategist = strategists[i];
            bytes32 currentRoot = manager.manageRoot(strategist);

            console.log("Strategist:", strategist);
            console.log("  Root:");
            console.logBytes32(currentRoot);

            if (currentRoot == bytes32(0)) {
                console.log("  Status: NOT SET");
            } else {
                console.log("  Status: Set");
            }
            console.log("");
        }
    }

    // ========================== LEAF GENERATORS ==========================

    /**
     * @notice Add ERC20 approve and transfer leaves for borrowing
     * @dev Unrestricted - allows approve/transfer to any address
     */
    function _addBorrowingLeafs(ManageLeaf[] memory leafs, address asset) internal {
        // ERC20 approve (unrestricted spender)
        leafs[leafIndex] = ManageLeaf({
            target: asset,
            canSendValue: false,
            signature: "approve(address,uint256)",
            argumentAddresses: new address[](1),
            description: "Approve any address to spend vault asset (borrowing)",
            decoderAndSanitizer: decoderAndSanitizer
        });
        // Empty address array means unrestricted
        leafIndex++;

        // ERC20 transfer (unrestricted recipient)
        leafs[leafIndex] = ManageLeaf({
            target: asset,
            canSendValue: false,
            signature: "transfer(address,uint256)",
            argumentAddresses: new address[](1),
            description: "Transfer vault asset to any address (borrowing)",
            decoderAndSanitizer: decoderAndSanitizer
        });
        // Empty address array means unrestricted
        leafIndex++;
    }

    /**
     * @notice Add Aave V3 supply and withdraw leaves
     */
    function _addAaveV3Leafs(ManageLeaf[] memory leafs, address asset) internal {
        // Approve Aave Pool to spend asset
        leafs[leafIndex] = ManageLeaf({
            target: asset,
            canSendValue: false,
            signature: "approve(address,uint256)",
            argumentAddresses: new address[](1),
            description: "Approve Aave V3 Pool to spend asset",
            decoderAndSanitizer: decoderAndSanitizer
        });
        leafs[leafIndex].argumentAddresses[0] = aaveV3Pool;
        leafIndex++;

        // Aave V3 supply
        leafs[leafIndex] = ManageLeaf({
            target: aaveV3Pool,
            canSendValue: false,
            signature: "supply(address,uint256,address,uint16)",
            argumentAddresses: new address[](2),
            description: "Supply asset to Aave V3",
            decoderAndSanitizer: decoderAndSanitizer
        });
        leafs[leafIndex].argumentAddresses[0] = asset;
        leafs[leafIndex].argumentAddresses[1] = boringVault;
        leafIndex++;

        // Aave V3 withdraw
        leafs[leafIndex] = ManageLeaf({
            target: aaveV3Pool,
            canSendValue: false,
            signature: "withdraw(address,uint256,address)",
            argumentAddresses: new address[](2),
            description: "Withdraw asset from Aave V3",
            decoderAndSanitizer: decoderAndSanitizer
        });
        leafs[leafIndex].argumentAddresses[0] = asset;
        leafs[leafIndex].argumentAddresses[1] = boringVault;
        leafIndex++;
    }

    /**
     * @notice Add Compound V3 supply and withdraw leaves (optional)
     * @dev Uncomment in run() to enable
     */
    // function _addCompoundV3Leafs(ManageLeaf[] memory leafs, address asset) internal {
    //     // Approve Compound Comet to spend asset
    //     leafs[leafIndex] = ManageLeaf({
    //         target: asset,
    //         canSendValue: false,
    //         signature: "approve(address,uint256)",
    //         argumentAddresses: new address[](1),
    //         description: "Approve Compound V3 Comet to spend asset",
    //         decoderAndSanitizer: decoderAndSanitizer
    //     });
    //     leafs[leafIndex].argumentAddresses[0] = compoundComet;
    //     leafIndex++;
    //
    //     // Compound V3 supply
    //     leafs[leafIndex] = ManageLeaf({
    //         target: compoundComet,
    //         canSendValue: false,
    //         signature: "supply(address,uint256)",
    //         argumentAddresses: new address[](1),
    //         description: "Supply asset to Compound V3",
    //         decoderAndSanitizer: decoderAndSanitizer
    //     });
    //     leafs[leafIndex].argumentAddresses[0] = asset;
    //     leafIndex++;
    //
    //     // Compound V3 withdraw
    //     leafs[leafIndex] = ManageLeaf({
    //         target: compoundComet,
    //         canSendValue: false,
    //         signature: "withdraw(address,uint256)",
    //         argumentAddresses: new address[](1),
    //         description: "Withdraw asset from Compound V3",
    //         decoderAndSanitizer: decoderAndSanitizer
    //     });
    //     leafs[leafIndex].argumentAddresses[0] = asset;
    //     leafIndex++;
    // }

    // ========================== MERKLE TREE HELPERS ==========================

    struct ManageLeaf {
        address target;
        bool canSendValue;
        string signature;
        address[] argumentAddresses;
        string description;
        address decoderAndSanitizer;
    }

    function _generateMerkleTree(ManageLeaf[] memory manageLeafs) internal pure returns (bytes32[][] memory tree) {
        uint256 leafsLength = manageLeafs.length;
        bytes32[][] memory leafs = new bytes32[][](1);
        leafs[0] = new bytes32[](leafsLength);

        for (uint256 i; i < leafsLength; ++i) {
            bytes4 selector = bytes4(keccak256(abi.encodePacked(manageLeafs[i].signature)));
            bytes memory rawDigest = abi.encodePacked(
                manageLeafs[i].decoderAndSanitizer, manageLeafs[i].target, manageLeafs[i].canSendValue, selector
            );

            uint256 argumentAddressesLength = manageLeafs[i].argumentAddresses.length;
            for (uint256 j; j < argumentAddressesLength; ++j) {
                rawDigest = abi.encodePacked(rawDigest, manageLeafs[i].argumentAddresses[j]);
            }
            leafs[0][i] = keccak256(rawDigest);
        }

        tree = _buildTrees(leafs);
    }

    function _buildTrees(bytes32[][] memory merkleTreeIn) internal pure returns (bytes32[][] memory merkleTreeOut) {
        uint256 merkleTreeIn_length = merkleTreeIn.length;
        merkleTreeOut = new bytes32[][](merkleTreeIn_length + 1);
        uint256 layer_length;

        for (uint256 i; i < merkleTreeIn_length; ++i) {
            layer_length = merkleTreeIn[i].length;
            merkleTreeOut[i] = new bytes32[](layer_length);
            for (uint256 j; j < layer_length; ++j) {
                merkleTreeOut[i][j] = merkleTreeIn[i][j];
            }
        }

        uint256 next_layer_length;
        if (layer_length % 2 != 0) {
            next_layer_length = (layer_length + 1) / 2;
        } else {
            next_layer_length = layer_length / 2;
        }

        merkleTreeOut[merkleTreeIn_length] = new bytes32[](next_layer_length);
        uint256 count;

        for (uint256 i; i < layer_length; i += 2) {
            merkleTreeOut[merkleTreeIn_length][count] =
                _hashPair(merkleTreeIn[merkleTreeIn_length - 1][i], merkleTreeIn[merkleTreeIn_length - 1][i + 1]);
            count++;
        }

        if (next_layer_length > 1) {
            merkleTreeOut = _buildTrees(merkleTreeOut);
        }
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}

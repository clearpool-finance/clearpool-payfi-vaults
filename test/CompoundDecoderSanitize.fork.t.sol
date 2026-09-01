// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { Test } from "@forge-std/Test.sol";
import { Authority, RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import {
    ClearpoolVaultDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/CustomDecoders/ClearpoolVaultDecoderAndSanitizer.sol";

interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface ICometRewards {
    function claim(address comet, address src, bool shouldAccrue) external;
}

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @title CompoundDecoderSanitizeForkTest
 * @notice Base-mainnet fork test for the fixed ClearpoolVaultDecoderAndSanitizer.
 *
 * Proves, against the REAL Compound V3 and Aave V3 contracts on Base:
 *   1. The live automation flow (approve -> supply -> withdraw on Comet) still works.
 *   2. Reward claim works and its leaf (comet + src) verifies.
 *   3. Aave supply/withdraw are unaffected (they already bound onBehalfOf/to).
 *   4. The fix actually BINDS the asset: a supply for a different asset than the leaf
 *      committed now fails proof verification (before the fix the asset was unconstrained).
 *   5. The removed delegation functions (supplyTo/withdrawTo/withdrawFrom/transferFrom/
 *      claimTo/collateral) now revert at the decoder and cannot be routed through the manager.
 *   6. The decoder's packed output matches EXACTLY what withdraw-tx-automation/scripts/
 *      setup-merkle.ts packs (approve->comet, supply->asset, withdraw->asset, claim->comet,src),
 *      so a regenerated root will verify unchanged.
 *
 * Run: forge test --match-contract CompoundDecoderSanitizeForkTest -vvv
 */
contract CompoundDecoderSanitizeForkTest is Test {
    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant STRATEGIST_ROLE = 2;

    // ---- Base mainnet addresses (Compound III deployments/base/usdc + Aave V3) ----
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant COMET_USDC = 0xb125E6687d4313864e53df431d5425969c15Eb2F;
    address internal constant COMET_REWARDS = 0x123964802e6ABabBE1Bc9547D72Ef1B69B00A6b1;
    address internal constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    // Selectors exactly as the live setup-merkle.ts generator uses them.
    bytes4 internal constant APPROVE_SEL = bytes4(keccak256("approve(address,uint256)"));
    bytes4 internal constant COMPOUND_SUPPLY_SEL = bytes4(keccak256("supply(address,uint256)")); // 0xf2b9fdb8
    bytes4 internal constant COMPOUND_WITHDRAW_SEL = bytes4(keccak256("withdraw(address,uint256)")); // 0xf3fef3a3
    bytes4 internal constant CLAIM_SEL = bytes4(keccak256("claim(address,address,bool)"));
    bytes4 internal constant AAVE_SUPPLY_SEL = bytes4(keccak256("supply(address,uint256,address,uint16)"));
    bytes4 internal constant AAVE_WITHDRAW_SEL = bytes4(keccak256("withdraw(address,uint256,address)"));

    address internal admin = address(this);
    address internal strategist = makeAddr("strategist-bot");

    RolesAuthority internal authority;
    BoringVault internal vault;
    ManagerWithMerkleVerification internal manager;
    ClearpoolVaultDecoderAndSanitizer internal decoder;

    // The live leaf set (mirrors setup-merkle.ts). Order fixed so we can index proofs.
    bytes32[] internal leaves;
    bytes32 internal root;

    uint256 internal constant FUND = 10_000e6;
    uint256 internal constant AMT = 1000e6;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));
        assertEq(block.chainid, 8453, "must fork Base mainnet");

        authority = new RolesAuthority(admin, Authority(address(0)));
        vault = new BoringVault(admin, "PayFi Vault", "PFV", 18);
        manager = new ManagerWithMerkleVerification(admin, address(vault), address(0));
        decoder = new ClearpoolVaultDecoderAndSanitizer(address(vault));

        vault.setAuthority(authority);
        manager.setAuthority(authority);

        authority.setRoleCapability(
            MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );
        authority.setRoleCapability(
            MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address[],bytes[],uint256[])")), true
        );
        authority.setRoleCapability(
            STRATEGIST_ROLE,
            address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );
        authority.setUserRole(address(manager), MANAGER_ROLE, true);
        authority.setUserRole(strategist, STRATEGIST_ROLE, true);

        _fundUSDC(address(vault), FUND);

        // Build the live leaf set exactly as the off-chain generator does.
        // 0 approve(comet) on USDC              -> decoder.approve returns (spender=comet)
        // 1 supply(USDC) on comet               -> decoder.supply  returns (asset=USDC)
        // 2 withdraw(USDC) on comet             -> decoder.withdraw returns (asset=USDC)
        // 3 claim(comet, vault) on cometRewards -> decoder.claim   returns (comet, src=vault)
        // 4 approve(aavePool) on USDC
        // 5 aave supply(USDC, vault) on pool    -> returns (asset=USDC, onBehalfOf=vault)
        // 6 aave withdraw(USDC, vault) on pool  -> returns (asset=USDC, to=vault)
        leaves = new bytes32[](7);
        leaves[0] = _leaf(USDC, APPROVE_SEL, abi.encodePacked(COMET_USDC));
        leaves[1] = _leaf(COMET_USDC, COMPOUND_SUPPLY_SEL, abi.encodePacked(USDC));
        leaves[2] = _leaf(COMET_USDC, COMPOUND_WITHDRAW_SEL, abi.encodePacked(USDC));
        leaves[3] = _leaf(COMET_REWARDS, CLAIM_SEL, abi.encodePacked(COMET_USDC, address(vault)));
        leaves[4] = _leaf(USDC, APPROVE_SEL, abi.encodePacked(AAVE_V3_POOL));
        leaves[5] = _leaf(AAVE_V3_POOL, AAVE_SUPPLY_SEL, abi.encodePacked(USDC, address(vault)));
        leaves[6] = _leaf(AAVE_V3_POOL, AAVE_WITHDRAW_SEL, abi.encodePacked(USDC, address(vault)));

        bytes32[][] memory proofs;
        (root, proofs) = _merkle(leaves);
        manager.setManageRoot(strategist, root);
    }

    // ============================ 1. Compound supply/withdraw flow ============================

    function test_compound_supply_then_withdraw_flow() public {
        (, bytes32[][] memory proofs) = _merkle(leaves);

        // approve + supply in one manage batch
        bytes32[][] memory p2 = new bytes32[][](2);
        p2[0] = proofs[0];
        p2[1] = proofs[1];
        address[] memory dec2 = _dupDecoder(2);
        address[] memory tgt2 = new address[](2);
        tgt2[0] = USDC;
        tgt2[1] = COMET_USDC;
        bytes[] memory data2 = new bytes[](2);
        data2[0] = abi.encodeWithSelector(APPROVE_SEL, COMET_USDC, AMT);
        data2[1] = abi.encodeWithSelector(COMPOUND_SUPPLY_SEL, USDC, AMT);
        uint256[] memory val2 = new uint256[](2);

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(address(vault));
        vm.prank(strategist);
        manager.manageVaultWithMerkleVerification(p2, dec2, tgt2, data2, val2);

        assertApproxEqAbs(
            ERC20(USDC).balanceOf(address(vault)), vaultUsdcBefore - AMT, 1, "vault USDC should drop by supplied amount"
        );
        assertApproxEqAbs(
            IComet(COMET_USDC).balanceOf(address(vault)), AMT, 2, "vault should hold a Comet base position"
        );

        // withdraw back to the vault
        bytes32[][] memory p1 = new bytes32[][](1);
        p1[0] = proofs[2];
        address[] memory dec1 = _dupDecoder(1);
        address[] memory tgt1 = new address[](1);
        tgt1[0] = COMET_USDC;
        bytes[] memory data1 = new bytes[](1);
        // withdraw the actual Comet base balance (supply rounds down ~1 wei)
        data1[0] = abi.encodeWithSelector(COMPOUND_WITHDRAW_SEL, USDC, IComet(COMET_USDC).balanceOf(address(vault)));
        uint256[] memory val1 = new uint256[](1);

        vm.prank(strategist);
        manager.manageVaultWithMerkleVerification(p1, dec1, tgt1, data1, val1);

        assertApproxEqAbs(
            ERC20(USDC).balanceOf(address(vault)), vaultUsdcBefore, 2, "vault USDC should be restored after withdraw"
        );
    }

    // ============================ 2. Reward claim flow ============================

    function test_compound_claim_flow_verifies_and_executes() public {
        (, bytes32[][] memory proofs) = _merkle(leaves);

        bytes32[][] memory p1 = new bytes32[][](1);
        p1[0] = proofs[3];
        address[] memory dec1 = _dupDecoder(1);
        address[] memory tgt1 = new address[](1);
        tgt1[0] = COMET_REWARDS;
        bytes[] memory data1 = new bytes[](1);
        data1[0] = abi.encodeWithSelector(CLAIM_SEL, COMET_USDC, address(vault), true);
        uint256[] memory val1 = new uint256[](1);

        // Should verify against the (comet, src) leaf and execute (0 owed is fine).
        vm.prank(strategist);
        manager.manageVaultWithMerkleVerification(p1, dec1, tgt1, data1, val1);
    }

    // ============================ 3. Aave unaffected ============================

    function test_aave_supply_then_withdraw_flow() public {
        (, bytes32[][] memory proofs) = _merkle(leaves);

        bytes32[][] memory p2 = new bytes32[][](2);
        p2[0] = proofs[4];
        p2[1] = proofs[5];
        address[] memory dec2 = _dupDecoder(2);
        address[] memory tgt2 = new address[](2);
        tgt2[0] = USDC;
        tgt2[1] = AAVE_V3_POOL;
        bytes[] memory data2 = new bytes[](2);
        data2[0] = abi.encodeWithSelector(APPROVE_SEL, AAVE_V3_POOL, AMT);
        data2[1] = abi.encodeWithSelector(AAVE_SUPPLY_SEL, USDC, AMT, address(vault), uint16(0));
        uint256[] memory val2 = new uint256[](2);

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(address(vault));
        vm.prank(strategist);
        manager.manageVaultWithMerkleVerification(p2, dec2, tgt2, data2, val2);

        assertApproxEqAbs(ERC20(AUSDC).balanceOf(address(vault)), AMT, 2, "vault should hold aUSDC after Aave supply");

        bytes32[][] memory p1 = new bytes32[][](1);
        p1[0] = proofs[6];
        address[] memory dec1 = _dupDecoder(1);
        address[] memory tgt1 = new address[](1);
        tgt1[0] = AAVE_V3_POOL;
        bytes[] memory data1 = new bytes[](1);
        // withdraw all (Aave treats type(uint256).max as the full balance)
        data1[0] = abi.encodeWithSelector(AAVE_WITHDRAW_SEL, USDC, type(uint256).max, address(vault));
        uint256[] memory val1 = new uint256[](1);

        vm.prank(strategist);
        manager.manageVaultWithMerkleVerification(p1, dec1, tgt1, data1, val1);

        assertApproxEqAbs(
            ERC20(USDC).balanceOf(address(vault)), vaultUsdcBefore, 2, "vault USDC restored after Aave withdraw"
        );
    }

    // ============================ 4. Asset is now bound ============================

    function test_supply_with_wrong_asset_now_reverts() public {
        (, bytes32[][] memory proofs) = _merkle(leaves);
        address WETH = 0x4200000000000000000000000000000000000006; // any asset != USDC

        bytes32[][] memory p1 = new bytes32[][](1);
        p1[0] = proofs[1]; // the USDC supply proof
        address[] memory dec1 = _dupDecoder(1);
        address[] memory tgt1 = new address[](1);
        tgt1[0] = COMET_USDC;
        bytes[] memory data1 = new bytes[](1);
        data1[0] = abi.encodeWithSelector(COMPOUND_SUPPLY_SEL, WETH, AMT); // substitute asset
        uint256[] memory val1 = new uint256[](1);

        // decoder now returns abi.encodePacked(WETH) != committed USDC -> proof fails.
        vm.prank(strategist);
        vm.expectRevert();
        manager.manageVaultWithMerkleVerification(p1, dec1, tgt1, data1, val1);
    }

    // ============================ 5. Delegation surface removed ============================

    function test_removed_delegation_selectors_revert_at_decoder() public {
        string[6] memory sigs = [
            "supplyTo(address,address,uint256)",
            "withdrawTo(address,address,uint256)",
            "withdrawFrom(address,address,address,uint256)",
            "transferFrom(address,address,uint256)",
            "claimTo(address,address,address,bool)",
            "supplyCollateral(address,uint256)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(decoder)
                .staticcall(
                    abi.encodeWithSelector(bytes4(keccak256(bytes(sigs[i]))), address(1), address(2), uint256(3))
                );
            assertFalse(ok, string.concat("decoder must reject: ", sigs[i]));
        }
    }

    function test_withdrawTo_cannot_be_routed_through_manager() public {
        // Even with an attacker-crafted single-leaf root, the decoder staticcall reverts,
        // so _verifyCallData reverts and the whole manage tx reverts.
        bytes4 withdrawToSel = bytes4(keccak256("withdrawTo(address,address,uint256)"));
        bytes32 fakeLeaf = _leaf(COMET_USDC, withdrawToSel, abi.encodePacked(address(0xBEEF)));
        manager.setManageRoot(strategist, fakeLeaf);

        bytes32[][] memory p1 = new bytes32[][](1);
        p1[0] = new bytes32[](0);
        address[] memory dec1 = _dupDecoder(1);
        address[] memory tgt1 = new address[](1);
        tgt1[0] = COMET_USDC;
        bytes[] memory data1 = new bytes[](1);
        data1[0] = abi.encodeWithSelector(withdrawToSel, address(0xBEEF), USDC, AMT);
        uint256[] memory val1 = new uint256[](1);

        vm.prank(strategist);
        vm.expectRevert();
        manager.manageVaultWithMerkleVerification(p1, dec1, tgt1, data1, val1);
    }

    // ============================ 6. Decoder output matches the generator ============================

    function test_decoder_packing_matches_setup_merkle_generator() public view {
        assertEq(decoder.approve(COMET_USDC, 0), abi.encodePacked(COMET_USDC), "approve -> spender");
        assertEq(decoder.supply(USDC, 0), abi.encodePacked(USDC), "compound supply -> asset");
        assertEq(decoder.withdraw(USDC, 0), abi.encodePacked(USDC), "compound withdraw -> asset");
        assertEq(
            decoder.claim(COMET_USDC, address(vault), true),
            abi.encodePacked(COMET_USDC, address(vault)),
            "claim -> comet,src"
        );
        assertEq(decoder.transfer(address(0xCAFE), 0), abi.encodePacked(address(0xCAFE)), "transfer -> to");
        // Aave (inherited) still binds recipient — proves no Aave-side change needed.
        assertEq(
            decoder.supply(USDC, 0, address(vault), 0),
            abi.encodePacked(USDC, address(vault)),
            "aave supply -> asset,onBehalfOf"
        );
        assertEq(
            decoder.withdraw(USDC, 0, address(vault)),
            abi.encodePacked(USDC, address(vault)),
            "aave withdraw -> asset,to"
        );
    }

    // ================================ helpers ================================

    function _leaf(address target, bytes4 selector, bytes memory packed) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(decoder), target, false, selector, packed));
    }

    function _dupDecoder(uint256 n) internal view returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = address(decoder);
        }
    }

    function _fundUSDC(address to, uint256 amount) internal {
        deal(USDC, to, amount);
        require(ERC20(USDC).balanceOf(to) >= amount, "USDC funding failed");
    }

    /// @dev Sorted-pair Merkle builder + per-leaf proof extraction, matching solmate MerkleProofLib
    ///      (commutative hashing) and the on-chain _verifyManageProof used by the manager.
    function _merkle(bytes32[] memory leavesIn) internal pure returns (bytes32 rootOut, bytes32[][] memory proofsOut) {
        uint256 n = leavesIn.length;
        proofsOut = new bytes32[][](n);
        uint256[] memory pos = new uint256[](n);
        uint256[] memory cnt = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            pos[i] = i;
            proofsOut[i] = new bytes32[](32); // oversized, trimmed below
        }

        bytes32[] memory layer = leavesIn;
        while (layer.length > 1) {
            uint256 len = layer.length;
            uint256 half = (len + 1) / 2;
            for (uint256 i; i < n; ++i) {
                uint256 p = pos[i];
                uint256 sib = p ^ 1;
                bytes32 sibVal = sib < len ? layer[sib] : layer[len - 1];
                proofsOut[i][cnt[i]++] = sibVal;
                pos[i] = p / 2;
            }
            bytes32[] memory next = new bytes32[](half);
            for (uint256 i; i < half; ++i) {
                bytes32 a = layer[2 * i];
                bytes32 b = (2 * i + 1 < len) ? layer[2 * i + 1] : layer[len - 1];
                next[i] = _hashPair(a, b);
            }
            layer = next;
        }
        rootOut = layer[0];

        for (uint256 i; i < n; ++i) {
            bytes32[] memory trimmed = new bytes32[](cnt[i]);
            for (uint256 j; j < cnt[i]; ++j) {
                trimmed[j] = proofsOut[i][j];
            }
            proofsOut[i] = trimmed;
        }
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

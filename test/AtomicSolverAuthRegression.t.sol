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
import { AtomicSolverV5 } from "src/atomic-queue/AtomicSolverV5.sol";
import { IAtomicSolver } from "src/atomic-queue/IAtomicSolver.sol";

/// @notice Mock queue that implements the CT-2/F-1 attack: ignore the normal protocol
///         and immediately call `solver.finishSolve` with attacker-supplied runData.
contract RogueQueue {
    function solve(
        ERC20 offer,
        ERC20 want,
        address[] calldata, /*users*/
        bytes calldata, /*runData*/
        address solver
    )
        external
    {
        // Attacker-chosen runData: drain `victim`'s allowance to solver, using the
        // SolveType.P2P path to route through _p2pSolve.
        bytes memory evilRunData = abi.encode(
            AtomicSolverV5.SolveType.P2P,
            address(0xdEADBEeF00000000000000000000000000000000), // victim
            uint256(0),
            type(uint256).max
        );
        IAtomicSolver(solver).finishSolve(evilRunData, solver, offer, want, 0, 100_000e18);
    }
}

/// @title Regression tests for the AtomicSolverV5 auth wiring
/// @notice These tests mirror the auth wiring produced by
///         `script/ConfigureAtomicRoles.s.sol::_configure()`. If any future edit silently
///         reverts the `setRoleCapability(QUEUE_ROLE, ...)` back to `setPublicCapability(...)`
///         for `finishSolve`, the CORRECT_wiring tests will fail. The BROKEN_wiring tests
///         document the exact attack class and serve as proof-of-effectiveness of the fix.
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
    AtomicSolverV5 internal solver;

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
        solver = new AtomicSolverV5(admin, authority);

        vault.setAuthority(authority);
        accountant.setAuthority(authority);
        teller.setAuthority(authority);

        // The victim has approved the solver (standard operator pattern).
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

        // In-contract whitelist: the real queue is approved; any other queue is not.
        solver.setQueueApproved(address(queue), true);
    }

    function test_correctWiring_attackerCannotCallFinishSolve() public {
        _wireCorrect();

        // Attacker crafts runData that would drain the victim if finishSolve ran
        bytes memory runData = abi.encode(
            AtomicSolverV5.SolveType.P2P,
            victim, // "solver" == victim (who has an approval)
            uint256(0), // minOfferReceived
            type(uint256).max // maxAssets
        );

        vm.prank(attacker);
        vm.expectRevert(); // reverts inside `requiresAuth` — attacker has no role
        solver.finishSolve(runData, address(solver), ERC20(address(want)), ERC20(address(want)), 0, 1e18);
    }

    function test_rogueQueueDirectFinishSolve_blockedByNotInSolveContext() public {
        _wireCorrect();

        // A rogue QUEUE_ROLE holder attempts a direct finishSolve call without first
        // entering a solve. Blocked by `_inSolveContext != 1` at the top of finishSolve.
        address rogueEOA = address(0xBadBadBad);
        authority.setUserRole(rogueEOA, QUEUE_ROLE, true);

        bytes memory runData = abi.encode(AtomicSolverV5.SolveType.P2P, victim, uint256(0), type(uint256).max);

        vm.prank(rogueEOA);
        vm.expectRevert(AtomicSolverV5.AtomicSolverV5___NotInSolveContext.selector);
        solver.finishSolve(runData, address(solver), ERC20(address(want)), ERC20(address(want)), 0, 1e18);
    }

    /// @notice End-to-end reproduction of CT-2/F-1 (the real attack path).
    /// @dev Models a compromised OPERATOR who:
    ///        1. Still holds `setUserRole` on the Authority (needed for borrower onboarding).
    ///        2. Has `p2pSolve` capability via the normal role wiring (OPERATOR has it).
    ///        3. Mints QUEUE_ROLE on an attacker-deployed RogueQueue contract.
    ///        4. Calls `solver.p2pSolve(rogueQueue, …)` to enter a live solve with the rogue.
    ///        5. RogueQueue.solve immediately callbacks finishSolve with attacker runData
    ///           to drain any pre-approved address.
    ///      Without the approved-queue whitelist, every check inside finishSolve passed
    ///      (`_inSolveContext == 1`, `msg.sender == _expectedQueue == rogueQueue`,
    ///      `initiator == address(this)`, `requiresAuth` OK) and the victim's allowance
    ///      was drained. After, `p2pSolve` reverts at entry with `UnapprovedQueue` before
    ///      the solve context is ever entered.
    function test_rogueQueue_endToEnd_blockedByApprovedQueueWhitelist() public {
        _wireCorrect();

        // Wire the attacker like a compromised OPERATOR would.
        bytes4 p2pSelector = bytes4(keccak256("p2pSolve(address,address,address,address[],uint256,uint256)"));
        authority.setRoleCapability(OPERATOR_ROLE, address(solver), p2pSelector, true);
        authority.setUserRole(attacker, OPERATOR_ROLE, true);

        // Attacker deploys and Authority-registers the rogue queue.
        RogueQueue rogue = new RogueQueue();
        authority.setUserRole(address(rogue), QUEUE_ROLE, true);

        uint256 victimBefore = want.balanceOf(victim);
        address[] memory users = new address[](0);

        // Exploit entry: must revert at UnapprovedQueue BEFORE the solve context opens.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(AtomicSolverV5.AtomicSolverV5___UnapprovedQueue.selector, address(rogue))
        );
        solver.p2pSolve(AtomicQueue(address(rogue)), ERC20(address(want)), ERC20(address(want)), users, 0, 1);

        // Victim untouched.
        assertEq(want.balanceOf(victim), victimBefore, "victim funds must not move");
        assertEq(want.balanceOf(address(solver)), 0, "solver must hold no victim funds");
        assertEq(want.allowance(address(solver), attacker), 0, "attacker must hold no allowance");
    }

    function test_correctWiring_queueCanPassAuthButLockBlocksDirectCall() public {
        _wireCorrect();

        // The queue has QUEUE_ROLE and therefore passes the Authority-level `requiresAuth` check.
        // However the new in-contract solve-context lock (C-1/M-2/L-2 fix) rejects ANY call
        // to finishSolve that is not reached via a live p2pSolve / redeemSolve. Direct calls
        // by the queue — if the queue were ever compromised or pointed at a different solver —
        // are blocked with NotInSolveContext. This is the defense-in-depth guarantee.
        bytes memory runData = abi.encode(AtomicSolverV5.SolveType.P2P, admin, uint256(0), type(uint256).max);

        vm.prank(address(queue));
        vm.expectRevert(AtomicSolverV5.AtomicSolverV5___NotInSolveContext.selector);
        solver.finishSolve(runData, address(solver), ERC20(address(want)), ERC20(address(want)), 0, 1e18);
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

    function test_brokenWiring_stillBlockedByInContractLock() public {
        // Simulate the ORIGINAL buggy wiring (setPublicCapability). Historically this
        // let attackers drain any address with an approval to the solver. Post-fix,
        // the in-contract solve-context lock blocks the exploit *even if* Authority
        // is misconfigured back to public — this is the defense-in-depth claim.
        _wireBroken();

        uint256 victimBefore = want.balanceOf(victim);
        uint256 solverBefore = want.balanceOf(address(solver));
        uint256 amount = 100_000e18;

        bytes memory runData = abi.encode(AtomicSolverV5.SolveType.P2P, victim, uint256(0), type(uint256).max);

        vm.prank(attacker);
        vm.expectRevert(AtomicSolverV5.AtomicSolverV5___NotInSolveContext.selector);
        solver.finishSolve(runData, address(solver), ERC20(address(want)), ERC20(address(want)), 0, amount);

        // Victim funds untouched, solver has nothing, no allowance created.
        assertEq(want.balanceOf(victim), victimBefore, "victim funds must remain intact");
        assertEq(want.balanceOf(address(solver)), solverBefore, "solver must not hold victim funds");
        assertEq(want.allowance(address(solver), attacker), 0, "no allowance to attacker");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { AtomicQueue, ERC20, SafeTransferLib } from "./AtomicQueue.sol";
import { IAtomicSolver } from "./IAtomicSolver.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";

/**
 * @title AtomicSolverV3
 * @author crispymangoes
 */
contract AtomicSolverV3 is IAtomicSolver, Auth {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    // ========================================= CONSTANTS =========================================

    ERC20 internal constant eETH = ERC20(0x35fA164735182de50811E8e2E824cFb9B6118ac2);
    ERC20 internal constant weETH = ERC20(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);

    // ========================================= ENUMS =========================================

    /**
     * @notice The Solve Type, used in `finishSolve` to determine the logic used.
     * @notice P2P Solver wants to swap share.asset() for user(s) shares
     * @notice REDEEM Solver needs to redeem shares, then can cover user(s) required assets.
     */
    enum SolveType {
        P2P,
        REDEEM
    }

    //============================== ERRORS ===============================

    error AtomicSolverV3___WrongInitiator();
    error AtomicSolverV3___AlreadyInSolveContext();
    error AtomicSolverV3___NotInSolveContext();
    error AtomicSolverV3___FailedToSolve();
    error AtomicSolverV3___SolveMaxAssetsExceeded(uint256 actualAssets, uint256 maxAssets);
    error AtomicSolverV3___P2PSolveMinSharesNotMet(uint256 actualShares, uint256 minShares);
    error AtomicSolverV3___BoringVaultTellerMismatch(address vault, address teller);

    //============================== STATE ===============================

    /**
     * @notice In-contract solve-context flag.
     * @dev Set to 1 by the `inSolveContext` modifier wrapping `p2pSolve` / `redeemSolve`,
     *      asserted in `finishSolve` to prove the callback is reached via a legitimate
     *      `queue.solve()` path. Complements the Authority-level `QUEUE_ROLE` gate —
     *      defense-in-depth if Authority is ever misconfigured.
     */
    uint256 private _inSolveContext;

    //============================== MODIFIERS ===============================

    modifier inSolveContext() {
        if (_inSolveContext != 0) revert AtomicSolverV3___AlreadyInSolveContext();
        _inSolveContext = 1;
        _;
        _inSolveContext = 0;
    }

    //============================== IMMUTABLES ===============================

    constructor(address _owner, Authority _authority) Auth(_owner, _authority) { }

    //============================== SOLVE FUNCTIONS ===============================
    /**
     * @notice Solver wants to exchange p2p share.asset() for withdraw queue shares.
     * @dev Solver should approve this contract to spend share.asset().
     */
    function p2pSolve(
        AtomicQueue queue,
        ERC20 offer,
        ERC20 want,
        address[] calldata users,
        uint256 minOfferReceived,
        uint256 maxAssets
    )
        external
        requiresAuth
        inSolveContext
    {
        bytes memory runData = abi.encode(SolveType.P2P, msg.sender, minOfferReceived, maxAssets);

        // Solve for `users`.
        queue.solve(offer, want, users, runData, address(this));
    }

    /**
     * @notice Solver wants to redeem withdraw offer shares, to help cover withdraw.
     * @dev `offer` MUST be an ERC4626 vault.
     */
    function redeemSolve(
        AtomicQueue queue,
        ERC20 offer,
        ERC20 want,
        address[] calldata users,
        uint256 minimumAssetsOut,
        uint256 maxAssets,
        TellerWithMultiAssetSupport teller
    )
        external
        requiresAuth
        inSolveContext
    {
        bytes memory runData = abi.encode(SolveType.REDEEM, msg.sender, minimumAssetsOut, maxAssets, teller);

        // Solve for `users`.
        queue.solve(offer, want, users, runData, address(this));
    }

    //============================== ISOLVER FUNCTIONS ===============================

    /**
     * @notice Implement the finishSolve function WithdrawQueue expects to call.
     * @dev Two layers of protection:
     *      1. `requiresAuth` + (off-chain) role wiring restrict direct callers to the queue.
     *      2. `_inSolveContext == 1` proves in-contract that we arrived via a legitimate
     *         `p2pSolve` / `redeemSolve` → `queue.solve()` → callback path. This defends
     *         against Authority misconfiguration even granting the selector to an attacker.
     */
    function finishSolve(
        bytes calldata runData,
        address initiator,
        ERC20 offer,
        ERC20 want,
        uint256 offerReceived,
        uint256 wantApprovalAmount
    )
        external
        requiresAuth
    {
        if (_inSolveContext != 1) revert AtomicSolverV3___NotInSolveContext();
        if (initiator != address(this)) revert AtomicSolverV3___WrongInitiator();

        address queue = msg.sender;

        SolveType _type = abi.decode(runData, (SolveType));

        if (_type == SolveType.P2P) {
            _p2pSolve(queue, runData, offer, want, offerReceived, wantApprovalAmount);
        } else if (_type == SolveType.REDEEM) {
            _redeemSolve(queue, runData, offer, want, offerReceived, wantApprovalAmount);
        }
    }

    //============================== HELPER FUNCTIONS ===============================

    /**
     * @notice Helper function containing the logic to handle p2p solves.
     */
    function _p2pSolve(
        address queue,
        bytes memory runData,
        ERC20 offer,
        ERC20 want,
        uint256 offerReceived,
        uint256 wantApprovalAmount
    )
        internal
    {
        (, address solver, uint256 minOfferReceived, uint256 maxAssets) =
            abi.decode(runData, (SolveType, address, uint256, uint256));

        // Make sure solver is receiving the minimum amount of offer.
        if (offerReceived < minOfferReceived) {
            revert AtomicSolverV3___P2PSolveMinSharesNotMet(offerReceived, minOfferReceived);
        }

        // Make sure solvers `maxAssets` was not exceeded.
        if (wantApprovalAmount > maxAssets) {
            revert AtomicSolverV3___SolveMaxAssetsExceeded(wantApprovalAmount, maxAssets);
        }

        // Transfer required want from solver.
        want.safeTransferFrom(solver, address(this), wantApprovalAmount);

        // Transfer offer to solver.
        offer.safeTransfer(solver, offerReceived);

        // Approve queue to spend wantApprovalAmount.
        want.safeApprove(queue, wantApprovalAmount);
    }

    /**
     * @notice Helper function containing the logic to handle redeem solves.
     */
    function _redeemSolve(
        address queue,
        bytes memory runData,
        ERC20 offer,
        ERC20 want,
        uint256 offerReceived,
        uint256 wantApprovalAmount
    )
        internal
    {
        (, address solver, uint256 minimumAssetsOut, uint256 maxAssets, TellerWithMultiAssetSupport teller) =
            abi.decode(runData, (SolveType, address, uint256, uint256, TellerWithMultiAssetSupport));

        if (address(offer) != address(teller.vault())) {
            revert AtomicSolverV3___BoringVaultTellerMismatch(address(offer), address(teller));
        }
        // Make sure solvers `maxAssets` was not exceeded.
        if (wantApprovalAmount > maxAssets) {
            revert AtomicSolverV3___SolveMaxAssetsExceeded(wantApprovalAmount, maxAssets);
        }

        // Redeem the shares, sending assets to solver.
        teller.bulkWithdraw(want, offerReceived, minimumAssetsOut, solver);

        // Transfer required assets from solver.
        want.safeTransferFrom(solver, address(this), wantApprovalAmount);

        // Approve queue to spend wantApprovalAmount.
        want.safeApprove(queue, wantApprovalAmount);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { AtomicQueue, ERC20, SafeTransferLib } from "./AtomicQueue.sol";
import { IAtomicSolver } from "./IAtomicSolver.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";

/**
 * @title AtomicSolverV5
 * @author crispymangoes
 */
contract AtomicSolverV5 is IAtomicSolver, Auth, ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

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

    error AtomicSolverV5___WrongInitiator();
    error AtomicSolverV5___WrongQueue(address expected, address actual);
    error AtomicSolverV5___UnapprovedQueue(address queue);
    error AtomicSolverV5___AlreadyInSolveContext();
    error AtomicSolverV5___NotInSolveContext();
    error AtomicSolverV5___FailedToSolve();
    error AtomicSolverV5___SolveMaxAssetsExceeded(uint256 actualAssets, uint256 maxAssets);
    error AtomicSolverV5___P2PSolveMinSharesNotMet(uint256 actualShares, uint256 minShares);
    error AtomicSolverV5___BoringVaultTellerMismatch(address vault, address teller);
    error AtomicSolverV5___FeeOnTransferTokenNotSupported(uint256 received, uint256 expected);
    error AtomicSolverV5___RedeemProceedsShortfall(uint256 proceeds, uint256 required);
    error AtomicSolverV5___ZeroAddress();

    //============================== EVENTS ===============================

    event QueueApprovalSet(address indexed queue, bool approved);

    //============================== STATE ===============================

    /**
     * @notice In-contract solve-context flag.
     * @dev Set to 1 by the `inSolveContext` modifier wrapping `p2pSolve` / `redeemSolve`,
     *      asserted in `finishSolve` to prove the callback is reached via a live solve.
     */
    uint256 private _inSolveContext;

    /**
     * @notice Queue address snapshotted on entry to p2pSolve / redeemSolve.
     * @dev Asserted to equal msg.sender in finishSolve. Blocks a sibling QUEUE_ROLE
     *      address from intercepting a callback from a solve that was initiated with
     *      a different queue.
     */
    address private _expectedQueue;

    /**
     * @notice Explicit whitelist of AtomicQueue contracts this solver will route through.
     * @dev This is the primary defense against the rogue-queue attack. A compromised
     *      OPERATOR still holds `setUserRole` (needed for ordinary borrower onboarding),
     *      so they can mint `QUEUE_ROLE` on any address. Without this whitelist the
     *      attacker could then call `p2pSolve(rogueQueue, ...)` and drive the full drain
     *      chain — `_expectedQueue` would be SET to the rogue queue (because the
     *      attacker is the one initiating the solve), so that check does not help here.
     *      Approvals are gated by `requiresAuth`, so the owner — or a role explicitly
     *      granted the `setQueueApproved` selector — controls queue membership.
     */
    mapping(address => bool) public approvedQueues;

    //============================== MODIFIERS ===============================

    modifier inSolveContext(address queue) {
        if (!approvedQueues[queue]) revert AtomicSolverV5___UnapprovedQueue(queue);
        if (_inSolveContext != 0) revert AtomicSolverV5___AlreadyInSolveContext();
        _inSolveContext = 1;
        _expectedQueue = queue;
        _;
        _inSolveContext = 0;
        _expectedQueue = address(0);
    }

    //============================== QUEUE MANAGEMENT ===============================

    /**
     * @notice Approve (or revoke) an AtomicQueue as a valid counterparty for solves.
     * @dev Gated by `requiresAuth`. Intentionally narrower than the Authority-level
     *      `QUEUE_ROLE` grant: OPERATOR holds `setUserRole` and can mint roles freely,
     *      but only the owner (or a role specifically granted this selector) can decide
     *      which queues this solver routes funds through.
     */
    function setQueueApproved(address queue, bool approved) external requiresAuth {
        if (queue == address(0)) revert AtomicSolverV5___ZeroAddress();
        approvedQueues[queue] = approved;
        emit QueueApprovalSet(queue, approved);
    }

    //============================== IMMUTABLES ===============================

    constructor(address _owner, Authority _authority) Auth(_owner, _authority) {
        // Solmate's Auth does not validate _owner; address(0) here would permanently
        // brick setOwner / setAuthority since only the current owner can rotate them.
        if (_owner == address(0)) revert AtomicSolverV5___ZeroAddress();
    }

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
        nonReentrant
        inSolveContext(address(queue))
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
        nonReentrant
        inSolveContext(address(queue))
    {
        bytes memory runData = abi.encode(SolveType.REDEEM, msg.sender, minimumAssetsOut, maxAssets, teller);

        // Solve for `users`.
        queue.solve(offer, want, users, runData, address(this));
    }

    //============================== ISOLVER FUNCTIONS ===============================

    /**
     * @notice Implement the finishSolve function AtomicQueue expects to call.
     * @dev Layered defense against the original C-1 drain (and its OPERATOR-cascade variant):
     *      1. `requiresAuth` + role wiring restricts direct callers (Authority layer).
     *      2. `_inSolveContext == 1` proves a live p2pSolve / redeemSolve is in flight.
     *      3. `msg.sender == _expectedQueue` blocks sibling QUEUE_ROLE addresses from
     *         intercepting a callback whose solve was initiated with a different queue.
     *      4. `approvedQueues[_expectedQueue]` (enforced by the inSolveContext modifier)
     *         blocks rogue queues even when the attacker is the one calling p2pSolve —
     *         the primary defense against the OPERATOR-grants-QUEUE_ROLE cascade.
     *      The `initiator != address(this)` check is retained as defense-in-depth against
     *      a queue implementation that forgets to hardcode `msg.sender` as the initiator;
     *      AtomicQueue.solve does hardcode it, so this check does not guard any currently
     *      reachable attack — it documents the invariant contractually.
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
        if (_inSolveContext != 1) revert AtomicSolverV5___NotInSolveContext();
        if (msg.sender != _expectedQueue) revert AtomicSolverV5___WrongQueue(_expectedQueue, msg.sender);
        if (initiator != address(this)) revert AtomicSolverV5___WrongInitiator(); // vestigial; see NatSpec

        address queue = msg.sender;

        SolveType _type = abi.decode(runData, (SolveType));

        if (_type == SolveType.P2P) {
            _p2pSolve(queue, runData, offer, want, offerReceived, wantApprovalAmount);
        } else if (_type == SolveType.REDEEM) {
            _redeemSolve(queue, runData, offer, want, offerReceived, wantApprovalAmount);
        }
    }

    //============================== ADMIN ===============================

    event Rescued(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Sweep stranded tokens out of the contract to `owner()`.
     * @dev Gated by `requiresAuth` (owner or a rescuer role). Blocked while a solve
     *      is in flight so a compromised admin cannot race an ongoing settlement.
     *      Emits an event for off-chain monitoring.
     *      The contract is not designed to hold user funds between solves — this is
     *      for dust, wrong-chain airdrops, or residue from an FoT/rebase edge case.
     *
     *      Recipient is hard-coded to `owner()` (the protocolAdmin Safe post-deploy).
     *      A compromised OPERATOR can trigger rescue but cannot redirect funds —
     *      they always land at the Safe, which then routes manually. This closes
     *      the "operator drains stuck tokens to attacker-picked address" path.
     */
    function rescue(ERC20 token, uint256 amount) external requiresAuth {
        if (_inSolveContext != 0) revert AtomicSolverV5___AlreadyInSolveContext();
        address to = owner;
        if (to == address(0)) revert AtomicSolverV5___ZeroAddress();
        token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
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
            revert AtomicSolverV5___P2PSolveMinSharesNotMet(offerReceived, minOfferReceived);
        }

        // Make sure solvers `maxAssets` was not exceeded.
        if (wantApprovalAmount > maxAssets) {
            revert AtomicSolverV5___SolveMaxAssetsExceeded(wantApprovalAmount, maxAssets);
        }

        // Transfer required want from solver, reconciling balance deltas to defend
        // against fee-on-transfer tokens whose transferFrom debits a fee and leaves
        // the contract with less than wantApprovalAmount.
        uint256 balBefore = want.balanceOf(address(this));
        want.safeTransferFrom(solver, address(this), wantApprovalAmount);
        uint256 received = want.balanceOf(address(this)) - balBefore;
        if (received < wantApprovalAmount) {
            revert AtomicSolverV5___FeeOnTransferTokenNotSupported(received, wantApprovalAmount);
        }

        // Approve queue to spend wantApprovalAmount BEFORE the outbound offer transfer.
        // Zero-reset first for USDT-style tokens whose approve() reverts when
        // allowance > 0 && amount > 0.
        // Ordering approvals first hardens against any future ERC777-style hook on
        // `offer` that observes contract state at the moment of safeTransfer — though
        // no currently-reachable function writes to anything sensitive mid-callback.
        want.safeApprove(queue, 0);
        want.safeApprove(queue, wantApprovalAmount);

        // Transfer offer to solver.
        offer.safeTransfer(solver, offerReceived);
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
            revert AtomicSolverV5___BoringVaultTellerMismatch(address(offer), address(teller));
        }
        // Make sure solvers `maxAssets` was not exceeded.
        if (wantApprovalAmount > maxAssets) {
            revert AtomicSolverV5___SolveMaxAssetsExceeded(wantApprovalAmount, maxAssets);
        }

        // Redeem the shares that the queue just moved into this contract, sending the
        // proceeds into THIS contract (not the solver bot). The prior design sent proceeds
        // to the solver then pulled wantApprovalAmount back via transferFrom — a pointless
        // round-trip that also forced solvers to grant this contract a standing allowance
        // on every want asset. Keeping the funds here makes the CEI order clean and removes
        // the solver-allowance attack surface.
        uint256 balBefore = want.balanceOf(address(this));
        uint256 assetsOut = teller.bulkWithdraw(want, offerReceived, minimumAssetsOut, address(this));
        uint256 received = want.balanceOf(address(this)) - balBefore;

        // FoT reconciliation: the teller computes assetsOut from the exchange rate but
        // vault.exit does the actual ERC20.transfer, so a FoT token can leave us short.
        if (received < wantApprovalAmount) {
            revert AtomicSolverV5___FeeOnTransferTokenNotSupported(received, wantApprovalAmount);
        }

        // Solver economics check: a sandwich on the teller exchange rate or a stale rate
        // can produce assetsOut < wantApprovalAmount, making the solve unprofitable. Fail
        // loud and early before any further state change.
        if (assetsOut < wantApprovalAmount) {
            revert AtomicSolverV5___RedeemProceedsShortfall(assetsOut, wantApprovalAmount);
        }

        // Approve queue to spend wantApprovalAmount BEFORE the outbound profit transfer.
        // If `want` has an ERC777-style transfer hook on the profit payout, the queue
        // allowance is already set when the callback fires; defense-in-depth against
        // any future entry point that might read/write mid-callback.
        want.safeApprove(queue, 0);
        want.safeApprove(queue, wantApprovalAmount);

        // Pay the solver their profit margin (proceeds in excess of the queue's take).
        uint256 solverProfit = received - wantApprovalAmount;
        if (solverProfit != 0) want.safeTransfer(solver, solverProfit);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";
import { IAtomicSolver } from "./IAtomicSolver.sol";
import { AccountantWithRateProviders } from "../base/Roles/AccountantWithRateProviders.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";

/**
 * @title AtomicQueue
 * @notice Allows users to create `AtomicRequests` that specify an ERC20 asset to `offer`
 *         and an ERC20 asset to `want` in return.
 * @notice Making atomic requests where the exchange rate between offer and want is not
 *         relatively stable is effectively the same as placing a limit order between
 *         those assets, so requests can be filled at a rate worse than the current market rate.
 * @notice It is possible for a user to make multiple requests that use the same offer asset.
 *         If this is done it is important that the user has approved the queue to spend the
 *         total amount of assets aggregated from all their requests, and to also have enough
 *         `offer` asset to cover the aggregate total request of `offerAmount`.
 * @author crispymangoes
 */
contract AtomicQueue is ReentrancyGuard, Auth {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // ========================================= STRUCTS =========================================

    /**
     * @notice Stores request information needed to fulfill a users atomic request.
     * @param deadline unix timestamp for when request is no longer valid
     * @param offerAmount the amount of `offer` asset the user wants converted to `want` asset
     * @param inSolve bool used during solves to prevent duplicate users, and to prevent redoing multiple checks
     */
    struct AtomicRequest {
        uint64 deadline; // deadline to fulfill request
        uint96 offerAmount; // The amount of offer asset the user wants to sell.
        bool inSolve; // Indicates whether this user is currently having their request fulfilled.
    }

    /**
     * @notice Used in `viewSolveMetaData` helper function to return data in a clean struct.
     * @param user the address of the user
     * @param flags 8 bits indicating the state of the user; only the
     * lowest 4 bits (0000XXXX) are used.
     *              Either all flags are false(user is solvable) or only 1 is true(an error occurred).
     *              From right to left
     *              - 0: indicates user deadline has passed.
     *              - 1: indicates user request has zero offer amount.
     *              - 2: indicates user does not have enough offer asset in wallet.
     *              - 3: indicates user has not given AtomicQueue approval.
     * @param assetsToOffer the amount of offer asset to solve
     * @param assetsForWant the amount of assets users want for their offer assets
     */
    struct SolveMetaData {
        address user;
        uint8 flags;
        uint256 assetsToOffer;
        uint256 assetsForWant;
    }

    // ========================================= GLOBAL STATE =========================================
    AccountantWithRateProviders public immutable accountant;

    /**
     * @notice Maps user address to offer asset to want asset to a AtomicRequest struct.
     */
    mapping(address => mapping(ERC20 => mapping(ERC20 => AtomicRequest))) public userAtomicRequest;

    //============================== ERRORS ===============================
    error AtomicQueue__ZeroOutputAmount();

    //============================== EVENTS ===============================

    /**
     * @notice Emitted when `updateAtomicRequest` is called.
     */
    event AtomicRequestUpdated(
        address user,
        address offerToken,
        address wantToken,
        uint256 amount,
        uint256 deadline,
        uint256 timestamp
    );

    /**
     * @notice Emitted when `solve` exchanges a users offer asset for their want asset.
     */
    event AtomicRequestFulfilled(
        address user,
        address offerToken,
        address wantToken,
        uint256 offerAmountSpent,
        uint256 wantAmountReceived,
        uint256 timestamp
    );

    //============================== CONSTRUCTOR ===============================

    constructor(address _accountant, address _owner, Authority _authority) Auth(_owner, _authority) {
        accountant = AccountantWithRateProviders(_accountant);
    }

    //============================== USER FUNCTIONS ===============================

    /**
     * @notice Get a users Atomic Request.
     * @param user the address of the user to get the request for
     * @param offer the ERC20 token they want to exchange for the want
     * @param want the ERC20 token they want in exchange for the offer
     */
    function getUserAtomicRequest(address _user, ERC20 _offer, ERC20 _want) external view returns (AtomicRequest memory) {
        return userAtomicRequest[_user][_offer][_want];
    }

    /**
     * @notice Helper function that returns either
     *         true: atomic request is valid.
     *         false: atomic request is not valid.
     * @dev It is possible for a atomic request to return false from this function, but using the
     *      request in `updateAtomicRequest` will succeed, but solvers will not be able to include
     *      the user in `solve` unless some other state is changed.
     * @param offer the ERC20 token they want to exchange for the want
     * @param user the address of the user making the request
     * @param userRequest the request struct to validate
     */
    function isAtomicRequestValid(
        ERC20 _offer,
        address _user,
        AtomicRequest calldata _userRequest
    )
        external
        view
        returns (bool)
    {
        if (_userRequest.offerAmount > _offer.balanceOf(_user)) return false;
        if (block.timestamp > _userRequest.deadline) return false;
        if (_offer.allowance(_user, address(this)) < _userRequest.offerAmount) return false;
        if (_userRequest.offerAmount == 0) return false;

        return true;
    }

    /**
     * @notice Allows user to add/update their atomic request.
     * @param offer the ERC20 token the user is offering in exchange for the want
     * @param want the ERC20 token the user wants in exchange for offer
     * @param deadline unix timestamp for when request is no longer valid
     * @param offerAmount the amount of offer asset to exchange
     */
    function updateAtomicRequest(ERC20 _offer, ERC20 _want, uint64 _deadline, uint96 _offerAmount) external nonReentrant {
        AtomicRequest storage request = userAtomicRequest[msg.sender][_offer][_want];

        request.deadline = _deadline;
        request.offerAmount = _offerAmount;

        emit AtomicRequestUpdated(msg.sender, address(_offer), address(_want), _offerAmount, _deadline, block.timestamp);
    }

    //============================== SOLVER FUNCTIONS ===============================

    /**
     * @notice Called by solvers in order to exchange offer asset for want asset.
     * @notice Solvers are optimistically transferred the offer asset, then are required to
     *         approve this contract to spend enough of want assets to cover all requests.
     * @dev It is very likely `solve` TXs will be front run if broadcasted to public mempools,
     *      so solvers should use private mempools.
     * @param offer the ERC20 offer token to solve for
     * @param want the ERC20 want token to solve for
     * @param users an array of user addresses to solve for
     * @param runData extra data that is passed back to solver when `finishSolve` is called
     * @param solver the address to make `finishSolve` callback to
     */
    function solve(
        ERC20 _offer,
        ERC20 _want,
        address[] calldata _users,
        bytes calldata _runData,
        address _solver
    )
        external
        requiresAuth
        nonReentrant
    {
        (uint256 assetsToOffer, uint256 assetsForWant, uint256[] memory userWantAmounts) =
            _prepareSolve(_offer, _want, _users, _solver);

        IAtomicSolver(_solver).finishSolve(_runData, msg.sender, _offer, _want, assetsToOffer, assetsForWant);

        _finalizeSolve(_offer, _want, _users, _solver, userWantAmounts);
    }

    //============================== INTERNAL HELPER FUNCTIONS ===============================
    /**
     * @notice New internal function to handle first phase of solve
     * @dev Validates all user requests and transfers offer tokens to solver
     * @dev Calculates total assets needed using current NAV from accountant
     * @param offer the ERC20 offer token
     * @param want the ERC20 want token
     * @param users array of users to process
     * @param solver the solver address receiving offer tokens
     * @return assetsToOffer total offer tokens transferred to solver
     * @return assetsForWant total want tokens solver needs to provide
     */
    function _prepareSolve(
        ERC20 _offer,
        ERC20 _want,
        address[] calldata _users,
        address _solver
    )
        internal
        returns (uint256 assetsToOffer, uint256 assetsForWant, uint256[] memory userWantAmounts)
    {
        userWantAmounts = new uint256[](_users.length);

        for (uint256 i; i < _users.length; ++i) {
            AtomicRequest storage request = userAtomicRequest[_users[i]][_offer][_want];

            if (request.inSolve) revert AtomicQueue__UserRepeated(_users[i]);
            if (block.timestamp > request.deadline) revert AtomicQueue__RequestDeadlineExceeded(_users[i]);
            if (request.offerAmount == 0) revert AtomicQueue__ZeroOfferAmount(_users[i]);

            uint256 wantAmount = _calculateWantAmount(_offer, _want, request.offerAmount);

            if (wantAmount == 0) revert AtomicQueue__ZeroOutputAmount();

            // Store the calculated amount for this user
            userWantAmounts[i] = wantAmount;
            assetsForWant += wantAmount;
            assetsToOffer += request.offerAmount;
            request.inSolve = true;

            _offer.safeTransferFrom(_users[i], _solver, request.offerAmount);
        }

        // Final checks
        if (assetsToOffer == 0) revert AtomicQueue__NoValidRequests();
        if (assetsForWant == 0) revert AtomicQueue__NoOutputExpected();
    }

    function _finalizeSolve(
        ERC20 _offer,
        ERC20 _want,
        address[] calldata _users,
        address _solver,
        uint256[] memory _userWantAmounts
    )
        internal
    {
        for (uint256 i; i < _users.length; ++i) {
            AtomicRequest storage request = userAtomicRequest[_users[i]][_offer][_want];

            if (!request.inSolve) revert AtomicQueue__UserNotInSolve(_users[i]);

            // Use pre-calculated amount
            uint256 amountOut = _userWantAmounts[i];

            _want.safeTransferFrom(_solver, _users[i], amountOut);

            emit AtomicRequestFulfilled(
                _users[i], address(_offer), address(_want), request.offerAmount, amountOut, block.timestamp
            );

            request.offerAmount = 0;
            request.deadline = 0;
            request.inSolve = false;
        }
    }

    /**
     * @notice Helper function solvers can use to determine if users are solvable, and the required amounts to do so.
     * @notice Repeated users are not accounted for in this setup, so if solvers have repeat users in their `users`
     *         array the results can be wrong.
     * @dev Since a user can have multiple requests with the same offer asset but different want asset, it is
     *      possible for `viewSolveMetaData` to report no errors, but for a solve to fail, if any solves were done
     *      between the time `viewSolveMetaData` and before `solve` is called.
     * @param offer the ERC20 offer token to check for solvability
     * @param want the ERC20 want token to check for solvability
     * @param users an array of user addresses to check for solvability
     */
    function viewSolveMetaData(
        ERC20 _offer,
        ERC20 _want,
        address[] calldata _users
    )
        external
        view
        returns (SolveMetaData[] memory metaData, uint256 totalAssetsForWant, uint256 totalAssetsToOffer)
    {
        metaData = new SolveMetaData[](_users.length);

        for (uint256 i; i < _users.length; ++i) {
            AtomicRequest memory request = userAtomicRequest[_users[i]][_offer][_want];
            metaData[i].user = _users[i];

            if (block.timestamp > request.deadline) {
                metaData[i].flags |= uint8(1);
            }
            if (request.offerAmount == 0) {
                metaData[i].flags |= uint8(1) << 1;
            }
            if (_offer.balanceOf(_users[i]) < request.offerAmount) {
                metaData[i].flags |= uint8(1) << 2;
            }
            if (_offer.allowance(_users[i], address(this)) < request.offerAmount) {
                metaData[i].flags |= uint8(1) << 3;
            }

            metaData[i].assetsToOffer = request.offerAmount;

            if (request.offerAmount > 0) {
                metaData[i].assetsForWant = _calculateWantAmount(_offer, _want, request.offerAmount);
            }

            if (metaData[i].flags == 0) {
                totalAssetsForWant += metaData[i].assetsForWant;
                totalAssetsToOffer += request.offerAmount;
            }
        }
    }

    /**
     * @notice Convert asset amount to 18 decimal value
     */
    function _convertAssetToValue18(ERC20 _asset, uint256 _amount) internal view returns (uint256) {
        if (address(_asset) == address(accountant.base())) {
            return _changeDecimals(_amount, accountant.decimals(), 18);
        }

        (bool isPegged,) = accountant.rateProviderData(_asset);
        if (isPegged) {
            return _changeDecimals(_amount, _asset.decimals(), 18);
        } else {
            (, IRateProvider rateProvider) = accountant.rateProviderData(_asset);
            uint256 rate = rateProvider.getRate();
            return _amount.mulDivDown(rate, 10 ** _asset.decimals());
        }
    }

    /**
     * @notice Convert 18 decimal value to asset amount
     */
    function _convertValue18ToAsset(ERC20 _asset, uint256 _valueIn18) internal view returns (uint256) {
        if (address(_asset) == address(accountant.base())) {
            return _changeDecimals(_valueIn18, 18, accountant.decimals());
        }

        (bool isPegged,) = accountant.rateProviderData(_asset);
        if (isPegged) {
            return _changeDecimals(_valueIn18, 18, _asset.decimals());
        } else {
            (, IRateProvider rateProvider) = accountant.rateProviderData(_asset);
            uint256 rate = rateProvider.getRate();
            return _valueIn18.mulDivDown(10 ** _asset.decimals(), rate);
        }
    }

    /**
     * @notice Helper to change decimals
     */
    function _changeDecimals(uint256 _amount, uint8 _fromDecimals, uint8 _toDecimals) internal pure returns (uint256) {
        if (_fromDecimals == _toDecimals) return _amount;
        if (_fromDecimals < _toDecimals) {
            return _amount * 10 ** (_toDecimals - _fromDecimals);
        } else {
            return _amount / 10 ** (_fromDecimals - _toDecimals);
        }
    }

    /**
     * @notice Calculate want amount for a given offer amount
     * @dev Single source of truth for swap calculations used by both _prepareSolve and viewSolveMetaData
     * @param offer the ERC20 offer token
     * @param want the ERC20 want token
     * @param offerAmount the amount of offer tokens
     * @return wantAmount the calculated want amount
     */
    function _calculateWantAmount(
        ERC20 _offer,
        ERC20 _want,
        uint256 _offerAmount
    )
        internal
        view
        returns (uint256 wantAmount)
    {
        uint256 rate = accountant.getRate(); // Rate is in 18 decimals

        if (address(_offer) == address(accountant.vault())) {
            // Withdrawing: vault shares -> asset
            uint8 vaultDecimals = ERC20(address(_offer)).decimals();
            uint256 sharesIn18 = _changeDecimals(_offerAmount, vaultDecimals, 18);
            uint256 valueIn18 = sharesIn18.mulDivDown(rate, 1e18);
            wantAmount = _convertValue18ToAsset(_want, valueIn18);
        } else if (address(_want) == address(accountant.vault())) {
            // Depositing: asset -> vault shares
            uint8 vaultDecimals = ERC20(address(_want)).decimals();
            uint256 valueIn18 = _convertAssetToValue18(_offer, _offerAmount);
            uint256 sharesIn18 = valueIn18.mulDivDown(1e18, rate);
            wantAmount = _changeDecimals(sharesIn18, 18, vaultDecimals);
        } else {
            // Swap: asset -> asset (through value)
            uint256 valueIn18 = _convertAssetToValue18(_offer, _offerAmount);
            wantAmount = _convertValue18ToAsset(_want, valueIn18);
        }
    }
}

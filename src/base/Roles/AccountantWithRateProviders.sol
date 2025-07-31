// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";

/**
 * @title AccountantWithRateProviders
 * @custom:security-contact security@molecularlabs.io
 */
contract AccountantWithRateProviders is Auth, IRateProvider {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    // ========================================= STRUCTS =========================================

    /**
     * @param payoutAddress the address `claimFees` sends fees to
     * @param feesOwedInBase total pending fees owed in terms of base
     * @param totalSharesLastUpdate total amount of shares the last exchange rate update
     * @param exchangeRate the current exchange rate in terms of base
     * @param _allowedExchangeRateChangeUpper the max allowed change to exchange rate from an update
     * @param _allowedExchangeRateChangeLower the min allowed change to exchange rate from an update
     * @param lastUpdateTimestamp the block timestamp of the last exchange rate update
     * @param isPaused whether or not this contract is paused
     * @param _minimumUpdateDelayInSeconds the minimum amount of time that must pass between
     *        exchange rate updates, such that the update won't trigger the contract to be paused
     * @param managementFee the management fee
     */
    struct AccountantState {
        address payoutAddress;
        uint128 feesOwedInBase;
        uint128 totalSharesLastUpdate;
        uint96 exchangeRate;
        uint16 _allowedExchangeRateChangeUpper;
        uint16 _allowedExchangeRateChangeLower;
        uint64 lastUpdateTimestamp;
        bool isPaused;
        uint32 _minimumUpdateDelayInSeconds;
        uint16 managementFee;
    }

    /**
     * @notice Lending specific state
     * @param lendingRate Annual lending interest rate in basis points (1000 = 10%)
     * @param lastAccrualTime Timestamp of last interest accrual
     */
    struct LendingInfo {
        uint256 lendingRate; // Rate for vault growth
        uint256 protocolFeeRate; // Management rate for protocol
        uint256 lastAccrualTime; // Last checkpoint
    }

    /**
     * @param isPeggedToBase whether or not the asset is 1:1 with the base asset
     * @param rateProvider the rate provider for this asset if `isPeggedToBase` is false
     */
    struct RateProviderData {
        bool isPeggedToBase;
        IRateProvider rateProvider;
    }

    // ========================================= CONSTANTS =========================================
    // Constants for calculations
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 constant BASIS_POINTS = 10_000;

    // ========================================= STATE =========================================

    /**
     * @notice Store the accountant state in 3 packed slots.
     */
    AccountantState public accountantState;
    LendingInfo public lendingInfo;
    uint256 public maxLendingRate;

    /**
     * @notice Maps ERC20s to their RateProviderData.
     */
    mapping(ERC20 => RateProviderData) public rateProviderData;

    //============================== ERRORS ===============================

    error AccountantWithRateProviders__UpperBoundTooSmall();
    error AccountantWithRateProviders__LowerBoundTooLarge();
    error AccountantWithRateProviders__ManagementFeeTooLarge();
    error AccountantWithRateProviders__Paused();
    error AccountantWithRateProviders__ZeroFeesOwed();
    error AccountantWithRateProviders__OnlyCallableByBoringVault();
    error AccountantWithRateProviders__UpdateDelayTooLarge();

    //============================== EVENTS ===============================

    event Paused();
    event Unpaused();
    event DelayInSecondsUpdated(uint32 oldDelay, uint32 newDelay);
    event UpperBoundUpdated(uint16 oldBound, uint16 newBound);
    event LowerBoundUpdated(uint16 oldBound, uint16 newBound);
    event ManagementFeeUpdated(uint16 oldFee, uint16 newFee);
    event PayoutAddressUpdated(address oldPayout, address newPayout);
    event RateProviderUpdated(address asset, bool isPegged, address rateProvider);
    event ExchangeRateUpdated(uint96 oldRate, uint96 newRate, uint64 currentTime);
    event FeesClaimed(address indexed _feeAsset, uint256 amount);
    event LendingRateUpdated(uint256 newRate, uint256 timestamp);
    event ProtocolFeeRateUpdated(uint256 newRate, uint256 timestamp);
    event MaxLendingRateUpdated(uint256 newMaxRate);

    //============================== IMMUTABLES ===============================

    /**
     * @notice The base asset rates are provided in.
     */
    ERC20 public immutable base;

    /**
     * @notice The decimals rates are provided in.
     */
    uint8 public immutable decimals;

    /**
     * @notice The BoringVault this accountant is working with.
     *         Used to determine share supply for fee calculation.
     */
    BoringVault public immutable vault;

    /**
     * @notice One share of the BoringVault.
     */
    uint256 internal immutable ONE_SHARE;

    constructor(
        address _owner,
        address _vault,
        address payoutAddress,
        uint96 startingExchangeRate,
        address _base,
        uint16 _allowedExchangeRateChangeUpper,
        uint16 _allowedExchangeRateChangeLower,
        uint32 _minimumUpdateDelayInSeconds,
        uint16 managementFee
    )
        Auth(_owner, Authority(address(0)))
    {
        base = ERC20(_base);
        decimals = ERC20(_base).decimals();
        vault = BoringVault(payable(_vault));
        ONE_SHARE = 10 ** vault.decimals();
        accountantState = AccountantState({
            payoutAddress: payoutAddress,
            feesOwedInBase: 0,
            totalSharesLastUpdate: uint128(vault.totalSupply()),
            exchangeRate: startingExchangeRate,
            _allowedExchangeRateChangeUpper: _allowedExchangeRateChangeUpper,
            _allowedExchangeRateChangeLower: _allowedExchangeRateChangeLower,
            lastUpdateTimestamp: uint64(block.timestamp),
            isPaused: false,
            _minimumUpdateDelayInSeconds: _minimumUpdateDelayInSeconds,
            managementFee: managementFee
        });
        lendingInfo.lastAccrualTime = block.timestamp;
        maxLendingRate = 5000;
    }

    // ========================================= ADMIN FUNCTIONS =========================================
    /**
     * @notice Pause this contract, which prevents future calls to `updateExchangeRate`, and any safe rate
     *         calls will revert.
     * @dev Pausing only prevents state changes, not time-based calculations
     * @dev Callable by MULTISIG_ROLE.
     */
    function pause() external requiresAuth {
        accountantState.isPaused = true;
        emit Paused();
    }

    /**
     * @notice Unpause this contract, which allows future calls to `updateExchangeRate`, and any safe rate
     *         calls will stop reverting.
     * @dev Callable by MULTISIG_ROLE.
     */
    function unpause() external requiresAuth {
        accountantState.isPaused = false;
        emit Unpaused();
    }

    /**
     * @notice Update the minimum time delay between `updateExchangeRate` calls.
     * @dev There are no input requirements, as it is possible the admin would want
     *      the exchange rate updated as frequently as needed.
     * @dev Callable by OWNER_ROLE.
     */
    function updateDelay(uint32 _minimumUpdateDelayInSeconds) external requiresAuth {
        if (_minimumUpdateDelayInSeconds > 14 days) revert AccountantWithRateProviders__UpdateDelayTooLarge();
        uint32 oldDelay = accountantState._minimumUpdateDelayInSeconds;
        accountantState._minimumUpdateDelayInSeconds = _minimumUpdateDelayInSeconds;
        emit DelayInSecondsUpdated(oldDelay, _minimumUpdateDelayInSeconds);
    }

    /**
     * @notice Update the allowed upper bound change of exchange rate between `updateExchangeRateCalls`.
     * @dev Callable by OWNER_ROLE.
     */
    function updateUpper(uint16 _allowedExchangeRateChangeUpper) external requiresAuth {
        if (_allowedExchangeRateChangeUpper < 1e4) revert AccountantWithRateProviders__UpperBoundTooSmall();
        uint16 oldBound = accountantState._allowedExchangeRateChangeUpper;
        accountantState._allowedExchangeRateChangeUpper = _allowedExchangeRateChangeUpper;
        emit UpperBoundUpdated(oldBound, _allowedExchangeRateChangeUpper);
    }

    /**
     * @notice Update the allowed lower bound change of exchange rate between `updateExchangeRateCalls`.
     * @dev Callable by OWNER_ROLE.
     */
    function updateLower(uint16 _allowedExchangeRateChangeLower) external requiresAuth {
        if (_allowedExchangeRateChangeLower > 1e4) revert AccountantWithRateProviders__LowerBoundTooLarge();
        uint16 oldBound = accountantState._allowedExchangeRateChangeLower;
        accountantState._allowedExchangeRateChangeLower = _allowedExchangeRateChangeLower;
        emit LowerBoundUpdated(oldBound, _allowedExchangeRateChangeLower);
    }

    /**
     * @notice Update the management fee to a new value.
     * @dev Callable by OWNER_ROLE.
     */
    function updateManagementFee(uint16 _managementFee) external requiresAuth {
        if (_managementFee > 0.2e4) revert AccountantWithRateProviders__ManagementFeeTooLarge();
        uint16 oldFee = accountantState.managementFee;
        accountantState.managementFee = _managementFee;
        emit ManagementFeeUpdated(oldFee, _managementFee);
    }

    /**
     * @notice Update the payout address fees are sent to.
     * @dev Callable by OWNER_ROLE.
     */
    function updatePayoutAddress(address _payoutAddress) external requiresAuth {
        address oldPayout = accountantState.payoutAddress;
        accountantState.payoutAddress = _payoutAddress;
        emit PayoutAddressUpdated(oldPayout, _payoutAddress);
    }

    /**
     * @notice Update the rate provider data for a specific `asset`.
     * @dev Rate providers must return rates in terms of `base` or
     * an asset pegged to base and they must use the same decimals
     * as `asset`.
     * @dev Callable by OWNER_ROLE.
     */
    function setRateProviderData(ERC20 _asset, bool _isPeggedToBase, address _rateProvider) external requiresAuth {
        rateProviderData[_asset] =
            RateProviderData({ isPeggedToBase: _isPeggedToBase, rateProvider: IRateProvider(_rateProvider) });
        emit RateProviderUpdated(address(_asset), _isPeggedToBase, _rateProvider);
    }

    // ========================================= UPDATE EXCHANGE RATE/FEES FUNCTIONS
    // =========================================

    /**
     * @notice Updates this contract exchangeRate.
     * @dev If new exchange rate is outside of accepted bounds, or if not enough time has passed, this
     *      will pause the contract, and this function will NOT calculate fees owed.
     * @dev Only checkpoints protocol fees, not interest (since we're manually setting the rate)
     * @dev Callable by UPDATE_EXCHANGE_RATE_ROLE.
     */
    function updateExchangeRate(uint96 _newExchangeRate) external requiresAuth {
        AccountantState storage state = accountantState;
        if (state.isPaused) revert AccountantWithRateProviders__Paused();

        uint64 currentTime = uint64(block.timestamp);
        (uint96 currentRateWithInterest,) = calculateExchangeRateWithInterest();

        // Now checkpoint protocol fees
        _checkpointProtocolFees();
        lendingInfo.lastAccrualTime = block.timestamp;

        uint256 currentTotalShares = vault.totalSupply();

        if (
            currentTime < state.lastUpdateTimestamp + state._minimumUpdateDelayInSeconds
                || _newExchangeRate
                    > uint256(currentRateWithInterest).mulDivDown(state._allowedExchangeRateChangeUpper, 1e4)
                || _newExchangeRate
                    < uint256(currentRateWithInterest).mulDivDown(state._allowedExchangeRateChangeLower, 1e4)
        ) {
            // Instead of reverting, pause the contract
            state.isPaused = true;
        } else {
            // Only update fees if we are not paused
            uint256 shareSupplyToUse = currentTotalShares;
            if (state.totalSharesLastUpdate < shareSupplyToUse) {
                shareSupplyToUse = state.totalSharesLastUpdate;
            }

            // Determine management fees owned (use stored rate for this calculation)
            uint256 timeDelta = currentTime - state.lastUpdateTimestamp;
            uint256 minimumAssets = _newExchangeRate > state.exchangeRate
                ? shareSupplyToUse.mulDivDown(state.exchangeRate, ONE_SHARE)
                : shareSupplyToUse.mulDivDown(_newExchangeRate, ONE_SHARE);
            uint256 managementFeesAnnual = minimumAssets.mulDivDown(state.managementFee, 1e4);
            uint256 newFeesOwedInBase = managementFeesAnnual.mulDivDown(timeDelta, 365 days);

            state.feesOwedInBase += uint128(newFeesOwedInBase);
        }

        state.exchangeRate = _newExchangeRate;
        state.totalSharesLastUpdate = uint128(currentTotalShares);
        state.lastUpdateTimestamp = currentTime;

        emit ExchangeRateUpdated(uint96(state.exchangeRate), _newExchangeRate, currentTime);
    }

    /**
     * @notice Set lending rate (expensive - requires checkpoint)
     * @dev Checkpoints current interest and protocol fees before changing rate
     * @dev This prevents loss of accrued value when rate changes
     * @param _lendingRate New lending rate in basis points (1000 = 10% APY)
     */
    function setLendingRate(uint256 _lendingRate) external requiresAuth {
        require(_lendingRate <= maxLendingRate, "Lending rate exceeds maximum");

        // Checkpoint both interest and fees before rate change
        _checkpointInterestAndFees();

        lendingInfo.lendingRate = _lendingRate;
        lendingInfo.lastAccrualTime = block.timestamp;
        emit LendingRateUpdated(_lendingRate, block.timestamp);
    }

    /**
     * @notice Set protocol fee rate (requires checkpoint)
     * @dev Checkpoints current protocol fees at old rate before changing
     * @dev This ensures fees are correctly attributed to each rate period
     * @param _protocolFeeRate New protocol fee rate in basis points
     */
    function setProtocolFeeRate(uint256 _protocolFeeRate) external requiresAuth {
        // Checkpoint protocol fees only (no interest impact)
        _checkpointProtocolFees();

        lendingInfo.protocolFeeRate = _protocolFeeRate;
        lendingInfo.lastAccrualTime = block.timestamp;
        emit ProtocolFeeRateUpdated(_protocolFeeRate, block.timestamp);
    }

    /**
     * @notice Set maximum lending rate
     * @dev Callable by OWNER_ROLE
     */
    function setMaxLendingRate(uint256 _maxLendingRate) external requiresAuth {
        maxLendingRate = _maxLendingRate;
        emit MaxLendingRateUpdated(_maxLendingRate);
    }

    /**
     * @notice Claim pending fees.
     * @dev This function must be called by the BoringVault.
     * @dev This function will lose precision if the exchange rate
     *      decimals is greater than the _feeAsset's decimals.
     */
    function claimFees(ERC20 _feeAsset) external {
        if (msg.sender != address(vault)) revert AccountantWithRateProviders__OnlyCallableByBoringVault();

        AccountantState storage state = accountantState;
        if (state.isPaused) revert AccountantWithRateProviders__Paused();

        // Checkpoint any unclaimed protocol fees
        _checkpointProtocolFees();
        lendingInfo.lastAccrualTime = block.timestamp;

        if (state.feesOwedInBase == 0) revert AccountantWithRateProviders__ZeroFeesOwed();

        // Determine amount of fees owed in _feeAsset
        uint256 feesOwedInFeeAsset;
        RateProviderData memory data = rateProviderData[_feeAsset];
        if (address(_feeAsset) == address(base)) {
            feesOwedInFeeAsset = state.feesOwedInBase;
        } else {
            uint8 feeAssetDecimals = ERC20(_feeAsset).decimals();
            uint256 feesOwedInBaseUsingFeeAssetDecimals =
                changeDecimals(state.feesOwedInBase, decimals, feeAssetDecimals);
            if (data.isPeggedToBase) {
                feesOwedInFeeAsset = feesOwedInBaseUsingFeeAssetDecimals;
            } else {
                uint256 rate = data.rateProvider.getRate();
                feesOwedInFeeAsset = feesOwedInBaseUsingFeeAssetDecimals.mulDivDown(10 ** feeAssetDecimals, rate);
            }
        }

        // Zero out fees owed
        state.feesOwedInBase = 0;

        // Transfer fee asset to payout address
        _feeAsset.safeTransferFrom(msg.sender, state.payoutAddress, feesOwedInFeeAsset);

        emit FeesClaimed(address(_feeAsset), feesOwedInFeeAsset);
    }

    // ========================================= RATE FUNCTIONS =========================================

    /**
     * @notice Get this BoringVault's current rate in the base (real-time with interest).
     */
    function getRate() public view returns (uint256 rate) {
        (uint96 currentRate,) = calculateExchangeRateWithInterest();
        return currentRate;
    }

    /**
     * @notice Calculate current exchange rate including accrued interest
     * @dev This is a view function - interest continues accruing even when paused
     * @return newRate The exchange rate including accrued interest
     * @return interestAccrued The amount of interest accrued since last checkpoint
     */
    function calculateExchangeRateWithInterest() public view returns (uint96 newRate, uint256 interestAccrued) {
        newRate = accountantState.exchangeRate;

        if (vault.totalSupply() > 0 && lendingInfo.lendingRate > 0) {
            uint256 timeElapsed = block.timestamp - lendingInfo.lastAccrualTime;

            // Calculate interest on total deposits
            uint256 totalDeposits = vault.totalSupply().mulDivDown(accountantState.exchangeRate, ONE_SHARE);
            interestAccrued =
                totalDeposits.mulDivDown(lendingInfo.lendingRate * timeElapsed, SECONDS_PER_YEAR * BASIS_POINTS);

            // Update rate (no fee deduction for lending model)
            uint256 totalSupply = vault.totalSupply();
            if (totalSupply > 0) {
                uint256 rateIncrease = interestAccrued.mulDivDown(ONE_SHARE, totalSupply);
                newRate += uint96(rateIncrease);
            }
        }
    }

    /**
     * @notice Get this BoringVault's current rate in the base.
     * @dev Revert if paused.
     */
    function getRateSafe() external view returns (uint256 rate) {
        if (accountantState.isPaused) revert AccountantWithRateProviders__Paused();
        (uint96 currentRate,) = calculateExchangeRateWithInterest();
        rate = currentRate;
    }

    /**
     * @notice Get this BoringVault's current rate in the provided quote.
     * @dev `quote` must have its RateProviderData set, else this will revert.
     * @dev This function will lose precision if the exchange rate
     *      decimals is greater than the _quote's decimals.
     */
    function getRateInQuote(ERC20 _quote) public view returns (uint256 rateInQuote) {
        // Get real-time rate first
        (uint96 currentRate,) = calculateExchangeRateWithInterest();

        if (address(_quote) == address(base)) {
            rateInQuote = currentRate;
        } else {
            RateProviderData memory data = rateProviderData[_quote];
            uint8 quoteDecimals = ERC20(_quote).decimals();
            uint256 exchangeRateInQuoteDecimals = changeDecimals(currentRate, decimals, quoteDecimals);
            if (data.isPeggedToBase) {
                rateInQuote = exchangeRateInQuoteDecimals;
            } else {
                uint256 quoteRate = data.rateProvider.getRate();
                uint256 oneQuote = 10 ** quoteDecimals;
                rateInQuote = oneQuote.mulDivDown(exchangeRateInQuoteDecimals, quoteRate);
            }
        }
    }

    /**
     * @notice Get this BoringVault's current rate in the provided quote.
     * @dev `quote` must have its RateProviderData set, else this will revert.
     * @dev Revert if paused.
     */
    function getRateInQuoteSafe(ERC20 _quote) external view returns (uint256 rateInQuote) {
        if (accountantState.isPaused) revert AccountantWithRateProviders__Paused();
        rateInQuote = getRateInQuote(_quote);
    }

    /**
     * @notice Get total rate paid by borrower
     * @dev This is the sum of lending rate (for depositors) and protocol fee rate
     * @return Total borrower rate in basis points
     */
    function getBorrowerRate() public view returns (uint256) {
        return lendingInfo.lendingRate + lendingInfo.protocolFeeRate;
    }

    /**
     * @notice Preview total protocol fees owed including unclaimed
     * @dev Calculates real-time fees without modifying state
     * @dev Includes both stored fees and fees accrued since last checkpoint
     * @return totalFees Total protocol fees owed in base asset
     */
    function previewFeesOwed() external view returns (uint256 totalFees) {
        totalFees = accountantState.feesOwedInBase;

        // Add unclaimed protocol fees
        if (vault.totalSupply() > 0 && lendingInfo.protocolFeeRate > 0) {
            uint256 timeElapsed = block.timestamp - lendingInfo.lastAccrualTime;
            uint256 totalDeposits = vault.totalSupply().mulDivDown(accountantState.exchangeRate, ONE_SHARE);
            uint256 protocolFees =
                totalDeposits.mulDivDown(lendingInfo.protocolFeeRate * timeElapsed, SECONDS_PER_YEAR * BASIS_POINTS);
            totalFees += protocolFees;
        }
    }

    // ========================================= INTERNAL HELPER FUNCTIONS =========================================
    /**
     * @notice Checkpoint protocol fees only
     * @dev Updates feesOwedInBase with accrued protocol fees
     */
    function _checkpointProtocolFees() internal {
        if (vault.totalSupply() > 0 && lendingInfo.protocolFeeRate > 0) {
            uint256 timeElapsed = block.timestamp - lendingInfo.lastAccrualTime;
            if (timeElapsed > 0) {
                uint256 totalDeposits = vault.totalSupply().mulDivDown(accountantState.exchangeRate, ONE_SHARE);
                uint256 protocolFees =
                    totalDeposits.mulDivDown(lendingInfo.protocolFeeRate * timeElapsed, SECONDS_PER_YEAR * BASIS_POINTS);
                accountantState.feesOwedInBase += uint128(protocolFees);
            }
        }
    }

    /**
     * @notice Checkpoint both interest and protocol fees
     * @dev Updates exchange rate with interest and feesOwedInBase with protocol fees
     */
    function _checkpointInterestAndFees() internal {
        if (vault.totalSupply() > 0 && lendingInfo.lendingRate > 0) {
            uint256 timeElapsed = block.timestamp - lendingInfo.lastAccrualTime;
            if (timeElapsed > 0) {
                uint256 totalDeposits = vault.totalSupply().mulDivDown(accountantState.exchangeRate, ONE_SHARE);

                // Calculate and apply interest to exchange rate
                uint256 interestAccrued =
                    totalDeposits.mulDivDown(lendingInfo.lendingRate * timeElapsed, SECONDS_PER_YEAR * BASIS_POINTS);

                if (interestAccrued > 0) {
                    uint256 rateIncrease = interestAccrued.mulDivDown(ONE_SHARE, vault.totalSupply());
                    accountantState.exchangeRate += uint96(rateIncrease);
                }

                // Calculate and store protocol fees
                uint256 protocolFees =
                    totalDeposits.mulDivDown(lendingInfo.protocolFeeRate * timeElapsed, SECONDS_PER_YEAR * BASIS_POINTS);
                accountantState.feesOwedInBase += uint128(protocolFees);
            }
        }
    }

    /**
     * @notice Used to change the decimals of precision used for an amount.
     */
    function changeDecimals(uint256 _amount, uint8 _fromDecimals, uint8 _toDecimals) internal pure returns (uint256) {
        if (_fromDecimals == _toDecimals) {
            return _amount;
        } else if (_fromDecimals < _toDecimals) {
            return _amount * 10 ** (_toDecimals - _fromDecimals);
        } else {
            return _amount / 10 ** (_fromDecimals - _toDecimals);
        }
    }
}

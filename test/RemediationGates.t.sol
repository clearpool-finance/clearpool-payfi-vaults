// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { Test } from "@forge-std/Test.sol";
import { Authority, RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MockERC20 } from "@solmate/test/utils/mocks/MockERC20.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { CrossChainTellerBase, BridgeData } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";

/// @notice Mock rate provider that returns a fixed rate set at construction or via `setRate`.
contract MockRateProvider is IRateProvider {
    uint256 public rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }
}

/// @notice Returns a safe rate to Accountant but an inflated rate to direct runtime callers.
contract CallerSensitiveRateProvider is IRateProvider {
    address internal immutable accountant;
    address internal immutable teller;
    address internal immutable queue;
    uint256 internal immutable safeRate;
    uint256 internal immutable inflatedRate;

    constructor(address _accountant, address _teller, address _queue, uint256 _safeRate, uint256 _inflatedRate) {
        accountant = _accountant;
        teller = _teller;
        queue = _queue;
        safeRate = _safeRate;
        inflatedRate = _inflatedRate;
    }

    function getRate() external view returns (uint256) {
        if (msg.sender == accountant) return safeRate;
        if (msg.sender == teller || msg.sender == queue) return inflatedRate;
        return safeRate;
    }
}

/// @notice Concrete teller that exposes `_beforeReceive` externally so the receive-pause
/// gate can be exercised without setting up a live LayerZero / Hyperlane / OP relayer.
/// Stubs every abstract bridge primitive — outbound bridge isn't tested here.
contract ExposedCrossChainTeller is CrossChainTellerBase {
    constructor(address _owner, address _vault, address _accountant)
        CrossChainTellerBase(_owner, _vault, _accountant)
    { }

    function exposed_beforeReceive() external {
        _beforeReceive();
    }

    function _bridge(uint256, BridgeData calldata) internal pure override returns (bytes32) {
        revert("not implemented");
    }

    function _quote(uint256, BridgeData calldata) internal pure override returns (uint256) {
        return 0;
    }

    function _beforeBridge(BridgeData calldata) internal pure override { }
}

/// @notice Negative-path tests for the security-tightening gates that lacked direct
/// regression coverage in the existing suite. Each test exercises one revert path that
/// `CheckAuthConfiguration` / on-chain logic relies on.
contract RemediationGatesTest is Test {
    BoringVault internal vault;
    AccountantWithRateProviders internal accountant;
    TellerWithMultiAssetSupport internal teller;
    RolesAuthority internal authority;

    MockERC20 internal base;
    MockERC20 internal otherAsset;

    address internal admin = address(this);
    address internal payout = vm.addr(0xBEEF);
    address internal user = vm.addr(0xCAFE);

    uint8 internal constant ADMIN_ROLE = 1;
    uint8 internal constant TELLER_ROLE = 3;
    uint8 internal constant SOLVER_ROLE = 5;
    uint8 internal constant PAUSER_ROLE = 6;

    function setUp() public {
        base = new MockERC20("Base", "BASE", 18);
        otherAsset = new MockERC20("Other", "OTH", 18);

        vault = new BoringVault(admin, "Test Vault", "TV", 18);
        accountant = new AccountantWithRateProviders(
            admin,
            address(vault),
            payout,
            1e18, // exchangeRate
            address(base),
            10_030, // upper +0.3%
            9970, //  lower -0.3%
            1, // delay
            0 // managementFee
        );
        teller = new TellerWithMultiAssetSupport(admin, address(vault), address(accountant));
        authority = new RolesAuthority(admin, Authority(address(0)));

        vault.setAuthority(authority);
        accountant.setAuthority(authority);
        teller.setAuthority(authority);

        // Minimal capability matrix — only what the negative tests need.
        authority.setRoleCapability(TELLER_ROLE, address(vault), BoringVault.enter.selector, true);
        authority.setRoleCapability(TELLER_ROLE, address(vault), BoringVault.exit.selector, true);
        authority.setRoleCapability(
            TELLER_ROLE, address(accountant), AccountantWithRateProviders.checkpoint.selector, true
        );
        authority.setRoleCapability(ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.bulkDeposit.selector, true);
        authority.setRoleCapability(ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.pause.selector, true);
        authority.setRoleCapability(ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.addAsset.selector, true);
        authority.setRoleCapability(
            ADMIN_ROLE, address(teller), TellerWithMultiAssetSupport.setDepositCap.selector, true
        );
        authority.setPublicCapability(address(teller), TellerWithMultiAssetSupport.deposit.selector, true);

        authority.setUserRole(admin, ADMIN_ROLE, true);
        authority.setUserRole(address(teller), TELLER_ROLE, true);

        teller.addAsset(base);
        teller.setDepositCap(type(uint256).max);
        accountant.setRateProviderData(base, true, address(0));
    }

    // ------------------------------------------------------------------
    // N-4: BoringVault.enter rejects non-contract assets
    // ------------------------------------------------------------------

    function test_N4_enterRevertsWhenAssetIsNotContract() public {
        // Approve a future-EOA address as the "asset" — `code.length == 0`.
        ERC20 phantom = ERC20(vm.addr(0xDEADBEEF));

        // Direct vault.enter call as a privileged user (admin holds no role here, so
        // grant TELLER_ROLE for the call surface).
        authority.setUserRole(admin, TELLER_ROLE, true);

        vm.expectRevert(abi.encodeWithSelector(BoringVault.BoringVault__AssetNotContract.selector, address(phantom)));
        vault.enter(admin, phantom, 1e18, admin, 1e18);
    }

    function test_N4_enterAcceptsRealContract() public {
        // Sanity: a real ERC20 contract works (rules out the check matching too broadly).
        authority.setUserRole(admin, TELLER_ROLE, true);
        deal(address(base), admin, 1e18);
        base.approve(address(vault), 1e18);
        vault.enter(admin, base, 1e18, admin, 1e18);
        assertEq(vault.balanceOf(admin), 1e18);
    }

    // ------------------------------------------------------------------
    // T-7: bulkDeposit reverts when teller is paused
    // ------------------------------------------------------------------

    function test_T7_bulkDepositRevertsWhenPaused() public {
        teller.pause();
        deal(address(base), admin, 1e18);
        base.approve(address(vault), 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__Paused.selector)
        );
        teller.bulkDeposit(base, 1e18, 0, admin);
    }

    function test_T7_bulkDepositAllowedWhenUnpaused() public {
        // Sanity baseline.
        deal(address(base), admin, 1e18);
        base.approve(address(vault), 1e18);
        uint256 shares = teller.bulkDeposit(base, 1e18, 0, admin);
        assertGt(shares, 0);
    }

    // ------------------------------------------------------------------
    // N-2: isReceivePaused gates _beforeReceive independently of isPaused
    // ------------------------------------------------------------------

    function test_N2_receivePauseGatesReceiveButNotIndependentOfDepositPause() public {
        ExposedCrossChainTeller xt = new ExposedCrossChainTeller(admin, address(vault), address(accountant));
        xt.setAuthority(authority);
        authority.setRoleCapability(ADMIN_ROLE, address(xt), TellerWithMultiAssetSupport.pause.selector, true);
        authority.setRoleCapability(ADMIN_ROLE, address(xt), TellerWithMultiAssetSupport.unpause.selector, true);
        authority.setRoleCapability(ADMIN_ROLE, address(xt), TellerWithMultiAssetSupport.pauseReceive.selector, true);
        authority.setRoleCapability(ADMIN_ROLE, address(xt), TellerWithMultiAssetSupport.unpauseReceive.selector, true);

        // Default: both flags false → receive open.
        xt.exposed_beforeReceive();

        // Pause deposits ONLY → receive should still open (this is the whole point of N-2).
        xt.pause();
        xt.exposed_beforeReceive();
        xt.unpause();

        // Pause receives → receive reverts.
        xt.pauseReceive();
        vm.expectRevert(
            abi.encodeWithSelector(TellerWithMultiAssetSupport.TellerWithMultiAssetSupport__ReceivePaused.selector)
        );
        xt.exposed_beforeReceive();

        // Unpause receives → open again.
        xt.unpauseReceive();
        xt.exposed_beforeReceive();
    }

    // ------------------------------------------------------------------
    // A-3: setRateProviderData rejects >5% deviation from prior provider
    // ------------------------------------------------------------------

    function test_A3_replacingNonPeggedProviderRevertsOnExcessiveDeviation() public {
        MockRateProvider oldProvider = new MockRateProvider(1e18);
        accountant.setRateProviderData(otherAsset, false, address(oldProvider));

        // 6% increase (above the 5% cap)
        MockRateProvider attackerProvider = new MockRateProvider(1.06e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                AccountantWithRateProviders.AccountantWithRateProviders__RateProviderDeviationTooHigh.selector,
                uint256(1e18),
                uint256(1.06e18)
            )
        );
        accountant.setRateProviderData(otherAsset, false, address(attackerProvider));
    }

    function test_A3_replacingPeggedToNonPeggedRevertsOnExcessiveDeviation() public {
        // Prior pegged registration ⇒ effective old rate is 1e18 per the contract logic.
        accountant.setRateProviderData(otherAsset, true, address(0));

        // Attacker tries to install a non-pegged provider whose rate is 7% off — should revert.
        MockRateProvider attackerProvider = new MockRateProvider(1.07e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                AccountantWithRateProviders.AccountantWithRateProviders__RateProviderDeviationTooHigh.selector,
                uint256(1e18),
                uint256(1.07e18)
            )
        );
        accountant.setRateProviderData(otherAsset, false, address(attackerProvider));
    }

    function test_A3_replacingProviderRejectsZeroRate() public {
        MockRateProvider zeroProvider = new MockRateProvider(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AccountantWithRateProviders.AccountantWithRateProviders__RateProviderZeroRate.selector
            )
        );
        accountant.setRateProviderData(otherAsset, false, address(zeroProvider));
    }

    function test_A3_replacingProviderWithinCapSucceeds() public {
        MockRateProvider oldProvider = new MockRateProvider(1e18);
        accountant.setRateProviderData(otherAsset, false, address(oldProvider));

        // 4% increase (below the 5% cap) — should succeed.
        MockRateProvider newProvider = new MockRateProvider(1.04e18);
        accountant.setRateProviderData(otherAsset, false, address(newProvider));

        (bool isPegged, IRateProvider provider) = accountant.rateProviderData(otherAsset);
        assertFalse(isPegged);
        assertEq(address(provider), address(newProvider));
    }

    function test_A3_callerSensitiveProviderCannotInflateTellerDeposit() public {
        teller.addAsset(otherAsset);
        CallerSensitiveRateProvider provider =
            new CallerSensitiveRateProvider(address(accountant), address(teller), address(0), 1e18, 2e18);
        accountant.setRateProviderData(otherAsset, false, address(provider));

        deal(address(otherAsset), user, 1e18);
        vm.startPrank(user);
        otherAsset.approve(address(vault), 1e18);
        uint256 shares = teller.deposit(otherAsset, 1e18, 0);
        vm.stopPrank();

        assertEq(shares, 1e18, "Teller must price through Accountant context");
    }

    function test_A3_callerSensitiveProviderCannotInflateAtomicQueueQuote() public {
        AtomicQueue queue = new AtomicQueue(address(accountant), admin, authority);
        CallerSensitiveRateProvider provider =
            new CallerSensitiveRateProvider(address(accountant), address(0), address(queue), 1e18, 2e18);
        accountant.setRateProviderData(otherAsset, false, address(provider));

        deal(address(otherAsset), user, 1e18);
        vm.startPrank(user);
        otherAsset.approve(address(queue), 1e18);
        queue.updateAtomicRequest(otherAsset, ERC20(address(vault)), uint64(block.timestamp + 1 days), uint96(1e18));
        vm.stopPrank();

        address[] memory users = new address[](1);
        users[0] = user;
        (AtomicQueue.SolveMetaData[] memory metaData, uint256 totalAssetsForWant, uint256 totalAssetsToOffer) =
            queue.viewSolveMetaData(otherAsset, ERC20(address(vault)), users);

        assertEq(metaData[0].assetsForWant, 1e18, "Queue must price through Accountant context");
        assertEq(totalAssetsForWant, 1e18, "Queue total must use Accountant-context rate");
        assertEq(totalAssetsToOffer, 1e18);
    }

    // ------------------------------------------------------------------
    // A-4: updateUpper / updateLower hard caps
    // ------------------------------------------------------------------

    function test_A4_updateUpperRevertsAboveMaxCap() public {
        // 11000 is the cap (+10%). 11001 must revert.
        vm.expectRevert(
            abi.encodeWithSelector(AccountantWithRateProviders.AccountantWithRateProviders__UpperBoundTooLarge.selector)
        );
        accountant.updateUpper(11_001);
    }

    function test_A4_updateUpperAcceptsAtMaxCap() public {
        accountant.updateUpper(11_000);
    }

    function test_A4_updateLowerRevertsBelowMinCap() public {
        // 9000 is the floor (-10%). 8999 must revert.
        vm.expectRevert(
            abi.encodeWithSelector(AccountantWithRateProviders.AccountantWithRateProviders__LowerBoundTooSmall.selector)
        );
        accountant.updateLower(8999);
    }

    function test_A4_updateLowerAcceptsAtMinCap() public {
        accountant.updateLower(9000);
    }
}

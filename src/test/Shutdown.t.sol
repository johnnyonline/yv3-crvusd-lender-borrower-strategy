pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {IController} from "../interfaces/IController.sol";

contract ShutdownTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Report profit
        vm.prank(keeper);
        strategy.report();

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_emergencyWithdraw_maxUint(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Airdrop dust to withdraw properly
        airdrop(asset, address(strategy), 5);

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_manualWithdraw_noShutdown(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(1 days);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        uint256 ltv = strategy.getCurrentLTV();

        assertEq(ERC20(borrowToken).balanceOf(address(strategy)), 0);
        assertRelApproxEq(strategy.getCurrentLTV(), ltv, 10);

        uint256 balance = strategy.balanceOfLentAssets();

        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        strategy.manualWithdraw(address(borrowToken), balance);

        vm.prank(management);
        strategy.manualWithdraw(address(borrowToken), balance);

        // Lender vault liquidity can leave a small residual behind
        assertLe(strategy.balanceOfLentAssets(), balance / 1000, "!lent residual");
        assertRelApproxEq(ERC20(borrowToken).balanceOf(address(strategy)), balance, 10);
        assertRelApproxEq(strategy.getCurrentLTV(), ltv, 10);

        vm.expectRevert("!keeper");
        vm.prank(user);
        strategy.claimAndSellRewards();

        vm.prank(management);
        strategy.claimAndSellRewards();

        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        strategy.manualRepayDebt();

        vm.prank(management);
        strategy.manualRepayDebt();

        assertFalse(IController(strategy.CONTROLLER()).loan_exists(address(strategy)));
        assertEq(strategy.balanceOfCollateral(), 0);
        // Excess borrow token is settled at report now, so closing manually can leave dust behind
        assertLe(strategy.balanceOfLentAssets(), balance / 1000, "!lent dust");
        assertLe(ERC20(borrowToken).balanceOf(address(strategy)), balance / 1000, "!loose dust");
        assertEq(strategy.getCurrentLTV(), 0);
        assertFalse(strategy.loanExists());

        // Set the LTV to 1 so it doesn't lever up
        vm.startPrank(management);
        strategy.setLtvMultipliers(1, strategy.warningLTVMultiplier());
        vm.stopPrank();

        vm.prank(management);
        strategy.tend();

        // Make sure we were able to create a new loan after closing it
        assertTrue(IController(strategy.CONTROLLER()).loan_exists(address(strategy)));
        assertGt(strategy.balanceOfCollateral(), 0);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw par of the funds
        vm.prank(user);
        strategy.redeem(_amount / 2, user, user);

        assertRelApproxEq(asset.balanceOf(user), balanceBefore + (_amount / 2), 10);
    }

    function test_sweep(
        uint256 _amount
    ) public {
        address gov = strategy.GOV();
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        ERC20 stuck = ERC20(tokenAddrs["DAI"]);
        airdrop(asset, address(strategy), _amount);
        airdrop(ERC20(borrowToken), address(strategy), _amount);
        airdrop(stuck, address(strategy), _amount);

        vm.expectRevert();
        vm.prank(user);
        strategy.sweep(address(stuck));

        vm.expectRevert();
        vm.prank(management);
        strategy.sweep(address(stuck));

        // Sweep stuck token
        uint256 beforeBalance = stuck.balanceOf(gov);

        vm.prank(gov);
        strategy.sweep(address(stuck));

        assertEq(stuck.balanceOf(gov), beforeBalance + _amount, "stuck swept");

        // Cant sweep asset, borrow token or lender vault shares
        vm.expectRevert("!asset");
        vm.prank(gov);
        strategy.sweep(address(asset));

        vm.expectRevert("!asset");
        vm.prank(gov);
        strategy.sweep(borrowToken);

        address lenderVault = strategy.lenderVault();
        vm.expectRevert("!asset");
        vm.prank(gov);
        strategy.sweep(lenderVault);
    }

    // TODO: Add tests for any emergency function added.


}

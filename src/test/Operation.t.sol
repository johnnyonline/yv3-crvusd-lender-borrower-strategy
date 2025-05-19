// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {IBaseStrategy} from "@tokenized-strategy/interfaces/IBaseStrategy.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {IController, IControllerFactory} from "../interfaces/IControllerFactory.sol";
import {ILenderBorrower} from "../interfaces/ILenderBorrower.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        assertEq(strategy.CRVUSD_INDEX(), 0);
        assertEq(strategy.ASSET_INDEX(), 1);
        assertEq(strategy.AMM(), address(IControllerFactory(strategy.CONTROLLER_FACTORY()).get_amm(address(asset))));
        assertEq(
            strategy.CONTROLLER(),
            address(IControllerFactory(strategy.CONTROLLER_FACTORY()).get_controller(address(asset)))
        );
        assertEq(strategy.CONTROLLER_FACTORY(), 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC);
        assertEq(strategy.VAULT_APR_ORACLE(), 0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);
        assertEq(strategy.GOV(), gov);
        assertEq(strategy.getLiquidateCollateralFactor(), 0.9e18);
        assertFalse(strategy.loanExists());
        console2.log("borrow APR:", strategy.getNetBorrowApr(0));
        console2.log("reward APR:", strategy.getNetRewardApr(0));
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertEq(strategy.balanceOfCollateral(), _amount, "collateral");
        assertApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 3);
        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_profitableReport(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertGt(strategy.totalAssets(), _amount);

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_profitableReport_withFees(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertGt(strategy.totalAssets(), _amount);

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        vm.prank(performanceFeeRecipient);
        strategy.redeem(expectedShares, performanceFeeRecipient, performanceFeeRecipient);

        assertGe(asset.balanceOf(performanceFeeRecipient), expectedShares, "!perf fee out");
    }

    function test_manualRepayDebt(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertEq(strategy.balanceOfCollateral(), _amount, "collateral");
        assertApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 3);

        // Earn Interest
        skip(1 days);

        // lower LTV
        uint256 borrowed = strategy.balanceOfDebt();
        airdrop(ERC20(borrowToken), address(strategy), borrowed / 4);

        vm.expectRevert("!emergency authorized");
        strategy.manualRepayDebt();

        vm.prank(management);
        strategy.manualRepayDebt();

        assertLt(strategy.getCurrentLTV(), targetLTV);

        // Report profit
        vm.prank(keeper);
        strategy.report();

        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore, "!final balance");
    }

    function test_partialWithdraw_lowerLTV(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertEq(strategy.balanceOfCollateral(), _amount, "collateral");
        assertApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 3);

        // Earn Interest
        skip(1 days);

        // lower LTV
        uint256 borrowed = strategy.balanceOfDebt();
        airdrop(ERC20(borrowToken), address(strategy), borrowed / 4);

        vm.prank(management);
        strategy.manualRepayDebt();

        assertLt(strategy.getCurrentLTV(), targetLTV);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount / 2, user, user, 1);

        assertGe(asset.balanceOf(user), ((balanceBefore + (_amount / 2)) * 9_999) / MAX_BPS, "!final balance");
    }

    function test_leaveDebtBehind_realizesLoss(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        vm.startPrank(management);
        strategy.setLeaveDebtBehind(true);
        vm.stopPrank();

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertEq(strategy.balanceOfCollateral(), _amount, "collateral");
        assertApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 3);

        // Pay without earning
        skip(30 days);

        // override availableWithdrawLimit
        vm.mockCall(
            address(strategy),
            abi.encodeWithSelector(IBaseStrategy.availableWithdrawLimit.selector),
            abi.encode(type(uint256).max)
        );

        uint256 balanceBefore = asset.balanceOf(user);

        // Redeem all funds. Default maxLoss == 10_000.
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // We should not have got the full amount out.
        assertLt(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // make sure there's still debt
        assertGt(strategy.balanceOfDebt(), 0, "!debt");
        assertGt(strategy.balanceOfCollateral(), 0, "!collateral");
    }

    function test_dontLeaveDebtBehind_realizesLoss(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertEq(strategy.balanceOfCollateral(), _amount, "collateral");
        assertApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 3);

        // Earn Interest
        skip(1 days);

        // override availableWithdrawLimit
        vm.mockCall(
            address(strategy),
            abi.encodeWithSelector(IBaseStrategy.availableWithdrawLimit.selector),
            abi.encode(type(uint256).max)
        );

        // lose some lent
        vm.startPrank(address(strategy));
        ERC20(lenderVault).transfer(address(420), ERC20(lenderVault).balanceOf(address(strategy)) * 10 / 100);
        vm.stopPrank();

        vm.startPrank(emergencyAdmin);
        strategy.manualWithdraw(address(0), strategy.balanceOfCollateral() * 10 / 100);
        strategy.buyBorrowToken(type(uint256).max); // sell all loose collateral
        vm.stopPrank();

        assertGe(strategy.balanceOfLentAssets() + strategy.balanceOfBorrowToken(), strategy.balanceOfDebt(), "!lent");

        uint256 balanceBefore = asset.balanceOf(user);

        // Redeem all funds. Default maxLoss == 10_000.
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // We should not have got the full amount out.
        assertLt(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // make sure there's no debt
        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertEq(strategy.balanceOfCollateral(), 0, "!collateral");
    }

    function test_operation_overWarningLTV_depositLeversDown(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        // Withdrawl some collateral to pump LTV
        uint256 collToSell = strategy.balanceOfCollateral() * 20 / 100;
        vm.prank(emergencyAdmin);
        strategy.manualWithdraw(address(0), collToSell);

        uint256 warningLTV = (strategy.getLiquidateCollateralFactor() * strategy.warningLTVMultiplier()) / MAX_BPS;

        assertGt(strategy.getCurrentLTV(), warningLTV);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (bool trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Borrow too much.
        uint256 toBorrow = (
            strategy.balanceOfCollateral()
                * ((strategy.getLiquidateCollateralFactor() * (strategy.warningLTVMultiplier() + 100)) / MAX_BPS)
        ) / 1e18;

        toBorrow = _fromUsd(_toUsd(toBorrow, address(asset)), borrowToken);

        vm.startPrank(address(strategy));
        IController(strategy.CONTROLLER()).borrow_more(0, toBorrow - strategy.balanceOfDebt());
        vm.stopPrank();

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "warning ltv");

        // Even with a 0 for max Tend Base Fee its true
        vm.startPrank(management);
        strategy.setMaxGasPriceToTend(0);
        vm.stopPrank();

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "warning ltv 2");

        // Even with a 0 for max Tend Base Fee its true
        vm.startPrank(management);
        strategy.setMaxGasPriceToTend(200e9);
        vm.stopPrank();

        vm.prank(keeper);
        strategy.tend();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger, "post tend");

        vm.prank(keeper);
        strategy.report();

        // Lower LTV
        uint256 borrowed = strategy.balanceOfDebt();
        airdrop(ERC20(borrowToken), address(strategy), borrowed / 2);

        vm.prank(management);
        strategy.manualRepayDebt();

        assertLt(strategy.getCurrentLTV(), targetLTV);

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger, "post tend");

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);
    }

    function test_resetLoanExists(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertTrue(strategy.loanExists());

        vm.expectRevert("!exists");
        vm.prank(management);
        strategy.resetLoanExists();

        vm.expectRevert("!management");
        strategy.resetLoanExists();
    }
}

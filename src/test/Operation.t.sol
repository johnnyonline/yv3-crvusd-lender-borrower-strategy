// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {IBaseStrategy} from "@tokenized-strategy/interfaces/IBaseStrategy.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {IController, IControllerFactory} from "../interfaces/IControllerFactory.sol";
import {ILenderBorrower} from "../interfaces/ILenderBorrower.sol";
import {IVaultAPROracle} from "../interfaces/IVaultAPROracle.sol";

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
        console2.log("getLiquidateCollateralFactor: ", strategy.getLiquidateCollateralFactor());
        assertEq(strategy.getLiquidateCollateralFactor(), 0.89e18);
        assertFalse(strategy.loanExists());
        console2.log("borrow APR:", strategy.getNetBorrowApr(0));
        console2.log("reward APR:", strategy.getNetRewardApr(0));
    }

    function test_operation(
        uint256 _amount
    ) public {
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

    function test_profitableReport(
        uint256 _amount
    ) public {
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

    function test_profitableReport_withFees(
        uint256 _amount
    ) public {
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

    function test_manualRepayDebt(
        uint256 _amount
    ) public {
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

    function test_partialWithdraw_lowerLTV(
        uint256 _amount
    ) public {
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

    function test_leaveDebtBehind_realizesLoss(
        uint256 _amount
    ) public {
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

    function test_dontLeaveDebtBehind_realizesLoss(
        uint256 _amount
    ) public {
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

    function test_operation_overWarningLTV_depositLeversDown(
        uint256 _amount
    ) public {
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

    function test_tendTrigger(
        uint256 _amount
    ) public {
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

    function test_tendTrigger_noRewards(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (bool trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // (almost) zero out rewards
        vm.mockCall(
            address(strategy.VAULT_APR_ORACLE()),
            abi.encodeWithSelector(IVaultAPROracle.getExpectedApr.selector),
            abi.encode(1)
        );
        assertEq(strategy.getNetRewardApr(0), 1);

        // Now that it's unprofitable to borrow, we should tend
        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(management);
        strategy.setForceLeverage(true);

        assertTrue(strategy.forceLeverage());
        assertEq(strategy.getNetBorrowApr(0), 0);

        // Now that we force leverage, we should not tend
        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.expectRevert("!management");
        strategy.setForceLeverage(false);
    }

    function test_resetLoanExists(
        uint256 _amount
    ) public {
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

    function test_resetLoanExists_onFullRepayment(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check that the loan exists
        assertTrue(strategy.loanExists());

        // Airdrop so we can repay full debt
        uint256 borrowed = strategy.balanceOfDebt();
        airdrop(ERC20(borrowToken), address(strategy), borrowed / 4);

        // Withdraw lent assets and full repay debt
        vm.startPrank(management);
        strategy.manualWithdraw(borrowToken, type(uint256).max);
        strategy.manualRepayDebt();
        vm.stopPrank();

        // Check that the loan no longer exists and we reset the flag
        assertFalse(strategy.loanExists());
    }

    function test_closePositionFully_andOpenAgain(
        uint256 _amount
    ) public {
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

        // (almost) zero out rewards
        vm.mockCall(
            address(strategy.VAULT_APR_ORACLE()),
            abi.encodeWithSelector(IVaultAPROracle.getExpectedApr.selector),
            abi.encode(1)
        );
        assertEq(strategy.getNetRewardApr(0), 1);

        // Now that it's unprofitable to borrow, we should tend to close the position
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        // Airdrop dust so we can repay full debt
        airdrop(ERC20(borrowToken), address(strategy), 5);

        // Close the position
        vm.prank(management);
        strategy.tend();

        // Make sure the position is closed
        assertFalse(strategy.loanExists());

        // Pump rewards
        vm.mockCall(
            address(strategy.VAULT_APR_ORACLE()),
            abi.encodeWithSelector(IVaultAPROracle.getExpectedApr.selector),
            abi.encode(100e18)
        );
        assertEq(strategy.getNetRewardApr(0), 100e18);

        // Even though now it's profitable to borrow, tend trigger can't identify that
        (trigger,) = strategy.tendTrigger();
        assertFalse(trigger);

        // So report will lever back up
        vm.prank(keeper);
        strategy.report();

        // Make sure the position was reopened
        assertTrue(strategy.loanExists());
    }

    function test_softLiqDoesNotMeanHardLiq(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit some assets into the strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Get into SL, without price nuke
        simulateSoftLiquidation(false);

        // Make sure we distinguish between soft and hard liquidation
        assertFalse(isHardLiquidatable(), "isHardLiquidatable");
        assertTrue(isSoftLiquidatable(), "!isSoftLiquidatable");
    }

    function test_getIntoSL(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Go degen so we're closer to SL
        vm.prank(management);
        strategy.setLtvMultipliers(uint16(8900), uint16(9000));

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check LTV
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);

        // We are all set, shouldn't tend
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger);

        // Cache debt, collateral and current LTV balances before SL
        uint256 debtBeforeSL = strategy.balanceOfDebt();
        uint256 collBeforeSL = strategy.balanceOfCollateral();
        uint256 ltvBeforeSL = strategy.getCurrentLTV();

        // Get into SL, without price nuke, meaning we cannot hard liquidate, only soft
        simulateSoftLiquidation(false);

        // Check debt, collateral and LTV balances after SL
        assertEq(strategy.balanceOfDebt(), debtBeforeSL, "!same debt");
        assertLt(strategy.balanceOfCollateral(), collBeforeSL, "!same collateral"); // Some of the collateral was converted to crvUSD
        assertGt(strategy.getCurrentLTV(), ltvBeforeSL, "!tvl increased");
        assertGt(strategy.getCurrentLTV(), strategy.warningLTVMultiplier(), "!tvl above warning threshold");

        // Make sure we are not hard liquidatable but in SL
        assertFalse(isHardLiquidatable(), "isHardLiquidatable");
        assertTrue(isSoftLiquidatable(), "!isSoftLiquidatable");

        // SL'd, need to repay some debt
        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        // If we were not checking `_isLiquidatable` before `_supplyCollateral`, this would cause a revert on `tend` with "Already in underwater mode"
        airdrop(asset, address(strategy), 1);

        // Fix the position
        vm.prank(management);
        strategy.tend();

        // Check that we fixed the LTV
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
    }

    function test_getIntoHL(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Go degen so we're closer to HL
        vm.prank(management);
        strategy.setLtvMultipliers(uint16(8900), uint16(9000));

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check LTV
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);

        // We are all set, shouldn't tend
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger);

        // Cache debt, collateral and current LTV balances before HL
        uint256 debtBeforeHL = strategy.balanceOfDebt();
        uint256 collBeforeHL = strategy.balanceOfCollateral();
        uint256 ltvBeforeHL = strategy.getCurrentLTV();

        // Drop price to get into HL, we were not SL'd though
        nukePrice();

        // Check debt, collateral and LTV balances after HL
        assertEq(strategy.balanceOfDebt(), debtBeforeHL, "!same debt");
        assertEq(strategy.balanceOfCollateral(), collBeforeHL, "!same collateral"); // None of the collateral was converted to crvUSD
        assertGt(strategy.getCurrentLTV(), ltvBeforeHL, "!tvl increased");
        assertGt(strategy.getCurrentLTV(), strategy.warningLTVMultiplier(), "!tvl above warning threshold");

        // Make sure we are not hard liquidatable but in SL
        assertTrue(isHardLiquidatable(), "!isHardLiquidatable");
        assertFalse(isSoftLiquidatable(), "isSoftLiquidatable");

        // In HL, need to repay some debt
        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        // Just for shits and giggles. Though this might cause a revert on `_supplyCollateral` as well, if not for the `_isLiquidatable` check
        airdrop(asset, address(strategy), 1);

        // Fix the position
        vm.prank(management);
        strategy.tend();

        // Check that we fixed the LTV
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
    }

    function test_rateForTapir(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Update fee to latest
        IController(strategy.CONTROLLER()).collect_fees();

        // Cache borrow rate before deposit
        uint256 borrowRateBefore = strategy.getNetBorrowApr(0);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check that the borrow rate did not change after deposit
        assertEq(strategy.getNetBorrowApr(0), borrowRateBefore);
    }

}

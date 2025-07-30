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

    function test_getIntoSL_andBorrowingHappensToBeUnprofitable(
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

        // Cache debt, collateral and current LTV balances before SL
        uint256 debtBeforeSL = strategy.balanceOfDebt();
        uint256 collBeforeSL = strategy.balanceOfCollateral();
        uint256 ltvBeforeSL = strategy.getCurrentLTV();

        // Get into SL, without price nuke, meaning we cannot hard liquidate, only soft
        simulateSoftLiquidation(false);

        // Sanity check that we still need to tend
        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        // Check debt, collateral and LTV balances after SL
        assertEq(strategy.balanceOfDebt(), debtBeforeSL, "!same debt");
        assertLt(strategy.balanceOfCollateral(), collBeforeSL, "!same collateral"); // Some of the collateral was converted to crvUSD
        assertGt(strategy.getCurrentLTV(), ltvBeforeSL, "!tvl increased");
        assertGt(strategy.getCurrentLTV(), strategy.warningLTVMultiplier(), "!tvl above warning threshold");

        // Make sure we are not hard liquidatable but in SL
        assertFalse(isHardLiquidatable(), "isHardLiquidatable");
        assertTrue(isSoftLiquidatable(), "!isSoftLiquidatable");

        // If we were not checking `_isLiquidatable` before `_supplyCollateral`, this would cause a revert on `tend` with "Already in underwater mode"
        airdrop(asset, address(strategy), 1);

        // Airdrop dust so we can repay debt fully
        airdrop(ERC20(borrowToken), address(strategy), 3);

        // Unwind the position since it's not profitable to borrow now
        vm.prank(management);
        strategy.tend();

        // Check that we fixed the LTV
        assertEq(strategy.getCurrentLTV(), 0, "LTV should be 0 since it's not profitable to borrow");

        // Double check the current debt, collateral, and that a loan does not exist
        assertEq(strategy.balanceOfDebt(), 0, "debt should be 0");
        assertEq(strategy.balanceOfCollateral(), 0, "collateral should be 0");
        assertFalse(strategy.loanExists(), "loan should not exist");

        // Check we got some crvUSD when we repayed the debt, since we were in SL
        assertGt(strategy.balanceOfBorrowToken(), 0, "should have some crvUSD idle");

        // Show that tend trigger does not catch that we need to `claimAndSellRewards()` and re-lever, through a report
        (trigger,) = strategy.tendTrigger();
        assertFalse(trigger);

        // Allow loss
        vm.prank(management);
        strategy.setDoHealthCheck(false);

        // Report -- Sell the crvUSD
        vm.prank(keeper);
        strategy.report();

        // Check we sold all the crvUSD
        assertApproxEq(strategy.balanceOfBorrowToken(), 0, 1, "shouldnt have some crvUSD idle");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertRelApproxEq(asset.balanceOf(user), balanceBefore + _amount, 100); // not more than 1% loss
    }

    function test_getIntoSL_cantWithdraw(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Go degen so we're closer to SL
        vm.prank(management);
        strategy.setLtvMultipliers(uint16(8900), uint16(9000));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Get into SL, without price nuke, meaning we cannot hard liquidate, only soft
        simulateSoftLiquidation(false);

        // Make sure can't withdraw if we are in SL
        assertEq(strategy.availableWithdrawLimit(user), 0, "!available withdraw limit");
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

        // SL'd, we need to close the position
        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        // Airdrop dust so we can repay debt fully
        airdrop(ERC20(borrowToken), address(strategy), 3);

        // Close the position
        vm.prank(management);
        strategy.tend();

        // Make sure we are not liquidatable anymore
        assertFalse(isHardLiquidatable(), "isHardLiquidatable");
        assertFalse(isSoftLiquidatable(), "isSoftLiquidatable");

        // Check some stuff now
        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertEq(strategy.balanceOfCollateral(), 0, "!collateral");
        assertGt(strategy.balanceOfAsset(), 0, "!asset"); // We should have some `asset` collateral, the rest is in crvUSD
        assertApproxEq(strategy.balanceOfLentAssets(), 0, 3, "!lent"); // We should have used everything to repay the debt
        assertGt(strategy.balanceOfBorrowToken(), 0, "!borrowToken"); // Some of the collateral was converted to crvUSD
        assertEq(strategy.getCurrentLTV(), 0, "!tvl");
        assertFalse(strategy.loanExists(), "!loanExists");
    }

    function test_depositWhenInSL(
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

        // Cache debt, collateral and current LTV balances before SL
        uint256 debtBeforeSL = strategy.balanceOfDebt();
        uint256 collBeforeSL = strategy.balanceOfCollateral();
        uint256 ltvBeforeSL = strategy.getCurrentLTV();

        // Cache total assets before SL
        uint256 totalAssetsBeforeSL = strategy.totalAssets();

        // Get into SL, without price nuke, meaning we cannot hard liquidate, only soft
        simulateSoftLiquidation(false);

        uint256 balanceOfDebtAfterSL_beforeDeposit = strategy.balanceOfDebt();

        // Check debt, collateral and LTV balances after SL
        assertEq(balanceOfDebtAfterSL_beforeDeposit, debtBeforeSL, "!same debt");
        assertLt(strategy.balanceOfCollateral(), collBeforeSL, "!same collateral"); // Some of the collateral was converted to crvUSD
        assertGt(strategy.getCurrentLTV(), ltvBeforeSL, "!tvl increased");
        assertGt(strategy.getCurrentLTV(), strategy.warningLTVMultiplier(), "!tvl above warning threshold");

        // Check total assets after SL
        assertEq(strategy.totalAssets(), totalAssetsBeforeSL, "!totalAssets");

        // Deposit again into strategy, while we are in SL
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check debt, collateral and LTV balances after SL and after another deposit
        assertLt(strategy.balanceOfDebt(), balanceOfDebtAfterSL_beforeDeposit, "!less debt"); // We repay some debt, bc balanceOfCollateral seems lower, as some was converted to crvUSD
        assertLt(strategy.balanceOfCollateral(), collBeforeSL, "!same collateral"); // Some of the collateral was converted to crvUSD
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000); // TVL should seem fixed now, as we repaid some debt

        // Check total assets after SL and after another deposit
        assertEq(strategy.totalAssets(), totalAssetsBeforeSL + _amount, "!totalAssets");
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

    function test_getHardLiquidated(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Make our lives a bit easier
        setFees(0, 0);

        // Go degen so we're closer to HL
        vm.prank(management);
        strategy.setLtvMultipliers(uint16(8900), uint16(9000));

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check LTV
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);

        // Get hard liquidated
        simulateHardLiquidation();

        // Check our position reports all zeros
        assertEq(strategy.balanceOfDebt(), 0);
        assertEq(strategy.balanceOfCollateral(), 0); // None of the collateral was converted to crvUSD
        assertEq(strategy.getCurrentLTV(), 0);
        assertEq(strategy.balanceOfCollateral(), 0);
        assertEq(strategy.balanceOfBorrowToken(), 0);

        // Check we still got our lent assets at least
        assertGt(strategy.balanceOfLentAssets(), 0);

        // Check users can deposit
        assertGt(strategy.availableDepositLimit(user), 0);

        // Show our strategy is still not aware that we don't have a loan anymore
        assertTrue(strategy.loanExists());

        // We don't want to tend
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger);

        // Allow loss
        vm.prank(management);
        strategy.setDoHealthCheck(false);

        // Reset the loanExists flag manually
        vm.prank(management);
        strategy.resetLoanExists();

        // Report the loss, sell the lent assets, and get back out there (relever)
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertGe(loss, 0, "!loss");

        // Check LTV
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);

        // Check we know we have a loan now
        assertTrue(strategy.loanExists());
    }

    function test_getHardLiquidated_userWithdrawBeforeCleanup(
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

        // Get hard liquidated
        simulateHardLiquidation();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Got nothing, should have waited...
        assertEq(asset.balanceOf(user), balanceBefore, "!final balance");
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import "../../../script/Deploy.s.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {CurveLenderBorrowerStrategy as Strategy, ERC20} from "../../Strategy.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {IController} from "../../interfaces/IController.sol";
// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {

    function governance() external view returns (address);

    function set_protocol_fee_bps(
        uint16
    ) external;

    function set_protocol_fee_recipient(
        address
    ) external;

}

contract Setup is Deploy, ExtendedTest, IEvents {

    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;

    address public borrowToken;

    address public lenderVault = 0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F; // yvcrvUSD-2

    address public controllerFactory = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public gov;
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 100e18;
    uint256 public minFuzzAmount = 1e18;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        uint256 _blockNumber = 22_305_807; // Caching for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["WETH"]);

        // Set decimals
        decimals = asset.decimals();

        // Set script vars
        s_asset = address(asset);
        s_lenderVault = lenderVault;
        s_management = management;
        s_performanceFeeRecipient = performanceFeeRecipient;
        s_keeper = keeper;
        s_emergencyAdmin = emergencyAdmin;

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        gov = strategy.GOV();

        borrowToken = strategy.borrowToken();

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        // notify deplyment script that this is a test
        isTest = true;
        // deploy and initialize contracts
        run();
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = s_newStrategy;

        vm.prank(management);
        _strategy.acceptManagement();

        return address(_strategy);
    }

    function depositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address _gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(_gov);
        IFactory(factory).set_protocol_fee_recipient(_gov);

        vm.prank(_gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    function _toUsd(uint256 _amount, address _token) internal view returns (uint256) {
        if (_amount == 0) return 0;
        unchecked {
            return (_amount * _getPrice(_token)) / (uint256(10 ** ERC20(_token).decimals()));
        }
    }

    function _fromUsd(uint256 _amount, address _token) internal view returns (uint256) {
        if (_amount == 0) return 0;
        unchecked {
            return (_amount * (uint256(10 ** ERC20(_token).decimals()))) / _getPrice(_token);
        }
    }

    function _getPrice(
        address _asset
    ) internal view returns (uint256 price) {
        if (_asset == address(asset)) {
            price = IController(strategy.CONTROLLER()).amm_price() / 1e10;
        } else {
            // Assumes crvUSD is 1
            price = 1e8;
        }
    }

}

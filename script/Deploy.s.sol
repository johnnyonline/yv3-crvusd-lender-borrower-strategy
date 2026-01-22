// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";
import {IVaultAPROracle} from "../src/interfaces/IVaultAPROracle.sol";
import {IExchange} from "../src/interfaces/IExchange.sol";

import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";
import {WETHToCRVUSDExchange as Exchange} from "../src/periphery/WETHToCRVUSDExchange.sol";
// import {WBTCToCRVUSDExchange as Exchange} from "../src/periphery/WBTCToCRVUSDExchange.sol";
// import {WSTETHToCRVUSDExchange as Exchange} from "../src/periphery/WSTETHToCRVUSDExchange.sol";

import {CurveLenderBorrowerStrategy as Strategy} from "../src/Strategy.sol";

// ---- Usage ----

// deploy:
// forge script script/Deploy.s.sol:Deploy --verify -g 200 --slow --legacy --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract Deploy is Script {

    bool public isTest;
    address public s_asset;
    address public s_lenderVault;
    address public s_management;
    address public s_performanceFeeRecipient;
    address public s_keeper;
    address public s_emergencyAdmin;
    IExchange public s_exchange;
    StrategyAprOracle public s_oracle;
    IStrategyInterface public s_newStrategy;

    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // SMS mainnet
    address public constant ACCOUNTANT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // SMS mainnet accountant
    address public constant DEPLOYER = 0x285E3b1E82f74A99D07D2aD25e159E75382bB43B; // johnnyonline.eth
    address public constant STRATEGY_APR_ORACLE = 0x0E40eb56626cFD0f41CA7A72618209D958561e65;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant LENDER_VAULT = 0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F; // yvcrvUSD
    address public constant MANAGEMENT = 0x285E3b1E82f74A99D07D2aD25e159E75382bB43B; // johnnyonline.eth
    address public constant YHAAS = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHAAS
    address public constant PERFORMANCE_FEE_RECIPIENT = ACCOUNTANT;
    address public constant EMERGENCY_ADMIN = MANAGEMENT;

    IVaultAPROracle public constant APR_ORACLE = IVaultAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    function run() public {
        uint256 _pk = isTest ? 42069 : vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_pk);

        if (!isTest) {
            require(_deployer == DEPLOYER, "!deployer");

            s_asset = WETH;
            s_lenderVault = LENDER_VAULT;
            s_management = SMS;
            s_performanceFeeRecipient = PERFORMANCE_FEE_RECIPIENT;
            s_keeper = YHAAS;
            s_emergencyAdmin = SMS;
        }

        string memory _name = "Curve WETH Lender crvUSD Borrower";

        vm.startBroadcast(_pk);

        // deploy
        s_exchange = IExchange(address(new Exchange()));
        // s_oracle = new StrategyAprOracle();
        s_newStrategy = IStrategyInterface(address(new Strategy(s_asset, s_lenderVault, address(s_exchange), _name)));

        // init
        if (isTest) {
            // @todo -- run this on deployment too!!!
            s_newStrategy.setPerformanceFeeRecipient(s_performanceFeeRecipient);
            s_newStrategy.setKeeper(s_keeper);
            s_newStrategy.setPendingManagement(s_management);
            s_newStrategy.setEmergencyAdmin(s_emergencyAdmin);
            s_oracle = StrategyAprOracle(STRATEGY_APR_ORACLE);
        }

        // ignore APRs
        if (!isTest) {
            s_newStrategy.setIgnoreBorrowApr(true);
            s_newStrategy.setIgnoreRewardApr(true);
        }

        // set APR oracle
        if (!isTest) APR_ORACLE.setOracle(address(s_newStrategy), STRATEGY_APR_ORACLE);

        vm.stopBroadcast();

        if (!isTest) {
            console.log("Exchange address: %s", address(s_exchange));
            // console.log("Oracle address: %s", address(s_oracle));
            console.log("Strategy address: %s", address(s_newStrategy));
        }
    }

}

// WETH
// Strategy address: 0x6fdF47fb4198677D5B0843e52Cf12B5464cE723E

// WETH -- with new APR oracle
// Strategy address: 0x1D07b80AaD4BAfb996482693A61B745234d9aDf9

// WETH -- with new APR oracle and ignore APRs
// Oracle address: 0x0E40eb56626cFD0f41CA7A72618209D958561e65
// Strategy address: 0x629656a04183aFFdE9449158757D36A8a13cd168

// WETH -- with fixed ignore APRs
// Strategy address: 0xdb0aEca3fB4337E1a902FA1CeeBe8096f4484b3E

// wstETH
// Strategy address: 0x38f4F9aAf92bdCACDFe92eD1e025a66E343b05eC

// PROD:
// WETH - 0x48E560AfB1482f63e5e8C0eA7fBdd8Fd82054eC3
// wstETH - 0x4727a60cb92bE2660A1BE082E3E830eaEF97f2d0
// WBTC - 0xBc7998142b446beaE87cfd024A94320907eb64b1

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";
import {CurveLenderBorrowerStrategy as Strategy} from "../src/Strategy.sol";

// ---- Usage ----

// deploy:
// forge script script/Deploy.s.sol:Deploy --verify --slow --legacy --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract Deploy is Script {

    bool public isTest;
    address public s_asset;
    address public s_lenderVault;
    address public s_management;
    address public s_performanceFeeRecipient;
    address public s_keeper;
    address public s_emergencyAdmin;
    IStrategyInterface public s_newStrategy;

    address public constant ACCOUNTANT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // SMS mainnet accountant
    address public constant DEPLOYER = 0x285E3b1E82f74A99D07D2aD25e159E75382bB43B; // johnnyonline.eth

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant LENDER_VAULT = 0xf9A7084Ec30238495b3F5C51f05BA7Cd1C358dcF; // yv^2crvUSD
    address public constant MANAGEMENT = 0x285E3b1E82f74A99D07D2aD25e159E75382bB43B; // johnnyonline.eth
    address public constant KEEPER = MANAGEMENT;
    address public constant PERFORMANCE_FEE_RECIPIENT = ACCOUNTANT;
    address public constant EMERGENCY_ADMIN = MANAGEMENT;

    function run() public {
        uint256 _pk = isTest ? 42069 : vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_pk);
        // require(_deployer == DEPLOYER, "!deployer");

        if (!isTest) {
            s_asset = WETH;
            s_lenderVault = LENDER_VAULT;
            s_management = MANAGEMENT;
            s_performanceFeeRecipient = PERFORMANCE_FEE_RECIPIENT;
            s_keeper = KEEPER;
            s_emergencyAdmin = EMERGENCY_ADMIN;
        }

        string memory _name = "Curve WETH Lender crvUSD Borrower";

        vm.startBroadcast(_pk);

        // deploy
        s_newStrategy = IStrategyInterface(address(new Strategy(s_asset, _name, s_lenderVault)));

        // init
        s_newStrategy.setPerformanceFeeRecipient(s_performanceFeeRecipient);
        s_newStrategy.setKeeper(s_keeper);
        s_newStrategy.setPendingManagement(s_management);
        s_newStrategy.setEmergencyAdmin(s_emergencyAdmin);

        vm.stopBroadcast();

        if (!isTest) console.log("Strategy address: %s", address(s_newStrategy));
    }

}

// WETH
// Strategy address: 0x6fdF47fb4198677D5B0843e52Cf12B5464cE723E

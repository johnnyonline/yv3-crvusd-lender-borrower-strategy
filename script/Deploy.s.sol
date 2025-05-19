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

    function run() public {
        uint256 _pk = isTest ? 42069 : vm.envUint("DEPLOYER_PRIVATE_KEY");

        string memory _name = "WETH/crvUSD Lender Borrower";

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

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import {IAMM} from "./IAMM.sol";
import {IController} from "./IController.sol";

interface IControllerFactory {
    function get_amm(address _collateral) external view returns (IAMM);
    function get_controller(address _collateral) external view returns (IController);
    function stablecoin() external view returns (address);
}

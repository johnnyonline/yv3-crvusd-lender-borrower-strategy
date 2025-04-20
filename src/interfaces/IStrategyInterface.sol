// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {ILenderBorrower} from "./ILenderBorrower.sol";

interface IStrategyInterface is IStrategy, ILenderBorrower {
    function CRVUSD_INDEX() external view returns (uint256);
    function ASSET_INDEX() external view returns (uint256);
    function AMM() external view returns (address);
    function CONTROLLER() external view returns (address);
    function CONTROLLER_FACTORY() external view returns (address);
    function VAULT_APR_ORACLE() external view returns (address);
    function GOV() external view returns (address);
    function sweep(address _token) external;
    function buyBorrowToken(uint256 _amount) external;
}

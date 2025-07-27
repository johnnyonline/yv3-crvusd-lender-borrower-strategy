// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

interface IMonetaryPolicy {

    function rate() external view returns (uint256);
    function sigma() external view returns (int256);
    function target_debt_fraction() external view returns (uint256);
    function peg_keepers(
        uint256 index
    ) external view returns (address);
    function rate0() external view returns (uint256);
    function rate_write() external returns (uint256);

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

interface IAMM {

    function rate() external view returns (uint256);
    function coins(
        uint256 i
    ) external view returns (address);
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external;

}

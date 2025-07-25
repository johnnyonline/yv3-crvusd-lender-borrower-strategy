// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

interface IPriceOracle {

    function price() external view returns (uint256);

}

interface IAMM {

    function read_user_tick_numbers(
        address user
    ) external view returns (int256[2] memory);
    function active_band() external view returns (int256);
    function price_oracle_contract() external view returns (IPriceOracle);
    function price_oracle() external view returns (uint256);
    function get_p() external view returns (uint256);
    function get_sum_xy(
        address user
    ) external view returns (uint256[2] memory);
    function rate() external view returns (uint256);
    function A() external view returns (uint256);
    function coins(
        uint256 i
    ) external view returns (address);
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external;
    function bands_y(
        int256 band
    ) external view returns (uint256);
    function get_dx(uint256 i, uint256 j, uint256 out_amount) external view returns (uint256);

}

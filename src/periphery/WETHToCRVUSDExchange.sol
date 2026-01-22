// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "../interfaces/IExchange.sol";
import {ICurveTricrypto as ICurvePool} from "../interfaces/ICurveTricrypto.sol";

contract WETHToCRVUSDExchange is IExchange {

    using SafeERC20 for IERC20;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Address of SMS on Mainnet
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    /// @notice TriCRV Curve Pool
    uint256 private constant _CRVUSD_INDEX_TRICRV = 0;
    uint256 private constant _WETH_INDEX_TRICRV = 1;
    ICurvePool private constant _TRICRV = ICurvePool(0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14);

    /// @notice Token addresses
    IERC20 private constant _CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 private constant _WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor() {
        _CRVUSD.forceApprove(address(_TRICRV), type(uint256).max);
        _WETH.forceApprove(address(_TRICRV), type(uint256).max);
    }

    // ============================================================================================
    // View functions
    // ============================================================================================

    /// @notice Returns the address of the borrow token
    /// @return Address of the borrow token
    function BORROW() external pure override returns (address) {
        return address(_CRVUSD);
    }

    /// @notice Returns the address of the collateral token
    /// @return Address of the collateral token
    function COLLATERAL() external pure override returns (address) {
        return address(_WETH);
    }

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    /// @notice Swaps between the borrow token and the collateral token
    /// @param _amount Amount of tokens to swap
    /// @param _minAmount Minimum amount of tokens to receive
    /// @param _fromBorrow If true, swap from borrow token to the collateral token, false otherwise
    /// @return Amount of tokens received
    function swap(
        uint256 _amount,
        uint256 _minAmount,
        bool _fromBorrow
    ) external override returns (uint256) {
        return _fromBorrow ? _swapFrom(_amount, _minAmount) : _swapTo(_amount, _minAmount);
    }

    /// @notice Sweep tokens from the contract
    /// @dev This contract should never hold any tokens
    /// @param _token The token to sweep
    function sweep(
        IERC20 _token
    ) external {
        require(msg.sender == SMS, "!caller");
        uint256 _balance = _token.balanceOf(address(this));
        require(_balance > 0, "!balance");
        _token.safeTransfer(SMS, _balance);
    }

    // ============================================================================================
    // Internal functions
    // ============================================================================================

    /// @notice Swaps from the borrow token to the collateral token
    /// @dev Using our own minAmount check to make sure revert message is consistent
    /// @param _amount Amount of borrow tokens to swap
    /// @param _minAmount Minimum amount of collateral tokens to receive
    /// @return Amount of collateral tokens received
    function _swapFrom(
        uint256 _amount,
        uint256 _minAmount
    ) internal returns (uint256) {
        // Pull crvUSD
        _CRVUSD.safeTransferFrom(msg.sender, address(this), _amount);

        // crvUSD --> WETH
        uint256 _amountOut = _TRICRV.exchange(
            _CRVUSD_INDEX_TRICRV,
            _WETH_INDEX_TRICRV,
            _amount,
            0, // minAmount
            false, // use_eth
            msg.sender // receiver
        );

        require(_amountOut >= _minAmount, "slippage rekt you");

        return _amountOut;
    }

    /// @notice Swaps from the collateral token to the borrow token
    /// @dev Using our own minAmount check to make sure revert message is consistent
    /// @param _amount Amount of collateral tokens to swap
    /// @param _minAmount Minimum amount of borrow tokens to receive
    /// @return Amount of borrow tokens received
    function _swapTo(
        uint256 _amount,
        uint256 _minAmount
    ) internal returns (uint256) {
        // Pull WETH
        _WETH.safeTransferFrom(msg.sender, address(this), _amount);

        // WETH --> crvUSD
        uint256 _amountOut = _TRICRV.exchange(
            _WETH_INDEX_TRICRV,
            _CRVUSD_INDEX_TRICRV,
            _amount,
            0, // minAmount
            false, // use_eth
            msg.sender // receiver
        );

        require(_amountOut >= _minAmount, "slippage rekt you");

        return _amountOut;
    }

}

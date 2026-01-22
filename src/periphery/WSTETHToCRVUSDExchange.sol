// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "../interfaces/IExchange.sol";
import {ICurveTricrypto as ICurvePool} from "../interfaces/ICurveTricrypto.sol";

contract WSTETHToCRVUSDExchange is IExchange {

    using SafeERC20 for IERC20;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Address of SMS on Mainnet
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    /// @notice TricryptoLLAMA Curve Pool
    uint256 private constant _CRVUSD_INDEX_TRICRYPTOLLAMA = 0;
    uint256 private constant _WSTETH_INDEX_TRICRYPTOLLAMA = 2;
    ICurvePool private constant _TRICRYPTOLLAMA = ICurvePool(0x2889302a794dA87fBF1D6Db415C1492194663D13);

    /// @notice Token addresses
    IERC20 private constant _CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 private constant _WSTETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor() {
        _CRVUSD.forceApprove(address(_TRICRYPTOLLAMA), type(uint256).max);
        _WSTETH.forceApprove(address(_TRICRYPTOLLAMA), type(uint256).max);
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
        return address(_WSTETH);
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

        // crvUSD --> wstETH
        uint256 _amountOut = _TRICRYPTOLLAMA.exchange(
            _CRVUSD_INDEX_TRICRYPTOLLAMA,
            _WSTETH_INDEX_TRICRYPTOLLAMA,
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
        // Pull wstETH
        _WSTETH.safeTransferFrom(msg.sender, address(this), _amount);

        // wstETH --> crvUSD
        uint256 _amountOut = _TRICRYPTOLLAMA.exchange(
            _WSTETH_INDEX_TRICRYPTOLLAMA,
            _CRVUSD_INDEX_TRICRYPTOLLAMA,
            _amount,
            0, // minAmount
            false, // use_eth
            msg.sender // receiver
        );

        require(_amountOut >= _minAmount, "slippage rekt you");

        return _amountOut;
    }

}

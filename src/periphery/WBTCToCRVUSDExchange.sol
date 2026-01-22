// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "../interfaces/IExchange.sol";
import {ICurvePool} from "../interfaces/ICurvePool.sol";
import {ICurveTricrypto} from "../interfaces/ICurveTricrypto.sol";

contract WBTCToCRVUSDExchange is IExchange {

    using SafeERC20 for IERC20;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Address of SMS on Mainnet
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    /// @notice TricryptoUSDC Curve Pool
    uint256 private constant _USDC_INDEX_TRICRYPTOUSDC = 0;
    uint256 private constant _WBTC_INDEX_TRICRYPTOUSDC = 1;
    ICurveTricrypto private constant _TRICRYPTOUSDC = ICurveTricrypto(0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B);

    /// @notice crvUSD/USDC PegKeeper Curve Pool
    int128 private constant _USDC_INDEX_PEGKEEPERPOOL = 0;
    int128 private constant _CRVUSD_INDEX_PEGKEEPERPOOL = 1;
    ICurvePool private constant _PEGKEEPERPOOL = ICurvePool(0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E);

    /// @notice Token addresses
    IERC20 private constant _CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 private constant _USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 private constant _WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor() {
        _USDC.forceApprove(address(_TRICRYPTOUSDC), type(uint256).max);
        _WBTC.forceApprove(address(_TRICRYPTOUSDC), type(uint256).max);
        _CRVUSD.forceApprove(address(_PEGKEEPERPOOL), type(uint256).max);
        _USDC.forceApprove(address(_PEGKEEPERPOOL), type(uint256).max);
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
        return address(_WBTC);
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

        // crvUSD --> USDC
        uint256 _amountOut = _PEGKEEPERPOOL.exchange(
            _CRVUSD_INDEX_PEGKEEPERPOOL,
            _USDC_INDEX_PEGKEEPERPOOL,
            _amount,
            0, // minAmount
            address(this) // receiver
        );

        // USDC --> WBTC
        _amountOut = _TRICRYPTOUSDC.exchange(
            _USDC_INDEX_TRICRYPTOUSDC,
            _WBTC_INDEX_TRICRYPTOUSDC,
            _amountOut,
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
        // Pull WBTC
        _WBTC.safeTransferFrom(msg.sender, address(this), _amount);

        // WBTC --> USDC
        uint256 _amountOut = _TRICRYPTOUSDC.exchange(
            _WBTC_INDEX_TRICRYPTOUSDC,
            _USDC_INDEX_TRICRYPTOUSDC,
            _amount,
            0, // minAmount
            false, // use_eth
            address(this) // receiver
        );

        // USDC --> crvUSD
        _amountOut = _PEGKEEPERPOOL.exchange(
            _USDC_INDEX_PEGKEEPERPOOL,
            _CRVUSD_INDEX_PEGKEEPERPOOL,
            _amountOut,
            0, // minAmount
            msg.sender // receiver
        );

        require(_amountOut >= _minAmount, "slippage rekt you");

        return _amountOut;
    }

}

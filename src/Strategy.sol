// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IExchange} from "./interfaces/IExchange.sol";
import {IVaultAPROracle} from "./interfaces/IVaultAPROracle.sol";
import {IAMM, IController, IControllerFactory} from "./interfaces/IControllerFactory.sol";

import {BaseLenderBorrower, ERC20, SafeERC20} from "./BaseLenderBorrower.sol";

contract CurveLenderBorrowerStrategy is BaseLenderBorrower {

    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Allowed slippage (in basis points) when swapping tokens
    /// @dev Initialized to `9_500` (5%) in the constructor
    uint256 public allowedSwapSlippageBps;

    /// @notice Indicates if a loan was created or should be created
    bool public loanExists;

    /// @notice If true, `getNetBorrowApr()` will always return 0
    bool public ignoreBorrowApr;

    /// @notice If true, `getNetRewardApr()` will always return 0
    bool public ignoreRewardApr;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The amplification, the measure of how concentrated the tick is
    uint256 public immutable A;

    /// @notice The number of bands for the loan
    uint256 public constant BANDS = 4;

    /// @notice The maximum active band when repaying
    int256 private constant MAX_ACTIVE_BAND = 2 ** 255 - 1;

    /// @notice The difference in decimals between the AMM price oracle (1e18) and our price (1e8)
    uint256 private constant DECIMALS_DIFF = 1e10;

    /// @notice The price precision used when converting between asset and borrow token
    uint256 private constant SCALED_PRICE_PRECISION = 1e36;

    /// @notice The precision of the `getPrice` function
    uint256 private constant GET_PRICE_PRECISION = 1e8;

    /// @notice The scale applied to the `getPrice` function when converting between asset and borrow token
    uint256 private immutable GET_PRICE_SCALE_FACTOR; // 10^(36 + borrow_decimals - asset_decimals)

    /// @notice The number of seconds in a year
    uint256 private constant SECONDS_IN_YEAR = 365 days;

    /// @notice The governance address
    address public constant GOV = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;

    /// @notice The exchange contract for buying/selling the borrow token
    IExchange public immutable EXCHANGE;

    /// @notice The AMM contract
    IAMM public immutable AMM;

    /// @notice The controller contract
    IController public immutable CONTROLLER;

    /// @notice The Curve Controller factory contract
    IControllerFactory public constant CONTROLLER_FACTORY =
        IControllerFactory(0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC);

    /// @notice The lender vault APR oracle contract
    IVaultAPROracle public constant VAULT_APR_ORACLE = IVaultAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @notice Constructor
    /// @param _asset The strategy's asset
    /// @param _lenderVault The address of the lender vault
    /// @param _exchange The exchange contract for buying/selling borrow token
    /// @param _name The strategy's name
    constructor(
        address _asset,
        address _lenderVault,
        address _exchange,
        string memory _name
    ) BaseLenderBorrower(_asset, _name, CONTROLLER_FACTORY.stablecoin(), _lenderVault) {
        EXCHANGE = IExchange(_exchange);
        require(EXCHANGE.BORROW() == borrowToken && EXCHANGE.COLLATERAL() == address(asset), "!exchange");

        AMM = CONTROLLER_FACTORY.get_amm(_asset);
        CONTROLLER = CONTROLLER_FACTORY.get_controller(_asset);

        A = AMM.A();

        GET_PRICE_SCALE_FACTOR = 10 ** (36 + IERC20Metadata(borrowToken).decimals() - IERC20Metadata(_asset).decimals());

        allowedSwapSlippageBps = 9500; // 5%

        asset.forceApprove(address(CONTROLLER), type(uint256).max);
        asset.forceApprove(address(EXCHANGE), type(uint256).max);

        ERC20 _borrowToken = ERC20(borrowToken);
        _borrowToken.forceApprove(address(CONTROLLER), type(uint256).max);
        _borrowToken.forceApprove(address(EXCHANGE), type(uint256).max);
    }

    // ===============================================================
    // Management functions
    // ===============================================================

    /// @notice Set the allowed swap slippage (in basis points)
    /// @dev E.g., 9_500 = 5% slippage allowed
    /// @param _allowedSwapSlippageBps The allowed swap slippage
    function setAllowedSwapSlippageBps(
        uint256 _allowedSwapSlippageBps
    ) external onlyManagement {
        require(_allowedSwapSlippageBps <= MAX_BPS, "!allowedSwapSlippageBps");
        allowedSwapSlippageBps = _allowedSwapSlippageBps;
    }

    /// @notice Set the loanExists flag to false
    function resetLoanExists() external onlyManagement {
        require(loanExists && !CONTROLLER.loan_exists(address(this)), "!exists");
        loanExists = false;
    }

    /// @notice Set the ignoreBorrowApr flag
    /// @param _ignoreBorrowApr Whether to ignore the borrow APR
    function setIgnoreBorrowApr(
        bool _ignoreBorrowApr
    ) external onlyManagement {
        ignoreBorrowApr = _ignoreBorrowApr;
    }

    /// @notice Set the ignoreRewardApr flag
    /// @param _ignoreRewardApr Whether to ignore the reward APR
    function setIgnoreRewardApr(
        bool _ignoreRewardApr
    ) external onlyManagement {
        ignoreRewardApr = _ignoreRewardApr;
    }

    // ===============================================================
    // Write functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _supplyCollateral(
        uint256 _amount
    ) internal override {
        if (!_isLiquidatable()) loanExists ? CONTROLLER.add_collateral(_amount) : _createLoan(_amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _withdrawCollateral(
        uint256 _amount
    ) internal override {
        CONTROLLER.remove_collateral(
            _amount,
            false // use_eth
        );
    }

    /// @inheritdoc BaseLenderBorrower
    function _borrow(
        uint256 _amount
    ) internal override {
        CONTROLLER.borrow_more(
            0, // collateral
            _amount
        );
    }

    /// @inheritdoc BaseLenderBorrower
    function _repay(
        uint256 _amount
    ) internal override {
        CONTROLLER.repay(
            _amount,
            address(this),
            MAX_ACTIVE_BAND,
            false // use_eth
        );

        // If the loan was fully repaid, set the flag to false
        if (!CONTROLLER.loan_exists(address(this))) loanExists = false;
    }

    /// @notice Create a loan and set the loanExists flag to true
    /// @param _amount The amount of asset to supply
    function _createLoan(
        uint256 _amount
    ) internal {
        if (_amount == 0) return;
        loanExists = true;
        CONTROLLER.create_loan(
            _amount,
            1, // 1 wei of debt
            BANDS
        );
    }

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Check if the strategy is in soft liquidation
    /// @dev We use AMM.get_sum_xy to get the amounts of stablecoins (index 0) and collateral (index 1)
    ///      we currently own. If we have stablecoins, it means some of our collateral was converted to crvUSD
    ///      and we're in soft liquidation
    /// @return True if the strategy is in soft liquidation, false otherwise
    function _isInSoftLiquidation() internal view returns (bool) {
        return AMM.get_sum_xy(address(this))[0] > 0;
    }

    /// @inheritdoc BaseLenderBorrower
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        return _isInSoftLiquidation() ? 0 : BaseLenderBorrower.availableWithdrawLimit(_owner);
    }

    /// @inheritdoc BaseLenderBorrower
    function _getPrice(
        address _asset
    ) internal view override returns (uint256) {
        return _asset == borrowToken ? WAD / DECIMALS_DIFF : AMM.price_oracle() / DECIMALS_DIFF;
    }

    /// @inheritdoc BaseLenderBorrower
    function _isSupplyPaused() internal pure override returns (bool) {
        return false;
    }

    /// @inheritdoc BaseLenderBorrower
    function _isBorrowPaused() internal pure override returns (bool) {
        return false;
    }

    /// @inheritdoc BaseLenderBorrower
    function _isLiquidatable() internal view override returns (bool) {
        // If the loan doesn't exist, we are not liquidatable
        // If it does, we check if we're in soft liquidation or eligible for hard liquidation
        return CONTROLLER.loan_exists(address(this))
            && (_isInSoftLiquidation()
                || CONTROLLER.health(
                    address(this),
                    true // with price difference above the highest band
                ) <= 0);
    }

    /// @inheritdoc BaseLenderBorrower
    function _maxCollateralDeposit() internal pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc BaseLenderBorrower
    function _maxBorrowAmount() internal view override returns (uint256) {
        return ERC20(borrowToken).balanceOf(address(CONTROLLER));
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetBorrowApr(
        uint256 /*_newAmount*/
    ) public view override returns (uint256) {
        return ignoreBorrowApr ? 0 : AMM.rate() * SECONDS_IN_YEAR; // Since we're not dumping, rate change is probably negligible
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetRewardApr(
        uint256 _newAmount
    ) public view override returns (uint256) {
        return ignoreRewardApr ? 1 : VAULT_APR_ORACLE.getStrategyApr(address(lenderVault), int256(_newAmount));
    }

    /// @inheritdoc BaseLenderBorrower
    function getLiquidateCollateralFactor() public view override returns (uint256) {
        return (WAD - CONTROLLER.loan_discount()) - ((BANDS * WAD) / (2 * A));
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfCollateral() public view override returns (uint256) {
        return CONTROLLER.user_state(address(this))[0];
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfDebt() public view override returns (uint256) {
        return CONTROLLER.debt(address(this));
    }

    // ===============================================================
    // Harvest / Token conversions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _tend(
        uint256 _totalIdle
    ) internal override {
        _isInSoftLiquidation() ? _liquidatePosition(balanceOfCollateral()) : BaseLenderBorrower._tend(_totalIdle);
    }

    /// @inheritdoc BaseLenderBorrower
    function _claimRewards() internal pure override {
        return;
    }

    /// @inheritdoc BaseLenderBorrower
    function _claimAndSellRewards() internal override {
        uint256 _loose = balanceOfBorrowToken();
        uint256 _have = balanceOfLentAssets() + _loose;
        uint256 _owe = balanceOfDebt();
        if (_owe >= _have) return;

        uint256 _toSell = _have - _owe;
        if (_toSell > _loose) _withdrawBorrowToken(_toSell - _loose);

        _loose = balanceOfBorrowToken();

        _sellBorrowToken(_toSell > _loose ? _loose : _toSell);
    }

    /// @inheritdoc BaseLenderBorrower
    function _sellBorrowToken(
        uint256 _amount
    ) internal virtual override {
        // Scale price to 1e36
        uint256 _scaledPrice = _getPrice(address(asset)) * GET_PRICE_SCALE_FACTOR / GET_PRICE_PRECISION;

        // Calculate the expected amount of collateral out in collateral token precision
        uint256 _expectedAmountOut = _amount * SCALED_PRICE_PRECISION / _scaledPrice;

        // Apply slippage tolerance
        uint256 _minAmountOut = _expectedAmountOut * allowedSwapSlippageBps / MAX_BPS;

        // Swap away
        EXCHANGE.swap(
            _amount,
            _minAmountOut, // minAmount
            true // fromBorrow
        );
    }

    /// @inheritdoc BaseLenderBorrower
    function _buyBorrowToken() internal virtual override {
        uint256 _borrowTokenStillOwed = borrowTokenOwedBalance();
        uint256 _maxAssetBalance = _fromUsd(_toUsd(_borrowTokenStillOwed, borrowToken), address(asset));
        _buyBorrowToken(_maxAssetBalance);
    }

    /// @notice Buy borrow token
    /// @param _amount The amount of asset to sale
    function _buyBorrowToken(
        uint256 _amount
    ) internal {
        // Scale price to 1e36
        uint256 _scaledPrice = _getPrice(address(asset)) * GET_PRICE_SCALE_FACTOR / GET_PRICE_PRECISION;

        // Calculate the expected amount of borrow token out
        uint256 _expectedAmountOut = _amount * _scaledPrice / SCALED_PRICE_PRECISION;

        // Apply slippage tolerance
        uint256 _minAmountOut = _expectedAmountOut * allowedSwapSlippageBps / MAX_BPS;

        // Swap away
        EXCHANGE.swap(
            _amount,
            _minAmountOut, // minAmount
            false // fromBorrow
        );
    }

    /// @notice Sweep of non-asset ERC20 tokens to governance
    /// @param _token The ERC20 token to sweep
    function sweep(
        ERC20 _token
    ) external {
        require(msg.sender == GOV, "!gov");
        require(_token != asset, "!asset");
        _token.safeTransfer(GOV, _token.balanceOf(address(this)));
    }

    /// @notice Manually buy borrow token
    /// @dev Potentially can never reach `_buyBorrowToken()` in `_liquidatePosition()`
    ///      because of lender vault accounting (i.e. `balanceOfLentAssets() == 0` is never true)
    function buyBorrowToken(
        uint256 _amount
    ) external onlyEmergencyAuthorized {
        if (_amount == type(uint256).max) _amount = balanceOfAsset();
        _buyBorrowToken(_amount);
    }

}

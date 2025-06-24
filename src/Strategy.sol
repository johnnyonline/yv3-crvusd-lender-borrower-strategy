// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import {IAMM, IController, IControllerFactory} from "./interfaces/IControllerFactory.sol";
import {IVaultAPROracle} from "./interfaces/IVaultAPROracle.sol";

import {BaseLenderBorrower, ERC20, SafeERC20} from "./BaseLenderBorrower.sol";

contract CurveLenderBorrowerStrategy is BaseLenderBorrower {

    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Indicates if a loan was created or should be created
    bool public loanExists;

    /// @notice If true, `getNetBorrowApr()` will return 0,
    ///         which means we'll always consider it profitable to borrow
    bool public forceLeverage;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The amplification, the measure of how concentrated the tick is
    uint256 public immutable A;

    /// @notice The index of the borrowed token in the AMM
    uint256 public immutable CRVUSD_INDEX;

    /// @notice The index of the asset in the AMM
    uint256 public immutable ASSET_INDEX;

    /// @notice The AMM contract
    IAMM public immutable AMM;

    /// @notice The controller contract
    IController public immutable CONTROLLER;

    /// @notice The Curve Controller factory contract
    IControllerFactory public constant CONTROLLER_FACTORY =
        IControllerFactory(0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC);

    /// @notice The lender vault APR oracle contract
    IVaultAPROracle public constant VAULT_APR_ORACLE = IVaultAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    /// @notice The governance address
    address public constant GOV = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;

    /// @notice The difference in decimals between the AMM price (1e18) and our price (1e8)
    uint256 private constant DECIMALS_DIFF = 1e10;

    /// @notice The number of seconds in a year
    uint256 private constant SECONDS_IN_YEAR = 365 days;

    /// @notice The number of bands for the loan
    uint256 private constant BANDS = 4;

    /// @notice The maximum active band when repaying
    int256 private constant MAX_ACTIVE_BAND = 2 ** 255 - 1;

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @notice Constructor
    /// @param _asset The strategy's asset
    /// @param _name The strategy's name
    /// @param _lenderVault The address of the lender vault
    constructor(
        address _asset,
        string memory _name,
        address _lenderVault
    ) BaseLenderBorrower(_asset, _name, CONTROLLER_FACTORY.stablecoin(), _lenderVault) {
        AMM = CONTROLLER_FACTORY.get_amm(_asset);
        CONTROLLER = CONTROLLER_FACTORY.get_controller(_asset);

        A = AMM.A();

        CRVUSD_INDEX = AMM.coins(0) == _asset ? 1 : 0;
        ASSET_INDEX = CRVUSD_INDEX == 1 ? 0 : 1;

        asset.forceApprove(address(CONTROLLER), type(uint256).max);
        asset.forceApprove(address(AMM), type(uint256).max);

        ERC20 _borrowToken = ERC20(borrowToken);
        _borrowToken.forceApprove(address(CONTROLLER), type(uint256).max);
        _borrowToken.forceApprove(address(AMM), type(uint256).max);
    }

    // ===============================================================
    // Management functions
    // ===============================================================

    /// @notice Set the loanExists flag to false
    function resetLoanExists() external onlyManagement {
        require(loanExists && !CONTROLLER.loan_exists(address(this)), "!exists");
        loanExists = false;
    }

    /// @notice Set the forceLeverage flag
    /// @param _forceLeverage The new value for the forceLeverage flag
    function setForceLeverage(
        bool _forceLeverage
    ) external onlyManagement {
        forceLeverage = _forceLeverage;
    }

    // ===============================================================
    // Write functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _supplyCollateral(
        uint256 _amount
    ) internal override {
        loanExists ? CONTROLLER.add_collateral(_amount) : _createLoan(_amount);
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
    }

    /// @notice Create a loan and set the loanExists flag to true
    /// @param _amount The amount of asset to supply
    function _createLoan(
        uint256 _amount
    ) internal {
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

    /// @inheritdoc BaseLenderBorrower
    function _getPrice(
        address _asset
    ) internal view override returns (uint256) {
        return _asset == borrowToken ? WAD / DECIMALS_DIFF : CONTROLLER.amm_price() / DECIMALS_DIFF;
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
        return CONTROLLER.health(
            address(this),
            true // with price difference above the highest band
        ) < 0;
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
        uint256 /* _newAmount */
    ) public view override returns (uint256) {
        return forceLeverage ? 0 : AMM.rate() * SECONDS_IN_YEAR; // Since we're not duming, rate will not necessarily change
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetRewardApr(
        uint256 _newAmount
    ) public view override returns (uint256) {
        return VAULT_APR_ORACLE.getExpectedApr(address(lenderVault), int256(_newAmount));
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
        AMM.exchange(CRVUSD_INDEX, ASSET_INDEX, _amount, 0);
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
        AMM.exchange(ASSET_INDEX, CRVUSD_INDEX, _amount, 0);
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

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IAMM, IController, IControllerFactory} from "./interfaces/IControllerFactory.sol";

import {BaseLenderBorrower, ERC20, SafeERC20} from "./BaseLenderBorrower.sol";

contract CurveLenderBorrowerStrategy is BaseLenderBorrower {
    using SafeERC20 for ERC20;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The governance address
    address public immutable GOV;

    /// @notice The index of the borrowed token in the AMM
    uint256 public immutable CRVUSD_INDEX;

    /// @notice The index of the asset in the AMM
    uint256 public immutable ASSET_INDEX;

    /// @notice The AMM contract
    IAMM public immutable AMM;

    /// @notice The controller contract
    IController public immutable CONTROLLER;

    /// @notice The Curve Controller factory contract
    IControllerFactory public constant CONTROLLER_FACTORY = IControllerFactory(0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC);

    /// @notice The difference in decimals between the AMM price (1e18) and our price (1e8)
    uint256 private constant DECIMALS_DIFF = 1e10;

    /// @notice The number of seconds in a year
    uint256 private constant SECONDS_IN_YEAR = 365 days;

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @notice Constructor
    /// @param _asset The strategy's asset
    /// @param _name The strategy's name
    /// @param _lenderVault The address of the lender vault
    /// @param _gov The governance address
    constructor(
        address _asset,
        string memory _name,
        address _lenderVault,
        address _gov
    ) BaseLenderBorrower(_asset, _name, CONTROLLER_FACTORY.stablecoin(), _lenderVault) {
        GOV = _gov;
        AMM = CONTROLLER_FACTORY.get_amm(_asset);
        CONTROLLER = CONTROLLER_FACTORY.get_controller(_asset);

        CRVUSD_INDEX = AMM.coins(0) == _asset ? 1 : 0;
        ASSET_INDEX = CRVUSD_INDEX == 1 ? 0 : 1;

        // @todo -- approve asset to amm too?
        asset.forceApprove(address(CONTROLLER), type(uint256).max);

        ERC20 _borrowToken = ERC20(CONTROLLER_FACTORY.stablecoin());
        _borrowToken.forceApprove(address(CONTROLLER), type(uint256).max);
        _borrowToken.forceApprove(address(AMM), type(uint256).max);
    }

    // ===============================================================
    // Internal write functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _supplyCollateral(uint256 _amount) internal override {
        !CONTROLLER.loan_exists(address(this))
            ? CONTROLLER.create_loan(_amount, 1, 10)
            : CONTROLLER.add_collateral(_amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _withdrawCollateral(uint256 _amount) internal override {
        CONTROLLER.remove_collateral(_amount, false);
    }

    /// @inheritdoc BaseLenderBorrower
    function _borrow(uint256 _amount) internal override {
        CONTROLLER.borrow_more(0, _amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _repay(uint256 amount) internal override {
        CONTROLLER.repay(amount, address(this), 2 ** 255 - 1, false);
    }

    // ===============================================================
    // Internal view functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _getPrice(address _asset) internal view override returns (uint256) {
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
        return CONTROLLER.health(address(this), true) < 0;
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
    function getNetBorrowApr(uint256 /* _newAmount */) public view override returns (uint256) {
        return AMM.rate() * SECONDS_IN_YEAR; // Since we're not duming, rate will not necessarily change
    }

    // @todo
    /// @inheritdoc BaseLenderBorrower
    function getNetRewardApr(uint256 /* _newAmount */) public pure override returns (uint256) {
        return 10;
    }

    /// @inheritdoc BaseLenderBorrower
    function getLiquidateCollateralFactor() public view override returns (uint256) {
        return CONTROLLER.loan_discount() * 10;
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfCollateral() public view override returns (uint256) {
        return CONTROLLER.user_state(address(this))[0];
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfDebt() public view override returns (uint256) {
        return CONTROLLER.debt(address(this));
    }

    /// ----------------- HARVEST / TOKEN CONVERSIONS ----------------- \\

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
    function _buyBorrowToken() internal virtual override {
        AMM.exchange(ASSET_INDEX, CRVUSD_INDEX, borrowTokenOwedBalance(), 0);
    }

    /// @inheritdoc BaseLenderBorrower
    function _sellBorrowToken(uint256 _amount) internal virtual override {
        AMM.exchange(CRVUSD_INDEX, ASSET_INDEX, _amount, 0);
    }

    /// @notice Sweep of non-asset ERC20 tokens to governance
    /// @param _token The ERC20 token to sweep
    function sweep(ERC20 _token) external {
        require(msg.sender == GOV, "!gov");
        require(_token != asset, "!asset");
        _token.safeTransfer(GOV, _token.balanceOf(address(this)));
    }
}

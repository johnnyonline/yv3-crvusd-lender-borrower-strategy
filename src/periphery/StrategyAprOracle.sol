// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";

import {IAMM} from "../interfaces/IAMM.sol";
import {IVaultAPROracle} from "../interfaces/IVaultAPROracle.sol";
import {IStrategyInterface as IStrategy} from "../interfaces/IStrategyInterface.sol";

contract StrategyAprOracle is AprOracleBase {

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The WAD
    uint256 private constant WAD = 1e18;

    /// @notice The maximum basis points
    uint256 private constant MAX_BPS = 10_000;

    /// @notice The number of seconds in a year
    uint256 private constant SECONDS_IN_YEAR = 365 days;

    /// @notice The lender vault APR oracle contract
    IVaultAPROracle public constant VAULT_APR_ORACLE = IVaultAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _governance Address of the Governance contract
    constructor(
        address _governance
    ) AprOracleBase("crvUSD Lender Borrower Strategy APR Oracle", _governance) {}

    // ===============================================================
    // View functions
    // ===============================================================

    /**
     * @notice Will return the expected Apr of a strategy post a debt change.
     * @dev _delta is a signed integer so that it can also represent a debt
     * decrease.
     *
     * This should return the annual expected return at the current timestamp
     * represented as 1e18.
     *
     *      ie. 10% == 1e17
     *
     * _delta will be == 0 to get the current apr.
     *
     * This will potentially be called during non-view functions so gas
     * efficiency should be taken into account.
     *
     * @param _strategy The token to get the apr for.
     * @param _delta The difference in debt.
     * @return . The expected apr for the strategy represented as 1e18.
     */
    function aprAfterDebtChange(address _strategy, int256 _delta) external view override returns (uint256) {
        IStrategy strategy_ = IStrategy(_strategy);
        uint256 _borrowApr = IAMM(strategy_.AMM()).rate() * SECONDS_IN_YEAR;
        uint256 _rewardApr = VAULT_APR_ORACLE.getExpectedApr(strategy_.lenderVault(), _delta);
        if (_borrowApr >= _rewardApr) return 0;
        uint256 _targetLTV = (strategy_.getLiquidateCollateralFactor() * strategy_.targetLTVMultiplier()) / MAX_BPS;
        return (_rewardApr - _borrowApr) * _targetLTV / WAD;
    }

}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DataTypes} from "./DataTypes.sol";
import {WadRayMath} from "./WadRayMath.sol";
import {PercentageMath} from "./PercentageMath.sol";

/**
 * @title DefaultReserveInterestRateStrategy contract
 * @notice Implements the calculation of the interest rates depending on the reserve state
 * @dev The model of interest rate is based on 2 slopes, one before the `OPTIMAL_USAGE_RATIO`
 * point of usage and another from that one to 100%.
 * - An instance of this same contract, can't be used across different markets, due to the caching
 *   of the PoolAddressesProvider
 */
contract DefaultReserveInterestRateStrategy {
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    /********************************************************************************************/
    /*                                       DATA VARIABLES                                     */
    /********************************************************************************************/

    /**
     * @notice Returns the usage ratio at which the pool aims to obtain most competitive borrow rates.
     * @return The optimal usage ratio, expressed in ray.
     */
    uint256 public immutable OPTIMAL_USAGE_RATIO;

    /**
     * @notice Returns the optimal stable to total debt ratio of the reserve.
     * @return The optimal stable to total debt ratio, expressed in ray.
     */
    uint256 public immutable OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO;

    /**
     * @notice Returns the excess usage ratio above the optimal.
     * @dev It's always equal to 1-optimal usage ratio (added as constant for gas optimizations)
     * @return The max excess usage ratio, expressed in ray.
     */
    uint256 public immutable MAX_EXCESS_USAGE_RATIO;

    /**
     * @notice Returns the excess stable debt ratio above the optimal.
     * @dev It's always equal to 1-optimal stable to total debt ratio (added as constant for gas optimizations)
     * @return The max excess stable to total debt ratio, expressed in ray.
     */
    uint256 public immutable MAX_EXCESS_STABLE_TO_TOTAL_DEBT_RATIO;

    // IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    // Base variable borrow rate when usage rate = 0. Expressed in ray
    uint256 internal immutable _baseVariableBorrowRate;

    // Slope of the variable interest curve when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO. Expressed in ray
    uint256 internal immutable _variableRateSlope1;

    // Slope of the variable interest curve when usage ratio > OPTIMAL_USAGE_RATIO. Expressed in ray
    uint256 internal immutable _variableRateSlope2;

    // Premium on top of `_variableRateSlope1` for base stable borrowing rate
    uint256 internal immutable _baseStableRateOffset;

    // Additional premium applied to stable rate when stable debt surpass `OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO`
    uint256 internal immutable _stableRateExcessOffset;

    struct CalcInterestRatesLocalVars {
        uint256 availableLiquidity;
        uint256 totalDebt;
        uint256 currentVariableBorrowRate;
        uint256 currentStableBorrowRate;
        uint256 currentLiquidityRate;
        uint256 borrowUsageRatio;
        uint256 supplyUsageRatio;
        uint256 stableToTotalDebtRatio;
        uint256 availableLiquidityPlusDebt;
    }

    /********************************************************************************************/
    /*                                       CONSTRUCTOR                                        */
    /********************************************************************************************/

    /**
     * @dev Constructor.
     * @param optimalUsageRatio The optimal usage ratio
     * @param baseVariableBorrowRate The base variable borrow rate
     * @param variableRateSlope1 The variable rate slope below optimal usage ratio
     * @param variableRateSlope2 The variable rate slope above optimal usage ratio
     * @param baseStableRateOffset The premium on top of variable rate for base stable borrowing rate
     * @param stableRateExcessOffset The premium on top of stable rate when there stable debt surpass the threshold
     * @param optimalStableToTotalDebtRatio The optimal stable debt to total debt ratio of the reserve
     */
    constructor(
        uint256 optimalUsageRatio,
        uint256 baseVariableBorrowRate,
        uint256 variableRateSlope1,
        uint256 variableRateSlope2,
        uint256 baseStableRateOffset,
        uint256 stableRateExcessOffset,
        uint256 optimalStableToTotalDebtRatio
    ) {
        require(
            WadRayMath.RAY >= optimalUsageRatio,
            "INVALID_OPTIMAL_USAGE_RATIO"
        );
        require(
            WadRayMath.RAY >= optimalStableToTotalDebtRatio,
            "INVALID_OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO"
        );
        OPTIMAL_USAGE_RATIO = optimalUsageRatio;
        MAX_EXCESS_USAGE_RATIO = WadRayMath.RAY - optimalUsageRatio;
        OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO = optimalStableToTotalDebtRatio;
        MAX_EXCESS_STABLE_TO_TOTAL_DEBT_RATIO =
            WadRayMath.RAY -
            optimalStableToTotalDebtRatio;
        _baseVariableBorrowRate = baseVariableBorrowRate;
        _variableRateSlope1 = variableRateSlope1;
        _variableRateSlope2 = variableRateSlope2;
        _baseStableRateOffset = baseStableRateOffset;
        _stableRateExcessOffset = stableRateExcessOffset;
    }

    /********************************************************************************************/
    /*                                       UTILITY FUNCTIONS                                  */
    /********************************************************************************************/

    /**
     * @notice Returns the variable rate slope below optimal usage ratio
     * @dev It's the variable rate when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO
     * @return The variable rate slope, expressed in ray
     */
    function getVariableRateSlope1() external view returns (uint256) {
        return _variableRateSlope1;
    }

    /**
     * @notice Returns the variable rate slope above optimal usage ratio
     * @dev It's the variable rate when usage ratio > OPTIMAL_USAGE_RATIO
     * @return The variable rate slope, expressed in ray
     */
    function getVariableRateSlope2() external view returns (uint256) {
        return _variableRateSlope2;
    }

    /**
     * @notice Returns the stable rate excess offset
     * @dev It's an additional premium applied to the stable when stable debt > OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO
     * @return The stable rate excess offset, expressed in ray
     */
    function getStableRateExcessOffset() external view returns (uint256) {
        return _stableRateExcessOffset;
    }

    /**
     * @notice Returns the base stable borrow rate
     * @return The base stable borrow rate, expressed in ray
     */
    function getBaseStableBorrowRate() public view returns (uint256) {
        return _variableRateSlope1 + _baseStableRateOffset;
    }

    /**
     * @notice Returns the base variable borrow rate
     * @return The base variable borrow rate, expressed in ray
     */
    function getBaseVariableBorrowRate() external view returns (uint256) {
        return _baseVariableBorrowRate;
    }

    /**
     * @notice Returns the maximum variable borrow rate
     * @return The maximum variable borrow rate, expressed in ray
     */
    function getMaxVariableBorrowRate() external view returns (uint256) {
        return
            _baseVariableBorrowRate + _variableRateSlope1 + _variableRateSlope2;
    }

    /********************************************************************************************/
    /*                                   CONTRACT FUNCTIONS                                     */
    /********************************************************************************************/

    /**
     * @notice Calculates the interest rates depending on the reserve's state and configurations
     * @param params The parameters needed to calculate interest rates
     * @return liquidityRate The liquidity rate expressed in rays - The liquidity rate is the rate paid to lenders on the protocol
     * @return stableBorrowRate The stable borrow rate expressed in rays
     * @return variableBorrowRate The variable borrow rate expressed in rays
     */
    function calculateInterestRates(
        DataTypes.CalculateInterestRatesParams memory params
    ) public view returns (uint256, uint256, uint256) {
        CalcInterestRatesLocalVars memory vars;

        vars.totalDebt = params.totalStableDebt + params.totalVariableDebt;

        vars.currentLiquidityRate = 0;
        vars.currentVariableBorrowRate = _baseVariableBorrowRate;
        vars.currentStableBorrowRate = getBaseStableBorrowRate();

        if (vars.totalDebt != 0) {
            vars.stableToTotalDebtRatio = params.totalStableDebt.rayDiv(
                vars.totalDebt
            );
            vars.availableLiquidity =
                IERC20(params.reserve).balanceOf(params.poolToken) +
                params.liquidityAdded -
                params.liquidityTaken;

            vars.availableLiquidityPlusDebt =
                vars.availableLiquidity +
                vars.totalDebt;
            vars.borrowUsageRatio = vars.totalDebt.rayDiv(
                vars.availableLiquidityPlusDebt
            );
            vars.supplyUsageRatio = vars.totalDebt.rayDiv(
                vars.availableLiquidityPlusDebt
            );
        }

        if (vars.borrowUsageRatio > OPTIMAL_USAGE_RATIO) {
            uint256 excessBorrowUsageRatio = (vars.borrowUsageRatio -
                OPTIMAL_USAGE_RATIO).rayDiv(MAX_EXCESS_USAGE_RATIO);

            vars.currentVariableBorrowRate +=
                _variableRateSlope1 +
                _variableRateSlope2.rayMul(excessBorrowUsageRatio);
        } else {
            vars.currentVariableBorrowRate += _variableRateSlope1
                .rayMul(vars.borrowUsageRatio)
                .rayDiv(OPTIMAL_USAGE_RATIO);
        }

        // Set the stable borrow rate based on the variable borrow rate
        vars.currentStableBorrowRate =
            vars.currentVariableBorrowRate +
            _baseStableRateOffset;

        if (vars.stableToTotalDebtRatio > OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO) {
            uint256 excessStableDebtRatio = (vars.stableToTotalDebtRatio -
                OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO).rayDiv(
                    MAX_EXCESS_STABLE_TO_TOTAL_DEBT_RATIO
                );
            vars.currentStableBorrowRate += _stableRateExcessOffset.rayMul(
                excessStableDebtRatio
            );
        }

        vars.currentLiquidityRate = _getOverallBorrowRate(
            params.totalStableDebt,
            params.totalVariableDebt,
            vars.currentVariableBorrowRate,
            params.averageStableBorrowRate
        ).rayMul(vars.supplyUsageRatio).percentMul(
                PercentageMath.PERCENTAGE_FACTOR - params.reserveFactor
            );

        return (
            vars.currentLiquidityRate,
            vars.currentStableBorrowRate,
            vars.currentVariableBorrowRate
        );
    }

    /**
     * @notice Adds the respective risk spreads on top of the base interest rates in order to calculate the final rates.
     * @param params The parameters needed to calculate interest rates
     * @param paysCoupon Flag that indicates if the user is paying the interest rate coupon
     * @param isCollateralInsured Flag that indicates if the collateral is insured
     * @return liquidityRate The liquidity rate expressed in rays - The liquidity rate is the rate paid to lenders on the protocol
     * @return finalStableBorrowRate The stable borrow rate expressed in rays after adding the premiums
     * @return finalVariableBorrowRate The variable borrow rate expressed in rays after adding the premiums
     */
    function riskAdjustedRate(
        DataTypes.CalculateInterestRatesParams memory params,
        bool paysCoupon,
        bool isCollateralInsured
    ) external pure returns (uint256, uint256, uint256) {
        CalcInterestRatesLocalVars memory vars;

        uint256 couponPremium = paysCoupon ? 0 : params.couponPremiumRate;
        uint256 collateralPremium = isCollateralInsured
            ? 0
            : params.collateralInsurancePremiumRate;

        uint256 finalStableBorrowRate = vars.currentStableBorrowRate +
            couponPremium +
            collateralPremium;
        uint256 finalVariableBorrowRate = vars.currentVariableBorrowRate +
            couponPremium +
            collateralPremium;

        return (
            vars.currentLiquidityRate,
            finalStableBorrowRate,
            finalVariableBorrowRate
        );
    }

    /**
     * @dev Calculates the overall borrow rate as the weighted average between the total variable debt and total stable
     * debt
     * @param totalStableDebt The total borrowed from the reserve at a stable rate
     * @param totalVariableDebt The total borrowed from the reserve at a variable rate
     * @param currentVariableBorrowRate The current variable borrow rate of the reserve
     * @param currentAverageStableBorrowRate The current weighted average of all the stable rate loans
     * @return The weighted averaged borrow rate
     */
    function _getOverallBorrowRate(
        uint256 totalStableDebt,
        uint256 totalVariableDebt,
        uint256 currentVariableBorrowRate,
        uint256 currentAverageStableBorrowRate
    ) internal pure returns (uint256) {
        uint256 totalDebt = totalStableDebt + totalVariableDebt;

        if (totalDebt == 0) return 0;

        uint256 weightedVariableRate = totalVariableDebt.wadToRay().rayMul(
            currentVariableBorrowRate
        );

        uint256 weightedStableRate = totalStableDebt.wadToRay().rayMul(
            currentAverageStableBorrowRate
        );

        uint256 overallBorrowRate = (weightedVariableRate + weightedStableRate)
            .rayDiv(totalDebt.wadToRay());

        return overallBorrowRate;
    }
}

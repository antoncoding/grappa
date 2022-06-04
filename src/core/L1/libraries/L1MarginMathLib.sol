// SPDX-License-Identifier: MIT
pragma solidity =0.8.13;

import "forge-std/console2.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "src/config/constants.sol";
import "src/config/types.sol";
import "src/config/errors.sol";

library L1MarginMathLib {
    using FixedPointMathLib for uint256;

    function getMinCollateral(
        MarginAccountDetail memory _account,
        uint256 _spot,
        ProductMarginParams memory params
    ) internal view returns (uint256) {
        // don't need collateral
        if (_account.putAmount == 0 && _account.callAmount == 0) return 0;

        if (params.discountRatioUpperBound == 0) revert InvalidConfig();

        // we only have short put
        if (_account.callAmount == 0) {
            return getMinCollateralForPutSpread(_account, _spot, params);
        }

        // we only have short call
        if (_account.putAmount == 0) {
            return getMinCollateralForCallSpread(_account, _spot, params);
        }

        // we have both call and short
        return getMinCollateralForDoubleShort(_account, _spot, params);
    }

    function getMinCollateralForDoubleShort(
        MarginAccountDetail memory _account,
        uint256 _spot,
        ProductMarginParams memory params
    ) internal view returns (uint256) {
        // there're both short call and put in the position
        uint256 minCollateralCall = getMinCollateralForCallSpread(_account, _spot, params);
        uint256 minCollateralPut = getMinCollateralForPutSpread(_account, _spot, params);

        if (_account.shortPutStrike < _account.shortCallStrike) {
            // if strikes don't cross (put strike < call strike),
            // you only need collateral of higher risk of either put or call
            return max(minCollateralCall, minCollateralPut);
        } else {
            // if strike crosses, it became more risky between shortStrike -> putStrike
            // but the max loss could be capped
            return minCollateralCall + minCollateralPut;

            // todo: if the amount is the same, capped at the max loss
        }
    }

    function getMinCollateralForCallSpread(
        MarginAccountDetail memory _account,
        uint256 _spot,
        ProductMarginParams memory params
    ) internal view returns (uint256) {
        // if max loss of short can always be covered by long
        if (_account.longCallStrike != 0 && _account.longCallStrike < _account.shortCallStrike) return 0;

        // it's a simple short call position
        uint256 minCollateralShortCall = getMinCollateralForShortCall(
            _account.callAmount,
            _account.shortCallStrike,
            _account.expiry,
            _spot,
            params
        );
        if (_account.longCallStrike == 0) return minCollateralShortCall;

        // we calculate the max loss of spread, dominated in collateral
        uint256 maxLoss = (_account.longCallStrike - _account.shortCallStrike).mulDivUp(_account.callAmount, UNIT);

        return min(maxLoss, minCollateralShortCall);
    }

    function getMinCollateralForPutSpread(
        MarginAccountDetail memory _account,
        uint256 _spot,
        ProductMarginParams memory params
    ) internal view returns (uint256) {
        // if max loss of short can always be covered by long
        if (_account.longPutStrike > _account.shortPutStrike) return 0;

        // long is not sufficient to cap loss for short, result is the same as
        uint256 minCollateralShortPut = getMinCollateralForShortPut(
            _account.putAmount,
            _account.shortPutStrike,
            _account.expiry,
            _spot,
            params
        );

        if (_account.longPutStrike == 0) return minCollateralShortPut;

        // we calculate the max loss of the put spread
        uint256 maxLoss = (_account.shortPutStrike - _account.longPutStrike).mulDivUp(_account.putAmount, UNIT);

        return min(minCollateralShortPut, maxLoss);
    }

    ///@notice get the minimum collateral for a naked short option
    function getMinCollateralForShortCall(
        uint256 _shortAmount,
        uint256 _strike,
        uint256 _expiry,
        uint256 _spot,
        ProductMarginParams memory params
    ) internal view returns (uint256) {
        // if ratio is 20%, we calculate price of spot * 120%
        uint256 shockPrice = _spot.mulDivUp(BPS + params.shockRatio, BPS);
        uint256 timeValueDecay = getTimeDecay(_expiry, params);
        uint256 safeCashValue = getCallCashValue(shockPrice, _strike);
        uint256 requireCollateral = min(_strike, shockPrice).mulDivUp(timeValueDecay, BPS) + safeCashValue;
        return requireCollateral.mulDivUp(_shortAmount, UNIT);
    }

    ///@notice get the minimum collateral for a put option
    ///@dev margin = decay(t) * min(strike, shockPrice) + max(strike — shockPrice, 0)
    ///     decay(t) = a multiplier from [0, 1]
    ///     shockPrice = (1-shockRatio) * spot
    function getMinCollateralForShortPut(
        uint256 _shortAmount,
        uint256 _strike,
        uint256 _expiry,
        uint256 _spot,
        ProductMarginParams memory params
    ) internal view returns (uint256) {
        // if ratio is 20%, we calculate price of spot * 80%
        uint256 shockPrice = _spot.mulDivUp(BPS - params.shockRatio, BPS);
        uint256 timeValueDecay = getTimeDecay(_expiry, params);

        uint256 safeCashValue = getPutCashValue(shockPrice, _strike);

        uint256 requireCollateral = min(_strike, shockPrice).mulDivUp(timeValueDecay, BPS) + safeCashValue;

        return requireCollateral.mulDivUp(_shortAmount, UNIT);
    }

    /**
     * get the time decay value apply to minimum collateral
     * @param _expiry expiry timestamp
     */
    function getTimeDecay(uint256 _expiry, ProductMarginParams memory params) internal view returns (uint256) {
        if (_expiry <= block.timestamp) return 0;

        uint256 timeToExpiry = _expiry - block.timestamp;
        if (timeToExpiry > params.discountPeriodUpperBound) return uint256(params.discountRatioUpperBound); // 80%
        if (timeToExpiry < params.discountPeriodLowerBound) return uint256(params.discountRatioLowerBound); // 10% of time value

        return
            uint256(params.discountRatioLowerBound) +
            ((timeToExpiry.sqrt() - params.sqrtMinDiscountPeriod) *
                (params.discountRatioUpperBound - params.discountRatioLowerBound)) /
            (params.sqrtMaxDiscountPeriod - params.sqrtMinDiscountPeriod);
    }

    /// @notice get the cash value of a call option strike
    /// @dev returns max(spot - strike, 0)
    /// @param _spot spot price in usd term with 8 decimals
    /// @param _strike strike price in usd term with 8 decimals
    function getCallCashValue(uint256 _spot, uint256 _strike) internal pure returns (uint256) {
        unchecked {
            return _spot < _strike ? 0 : _spot - _strike;
        }
    }

    /// @notice get the cash value of a put option strike
    /// @dev returns max(strike - spot, 0)
    /// @param _spot spot price in usd term with 8 decimals
    /// @param _strike strike price in usd term with 8 decimals
    function getPutCashValue(uint256 _spot, uint256 _strike) internal pure returns (uint256) {
        unchecked {
            return _spot > _strike ? 0 : _strike - _spot;
        }
    }

    function getCashValueCallDebitSpread(
        uint256 _spot,
        uint256 _longStrike,
        uint256 _shortStrike
    ) internal pure returns (uint256) {
        unchecked {
            return min(getCallCashValue(_spot, _longStrike), _shortStrike - _longStrike);
        }
    }

    function getCashValuePutDebitSpread(
        uint256 _spot,
        uint256 _longStrike,
        uint256 _shortStrike
    ) internal pure returns (uint256) {
        unchecked {
            return min(getPutCashValue(_spot, _longStrike), _longStrike - _shortStrike);
        }
    }

    /// @dev return the max of a and b
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @dev return the min of a and b
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

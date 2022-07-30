// SPDX-License-Identifier: MIT
pragma solidity =0.8.13;

library NumberUtil {
    /**
     * @notice convert decimals of an amount
     *
     * @param  _amount      number to convert
     * @param _fromDecimals the decimals _amount has
     * @param _toDecimals   the target decimals
     *
     * @return _ number with _toDecimals decimals
     */
    function convertDecimals(
        uint256 _amount,
        uint8 _fromDecimals,
        uint8 _toDecimals
    ) internal pure returns (uint256) {
        if (_fromDecimals == _toDecimals) return _amount;

        if (_fromDecimals > _toDecimals) {
            uint8 diff;
            unchecked {
                diff = _fromDecimals - _toDecimals;
            }
            return _amount / (10**diff);
        } else {
            uint8 diff;
            unchecked {
                diff = _toDecimals - _fromDecimals;
            }
            return _amount * (10**diff);
        }
    }
}

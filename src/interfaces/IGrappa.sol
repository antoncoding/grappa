// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGrappa {
    function getAssetsFromProductId(uint32 _productId)
        external
        view
        returns (
            address underlying,
            address strike,
            address collateral,
            uint8 collateralDecimals
        );

    function assets(uint8 _id) external view returns (address asset);

    function getPayout(uint256 tokenId, uint64 amount) external view returns (address collateral, uint256 payout);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console2.sol";
import "src/config/enums.sol";
import "src/config/types.sol";

import "src/libraries/OptionTokenUtils.sol";

contract ActionHelper {
    function getTokenId(
        TokenType tokenType,
        uint32 productId,
        uint256 expiry,
        uint256 longStrike,
        uint256 shortStrike
    ) internal pure returns (uint256 tokenId) {
        tokenId = OptionTokenUtils.formatTokenId(
            tokenType,
            productId,
            uint64(expiry),
            uint64(longStrike),
            uint64(shortStrike)
        );
    }

    function parseTokenId(uint256 tokenId)
        internal
        pure
        returns (
            TokenType tokenType,
            uint32 productId,
            uint64 expiry,
            uint64 longStrike,
            uint64 shortStrike
        )
    {
        return OptionTokenUtils.parseTokenId(tokenId);
    }

    function createAddCollateralAction(
        uint8 collateralId,
        address from,
        uint256 amount
    ) internal pure returns (ActionArgs memory action) {
        action = ActionArgs({action: ActionType.AddCollateral, data: abi.encode(from, uint80(amount), collateralId)});
    }

    function createRemoveCollateralAction(uint256 amount, address recipient)
        internal
        pure
        returns (ActionArgs memory action)
    {
        action = ActionArgs({action: ActionType.RemoveCollateral, data: abi.encode(uint80(amount), recipient)});
    }

    function createMintAction(
        uint256 tokenId,
        address recipient,
        uint256 amount
    ) internal pure returns (ActionArgs memory action) {
        action = ActionArgs({action: ActionType.MintShort, data: abi.encode(tokenId, recipient, uint64(amount))});
    }

    function createBurnAction(
        uint256 tokenId,
        address from,
        uint256 amount
    ) internal pure returns (ActionArgs memory action) {
        action = ActionArgs({action: ActionType.BurnShort, data: abi.encode(tokenId, from, uint64(amount))});
    }

    function createMergeAction(uint256 tokenId, address from) internal pure returns (ActionArgs memory action) {
        action = ActionArgs({action: ActionType.MergeOptionToken, data: abi.encode(tokenId, from)});
    }

    function createSplitAction(TokenType tokenType, address recipient)
        internal
        pure
        returns (ActionArgs memory action)
    {
        action = ActionArgs({action: ActionType.SplitOptionToken, data: abi.encode(tokenType, recipient)});
    }
}

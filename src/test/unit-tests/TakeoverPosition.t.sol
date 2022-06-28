// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// import test base and helpers.
import {Fixture} from "src/test/shared/Fixture.t.sol";

import "src/config/enums.sol";
import "src/config/types.sol";
import "src/config/constants.sol";
import "src/config/errors.sol";

import "forge-std/console2.sol";

contract TestTakeoverPosition is Fixture {
    uint256 public expiry;

    uint64 private amount = uint64(1 * UNIT);
    uint256 private tokenId;
    uint64 private strike;
    uint256 private initialCollateral;

    address private accountId;

    function setUp() public {
        usdc.mint(address(this), 1000_000 * 1e6);
        usdc.approve(address(grappa), type(uint256).max);

        // setup account for alice
        vm.startPrank(alice);
        usdc.mint(alice, 1000_000 * 1e6);

        usdc.approve(address(grappa), type(uint256).max);

        expiry = block.timestamp + 7 days;

        oracle.setSpotPrice(3500 * UNIT);

        // mint option
        initialCollateral = 500 * 1e6;

        strike = uint64(4000 * UNIT);

        accountId = alice;

        tokenId = getTokenId(TokenType.CALL, productId, expiry, strike, 0);
        ActionArgs[] memory actions = new ActionArgs[](2);
        actions[0] = createAddCollateralAction(usdcId, alice, initialCollateral);
        actions[1] = createMintAction(tokenId, alice, amount);

        // mint option
        grappa.execute(accountId, actions);

        vm.stopPrank();
    }

    function testCannotTakeoverHealthyVault() public {
        vm.expectRevert(AccountIsHealthy.selector);
        grappa.takeoverPosition(accountId, address(this), 0);
    }

    function testCannotTakeoverPositionWithoutPayingCollateral() public {
        oracle.setSpotPrice(3800 * UNIT);

        vm.expectRevert(AccountUnderwater.selector);
        grappa.takeoverPosition(accountId, address(this), 0);
    }

    function testCannotTakeoverPositionWithoutPayingEnoughCollateral() public {
        oracle.setSpotPrice(3800 * UNIT);

        vm.expectRevert(AccountUnderwater.selector);
        grappa.takeoverPosition(accountId, address(this), uint80(50 * 1e6));
    }

    function testTakeoverPosition() public {
        oracle.setSpotPrice(3800 * UNIT);

        uint80 tapUpAmount = 300 * 1e6;

        grappa.takeoverPosition(accountId, address(this), tapUpAmount);

        // old margin account should be reset
        (uint256 shortCallId, , uint64 shortCallAmount, , uint80 collateralAmount, uint8 collateralId) = grappa
            .marginAccounts(accountId);

        assertEq(shortCallId, 0);
        assertEq(shortCallAmount, 0);
        assertEq(collateralAmount, 0);
        assertEq(collateralId, 0);

        // new margin account should be updated
        (shortCallId, , shortCallAmount, , collateralAmount, collateralId) = grappa.marginAccounts(address(this));

        assertEq(shortCallId, tokenId);
        assertEq(shortCallAmount, amount);
        assertEq(collateralAmount, initialCollateral + tapUpAmount);
        assertEq(collateralId, usdcId);
    }
}

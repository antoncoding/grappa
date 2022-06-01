// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "src/test/mocks/MockERC20.sol";
import "src/test/mocks/MockOracle.sol";

import "src/core/L1/MarginAccount.sol";
import "src/core/OptionToken.sol";

import "src/config/enums.sol";
import "src/config/types.sol";

abstract contract Fixture is Test {
    MarginAccount internal grappa;
    OptionToken internal option;

    MockERC20 internal usdc;
    MockERC20 internal weth;

    MockOracle internal oracle;

    address internal alice;
    address internal charlie;
    address internal bob;

    // usdc collateralized call / put
    uint32 internal productId;

    // eth collateralized call / put
    uint32 internal productIdEthCollat;

    constructor() {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);

        oracle = new MockOracle();

        option = new OptionToken(address(oracle));

        grappa = new MarginAccount(address(option));

        // register products
        option.registerAsset(address(usdc));
        option.registerAsset(address(weth));

        // grant margin account rights to mint and burn
        option.setIsMinter(address(grappa), true);

        productId = option.getProductId(address(weth), address(usdc), address(usdc));
        productIdEthCollat = option.getProductId(address(weth), address(usdc), address(weth));

        charlie = address(0xcccc);
        vm.label(charlie, "Charlie");

        bob = address(0xb00b);
        vm.label(bob, "Bob");

        alice = address(0xaaaa);
        vm.label(alice, "Alice");

        // make sure timestamp is not 0
        vm.warp(0xffff);

        usdc.mint(alice, 1000_000_000 * 1e6);
        usdc.mint(bob, 1000_000_000 * 1e6);
        usdc.mint(charlie, 1000_000_000 * 1e6);
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}

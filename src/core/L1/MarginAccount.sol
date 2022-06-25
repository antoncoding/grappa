// SPDX-License-Identifier: MIT
pragma solidity =0.8.13;
import {IMarginAccount} from "src/interfaces/IMarginAccount.sol";
import {IERC20} from "src/interfaces/IERC20.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {IOptionToken} from "src/interfaces/IOptionToken.sol";

import {OptionTokenUtils} from "src/libraries/OptionTokenUtils.sol";
import {L1MarginMathLib} from "./libraries/L1MarginMathLib.sol";
import {L1AccountLib} from "./libraries/L1AccountLib.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";

import {Settlement} from "src/core/Settlement.sol";

import "src/config/types.sol";
import "src/config/enums.sol";
import "src/config/constants.sol";
import "src/config/errors.sol";

/**
 * @title   MarginAccount
 * @author  antoncoding
 * @dev     MarginAccount is in charge of maintaining margin requirement for each "account"
            Users can deposit collateral into MarginAccount and mint optionTokens (debt) out of it.
            Interacts with OptionToken to mint / burn and get product information.
 */
contract MarginAccount is IMarginAccount, ReentrancyGuard, Settlement {
    using L1MarginMathLib for MarginAccountDetail;
    using L1AccountLib for Account;

    /*///////////////////////////////////////////////////////////////
                                  Variables
    //////////////////////////////////////////////////////////////*/

    ///@dev accountId => Account.
    ///     accountId can be an address similar to the primary account, but has the last 8 bits different.
    ///     this give every account access to 256 sub-accounts
    mapping(address => Account) public marginAccounts;

    ///@dev primaryAccountId => operator => authorized
    ///     every account can authorize any amount of addresses to modify all accounts he controls.
    mapping(uint160 => mapping(address => bool)) public authorized;

    mapping(uint32 => ProductMarginParams) public productParams;

    constructor(address _optionToken, address _oracle) Settlement(_optionToken, _oracle) {}

    /**
     * @notice get minimum collateral needed for a margin account
     * @param _accountId account id.
     * @return minCollateral minimum collateral required, in collateral asset's decimals
     */
    function getMinCollateral(address _accountId) external view returns (uint256 minCollateral) {
        Account memory account = marginAccounts[_accountId];
        MarginAccountDetail memory detail = _getAccountDetail(account);

        minCollateral = _getMinCollateral(detail);
    }

    /**
     * @dev execute array of actions on an account
     */
    function execute(address _accountId, ActionArgs[] calldata actions) external nonReentrant {
        _assertCallerHasAccess(_accountId);
        Account memory account = marginAccounts[_accountId];

        // update the account memory and do external calls on the flight
        for (uint256 i; i < actions.length; ) {
            if (actions[i].action == ActionType.AddCollateral) _addCollateral(account, actions[i].data, _accountId);
            else if (actions[i].action == ActionType.RemoveCollateral) _removeCollateral(account, actions[i].data);
            else if (actions[i].action == ActionType.MintShort) _mintOption(account, actions[i].data);
            else if (actions[i].action == ActionType.BurnShort) _burnOption(account, actions[i].data, _accountId);
            else if (actions[i].action == ActionType.MergeOptionToken) _merge(account, actions[i].data, _accountId);
            else if (actions[i].action == ActionType.SplitOptionToken) _split(account, actions[i].data);

            // increase i without checking overflow
            unchecked {
                i++;
            }
        }
        _assertAccountHealth(account);
        marginAccounts[_accountId] = account;
    }

    /**
     * @dev pull token from user, increase collateral in account memory
     */
    function _addCollateral(
        Account memory _account,
        bytes memory _data,
        address accountId
    ) internal {
        // decode parameters
        (address from, uint80 amount, uint8 collateralId) = abi.decode(_data, (address, uint80, uint8));

        // update the account structure in memory
        _account.addCollateral(amount, collateralId);

        address collateral = address(assets[collateralId].addr);

        // collateral must come from caller or the primary account for this accountId
        if (from != msg.sender && !_isPrimaryAccountFor(from, accountId)) revert InvalidFromAddress();
        IERC20(collateral).transferFrom(from, address(this), amount);
    }

    /**
     * @dev push token to user, decrease collateral in account memory
     */
    function _removeCollateral(Account memory _account, bytes memory _data) internal {
        // decode parameters
        (uint80 amount, address recipient) = abi.decode(_data, (uint80, address));
        address collateral = address(assets[_account.collateralId].addr);

        // update the account structure in memory
        _account.removeCollateral(amount);

        // external calls
        IERC20(collateral).transfer(recipient, amount);
    }

    /**
     * @dev mint option token to user, increase short position (debt) in account memory
     */
    function _mintOption(Account memory _account, bytes memory _data) internal {
        // decode parameters
        (uint256 tokenId, address recipient, uint64 amount) = abi.decode(_data, (uint256, address, uint64));

        // update the account structure in memory
        _account.mintOption(tokenId, amount);

        // mint the real option token
        optionToken.mint(recipient, tokenId, amount);
    }

    /**
     * @dev burn option token from user, decrease short position (debt) in account memory
     */
    function _burnOption(
        Account memory _account,
        bytes memory _data,
        address accountId
    ) internal {
        // decode parameters
        (uint256 tokenId, address from, uint64 amount) = abi.decode(_data, (uint256, address, uint64));

        // update the account structure in memory
        _account.burnOption(tokenId, amount);

        // token being burn must come from caller or the primary account for this accountId
        if (from != msg.sender && !_isPrimaryAccountFor(from, accountId)) revert InvalidFromAddress();
        optionToken.burn(from, tokenId, amount);
    }

    /**
     * @dev burn option token and change the short position to spread. This will reduce collateral requirement
     */
    function _merge(
        Account memory _account,
        bytes memory _data,
        address accountId
    ) internal {
        // decode parameters
        (uint256 tokenId, address from) = abi.decode(_data, (uint256, address));

        // update the account structure in memory
        uint64 amount = _account.merge(tokenId);

        // token being burn must come from caller or the primary account for this accountId
        if (from != msg.sender && !_isPrimaryAccountFor(from, accountId)) revert InvalidFromAddress();

        optionToken.burn(from, tokenId, amount);
    }

    /**
     * @dev Change existing spread position to short, and mint option token for recipient
     */
    function _split(Account memory _account, bytes memory _data) internal {
        // decode parameters
        (TokenType tokenType, address recipient) = abi.decode(_data, (TokenType, address));

        // update the account structure in memory
        (uint256 tokenId, uint64 amount) = _account.split(tokenType);

        optionToken.mint(recipient, tokenId, amount);
    }

    /**
     * @notice return if {_account} address is the primary account for _accountId
     */
    function _isPrimaryAccountFor(address _account, address _accountId) internal pure returns (bool) {
        return (uint160(_account) | 0xFF) == (uint160(_accountId) | 0xFF);
    }

    /**
     * @notice return if the calling address is eligible to access accountId
     */
    function _assertCallerHasAccess(address _accountId) internal view {
        if (_isPrimaryAccountFor(msg.sender, _accountId)) return;
        // the sender is not the direct owner. check if he's authorized
        uint160 primaryAccountId = (uint160(_accountId) | 0xFF);
        if (!authorized[primaryAccountId][msg.sender]) revert NoAccess();
    }

    /**
     * @dev make sure account is above water
     */
    function _assertAccountHealth(Account memory account) internal view {
        if (!_isAccountHealthy(account)) revert AccountUnderwater();
    }

    /**
     * @dev return whether if an account is healthy.
     * @param account account structure in memory
     * @return isHealthy true if account is in good condition, false if it's liquidatable
     */
    function _isAccountHealthy(Account memory account) internal view returns (bool isHealthy) {
        MarginAccountDetail memory detail = _getAccountDetail(account);
        uint256 minCollateral = _getMinCollateral(detail);
        isHealthy = account.collateralAmount >= minCollateral;
    }

    /**
     * @notice get minimum collateral needed for a margin account
     * @param detail account memory dtail
     * @return minCollateral minimum collateral required, in collateral asset's decimals
     */
    function _getMinCollateral(MarginAccountDetail memory detail) internal view returns (uint256 minCollateral) {
        ProductAssets memory assets = _getProductAssets(detail.productId);

        // denominated in {UNIT_DECIMALS}
        uint256 spotPrice = oracle.getSpotPrice(assets.underlying, assets.strike);

        // need to pass in collateral/strike price. Pass in 0 if collateral is strike to save gas.
        uint256 collateralStrikePrice = 0;
        if (assets.collateral == assets.underlying) collateralStrikePrice = spotPrice;
        else if (assets.collateral != assets.strike) {
            collateralStrikePrice = oracle.getSpotPrice(assets.collateral, assets.strike);
        }

        uint256 minCollateralInUnit = detail.getMinCollateral(
            assets,
            spotPrice,
            collateralStrikePrice,
            productParams[detail.productId]
        );

        minCollateral = _convertDecimals(minCollateralInUnit, UNIT_DECIMALS, assets.collateralDecimals);
    }

    /**
     * @dev convert Account struct from storage to in-memory detail struct
     */
    function _getAccountDetail(Account memory account) internal pure returns (MarginAccountDetail memory detail) {
        detail = MarginAccountDetail({
            putAmount: account.shortPutAmount,
            callAmount: account.shortCallAmount,
            longPutStrike: 0,
            shortPutStrike: 0,
            longCallStrike: 0,
            shortCallStrike: 0,
            expiry: 0,
            collateralAmount: account.collateralAmount,
            productId: 0
        });

        // if it contains a call
        if (account.shortCallId != 0) {
            (, , , uint64 longStrike, uint64 shortStrike) = OptionTokenUtils.parseTokenId(account.shortCallId);
            // the short position of the account is the long of the minted optionToken
            detail.shortCallStrike = longStrike;
            detail.longCallStrike = shortStrike;
        }

        // if it contains a put
        if (account.shortPutId != 0) {
            (, , , uint64 longStrike, uint64 shortStrike) = OptionTokenUtils.parseTokenId(account.shortPutId);

            // the short position of the account is the long of the minted optionToken
            detail.shortPutStrike = longStrike;
            detail.longPutStrike = shortStrike;
        }

        // parse common field
        // use the OR operator, so as long as one of shortPutId or shortCallId is non-zero, got reflected here
        uint256 commonId = account.shortPutId | account.shortCallId;

        (, uint32 productId, uint64 expiry, , ) = OptionTokenUtils.parseTokenId(commonId);
        detail.productId = productId;
        detail.expiry = expiry;
    }

    /**
     * @dev get a struct that stores all relevent token addresses, along with collateral asset decimals
     */
    function _getProductAssets(uint32 _productId) internal view returns (ProductAssets memory info) {
        (address underlying, address strike, address collateral, uint8 collatDecimals) = parseProductId(_productId);
        info.underlying = underlying;
        info.strike = strike;
        info.collateral = collateral;
        info.collateralDecimals = collatDecimals;
    }

    /**
     * @notice set the margin config for specific productId
     * @param _productId product id
     * @param _discountPeriodUpperBound (sec) max time to expiry to offer a collateral requirement discount
     * @param _discountPeriodLowerBound (sec) min time to expiry to offer a collateral requirement discount
     * @param _discountRatioUpperBound (BPS) discount ratio if the time to expiry is at the upper bound
     * @param _discountRatioLowerBound (BPS) discount ratio if the time to expiry is at the lower bound
     * @param _shockRatio (BPS) spot shock
     */
    function setProductMarginConfig(
        uint32 _productId,
        uint32 _discountPeriodUpperBound,
        uint32 _discountPeriodLowerBound,
        uint32 _discountRatioUpperBound,
        uint32 _discountRatioLowerBound,
        uint32 _shockRatio
    ) external onlyOwner {
        productParams[_productId] = ProductMarginParams({
            discountPeriodUpperBound: _discountPeriodUpperBound,
            discountPeriodLowerBound: _discountPeriodLowerBound,
            sqrtMaxDiscountPeriod: uint32(FixedPointMathLib.sqrt(uint256(_discountPeriodUpperBound))),
            sqrtMinDiscountPeriod: uint32(FixedPointMathLib.sqrt(uint256(_discountPeriodLowerBound))),
            discountRatioUpperBound: _discountRatioUpperBound,
            discountRatioLowerBound: _discountRatioLowerBound,
            shockRatio: _shockRatio
        });
    }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.13;

// imported contracts and libraries
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

// interfaces
import {IOracle} from "../interfaces/IOracle.sol";
import {IOptionToken} from "../interfaces/IOptionToken.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";

// inheriting contract
import {Registry} from "./Registry.sol";

// librarise
import {TokenIdUtil} from "../libraries/TokenIdUtil.sol";
import {ProductIdUtil} from "../libraries/ProductIdUtil.sol";
import {NumberUtil} from "../libraries/NumberUtil.sol";
import {SimpleMarginMath} from "./engines/libraries/SimpleMarginMath.sol";
import {SimpleMarginLib} from "./engines/libraries/SimpleMarginLib.sol";

// constants and types
import "../config/types.sol";
import "../config/enums.sol";
import "../config/constants.sol";
import "../config/errors.sol";

/**
 * @title   Grappa
 * @author  @antoncoding
 * @notice  Grappa is in the entry point to mint / burn option tokens
            Interacts with different MarginEngines to mint optionTokens.
            Interacts with OptionToken to mint / burn.
 */
contract Grappa is ReentrancyGuard, Registry {
    using SimpleMarginMath for SimpleMarginDetail;
    using SimpleMarginLib for Account;
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;
    using NumberUtil for uint256;

    ///@dev maskedAccount => operator => authorized
    ///     every account can authorize any amount of addresses to modify all sub-accounts he controls.
    mapping(uint160 => mapping(address => bool)) public authorized;

    /// @dev optionToken address
    IOptionToken public immutable optionToken;
    IMarginEngine public immutable engine;
    IOracle public immutable oracle;

    constructor(
        address _optionToken,
        address _engine,
        address _oracle
    ) {
        optionToken = IOptionToken(_optionToken);
        engine = IMarginEngine(_engine);
        oracle = IOracle(_oracle);
    }

    /*///////////////////////////////////////////////////////////////
                                  Events
    //////////////////////////////////////////////////////////////*/
    event ProductConfigurationUpdated(
        uint32 productId,
        uint32 dUpper,
        uint32 dLower,
        uint32 rUpper,
        uint32 rLower,
        uint32 volMul
    );

    /*///////////////////////////////////////////////////////////////
                        External Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice  execute array of actions on an account
     * @dev     expected to be called by account owners.
     */
    function execute(address _subAccount, ActionArgs[] calldata actions) external nonReentrant {
        _assertCallerHasAccess(_subAccount);
        // Account memory account = marginAccounts[_subAccount];

        // update the account memory and do external calls on the flight
        for (uint256 i; i < actions.length; ) {
            if (actions[i].action == ActionType.AddCollateral) _addCollateral(_subAccount, actions[i].data);
            else if (actions[i].action == ActionType.RemoveCollateral) _removeCollateral(_subAccount, actions[i].data);
            else if (actions[i].action == ActionType.MintShort) _mintOption(_subAccount, actions[i].data);
            else if (actions[i].action == ActionType.BurnShort) _burnOption(_subAccount, actions[i].data);
            else if (actions[i].action == ActionType.MergeOptionToken) _merge(_subAccount, actions[i].data);
            else if (actions[i].action == ActionType.SplitOptionToken) _split(_subAccount, actions[i].data);
            else if (actions[i].action == ActionType.SettleAccount) _settle(_subAccount);

            // increase i without checking overflow
            unchecked {
                i++;
            }
        }
        _assertAccountHealth(_subAccount);
    }

    function liquidate(
        address _engine,
        address _subAccount,
        uint256[] memory _tokensToBurn,
        uint256[] memory _amountsToBurn
    ) external {
        (uint8 collateralId, uint80 amountToPay) = IMarginEngine(_engine).liquidate(
            _subAccount,
            _tokensToBurn,
            _amountsToBurn
        );
        optionToken.batchBurn(msg.sender, _tokensToBurn, _amountsToBurn);

        address asset = assets[collateralId].addr;
        if (asset != address(0)) IERC20(asset).safeTransfer(msg.sender, amountToPay);
    }

    /**
     * @notice burn option token and get out cash value at expiry
     *
     * @param _account who to settle for
     * @param _tokenId  tokenId of option token to burn
     * @param _amount   amount to settle
     */
    function settleOption(
        address _account,
        uint256 _tokenId,
        uint256 _amount
    ) external {
        (address collateral, uint256 payout) = getPayout(_tokenId, uint64(_amount));

        optionToken.burn(_account, _tokenId, _amount);

        IERC20(collateral).safeTransfer(_account, payout);
    }

    /**
     * @notice burn option token and get out cash value at expiry
     *
     * @param _account who to settle for
     * @param _tokenIds array of tokenIds to burn
     * @param _amounts   array of amounts to burn
     * @param _collateral collateral asset to settle in.
     */
    function batchSettleOptions(
        address _account,
        uint256[] memory _tokenIds,
        uint256[] memory _amounts,
        address _collateral
    ) external {
        if (_tokenIds.length != _amounts.length) revert ST_WrongArgumentLength();

        uint256 totalPayout;

        for (uint256 i; i < _tokenIds.length; ) {
            (address collateral, uint256 payout) = getPayout(_tokenIds[i], uint64(_amounts[i]));

            if (collateral != _collateral) revert ST_WrongSettlementCollateral();
            totalPayout += payout;

            unchecked {
                i++;
            }
        }

        optionToken.batchBurn(_account, _tokenIds, _amounts);

        IERC20(_collateral).safeTransfer(_account, totalPayout);
    }

    /**
     * @dev calculate the payout for an expired option token
     *
     * @param _tokenId  token id of option token
     * @param _amount   amount to settle
     *
     * @return collateral asset to settle in
     * @return payout amount paid
     **/
    function getPayout(uint256 _tokenId, uint64 _amount) public view returns (address, uint256 payout) {
        (TokenType tokenType, uint32 productId, uint64 expiry, uint64 longStrike, uint64 shortStrike) = TokenIdUtil
            .parseTokenId(_tokenId);

        if (block.timestamp < expiry) revert MA_NotExpired();

        (address underlying, address strike, address collateral, uint8 collateralDecimals) = getAssetsFromProductId(
            productId
        );

        // cash value denominated in strike (usually USD), with {UNIT_DECIMALS} decimals
        uint256 cashValue;

        // expiry price of underlying, denominated in strike (usually USD), with {UNIT_DECIMALS} decimals
        uint256 expiryPrice = oracle.getPriceAtExpiry(underlying, strike, expiry);

        if (tokenType == TokenType.CALL) {
            cashValue = SimpleMarginMath.getCallCashValue(expiryPrice, longStrike);
        } else if (tokenType == TokenType.CALL_SPREAD) {
            cashValue = SimpleMarginMath.getCashValueCallDebitSpread(expiryPrice, longStrike, shortStrike);
        } else if (tokenType == TokenType.PUT) {
            cashValue = SimpleMarginMath.getPutCashValue(expiryPrice, longStrike);
        } else if (tokenType == TokenType.PUT_SPREAD) {
            cashValue = SimpleMarginMath.getCashValuePutDebitSpread(expiryPrice, longStrike, shortStrike);
        }

        // payout is denominated in strike asset (usually USD), with {UNIT_DECIMALS} decimals
        payout = cashValue.mulDivDown(_amount, UNIT);

        // the following logic convert payout amount if collateral is not strike:
        if (collateral == underlying) {
            // collateral is underlying. payout should be devided by underlying price
            payout = payout.mulDivDown(UNIT, expiryPrice);
        } else if (collateral != strike) {
            // collateral is not underlying nor strike
            uint256 collateralPrice = oracle.getPriceAtExpiry(collateral, strike, expiry);
            payout = payout.mulDivDown(UNIT, collateralPrice);
        }

        return (collateral, payout.convertDecimals(UNIT_DECIMALS, collateralDecimals));
    }

    /**
     * @notice  grant or revoke an account access to all your sub-accounts
     * @dev     expected to be call by account owner
     *          usually user should only give access to helper contracts
     * @param   _account account to update authorization
     * @param   _isAuthorized to grant or revoke access
     */
    function setAccountAccess(address _account, bool _isAuthorized) external {
        authorized[uint160(msg.sender) | 0xFF][_account] = _isAuthorized;
    }

    /** ========================================================= **
     *                 * -------------------- *                    *
     *                 |  Actions  Functions  |                    *
     *                 * -------------------- *                    *
     *    These functions all call engine to update account info   *
     *    & deal with burning / minting or transfering collateral  *
     ** ========================================================= **/

    /**
     * @dev pull token from user, increase collateral in account memory
            the collateral has to be provided by either caller, or the primary owner of subaccount
     */
    function _addCollateral(address _subAccount, bytes memory _data) internal {
        // decode parameters
        (address from, uint80 amount, uint8 collateralId) = abi.decode(_data, (address, uint80, uint8));

        // update the account structure in memory
        IMarginEngine(engine).increaseCollateral(_subAccount, amount, collateralId);

        address collateral = address(assets[collateralId].addr);

        // collateral must come from caller or the primary account for this subAccount
        if (from != msg.sender && !_isPrimaryAccountFor(from, _subAccount)) revert MA_InvalidFromAddress();
        IERC20(collateral).safeTransferFrom(from, address(this), amount);
    }

    /**
     * @dev push token to user, decrease collateral in account memory
     * @param _data bytes data to decode
     */
    function _removeCollateral(address _subAccount, bytes memory _data) internal {
        // todo: check expiry if has short

        // decode parameters
        (uint80 amount, address recipient, uint8 collateralId) = abi.decode(_data, (uint80, address, uint8));

        // update the account structure in memory
        IMarginEngine(engine).decreaseCollateral(_subAccount, collateralId, amount);

        address collateral = address(assets[collateralId].addr);

        // external calls
        IERC20(collateral).safeTransfer(recipient, amount);
    }

    /**
     * @dev mint option token to user, increase short position (debt) in account memory
     * @param _data bytes data to decode
     */
    function _mintOption(address _subAccount, bytes memory _data) internal {
        // decode parameters
        (uint256 tokenId, address recipient, uint64 amount) = abi.decode(_data, (uint256, address, uint64));

        // update the account structure in memory
        IMarginEngine(engine).increaseDebt(_subAccount, tokenId, amount);

        // mint the real option token
        optionToken.mint(recipient, tokenId, amount);
    }

    /**
     * @dev burn option token from user, decrease short position (debt) in account memory
            the option has to be provided by either caller, or the primary owner of subaccount
     * @param _data bytes data to decode
     * @param _subAccount the id of the subaccount passed in
     */
    function _burnOption(address _subAccount, bytes memory _data) internal {
        // decode parameters
        (uint256 tokenId, address from, uint64 amount) = abi.decode(_data, (uint256, address, uint64));

        // update the account structure in memory
        IMarginEngine(engine).decreaseDebt(_subAccount, tokenId, amount);

        // token being burn must come from caller or the primary account for this subAccount
        if (from != msg.sender && !_isPrimaryAccountFor(from, _subAccount)) revert MA_InvalidFromAddress();
        optionToken.burn(from, tokenId, amount);
    }

    /**
     * @dev burn option token and change the short position to spread. This will reduce collateral requirement
            the option has to be provided by either caller, or the primary owner of subaccount
     * @param _data bytes data to decode
     */
    function _merge(address _subAccount, bytes memory _data) internal {
        // decode parameters
        (uint256 tokenId, address from) = abi.decode(_data, (uint256, address));

        // update the account structure in memory
        uint64 amount = IMarginEngine(engine).merge(_subAccount, tokenId);

        // token being burn must come from caller or the primary account for this subAccount
        if (from != msg.sender && !_isPrimaryAccountFor(from, _subAccount)) revert MA_InvalidFromAddress();

        optionToken.burn(from, tokenId, amount);
    }

    /**
     * @dev Change existing spread position to short, and mint option token for recipient
     * @param _subAccount subaccount that will be update in place
     */
    function _split(address _subAccount, bytes memory _data) internal {
        // decode parameters
        (TokenType tokenType, address recipient) = abi.decode(_data, (TokenType, address));

        (uint256 tokenId, uint64 amount) = IMarginEngine(engine).split(_subAccount, tokenType);

        optionToken.mint(recipient, tokenId, amount);
    }

    /**
     * @notice  settle the margin account at expiry
     * @dev     this update the account memory in-place
     * @param _subAccount subaccount structure that will be update in place
     */
    function _settle(address _subAccount) internal {
        IMarginEngine(engine).settleAtExpiry(_subAccount);
    }

    /** ========================================================= **
                            Internal Functions
     ** ========================================================= **/

    /**
     * @notice return if {_primary} address is the primary account for {_subAccount}
     */
    function _isPrimaryAccountFor(address _primary, address _subAccount) internal pure returns (bool) {
        return (uint160(_primary) | 0xFF) == (uint160(_subAccount) | 0xFF);
    }

    /**
     * @notice return if the calling address is eligible to access an subAccount address
     */
    function _assertCallerHasAccess(address _subAccount) internal view {
        if (_isPrimaryAccountFor(msg.sender, _subAccount)) return;

        // the sender is not the direct owner. check if he's authorized
        uint160 maskedAccountId = (uint160(_subAccount) | 0xFF);
        if (!authorized[maskedAccountId][msg.sender]) revert NoAccess();
    }

    /**
     * @dev make sure account is above water
     */
    function _assertAccountHealth(address _subAccount) internal view {
        if (!engine.isAccountHealthy(_subAccount)) revert MA_AccountUnderwater();
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFilecoinPayV1} from "./interfaces/IFilecoinPayV1.sol";
import {AOperator} from "./abstracts/AOperator.sol";

/**
 * @title Operator
 * @dev Implements operator logic for managing Filecoin Pay rails
 * @notice Retrieval payment operator for Filecoin Pay
 */
contract Operator is Initializable, AccessControlUpgradeable, AOperator {
    /**
     * @notice Error indicating that the admin address provided during initialization is the zero address
     * @dev 0x05bb467c
     */
    error InvalidAdminAddress();

    /**
     * @notice Error indicating that the FilecoinPay address provided during initialization is the zero address
     * @dev 0x5419d62f
     */
    error InvalidFilecoinPayAddress();

    /**
     * @notice Error indicating that the token address provided during initialization is the zero address
     * @dev 0x1f27f313
     */
    error InvalidTokenAddress();

    /**
     * @notice Error indicating that an invalid rail ID was provided
     * @dev 0x664f7d6c
     */
    error InvalidRailId();

    /**
     * @notice Error indicating that the operator is not approved
     * @dev 0xe3129001
     */
    error OperatorNotApproved();

    /**
     * @notice Error indicating that the lockup allowance is not set properly
     * @dev 0xae339be9
     */
    error InvalidLockupAllowance();

    /**
     * @notice Error indicating that the fixed lockup amount is invalid
     */
    error InvalidFixedLockupAmount();

    // solhint-disable gas-indexed-events

    /**
     * @notice Event emitted when the lockup period of a rail is updated
     * @param railId The ID of the rail
     * @param newLockupPeriod The new lockup period for the rail
     * @param fixedLockupAmount The fixed lockup amount for the rail
     */
    event LockupPeriodUpdated(uint256 indexed railId, uint256 newLockupPeriod, uint256 fixedLockupAmount);

    /**
     * @notice Event emitted when the payment rate of a rail is modified
     * @param railId The ID of the rail
     * @param priceForRetrieval The new price for retrieval for the rail
     */
    event RailPaymentModified(uint256 indexed railId, uint256 priceForRetrieval);

    // solhint-enable gas-indexed-events

    /// @custom:storage-location erc7201:filecoinpayretrieval.storage.OperatorStorage
    struct OperatorStorage {
        address filecoinPay;
        IERC20 token;
        mapping(uint256 railId => address payer) railIdToPayer;
        mapping(uint256 railId => uint256 price) priceForRetrieval;
    }

    /**
     * @notice Storage location for OperatorStorage struct
     * @dev keccak256(abi.encode(uint256(keccak256("filecoinpayretrieval.storage.OperatorStorage")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant OPERATOR_STORAGE_LOCATION =
        0xc4e3a428136a90500760888642a5b13bddc45b7055c1ebff56928e6ae6937700;

    /**
     * @notice Constructor
     * @dev Constructor disables initializers
     */
    constructor() {
        _disableInitializers(); // LCOV_EXCL_LINE
    }

    // solhint-disable func-param-name-mixedcase
    /**
     * @notice Initializes the contract
     * @param _admin Address to be granted the default admin role
     * @param _filecoinPay Address of the FilecoinPay contract
     * @param token Address of the ERC20 token to be used for payments
     */
    function initialize(address _admin, address _filecoinPay, IERC20 token) external initializer {
        _validateInitializeAddresses(_admin, _filecoinPay, token);

        __AccessControl_init(); // LCOV_EXCL_LINE
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        OperatorStorage storage $ = _getOperatorStorage();
        $.filecoinPay = _filecoinPay;
        $.token = token;
    }

    // solhint-enable function-max-lines, gas-strict-inequalities

    /**
     * @notice Creates a payment rail with the specified parameters and set initial lockup period
     * @dev Only callable by the client
     * @dev Stores the rail ID locally so the admin can finalize or cancel the retrieval payment.
     * @param payer The address paying the tokens
     * @param payee The address receiving the tokens
     * @param fixedLockupAmount The fixed amount of tokens to lock up for the payment rail
     */
    function createRail(address payer, address payee, uint256 fixedLockupAmount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        OperatorStorage storage $ = _getOperatorStorage();

        (bool isApproved,, uint256 lockupAllowance,, uint256 lockupUsage,) =
            IFilecoinPayV1($.filecoinPay).operatorApprovals($.token, payer, address(this));

        if (!isApproved) {
            revert OperatorNotApproved();
        }

        if (fixedLockupAmount == 0) {
            revert InvalidFixedLockupAmount();
        }

        if (lockupAllowance < lockupUsage + fixedLockupAmount) {
            revert InvalidLockupAllowance();
        }

        uint256 railId = _createRail(IFilecoinPayV1($.filecoinPay), $.token, payer, payee, 0, address(0));
        $.railIdToPayer[railId] = payer;
        $.priceForRetrieval[railId] = fixedLockupAmount;
        _setInitialLockup(railId, 0, fixedLockupAmount);
    }

    /**
     * @notice Modifies the payment rate
     * @dev Only callable by POREP_SERVICE bot
     * @param railId The ID of the rail to modify
     */
    function modifyRailPayment(uint256 railId) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        OperatorStorage storage $ = _getOperatorStorage();
        address payer = $.railIdToPayer[railId];
        if (payer == address(0)) {
            revert InvalidRailId();
        }
        uint256 priceForRetrieval = $.priceForRetrieval[railId];
        IFilecoinPayV1 filecoinPay = IFilecoinPayV1($.filecoinPay);

        _modifyRailPayment(filecoinPay, railId, 0, priceForRetrieval);
        _closeRail(filecoinPay, railId);
        _clearRailState($, railId);
        emit RailPaymentModified(railId, priceForRetrieval);
    }

    /**
     * @notice Terminates a payment rail, preventing further payments after the rail's lockup period. After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced.
     * @param railId The ID of the rail to terminate.
     */
    function terminateRail(uint256 railId) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        OperatorStorage storage $ = _getOperatorStorage();
        address payer = $.railIdToPayer[railId];
        if (payer == address(0)) {
            revert InvalidRailId();
        }
        IFilecoinPayV1 filecoinPay = IFilecoinPayV1($.filecoinPay);
        _updateLockupPeriod(filecoinPay, railId, 0, 0);
        _closeRail(filecoinPay, railId);
        _clearRailState($, railId);
    }

    /**
     * @notice Sets the initial lockup period for a payment rail
     * @param railId The ID of the rail for which to set the initial lockup period
     * @param lockupPeriod The lockup period to set
     * @param fixedLockupAmount The fixed amount of tokens to lock up for the payment rail
     */
    function _setInitialLockup(uint256 railId, uint256 lockupPeriod, uint256 fixedLockupAmount) internal {
        OperatorStorage storage $ = _getOperatorStorage();
        _updateLockupPeriod(IFilecoinPayV1($.filecoinPay), railId, lockupPeriod, fixedLockupAmount);
        emit LockupPeriodUpdated(railId, lockupPeriod, fixedLockupAmount);
    }

    /**
     * @notice Terminates and finalizes a rail with Filecoin Pay.
     * @param filecoinPay The FilecoinPay contract.
     * @param railId The ID of the rail to close.
     */
    function _closeRail(IFilecoinPayV1 filecoinPay, uint256 railId) internal {
        IFilecoinPayV1.RailView memory rail = filecoinPay.getRail(railId);
        if (rail.endEpoch == 0) {
            _terminateRail(filecoinPay, railId);
        }
        _settleRail(filecoinPay, railId, block.number);
    }

    /**
     * @notice Clears local bookkeeping for a completed or cancelled rail.
     * @param operatorStorage Operator storage.
     * @param railId The ID of the rail to clear.
     */
    function _clearRailState(OperatorStorage storage operatorStorage, uint256 railId) internal {
        delete operatorStorage.railIdToPayer[railId];
        delete operatorStorage.priceForRetrieval[railId];
    }

    /**
     * @notice Validates that the provided addresses for initialization are not zero addresses
     * @param _admin Address to be granted the default admin role
     * @param _filecoinPay Address of the FilecoinPay contract
     * @param token Address of the ERC20 token to be used for payments
     */
    function _validateInitializeAddresses(address _admin, address _filecoinPay, IERC20 token) internal pure {
        if (_admin == address(0)) {
            revert InvalidAdminAddress();
        }
        if (_filecoinPay == address(0)) {
            revert InvalidFilecoinPayAddress();
        }
        if (address(token) == address(0)) {
            revert InvalidTokenAddress();
        }
    }

    //  solhint-disable
    /**
     * @notice Retrieves the OperatorStorage struct from the designated storage location
     * @return $ Reference to the OperatorStorage struct
     */
    function _getOperatorStorage() private pure returns (OperatorStorage storage $) {
        // LCOV_EXCL_START
        assembly {
            $.slot := OPERATOR_STORAGE_LOCATION
        }
        // LCOV_EXCL_STOP
    }
    // solhint-enable
}

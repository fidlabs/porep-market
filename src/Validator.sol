// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase, private-vars-leading-underscore

pragma solidity =0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

import {IFilecoinPayV1} from "./interfaces/IFilecoinPayV1.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {ISLIScorer} from "./interfaces/ISLIScorer.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {Operator} from "./abstracts/Operator.sol";
import {Client} from "./Client.sol";

/**
 * @title Validator
 * @dev Implements payment validation logic for Filecoin Pay rails
 * @notice Validator contract for Filecoin Pay
 */
contract Validator is Initializable, AccessControlUpgradeable, IValidator, Operator {
    /**
     * @notice Error indicating that the caller is not the FilecoinPay contract
     */
    error CallerIsNotFilecoinPay();

    /**
     * @notice Error indicating that the caller is not the Client Smart Contract
     */
    error CallerIsNotClientSC();

    /**
     * @notice Error indicating that the admin address provided during initialization is the zero address
     */
    error AdminCannotBeZeroAddress();

    /**
     * @notice Error indicating that the FilecoinPay address provided during initialization is the zero address
     */
    error FilecoinPayCannotBeZeroAddress();

    /**
     * @notice Error indicating that the SLC address provided during initialization is the zero address
     */
    error SLCCannotBeZeroAddress();

    /**
     * @notice Error indicating that the client smart contract address provided during initialization is the zero address
     */
    error ClientSCCannotBeZeroAddress();

    /**
     * @notice Error indicating that the PoRepMarket address provided during initialization is the zero address
     */
    error PoRepMarketCannotBeZeroAddress();

    /**
     * @notice Error indicating that the caller is not the client
     */
    error CallerIsNotClient();

    /**
     * @notice Error indicating that a payment rail has already been created for this validator
     */
    error RailAlreadyCreated();

    /**
     * @notice Error indicating that an invalid rail ID was provided
     * @dev We expect only one rail ID to be valid for per validator
     * @param expected The expected rail ID
     * @param actual The actual rail ID provided in the function call
     */
    error InvalidRailId(uint256 expected, uint256 actual);

    // solhint-disable gas-indexed-events
    /**
     * @notice Event emitted when a payment rail is terminated
     * @param railId The ID of the terminated rail
     * @param terminator The address that initiated the termination
     * @param endEpoch The Filecoin epoch at which the rail was terminated
     */
    event RailTerminated(uint256 indexed railId, address indexed terminator, uint256 endEpoch);

    /**
     * @notice Event emitted when the lockup period of a rail is updated
     * @param railId The ID of the rail
     * @param newLockupPeriod The new lockup period for the rail
     */
    event LockupPeriodUpdated(uint256 indexed railId, uint256 newLockupPeriod);

    /**
     * @notice Event emitted when the payment rate of a rail is modified
     * @param railId The ID of the rail
     * @param newRate The new payment rate for the rail
     */
    event RailPaymentModified(uint256 indexed railId, uint256 newRate);

    // solhint-enable gas-indexed-events

    /// @custom:storage-location erc7201:porepmarket.storage.ValidatorStorage
    struct ValidatorStorage {
        uint256 railId;
        uint256 dealId;
        address filecoinPay;
        address SLC;
        address clientSC;
        address poRepMarket;
        CommonTypes.FilActorId providerId;
    }

    /**
     * @notice Role for POREP Bot which is responsible for automating validator functions
     */
    bytes32 public constant POREP_SERVICE_ROLE = keccak256("POREP_SERVICE_ROLE");

    /**
     * @notice Number of epochs in one month
     * @dev 30 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 86_400 epochs
     */
    uint256 private constant EPOCHS_IN_MONTH = 86_400;

    /**
     * @notice Storage location for ValidatorStorage struct
     * @dev keccak256(abi.encode(uint256(keccak256("porepmarket.storage.ValidatorStorage")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant VALIDATOR_STORAGE_LOCATION =
        0xf51cddbeb47ca42a561371db80eaffa401732269b8af46b255e3f43a7c044000;

    /**
     * @notice Modifier to check that the provided rail ID is valid before executing the function
     * @param railId The rail ID to validate
     */
    modifier isRailIdValid(uint256 railId) {
        _checkRailIdValid(railId);
        _;
    }

    /**
     * @notice Constructor
     * @dev Constructor disables initializers
     */
    constructor() {
        _disableInitializers();
    }

    // solhint-disable func-param-name-mixedcase
    /**
     * @notice Initializes the contract
     * @param _admin Address to be granted the default admin role
     * @param _filecoinPay Address of the FilecoinPay contract
     * @param _SLC Address of the SLC contract
     * @param _clientSC Address of the client smart contract
     * @param _poRepMarket Address of the PoRepMarket contract
     * @param _dealId The ID of the deal for which this validator is being initialized
     */
    function initialize(
        address _admin,
        address _filecoinPay,
        address _SLC,
        address _clientSC,
        address _poRepMarket,
        uint256 _dealId
    ) external initializer {
        _validateInitializeAddresses(_admin, _filecoinPay, _SLC, _clientSC, _poRepMarket);

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(POREP_SERVICE_ROLE, _admin);

        ValidatorStorage storage $ = _getValidatorStorage();

        IPoRepMarket.DealProposal memory dealProposal = IPoRepMarket(_poRepMarket).getDealProposal(_dealId);

        $.providerId = dealProposal.provider;
        $.filecoinPay = _filecoinPay;
        $.SLC = _SLC;
        $.clientSC = _clientSC;
        $.poRepMarket = _poRepMarket;
        $.dealId = _dealId;

        IPoRepMarket(_poRepMarket).updateValidatorAddress(_dealId);
    }

    // solhint-enable func-param-name-mixedcase

    // solhint-disable no-unused-vars
    /**
     * @notice Validates a proposed payment amount for a payment rail
     * @dev Only callable by the FilecoinPay contract
     * @param railId ID of the payment rail
     * @param proposedAmount Proposed payment amount to validate
     * @param fromEpoch The epoch up to and including which the rail has already been settled
     * @param toEpoch The epoch up to and including which validation is requested; payment will be validated for (toEpoch - fromEpoch) epochs
     * @param rate Rate used for payment calculation
     * @return result ValidationResult struct containing validation outcome
     */
    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate)
        external
        returns (IValidator.ValidationResult memory result)
    {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.filecoinPay) {
            revert CallerIsNotFilecoinPay();
        }

        _checkRailIdValid(railId);

        if (toEpoch < fromEpoch + EPOCHS_IN_MONTH) {
            result.modifiedAmount = 0;
            result.settleUpto = fromEpoch;
            result.note = "too early for next payout";
            return result;
        }

        IPoRepMarket.DealProposal memory dealProposal = IPoRepMarket($.poRepMarket).getDealProposal($.dealId);
        uint256 score = ISLIScorer($.SLC).calculateScore($.providerId, dealProposal.requirements);
        bool dataSizeMatches = Client($.clientSC).isDataSizeMatching($.dealId);

        if (!dataSizeMatches) {
            result.modifiedAmount = 0;
            result.settleUpto = fromEpoch;
            result.note = "datacap mismatch";
            return result;
        }

        if (score != 100) {
            result.modifiedAmount = 0;
            result.note = "full slash";
        } else {
            result.modifiedAmount = proposedAmount;
            result.note = "ok";
        }

        result.settleUpto = toEpoch;
    }

    /**
     * @notice Creates a payment rail with the specified parameters and set initial lockup period
     * @dev Only callable by the client
     * @dev Sets railID in contract state and updates the PoRepMarket with the created rail ID
     * @param token The ERC20 token to use for the payment rail
     * @param payee The address receiving the tokens
     */
    function createRail(IERC20 token, address payee) external override {
        ValidatorStorage storage $ = _getValidatorStorage();
        IPoRepMarket.DealProposal memory dealProposal = IPoRepMarket($.poRepMarket).getDealProposal($.dealId);

        if (msg.sender != dealProposal.client) {
            revert CallerIsNotClient();
        }

        if ($.railId != 0) {
            revert RailAlreadyCreated();
        }

        uint256 railId = _createRail(IFilecoinPayV1($.filecoinPay), token, dealProposal.client, payee, 0, address(0));
        $.railId = railId;

        IPoRepMarket($.poRepMarket).updateRailId($.dealId, railId);
        _setInitialLockup(railId, EPOCHS_IN_MONTH);
    }

    /**
     * @notice Modifies the payment rate
     * @param railId The ID of the rail to modify.
     * @param newRate The new payment rate (per epoch). This new rate applies starting the next epoch after the current one.
     */
    function modifyRailPayment(uint256 railId, uint256 newRate)
        external
        override
        onlyRole(POREP_SERVICE_ROLE)
        isRailIdValid(railId)
    {
        ValidatorStorage storage $ = _getValidatorStorage();
        IFilecoinPayV1($.filecoinPay).modifyRailPayment(railId, newRate, 0);
        emit RailPaymentModified(railId, newRate);
    }

    /**
     * @notice Updates the lockup period of a payment rail
     * @dev Only callable by the admin
     * @param railId The ID of the rail to modify
     * @param newLockupPeriod New lockup period to set
     */
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        isRailIdValid(railId)
    {
        ValidatorStorage storage $ = _getValidatorStorage();
        _updateLockupPeriod(IFilecoinPayV1($.filecoinPay), railId, newLockupPeriod, 0);
        emit LockupPeriodUpdated(railId, newLockupPeriod);
    }

    /**
     * @notice Terminates a payment rail, preventing further payments after the rail's lockup period. After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced.
     * @param railId The ID of the rail to terminate.
     */
    function terminateRail(uint256 railId) external override onlyRole(POREP_SERVICE_ROLE) isRailIdValid(railId) {
        ValidatorStorage storage $ = _getValidatorStorage();
        IFilecoinPayV1($.filecoinPay).terminateRail(railId);
    }

    /**
     * @notice Invoked when a payment rail is terminated
     * @dev Only callable by the FilecoinPay contract
     * @param railId The ID of the terminated rail
     * @param terminator Address that initiated the termination
     * @param endEpoch Filecoin epoch at which the rail was terminated
     */
    function railTerminated(uint256 railId, address terminator, uint256 endEpoch)
        external
        override
        isRailIdValid(railId)
    {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.filecoinPay) {
            revert CallerIsNotFilecoinPay();
        }

        IPoRepMarket($.poRepMarket).terminateDeal($.dealId, terminator, endEpoch);
        emit RailTerminated(railId, terminator, endEpoch);
    }

    // solhint-enable no-unused-vars

    /**
     * @notice Checks that the provided rail ID matches the expected rail ID stored in contract state
     * @param railId The rail ID to validate
     */
    function _checkRailIdValid(uint256 railId) internal view {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (railId != $.railId) {
            revert InvalidRailId({expected: $.railId, actual: railId});
        }
    }

    /**
     * @notice Sets the initial lockup period for a payment rail
     * @param railId The ID of the rail for which to set the initial lockup period
     * @param lockupPeriod The lockup period to set
     */
    function _setInitialLockup(uint256 railId, uint256 lockupPeriod) internal {
        ValidatorStorage storage $ = _getValidatorStorage();
        _updateLockupPeriod(IFilecoinPayV1($.filecoinPay), railId, lockupPeriod, 0);
    }

    /**
     * @notice Validates that the provided addresses for initialization are not zero addresses
     * @param admin Address to be granted the default admin role
     * @param _filecoinPay Address of the FilecoinPay contract
     * @param _SLC Address of the SLC contract
     * @param _clientSC Address of the client smart contract
     * @param _poRepMarket Address of the PoRepMarket contract
     */
    function _validateInitializeAddresses(
        address admin,
        address _filecoinPay,
        address _SLC,
        address _clientSC,
        address _poRepMarket
    ) internal pure {
        if (admin == address(0)) {
            revert AdminCannotBeZeroAddress();
        }
        if (_filecoinPay == address(0)) {
            revert FilecoinPayCannotBeZeroAddress();
        }
        if (_SLC == address(0)) {
            revert SLCCannotBeZeroAddress();
        }
        if (_clientSC == address(0)) {
            revert ClientSCCannotBeZeroAddress();
        }
        if (_poRepMarket == address(0)) {
            revert PoRepMarketCannotBeZeroAddress();
        }
    }

    //  solhint-disable
    /**
     * @notice Retrieves the ValidatorStorage struct from the designated storage location
     * @return $ Reference to the ValidatorStorage struct
     */
    function _getValidatorStorage() private pure returns (ValidatorStorage storage $) {
        assembly {
            $.slot := VALIDATOR_STORAGE_LOCATION
        }
    }
    // solhint-enable
}

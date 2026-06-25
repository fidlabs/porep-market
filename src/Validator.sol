// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

import {IFilecoinPayV1} from "./interfaces/IFilecoinPayV1.sol";
import {IFilecoinPayValidator} from "./interfaces/IFilecoinPayValidator.sol";
import {ISLIScorer} from "./interfaces/ISLIScorer.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {IDataCapEvidenceAdapter} from "./interfaces/IDataCapEvidenceAdapter.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {Operator} from "./abstracts/Operator.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {SharedTypes} from "./types/SharedTypes.sol";
import {RailStatus} from "./types/RailStatus.sol";

/**
 * @title Validator
 * @dev Implements validator and operator logic for managing Filecoin Pay rails
 * @notice Validator contract for Filecoin Pay
 */
contract Validator is Initializable, AccessControlUpgradeable, IFilecoinPayValidator, IValidator, Operator {
    /**
     * @notice Error indicating that the caller is not the FilecoinPay contract
     * @dev 0x46a5d52f
     */
    error CallerIsNotFilecoinPay();

    /**
     * @notice Error indicating that the caller is not the PoRepMarket contract
     * @dev 0x9dd45c94
     */
    error CallerIsNotPoRepMarket();

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
     * @notice Error indicating that the SLIScorer address provided during initialization is the zero address
     * @dev 0x91d3d465
     */
    error InvalidSLIScorerAddress();

    /**
     * @notice Error indicating that the DataCap evidence adapter address provided during initialization is the zero address
     * @dev 0xd2178646
     */
    error InvalidDataCapEvidenceAdapterAddress();

    /**
     * @notice Error indicating that the PoRepMarket address provided during initialization is the zero address
     * @dev 0xc9cc4a06
     */
    error InvalidPoRepMarketAddress();

    /**
     * @notice Error indicating that the PoRep service bot address provided during initialization is the zero address
     * @dev 0x7725d473
     */
    error InvalidPoRepServiceAddress();

    /**
     * @notice Error indicating that the SPRegistry address provided during initialization is the zero address
     * @dev 0xe6e262d1
     */
    error InvalidSPRegistryAddress();

    /**
     * @notice Error indicating that the caller is not the client
     * @dev 0x370ce6d7
     */
    error CallerIsNotClient();

    /**
     * @notice Error indicating that a payment rail has already been created for this validator
     * @dev 0xde605aee
     */
    error RailAlreadyCreated();

    /**
     * @notice Error indicating that an invalid deal ID was provided
     * @dev 0xb06db32a
     */
    error InvalidDealId();

    /**
     * @notice Error indicating that the operator is not approved
     * @dev 0xe3129001
     */
    error OperatorNotApproved();

    /**
     * @notice Error indicating that the maximum lockup period is less than the minimum required lockup period
     * @dev 0x1f27f313
     */
    error MaxLockupPeriodLessThanMinimum();

    /**
     * @notice Error indicating that the lockup allowance is not set properly
     * @dev 0xae339be9
     */
    error InvalidLockupAllowance();

    /**
     * @notice Error indicating that the rate allowance is not set properly
     * @dev 0xf55adfc6
     */
    error InvalidRateAllowance();

    /**
     * @notice Error indicating that the caller is not authorized to perform the action
     * @dev 0x5c427cd9
     */
    error UnauthorizedCaller();

    /**
     * @notice Error indicating that the calculated amount per epoch is zero, which is invalid
     * @dev 0xdd484e70
     */
    error InvalidZeroAmount();

    /**
     * @notice Error indicating that the deal payment/service window has not been activated yet
     * @param dealId The ID of the deal whose payment/service window is not active
     * @dev 0xe03f8b0e
     */
    error DealPaymentNotActivated(uint256 dealId);

    /**
     * @notice Error indicating that an invalid rail ID was provided
     * @dev We expect only one rail ID to be valid for per validator
     * @param expected The expected rail ID
     * @param actual The actual rail ID provided in the function call
     * @dev 0x664f7d6c
     */
    error InvalidRailId(uint256 expected, uint256 actual);

    /**
     * @notice Error indicating that the minimum time between settlements is invalid
     * @dev 0xf90f5b8f
     */
    error InvalidMinEpochsBetweenSettlements();

    /**
     * @notice Error indicating that the maximum time between settlements is exceeded
     * @dev 0xb0c81e57
     */
    error MinEpochsBetweenSettlementsExceeded();

    /**
     * @notice Error indicating that a deal is not ready to be finished
     * @param serviceEndEpoch The epoch at which the deal service ends
     * @param currentEpoch The current block epoch
     */
    error ServiceNotEnded(uint256 serviceEndEpoch, uint256 currentEpoch);

    /**
     * @notice Error indicating that an invalid terminator address was provided
     * @dev 0xee5ab23e
     */
    error InvalidTerminator();

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

    /**
     * @notice Event emitted when a rail is terminated early
     * @param railId The ID of the rail that was terminated early
     */
    event EarlyRailTerminated(uint256 indexed railId);

    /**
     * @notice Event emitted when a deal and its payment rail are finished
     * @param dealId The ID of the finalized deal
     * @param railId The ID of the finished rail
     */
    event DealFinalized(uint256 indexed dealId, uint256 indexed railId);

    /**
     * @notice Event emitted when the minimum time between settlements is updated
     * @param dealId The ID of the deal associated with the validator
     * @param minTimeBetweenSettlementsInEpochs The new minimum time between settlements in epochs
     */
    event MinEpochsBetweenSettlementsUpdated(uint256 indexed dealId, uint256 minTimeBetweenSettlementsInEpochs);

    // solhint-enable gas-indexed-events

    /// @custom:storage-location erc7201:porepmarket.storage.ValidatorStorage
    struct ValidatorStorage {
        uint256 railId;
        uint256 dealId;
        uint8 railStatus;
        address filecoinPay;
        address SLIScorer;
        address dataCapEvidenceAdapter;
        address poRepMarket;
        address SPRegistry;
        CommonTypes.FilActorId providerId;
        uint256 amountPerEpoch;
        uint256 earlyTerminatedEpoch;
        uint256 minTimeBetweenSettlementsInEpochs;
    }

    /**
     * @notice Role for PoRep bot which is responsible for automating validator functions
     */
    bytes32 public constant POREP_SERVICE_ROLE = keccak256("POREP_SERVICE_ROLE");

    /**
     * @notice Name of the validator
     */
    string public constant NAME = "FCSS";

    /**
     * @notice Description of the validator
     */
    string public constant DESCRIPTION = "Filecoin Cold Storage Service";

    /**
     * @notice Number of epochs in one month
     * @dev 30 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 86_400 epochs
     */
    uint256 private constant EPOCHS_IN_MONTH = 86_400;

    /**
     * @notice Number of epochs in one year
     * @dev 365 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 1_051_200 epochs
     */
    uint256 private constant EPOCHS_IN_YEAR = 1_051_200;

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
     * @param _porepService Address of the PoRep service bot
     * @param _filecoinPay Address of the FilecoinPay contract
     * @param _SLIScorer Address of the SLIScorer contract
     * @param _dataCapEvidenceAdapter Address of the DataCap evidence adapter
     * @param _poRepMarket Address of the PoRepMarket contract
     * @param _SPRegistry Address of the SPRegistry contract
     * @param _dealId The ID of the deal for which this validator is being initialized
     */
    function initialize(
        address _admin,
        address _porepService,
        address _filecoinPay,
        address _SLIScorer,
        address _dataCapEvidenceAdapter,
        address _poRepMarket,
        address _SPRegistry,
        uint256 _dealId
    ) external initializer {
        _validateInitializeAddresses(
            _admin, _porepService, _filecoinPay, _SLIScorer, _dataCapEvidenceAdapter, _SPRegistry, _poRepMarket
        );

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(POREP_SERVICE_ROLE, _porepService);

        ValidatorStorage storage $ = _getValidatorStorage();

        PoRepTypes.Deal memory deal = IPoRepMarket(_poRepMarket).getDeal(_dealId);

        $.providerId = deal.provider;
        $.filecoinPay = _filecoinPay;
        $.SLIScorer = _SLIScorer;
        $.dataCapEvidenceAdapter = _dataCapEvidenceAdapter;
        $.poRepMarket = _poRepMarket;
        $.SPRegistry = _SPRegistry;
        $.dealId = _dealId;
        $.minTimeBetweenSettlementsInEpochs = EPOCHS_IN_MONTH;

        IPoRepMarket(_poRepMarket).updateValidator(_dealId);
    }

    // solhint-enable func-param-name-mixedcase

    // solhint-disable function-max-lines, gas-strict-inequalities
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
        override
        returns (ValidationResult memory result)
    {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.filecoinPay) {
            revert CallerIsNotFilecoinPay();
        }

        _checkRailIdValid(railId);

        PoRepTypes.DealService memory service = IPoRepMarket($.poRepMarket).getDealService($.dealId);
        uint256 serviceEndEpoch = uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch)));

        if (serviceEndEpoch == 0) {
            revert DealPaymentNotActivated($.dealId);
        }

        if ($.earlyTerminatedEpoch != 0 && $.earlyTerminatedEpoch < serviceEndEpoch) {
            serviceEndEpoch = $.earlyTerminatedEpoch;
        }

        if (toEpoch < fromEpoch + $.minTimeBetweenSettlementsInEpochs) {
            result.settleUpto = fromEpoch;
            result.note = "too early for settlement";
            return result;
        }

        SharedTypes.SLIThresholds memory slis = IPoRepMarket($.poRepMarket).getDealSLIs($.dealId);
        uint256 score = ISLIScorer($.SLIScorer).calculateScore($.dealId, slis);

        bool scoreMatches = score == 100;
        bool dataSizeMatches = IDataCapEvidenceAdapter($.dataCapEvidenceAdapter).isDataSizeMatching($.dealId);

        if (!scoreMatches || !dataSizeMatches) {
            result.settleUpto = toEpoch;
            result.note = !scoreMatches ? "score below required threshold" : "data size does not match the deal";
            return result;
        }

        if (fromEpoch >= serviceEndEpoch) {
            result.settleUpto = fromEpoch;
            result.note = "service ended";
            return result;
        }

        if (toEpoch > serviceEndEpoch) {
            result.modifiedAmount = rate * (serviceEndEpoch - fromEpoch);
            result.note = "limited to service end epoch";
            result.settleUpto = serviceEndEpoch;
        } else {
            result.modifiedAmount = proposedAmount;
            result.note = "payment validated successfully";
            result.settleUpto = toEpoch;
        }
    }

    // solhint-enable function-max-lines, gas-strict-inequalities

    /**
     * @notice Creates a payment rail with the specified parameters and set initial lockup period
     * @dev Only callable by the client
     * @dev Sets railID in contract state and updates the PoRepMarket with the created rail ID
     * @param token Kept for interface compatibility; the payment rail token is read from the frozen deal payment state
     */
    function createRail(IERC20 token) external override {
        ValidatorStorage storage $ = _getValidatorStorage();
        PoRepTypes.Deal memory deal = IPoRepMarket($.poRepMarket).getDeal($.dealId);
        PoRepTypes.DealPayment memory payment = IPoRepMarket($.poRepMarket).getDealPayment($.dealId);
        IERC20 railToken = IERC20(payment.paymentToken);
        token;

        if (msg.sender != deal.client) {
            revert CallerIsNotClient();
        }

        if ($.railId != 0) {
            revert RailAlreadyCreated();
        }

        (bool isApproved, uint256 rateAllowance, uint256 lockupAllowance,,, uint256 maxLockupPeriod) =
            IFilecoinPayV1($.filecoinPay).operatorApprovals(railToken, deal.client, address(this));

        if (!isApproved) {
            revert OperatorNotApproved();
        }

        if (maxLockupPeriod < EPOCHS_IN_MONTH) {
            revert MaxLockupPeriodLessThanMinimum();
        }

        if (lockupAllowance == 0) {
            revert InvalidLockupAllowance();
        }

        if (rateAllowance == 0) {
            revert InvalidRateAllowance();
        }

        uint256 railId =
            _createRail(IFilecoinPayV1($.filecoinPay), railToken, deal.client, payment.payee, 0, address(0));
        $.railStatus = RailStatus.PREPARED;
        $.railId = railId;

        IPoRepMarket($.poRepMarket).updateRailId($.dealId, railId);
        _setInitialLockup(EPOCHS_IN_MONTH);
    }

    /**
     * @notice Modifies the payment rate
     * @dev Only callable by the PoRepMarket contract
     * @param newRate The new payment rate per epoch
     */
    function modifyRailPayment(uint256 newRate) external override {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.poRepMarket) {
            revert CallerIsNotPoRepMarket();
        }

        if (newRate == 0) {
            revert InvalidZeroAmount();
        }

        $.amountPerEpoch = newRate;

        if ($.railStatus != RailStatus.TERMINATED) {
            $.railStatus = RailStatus.ACTIVE;
        }

        _modifyRailPayment(IFilecoinPayV1($.filecoinPay), $.railId, newRate, 0);
        emit RailPaymentModified($.railId, newRate);
    }

    /**
     * @notice Terminates a payment rail early and terminates its deal
     * @dev Only callable by POREP_SERVICE bot
     */
    function earlyRailTermination() external override onlyRole(POREP_SERVICE_ROLE) {
        ValidatorStorage storage $ = _getValidatorStorage();
        _terminateDeal();
        _terminateRail(IFilecoinPayV1($.filecoinPay), $.railId);
        emit EarlyRailTerminated($.railId);
    }

    /**
     * @notice Updates the lockup period of a payment rail
     * @dev Only callable by the admin
     * @param newLockupPeriod New lockup period to set
     */
    function updateLockupPeriod(uint256 newLockupPeriod) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        ValidatorStorage storage $ = _getValidatorStorage();
        _updateLockupPeriod(IFilecoinPayV1($.filecoinPay), $.railId, newLockupPeriod, 0);
        emit LockupPeriodUpdated($.railId, newLockupPeriod);
    }

    /**
     * @notice Terminates the deal and its payment rail.
     */
    function finalizeDeal() external override {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (!hasRole(POREP_SERVICE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }

        PoRepTypes.DealService memory service = IPoRepMarket($.poRepMarket).getDealService($.dealId);
        uint256 serviceEndEpoch = uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch)));
        bool serviceEnded = serviceEndEpoch < block.number;
        if (!serviceEnded) {
            revert ServiceNotEnded(serviceEndEpoch, block.number);
        }

        $.railStatus = RailStatus.TERMINATED;
        IPoRepMarket($.poRepMarket).finalizeDeal($.dealId);
        _terminateRail(IFilecoinPayV1($.filecoinPay), $.railId);
        emit DealFinalized($.dealId, $.railId);
    }

    /**
     * @notice Terminates the deal in PoRep Market and records the early termination epoch.
     */
    function _terminateDeal() internal {
        ValidatorStorage storage $ = _getValidatorStorage();
        $.earlyTerminatedEpoch = block.number;
        $.railStatus = RailStatus.TERMINATED;
        IPoRepMarket($.poRepMarket).terminateDeal($.dealId, block.number);
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

        if (terminator != address(this)) {
            revert InvalidTerminator();
        }

        emit RailTerminated(railId, terminator, endEpoch);
    }

    /**
     * @notice Sets the minimum time between settlements in epochs
     * @dev Only callable by the admin
     * @param minEpochs Minimum time between settlements in epochs
     */
    function setMinEpochsBetweenSettlements(uint256 minEpochs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minEpochs == 0) {
            revert InvalidMinEpochsBetweenSettlements();
        }

        if (minEpochs > EPOCHS_IN_YEAR) {
            revert MinEpochsBetweenSettlementsExceeded();
        }
        ValidatorStorage storage $ = _getValidatorStorage();
        $.minTimeBetweenSettlementsInEpochs = minEpochs;
        emit MinEpochsBetweenSettlementsUpdated($.dealId, minEpochs);
    }

    /**
     * @notice Retrieves the minimum time between settlements in epochs
     * @return minTimeBetweenSettlementsInEpochs Minimum time between settlements in epochs
     */
    function getMinEpochsBetweenSettlements() external view returns (uint256 minTimeBetweenSettlementsInEpochs) {
        minTimeBetweenSettlementsInEpochs = _getValidatorStorage().minTimeBetweenSettlementsInEpochs;
    }

    /**
     * @notice Retrieves the current status of the payment rail
     * @return railStatus Current status of the payment rail
     */
    function getRailStatus() external view returns (uint8 railStatus) {
        railStatus = _getValidatorStorage().railStatus;
    }

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
     * @param lockupPeriod The lockup period to set
     */
    function _setInitialLockup(uint256 lockupPeriod) internal {
        ValidatorStorage storage $ = _getValidatorStorage();
        _updateLockupPeriod(IFilecoinPayV1($.filecoinPay), $.railId, lockupPeriod, 0);
        emit LockupPeriodUpdated($.railId, lockupPeriod);
    }

    /**
     * @notice Validates that the provided addresses for initialization are not zero addresses
     * @param _admin Address to be granted the default admin role
     * @param _porepService Address of the PoRep service bot
     * @param _filecoinPay Address of the FilecoinPay contract
     * @param _SLIScorer Address of the SLIScorer contract
     * @param _dataCapEvidenceAdapter Address of the DataCap evidence adapter
     * @param _SPRegistry Address of the SPRegistry contract
     * @param _poRepMarket Address of the PoRepMarket contract
     */
    function _validateInitializeAddresses(
        address _admin,
        address _porepService,
        address _filecoinPay,
        address _SLIScorer,
        address _dataCapEvidenceAdapter,
        address _SPRegistry,
        address _poRepMarket
    ) internal pure {
        if (_admin == address(0)) {
            revert InvalidAdminAddress();
        }
        if (_porepService == address(0)) {
            revert InvalidPoRepServiceAddress();
        }
        if (_filecoinPay == address(0)) {
            revert InvalidFilecoinPayAddress();
        }
        if (_SLIScorer == address(0)) {
            revert InvalidSLIScorerAddress();
        }
        if (_dataCapEvidenceAdapter == address(0)) {
            revert InvalidDataCapEvidenceAdapterAddress();
        }
        if (_SPRegistry == address(0)) {
            revert InvalidSPRegistryAddress();
        }
        if (_poRepMarket == address(0)) {
            revert InvalidPoRepMarketAddress();
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

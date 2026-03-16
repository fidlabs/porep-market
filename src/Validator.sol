// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

import {IFilecoinPayV1} from "./interfaces/IFilecoinPayV1.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {ISLIScorer} from "./interfaces/ISLIScorer.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {Operator} from "./abstracts/Operator.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {Client} from "./Client.sol";

/**
 * @title Validator
 * @dev Implements validator and operator logic for managing Filecoin Pay rails
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
    error InvalidAdminAddress();

    /**
     * @notice Error indicating that the FilecoinPay address provided during initialization is the zero address
     */
    error InvalidFilecoinPayAddress();

    /**
     * @notice Error indicating that the SLIScorer address provided during initialization is the zero address
     */
    error InvalidSLIScorerAddress();

    /**
     * @notice Error indicating that the client smart contract address provided during initialization is the zero address
     */
    error InvalidClientSCAddress();

    /**
     * @notice Error indicating that the PoRepMarket address provided during initialization is the zero address
     */
    error InvalidPoRepMarketAddress();

    /**
     * @notice Error indicating that the PoRep service bot address provided during initialization is the zero address
     */
    error InvalidPoRepServiceAddress();

    /**
     * @notice Error indicating that the SPRegistry address provided during initialization is the zero address
     */
    error InvalidSPRegistryAddress();

    /**
     * @notice Error indicating that the caller is not the client
     */
    error CallerIsNotClient();

    /**
     * @notice Error indicating that a payment rail has already been created for this validator
     */
    error RailAlreadyCreated();

    /**
     * @notice Error indicating that an invalid deal ID was provided
     */
    error InvalidDealId();

    /**
     * @notice Error indicating that the operator is not approved
     */
    error OperatorNotApproved();

    /**
     * @notice Error indicating that the maximum lockup period is less than the minimum required lockup period
     */
    error MaxLockupPeriodLessThanMinimum();

    /**
     * @notice Error indicating that the lockup allowance is not set properly
     */
    error InvalidLockupAllowance();

    /**
     * @notice Error indicating that the rate allowance is not set properly
     */
    error InvalidRateAllowance();

    /**
     * @notice Error indicating that the number of sectors in the deal is zero, which is invalid
     */
    error InvalidSectorCount();

    /**
     * @notice Error indicating that the duration of the deal is zero, which is invalid
     */
    error InvalidDealDuration();

    /**
     * @notice Error indicating that the caller is not authorized to perform the action
     */
    error UnauthorizedCaller();

    /**
     * @notice Error indicating that the provided end epoch is negative, which is invalid
     */
    error NegativeEndEpoch();

    /**
     * @notice Error indicating that the calculated amount per epoch is zero, which is invalid
     */
    error InvalidZeroAmount();

    /**
     * @notice Error indicating that the deal associated with this validator has not been completed yet
     * @param dealId The ID of the deal that is not completed
     */
    error DealNotCompleted(uint256 dealId);

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

    /**
     * @notice Event emitted when the deal end epoch is updated
     * @param dealId The ID of the deal
     * @param endEpoch The Filecoin epoch at which the deal ended
     */
    event DealEndEpochUpdated(uint256 indexed dealId, CommonTypes.ChainEpoch endEpoch);

    /**
     * @notice Event emitted when a rail is disabled for future payments
     * @param railId The ID of the rail that has been disabled
     */
    event RailDisabled(uint256 indexed railId);

    // solhint-enable gas-indexed-events

    /// @custom:storage-location erc7201:porepmarket.storage.ValidatorStorage
    struct ValidatorStorage {
        uint256 railId;
        uint256 dealId;
        address filecoinPay;
        address SLIScorer;
        address clientSC;
        address poRepMarket;
        address SPRegistry;
        CommonTypes.FilActorId providerId;
        CommonTypes.ChainEpoch dealEndEpoch;
        uint256 amountPerEpoch;
        uint256 earlyTerminatedEpoch;
    }

    /**
     * @notice Role for PoRep bot which is responsible for automating validator functions
     */
    bytes32 public constant POREP_SERVICE_ROLE = keccak256("POREP_SERVICE_ROLE");

    /**
     * @notice Number of epochs in one month
     * @dev 30 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 86_400 epochs
     */
    uint256 private constant EPOCHS_IN_MONTH = 86_400;

    /**
     * @notice Number of epochs in one day
     * @dev 24 hours/day * 60 minutes/hour * 2 epochs/minute = 2_880 epochs
     */
    uint256 private constant EPOCHS_IN_DAY = 2_880;

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
     * @param _clientSC Address of the client smart contract
     * @param _poRepMarket Address of the PoRepMarket contract
     * @param _SPRegistry Address of the SPRegistry contract
     * @param _dealId The ID of the deal for which this validator is being initialized
     */
    function initialize(
        address _admin,
        address _porepService,
        address _filecoinPay,
        address _SLIScorer,
        address _clientSC,
        address _poRepMarket,
        address _SPRegistry,
        uint256 _dealId
    ) external initializer {
        _validateInitializeAddresses(
            _admin, _porepService, _filecoinPay, _SLIScorer, _clientSC, _SPRegistry, _poRepMarket
        );

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(POREP_SERVICE_ROLE, _porepService);

        ValidatorStorage storage $ = _getValidatorStorage();

        PoRepTypes.DealProposal memory dealProposal = IPoRepMarket(_poRepMarket).getDealProposal(_dealId);

        $.providerId = dealProposal.provider;
        $.filecoinPay = _filecoinPay;
        $.SLIScorer = _SLIScorer;
        $.clientSC = _clientSC;
        $.poRepMarket = _poRepMarket;
        $.SPRegistry = _SPRegistry;
        $.dealId = _dealId;

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
        returns (IValidator.ValidationResult memory result)
    {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.filecoinPay) {
            revert CallerIsNotFilecoinPay();
        }

        _checkRailIdValid(railId);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 dealEndEpoch = uint256(uint64(CommonTypes.ChainEpoch.unwrap($.dealEndEpoch)));

        if (dealEndEpoch == 0) {
            revert DealNotCompleted($.dealId);
        }

        if ($.earlyTerminatedEpoch != 0 && $.earlyTerminatedEpoch < dealEndEpoch) {
            dealEndEpoch = $.earlyTerminatedEpoch;
        }

        if (toEpoch < fromEpoch + EPOCHS_IN_MONTH) {
            result.settleUpto = fromEpoch;
            result.note = "1mo payout period not reached";
            return result;
        }

        PoRepTypes.DealProposal memory dealProposal = IPoRepMarket($.poRepMarket).getDealProposal($.dealId);
        uint256 score = ISLIScorer($.SLIScorer).calculateScore($.providerId, dealProposal.requirements);

        bool scoreMatches = score == 100;
        bool dataSizeMatches = Client($.clientSC).isDataSizeMatching($.dealId);

        if (!scoreMatches || !dataSizeMatches) {
            result.settleUpto = toEpoch;
            result.note =
                !scoreMatches ? "score below required threshold" : "data size does not match the deal proposal";
            return result;
        }

        if (fromEpoch >= dealEndEpoch) {
            result.settleUpto = fromEpoch;
            result.note = "deal ended";
            return result;
        }

        if (toEpoch > dealEndEpoch) {
            result.modifiedAmount = rate * (dealEndEpoch - fromEpoch);
            result.note = "payment limited to deal endepoch";
            result.settleUpto = dealEndEpoch;
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
     * @param token The ERC20 token to use for the payment rail
     */
    function createRail(IERC20 token) external override {
        ValidatorStorage storage $ = _getValidatorStorage();
        PoRepTypes.DealProposal memory dealProposal = IPoRepMarket($.poRepMarket).getDealProposal($.dealId);

        if (msg.sender != dealProposal.client) {
            revert CallerIsNotClient();
        }

        if ($.railId != 0) {
            revert RailAlreadyCreated();
        }

        (bool isApproved, uint256 rateAllowance, uint256 lockupAllowance,,, uint256 maxLockupPeriod) =
            IFilecoinPayV1($.filecoinPay).operatorApprovals(token, dealProposal.client, address(this));

        if (!isApproved) {
            revert OperatorNotApproved();
        }
        /// NOTE: to be discussed - might be shorter period than a month
        if (maxLockupPeriod < EPOCHS_IN_MONTH) {
            revert MaxLockupPeriodLessThanMinimum();
        }

        if (lockupAllowance == 0) {
            revert InvalidLockupAllowance();
        }

        if (rateAllowance == 0) {
            revert InvalidRateAllowance();
        }

        address payee = ISPRegistry($.SPRegistry).getPayee($.providerId);

        uint256 railId = _createRail(IFilecoinPayV1($.filecoinPay), token, dealProposal.client, payee, 0, address(0));
        $.railId = railId;

        IPoRepMarket($.poRepMarket).updateRailId($.dealId, railId);
        _setInitialLockup(railId, EPOCHS_IN_MONTH);
    }

    /**
     * @notice Modifies the payment rate
     * @dev Only callable by POREP_SERVICE bot
     * @param railId The ID of the rail to modify
     */
    function modifyRailPayment(uint256 railId) external override onlyRole(POREP_SERVICE_ROLE) isRailIdValid(railId) {
        ValidatorStorage storage $ = _getValidatorStorage();

        uint256 newRate = _calculateAmountPerEpoch();
        $.amountPerEpoch = newRate;

        _modifyRailPayment(IFilecoinPayV1($.filecoinPay), railId, newRate, 0);
        emit RailPaymentModified(railId, newRate);
    }

    /**
     * @notice Disables future payments for a payment rail by terminating the rail
     * @dev Only callable by POREP_SERVICE bot
     * @dev After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced
     * @param railId The ID of the rail to terminate
     */
    function disableFutureRailPayments(uint256 railId) external onlyRole(POREP_SERVICE_ROLE) isRailIdValid(railId) {
        ValidatorStorage storage $ = _getValidatorStorage();
        $.earlyTerminatedEpoch = block.number;
        _terminateRail(IFilecoinPayV1($.filecoinPay), railId);
        emit RailDisabled(railId);
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
    function terminateRail(uint256 railId) external override isRailIdValid(railId) {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (!hasRole(POREP_SERVICE_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _terminateRail(IFilecoinPayV1($.filecoinPay), railId);
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

    /**
     * @notice Sets the end epoch for the deal associated with this validator
     * @dev Only callable by the client smart contract
     * @param dealId The ID of the deal
     * @param endEpoch The Filecoin epoch at which the deal ended
     */
    function setDealEndEpoch(uint256 dealId, CommonTypes.ChainEpoch endEpoch) external {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.clientSC) {
            revert CallerIsNotClientSC();
        }

        if (dealId != $.dealId) {
            revert InvalidDealId();
        }

        int64 unwrappedEndEpoch = CommonTypes.ChainEpoch.unwrap(endEpoch);
        if (unwrappedEndEpoch < 0) {
            revert NegativeEndEpoch();
        }

        $.dealEndEpoch = endEpoch;
        emit DealEndEpochUpdated(dealId, endEpoch);
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
     * @param railId The ID of the rail for which to set the initial lockup period
     * @param lockupPeriod The lockup period to set
     */
    function _setInitialLockup(uint256 railId, uint256 lockupPeriod) internal {
        ValidatorStorage storage $ = _getValidatorStorage();
        _updateLockupPeriod(IFilecoinPayV1($.filecoinPay), railId, lockupPeriod, 0);
        emit LockupPeriodUpdated(railId, lockupPeriod);
    }

    /**
     * @notice Calculates the amount to be paid per epoch for the deal
     * @return Amount to be paid per epoch
     */
    function _calculateAmountPerEpoch() internal view returns (uint256) {
        ValidatorStorage storage $ = _getValidatorStorage();

        PoRepTypes.DealProposal memory dealProposal = IPoRepMarket($.poRepMarket).getDealProposal($.dealId);
        CommonTypes.FilActorId[] memory allocationIds = Client($.clientSC).getClientAllocationIdsPerDeal($.dealId);

        uint256 sectorCount = allocationIds.length;
        uint256 pricePerSector = dealProposal.terms.pricePerSector;
        uint32 durationDays = dealProposal.terms.durationDays;

        if (sectorCount == 0) {
            revert InvalidSectorCount();
        }

        if (durationDays == 0) {
            revert InvalidDealDuration();
        }

        uint256 totalEpochs = durationDays * EPOCHS_IN_DAY;
        uint256 amount = (pricePerSector * sectorCount) / totalEpochs;

        if (amount == 0) {
            revert InvalidZeroAmount();
        }

        return amount;
    }

    /**
     * @notice Validates that the provided addresses for initialization are not zero addresses
     * @param _admin Address to be granted the default admin role
     * @param _porepService Address of the PoRep service bot
     * @param _filecoinPay Address of the FilecoinPay contract
     * @param _SLIScorer Address of the SLIScorer contract
     * @param _clientSC Address of the client smart contract
     * @param _SPRegistry Address of the SPRegistry contract
     * @param _poRepMarket Address of the PoRepMarket contract
     */
    function _validateInitializeAddresses(
        address _admin,
        address _porepService,
        address _filecoinPay,
        address _SLIScorer,
        address _clientSC,
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
        if (_clientSC == address(0)) {
            revert InvalidClientSCAddress();
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

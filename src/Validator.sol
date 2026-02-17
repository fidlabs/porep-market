// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase, private-vars-leading-underscore

pragma solidity =0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {PrecompilesAPI} from "filecoin-solidity/v0.8/PrecompilesAPI.sol";
import {FilAddressIdConverter} from "filecoin-solidity/v0.8/utils/FilAddressIdConverter.sol";

import {IFilecoinPayV1} from "./interfaces/IFilecoinPayV1.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {MinerUtils} from "./libs/MinerUtils.sol";
import {Operator} from "./abstracts/Operator.sol";
import {PoRepMarket} from "./PoRepMarket.sol";
import {SLCMock} from "../test/contracts/SLCMock.sol";
import {ClientSCMock} from "../test/contracts/ClientSCMock.sol";

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

    // solhint-enable gas-indexed-events

    /// @custom:storage-location erc7201:porepmarket.storage.ValidatorStorage
    struct ValidatorStorage {
        uint256 railId;
        address filecoinPay;
        address SLC;
        address clientSC;
        address poRepMarket;
        CommonTypes.FilActorId providerId;
    }

    /**
     * @notice Input parameters for deposit and rail creation
     */
    struct DepositWithRailInputParams {
        IERC20 token;
        uint8 v;
        uint256 amount;
        uint256 deadline;
        bytes32 r;
        bytes32 s;
        uint256 dealId;
    }

    /**
     * @notice Role for settlement service
     */
    bytes32 public constant SETTLEMENT_SERVICE_ROLE = keccak256("SETTLEMENT_SERVICE_ROLE");

    /**
     * @notice Number of epochs in one month
     * @dev 30 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 86,400 epochs
     */
    uint256 private constant EPOCHS_IN_MONTH = 86_400;

    /**
     * @notice Maximum lockup period (5 years)
     * @dev 5 years * 365 days/year * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 5_256_000 epochs
     */
    uint256 private constant MAX_LOCKUP_PERIOD = 5_256_000;

    /**
     * @notice Storage location for ValidatorStorage struct
     * @dev keccak256(abi.encode(uint256(keccak256("porepmarket.storage.ValidatorStorage")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant VALIDATOR_STORAGE_LOCATION =
        0xf51cddbeb47ca42a561371db80eaffa401732269b8af46b255e3f43a7c044000;

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
     * @param admin Address to be granted the default admin role
     * @param _filecoinPay Address of the FilecoinPay contract
     * @param _SLC Address of the SLC contract
     * @param _clientSC Address of the client smart contract
     * @param _poRepMarket Address of the PoRepMarket contract
     * @param params Parameters for deposit and rail creation
     */
    function initialize(
        address admin,
        address _filecoinPay,
        address _SLC,
        address _clientSC,
        address _poRepMarket,
        DepositWithRailInputParams calldata params
    ) external initializer {
        _validateInitializeAddresses(admin, _filecoinPay, _SLC, _clientSC, _poRepMarket);

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SETTLEMENT_SERVICE_ROLE, admin);

        ValidatorStorage storage $ = _getValidatorStorage();

        PoRepMarket.DealProposal memory dp = PoRepMarket(_poRepMarket).getDealProposal(params.dealId);
        address payer = dp.client;

        CommonTypes.FilAddress memory providerOwner = MinerUtils.getOwner(dp.provider).owner;
        uint64 providerOwnerId = PrecompilesAPI.resolveAddress(providerOwner);
        address payee = FilAddressIdConverter.toAddress(providerOwnerId);

        $.providerId = dp.provider;
        $.filecoinPay = _filecoinPay;
        $.SLC = _SLC;
        $.clientSC = _clientSC;
        $.poRepMarket = _poRepMarket;

        DepositWithRailParams memory initParams = DepositWithRailParams({
            token: params.token,
            payer: payer,
            payee: payee,
            amount: params.amount,
            deadline: params.deadline,
            v: params.v,
            r: params.r,
            s: params.s,
            dealId: params.dealId
        });

        _depositWithPermitAndCreateRailForDeal(initParams);
    }

    // solhint-enable func-param-name-mixedcase

    // solhint-disable no-unused-vars
    /**
     * @notice Validates a proposed payment amount for a payment rail
     * @param railId ID of the payment rail
     * @param proposedAmount Proposed payment amount to validate
     * @param fromEpoch The epoch up to and including which the rail has already been settled
     * @param toEpoch The epoch up to and including which validation is requested; payment will be validated for (toEpoch - fromEpoch) epochs
     * @param rate Rate used for payment calculation
     * @return result ValidationResult struct containing validation outcome
     */
    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate)
        external
        view
        returns (IValidator.ValidationResult memory result)
    {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.filecoinPay) {
            revert CallerIsNotFilecoinPay();
        }

        if (railId != $.railId) {
            revert InvalidRailId({expected: $.railId, actual: railId});
        }

        if (toEpoch < fromEpoch + EPOCHS_IN_MONTH) {
            result.modifiedAmount = 0;
            result.settleUpto = fromEpoch;
            result.note = "too early for next payout";
            return result;
        }

        /// TODO: Replace with real SLC and ClientSC interactions when available; currently using mocks for testing purposes
        uint256 score = SLCMock($.SLC).getScore($.providerId);
        bool isDataSizeMatching = ClientSCMock($.clientSC).verifyAllocatedDataCapEqualsSealed($.providerId);

        if (!isDataSizeMatching) {
            result.modifiedAmount = 0;
            result.settleUpto = fromEpoch;
            result.note = "datacap mismatch";
            return result;
        }

        if (score == 0) {
            result.modifiedAmount = 0;
            result.note = "full slash";
        } else {
            result.modifiedAmount = proposedAmount;
            result.note = "ok";
        }

        result.settleUpto = toEpoch;
    }

    /**
     * @notice Updates the lockup period of a payment rail
     * @param railId The ID of the rail to modify
     * @param newLockupPeriod New lockup period to set
     */
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external override {
        ValidatorStorage storage $ = _getValidatorStorage();

        if (msg.sender != $.clientSC) {
            revert CallerIsNotClientSC();
        }

        if (railId != $.railId) {
            revert InvalidRailId({expected: $.railId, actual: railId});
        }

        _updateLockupPeriod(IFilecoinPayV1($.filecoinPay), railId, newLockupPeriod, 0);
        emit LockupPeriodUpdated(railId, newLockupPeriod);
    }

    /**
     * @notice Invoked when a payment rail is terminated
     * @param railId The ID of the terminated rail
     * @param terminator Address that initiated the termination
     * @param endEpoch Filecoin epoch at which the rail was terminated
     */
    function railTerminated(uint256 railId, address terminator, uint256 endEpoch) external override {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.filecoinPay) {
            revert CallerIsNotFilecoinPay();
        }

        /// TODO: Implement any necessary cleanup or state updates upon rail termination; currently just emitting an event

        emit RailTerminated(railId, terminator, endEpoch);
    }

    // solhint-enable no-unused-vars

    /**
     * @notice Deposits tokens with permit and creates a payment rail for a deal
     * @param params Parameters for deposit with rail creation
     */
    function _depositWithPermitAndCreateRailForDeal(DepositWithRailParams memory params) internal override {
        ValidatorStorage storage $ = _getValidatorStorage();

        _setOperatorApproval(
            IFilecoinPayV1($.filecoinPay),
            params.token,
            address(this),
            true,
            params.amount,
            params.amount,
            MAX_LOCKUP_PERIOD
        );

        _depositWithPermit(
            IFilecoinPayV1($.filecoinPay),
            params.token,
            params.payer,
            params.amount,
            params.deadline,
            params.v,
            params.r,
            params.s
        );

        uint256 railId =
            _createRail(IFilecoinPayV1($.filecoinPay), params.token, params.payer, params.payee, 0, address(0));

        $.railId = railId;

        PoRepMarket($.poRepMarket).updateValidatorAndRailId(params.dealId, railId);
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

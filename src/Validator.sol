// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase, private-vars-leading-underscore

pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {IValidator, FilecoinPayV1} from "filecoin-pay/FilecoinPayV1.sol";
import {PrecompilesAPI} from "filecoin-solidity/v0.8/PrecompilesAPI.sol";
import {FilAddressIdConverter} from "filecoin-solidity/v0.8/utils/FilAddressIdConverter.sol";
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
     * @notice Number of epochs in one month
     * @dev 30 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 86,400 epochs
     */
    uint256 private constant EPOCHS_IN_MONTH = 86_400;

    /// @custom:storage-location erc7201:porepmarket.storage.ValidatorStorage
    struct ValidatorStorage {
        address filecoinPay;
        address SLC;
        address clientSC;
        address poRepMarket;
        CommonTypes.FilActorId providerId;
    }

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
        DepositWithRailParams calldata params
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

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
        returns (ValidationResult memory result)
    {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.filecoinPay) {
            revert CallerIsNotFilecoinPay();
        }

        if (toEpoch < fromEpoch + EPOCHS_IN_MONTH) {
            result.modifiedAmount = 0;
            result.settleUpto = fromEpoch;
            result.note = "too early for next payout";
            return result;
        }

        // Mock's usage (temporary)
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
     * @notice Deposits tokens with permit and creates a payment rail for a deal
     * @param params Parameters for deposit with rail creation
     */
    function depositWithPermitAndCreateRailForDeal(DepositWithRailParams calldata params) external override {
        DepositWithRailParams memory p = params;
        _depositWithPermitAndCreateRailForDeal(p);
    }

    /**
     * @notice Deposits tokens with permit and creates a payment rail for a deal
     * @param params Parameters for deposit with rail creation
     */
    function _depositWithPermitAndCreateRailForDeal(DepositWithRailParams memory params) internal {
        ValidatorStorage storage $ = _getValidatorStorage();

        _depositWithPermitAndApproveOperator(
            FilecoinPayV1($.filecoinPay),
            params.token,
            params.payer,
            params.amount,
            params.deadline,
            params.v,
            params.r,
            params.s,
            0,
            0,
            0
        );

        uint256 railId =
            _createRail(FilecoinPayV1($.filecoinPay), params.token, params.payer, params.payee, 0, address(0));

        PoRepMarket($.poRepMarket).updateValidatorAndRailId(params.dealId, railId);
    }

    /**
     * @notice Updates the lockup period of a payment rail
     * @param railId The ID of the rail to modify
     * @param newLockupPeriod New lockup period to set
     * @param lockupFixed New fixed lockup amount
     */
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod, uint256 lockupFixed) external override {
        ValidatorStorage storage $ = _getValidatorStorage();

        if (msg.sender != $.clientSC) {
            revert CallerIsNotClientSC();
        }

        _updateLockupPeriod(FilecoinPayV1($.filecoinPay), railId, newLockupPeriod, lockupFixed);
    }

    /**
     * @notice Invoked when a payment rail is terminated
     * @param railId The ID of the terminated rail
     * @param terminator Address that initiated the termination
     * @param endEpoch Filecoin epoch at which the rail was terminated
     */
    function railTerminated(uint256 railId, address terminator, uint256 endEpoch) external view override {
        ValidatorStorage storage $ = _getValidatorStorage();
        if (msg.sender != $.filecoinPay) {
            revert CallerIsNotFilecoinPay();
        }
    }

    // solhint-enable no-unused-vars

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

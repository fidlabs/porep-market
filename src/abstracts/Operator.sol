// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFilecoinPayV1} from "../interfaces/IFilecoinPayV1.sol";

/**
 * @title Operator abstract contract
 * @notice Abstract contract defining operator functions for managing payment rails and deposits
 */
abstract contract Operator {
    /**
     * @notice Parameters for deposit with rail creation
     * @param token The ERC20 token to deposit
     * @param payer The address paying the tokens
     * @param payee The address receiving the tokens
     * @param amount The amount of tokens to deposit
     * @param deadline The deadline for the permit
     * @param v The v component of the permit signature
     * @param r The r component of the permit signature
     * @param s The s component of the permit signature
     * @param dealId The ID of the deal associated with the payment rail
     */
    struct DepositWithRailParams {
        IERC20 token;
        address payer;
        address payee;
        uint8 v;
        uint256 amount;
        uint256 deadline;
        bytes32 r;
        bytes32 s;
        uint256 dealId;
    }

    /**
     * @notice Updates the lockup period of a payment rail
     * @param railId ID of the payment rail
     * @param newLockupPeriod New lockup period to set
     */
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external virtual;

    /**
     * @notice Deposits tokens with permit and creates a payment rail for a deal
     * @param params Parameters for deposit and rail creation
     */
    function _depositWithPermitAndCreateRailForDeal(DepositWithRailParams memory params) internal virtual;

    /**
     * @notice Internal function to deposit tokens using permit (EIP-2612) approval in a single transaction.
     * @param filecoinPay The FilecoinPayV1 interface
     * @param token The ERC20 token address to deposit.
     * @param to The address whose account will be credited (must be the permit signer).
     * @param amount The amount of tokens to deposit.
     * @param deadline Permit deadline (timestamp).
     * @param v The v component of the permit signature.
     * @param r The r component of the permit signature.
     * @param s The s component of the permit signature.
     */
    function _depositWithPermit(
        IFilecoinPayV1 filecoinPay,
        IERC20 token,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        filecoinPay.depositWithPermit(token, to, amount, deadline, v, r, s);
    }

    /**
     * @notice Updates the approval status and allowances for an operator on behalf of the message sender.
     * @param filecoinPay The FilecoinPayV1 interface
     * @param token The ERC20 token address for which the approval is being set.
     * @param operator The address of the operator whose approval is being modified.
     * @param approved Whether the operator is approved (true) or not (false) to create new rails.
     * @param rateAllowance The maximum payment rate the operator can set across all rails created by the operator on behalf of the message sender. If this is less than the current payment rate, the operator will only be able to reduce rates until they fall below the target.
     * @param lockupAllowance The maximum amount of funds the operator can lock up on behalf of the message sender towards future payments. If this exceeds the current total amount of funds locked towards future payments, the operator will only be able to reduce future lockup.
     * @param maxLockupPeriod The maximum number of epochs (blocks) the operator can lock funds for. If this is less than the current lockup period for a rail, the operator will only be able to reduce the lockup period.
     */
    function _setOperatorApproval(
        IFilecoinPayV1 filecoinPay,
        IERC20 token,
        address operator,
        bool approved,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) internal {
        filecoinPay.setOperatorApproval(token, operator, approved, rateAllowance, lockupAllowance, maxLockupPeriod);
    }

    /**
     * @notice Internal function to create a payment rail
     * @param filecoinPay The FilecoinPayV1 interface
     * @param token The ERC20 token to use for the payment rail
     * @param payer The address paying the tokens
     * @param payee The address receiving the tokens
     * @param commissionRateBps The commission rate in basis points for the payment rail
     * @param serviceFeeRecipient The recipient of service fees for the payment rail
     * @return railId ID of the created payment rail
     */
    function _createRail(
        IFilecoinPayV1 filecoinPay,
        IERC20 token,
        address payer,
        address payee,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) internal returns (uint256 railId) {
        railId = filecoinPay.createRail(token, payer, payee, address(this), commissionRateBps, serviceFeeRecipient);
    }

    /**
     * @notice Internal function to update the lockup period of a payment rail
     * @param filecoinPay The FilecoinPayV1 interface
     * @param railId ID of the payment rail
     * @param newLockupPeriod New lockup period to set
     * @param lockupFixed Fixed lockup amount
     */
    function _updateLockupPeriod(
        IFilecoinPayV1 filecoinPay,
        uint256 railId,
        uint256 newLockupPeriod,
        uint256 lockupFixed
    ) internal {
        filecoinPay.modifyRailLockup(railId, newLockupPeriod, lockupFixed);
    }
}

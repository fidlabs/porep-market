// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interface for FilecoinPayV1
 * @notice Includes necessary functions from FilecoinPayV1 for operator interactions
 */
interface IFilecoinPayV1 {
    /**
     * @notice Rail data returned by Filecoin Pay.
     */
    struct RailView {
        IERC20 token;
        address from;
        address to;
        address operator;
        address validator;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        uint256 settledUpTo;
        uint256 endEpoch;
        uint256 commissionRateBps;
        address serviceFeeRecipient;
    }

    /**
     * @notice Creates a payment rail
     * @param token The ERC20 token to use for the payment rail
     * @param payer The address paying the tokens
     * @param payee The address receiving the tokens
     * @param operator The operator address for the payment rail
     * @param commissionRateBps The commission rate in basis points for the payment rail
     * @param serviceFeeRecipient The recipient of service fees for the payment rail
     * @return railId ID of the created payment rail
     * @custom:constraint Caller must be approved as an operator by the client (from address).
     */
    function createRail(
        IERC20 token,
        address payer,
        address payee,
        address operator,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) external returns (uint256);

    /**
     * @notice Custom getter for operator approvals
     * @param token The ERC20 token address for which the approval is being set
     * @param client The client address for which to check operator approval
     * @param operator The operator address for which to check approval
     * @return isApproved Whether the operator is approved by the client for the specified token
     * @return rateAllowance The maximum payment rate the operator can set across all rails created by the operator on behalf of the message sender
     * @return lockupAllowance The maximum amount of funds the operator can lock up on behalf of the message sender towards future payments
     * @return rateUsage Track actual usage for rate
     * @return lockupUsage Track actual usage for lockup
     * @return maxLockupPeriod Maximum lockup period the operator can set for rails created on behalf of the client
     */
    function operatorApprovals(IERC20 token, address client, address operator)
        external
        view
        returns (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        );

    /**
     * @notice Gets the current state of an active rail.
     * @param railId The ID of the rail.
     * @return rail The active rail data.
     */
    function getRail(uint256 railId) external view returns (RailView memory rail);

    /**
     * @notice Modifies the fixed lockup and lockup period of a rail.
     * @dev - If the rail has already been terminated, the lockup period may not be altered and the fixed lockup may only be reduced.
     * @dev - If the rail is active, the lockup may only be modified if the payer's account is fully funded and will remain fully funded after the operation.
     * @param railId The ID of the rail to modify.
     * @param period The new lockup period (in epochs/blocks).
     * @param lockupFixed The new fixed lockup amount.
     * @custom:constraint Caller must be the rail operator.
     * @custom:constraint Operator must have sufficient lockup allowance to cover any increases the lockup period or the fixed lockup.
     */
    function modifyRailLockup(uint256 railId, uint256 period, uint256 lockupFixed) external;

    /**
     * @notice Modifies the payment rate and optionally makes a one-time payment.
     * @dev - If the rail has already been terminated, one-time payments can be made and the rate may always be decreased (but never increased) regardless of the status of the payer's account.
     * @dev - If the payer's account isn't fully funded and the rail is active (not terminated), the rail's payment rate may not be changed at all (increased or decreased).
     * @dev - Regardless of the payer's account status, one-time payments will always go through provided that the rail has sufficient fixed lockup to cover the payment.
     * @param railId The ID of the rail to modify.
     * @param newRate The new payment rate (per epoch). This new rate applies starting the next epoch after the current one.
     * @param oneTimePayment Optional one-time payment amount to transfer immediately, taken out of the rail's fixed lockup.
     * @custom:constraint Caller must be the rail operator.
     * @custom:constraint Operator must have sufficient rate and lockup allowances for any increases.
     */
    function modifyRailPayment(uint256 railId, uint256 newRate, uint256 oneTimePayment) external;

    /**
     * @notice Terminates a payment rail, preventing further payments after the rail's lockup period. After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced.
     * @param railId The ID of the rail to terminate.
     * @custom:constraint Caller must be a rail client or operator.
     * @custom:constraint Rail must be active and not already terminated.
     * @custom:constraint If called by the client, the payer's account must be fully funded.
     * @custom:constraint If called by the operator, the payer's funding status isn't checked.
     */
    function terminateRail(uint256 railId) external;

    /**
     * @notice Settles payments for a rail up to the requested epoch.
     * @param railId The ID of the rail to settle.
     * @param untilEpoch The epoch up to which to settle.
     * @return totalSettledAmount The total amount settled and transferred.
     * @return totalNetPayeeAmount The net amount credited to the payee after fees.
     * @return totalOperatorCommission The commission credited to the operator.
     * @return totalNetworkFee The fee accrued to Filecoin Pay.
     * @return finalSettledEpoch The epoch up to which settlement completed.
     * @return note Additional settlement information.
     */
    function settleRail(uint256 railId, uint256 untilEpoch)
        external
        returns (
            uint256 totalSettledAmount,
            uint256 totalNetPayeeAmount,
            uint256 totalOperatorCommission,
            uint256 totalNetworkFee,
            uint256 finalSettledEpoch,
            string memory note
        );
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interface for FilecoinPayV1
 * @notice Includes necessary functions from FilecoinPayV1 for operator interactions
 */
interface IFilecoinPayV1 {
    /**
     * @notice RailView struct represents a read-only view of a payment rail, including all relevant details for operators and validators
     *  token: The ERC20 token to use for the payment rail
     *  from: The address paying the tokens
     *  to: The address receiving the tokens
     *  operator: The operator address for the payment rail
     *  validator: Rail validator address
     *  paymentRate: Current payment rate per epoch
     *  lockupPeriod: Lockup period in epochs
     *  lockupFixed: Fixed lockup amount
     *  settledUpTo: Epoch up to which the rail has been settled
     *  endEpoch: Epoch at which the rail ends
     *  commissionRateBps: The commission rate in basis points for the payment rail
     *  serviceFeeRecipient: The recipient of service fees for the payment rail
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
     * @notice Custom getter for a client account on FilecoinPay.
     * @param token The ERC20 token to read the account for.
     * @param owner The account owner.
     * @return funds Total deposited funds for the account.
     * @return lockupCurrent Currently locked funds across all rails of the account.
     * @return lockupRate Aggregate lockup accrual rate per epoch across the account's rails.
     * @return lockupLastSettledAt Epoch up to and including which lockup has been settled.
     */
    function accounts(IERC20 token, address owner)
        external
        view
        returns (uint256 funds, uint256 lockupCurrent, uint256 lockupRate, uint256 lockupLastSettledAt);

    /**
     * @notice Gets the current state of the target rail or reverts if the rail isn't active
     * @param railId The ID of the rail to read
     * @return rail Read-only view of the rail
     */
    function getRail(uint256 railId) external view returns (RailView memory rail);

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
     * @notice Gets information about an account - when it would go into debt, total balance, available balance, and lockup rate.
     * @param token The token address to get account info for.
     * @param owner The address of the account owner.
     * @return fundedUntilEpoch The epoch at which the account would go into debt given current lockup rate and balance.
     * @return currentFunds The current funds in the account.
     * @return availableFunds The funds available after accounting for simulated lockup.
     * @return currentLockupRate The current lockup rate per epoch.
     */
    function getAccountInfoIfSettled(IERC20 token, address owner)
        external
        view
        returns (uint256 fundedUntilEpoch, uint256 currentFunds, uint256 availableFunds, uint256 currentLockupRate);
}

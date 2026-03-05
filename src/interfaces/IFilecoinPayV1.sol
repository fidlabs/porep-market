// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interface for FilecoinPayV1
 * @notice Includes necessary functions from FilecoinPayV1 for operator interactions
 */
interface IFilecoinPayV1 {
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
}

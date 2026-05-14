// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title IOperator
 * @notice Interface for operator functions to create and manage payment rails in the FilecoinPayV1 system
 */
interface IOperator {
    /**
     * @notice Creates a payment rail
     * @param payer The address of the payer
     * @param payee The address of the payee
     * @param fixedLockupAmount The fixed lockup amount for the payment rail
     */
    function createRail(address payer, address payee, uint256 fixedLockupAmount) external;

    /**
     * @notice Modifies the payment rate and optionally makes a one-time payment.
     * @param railId The ID of the rail to modify.
     */
    function modifyRailPayment(uint256 railId) external;

    /**
     * @notice Terminates a payment rail, preventing further payments after the rail's lockup period. After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced.
     * @param railId The ID of the rail to terminate.
     */
    function terminateRail(uint256 railId) external;
}

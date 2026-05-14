// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title IOperator
 * @notice Interface for fixed-price retrieval payment operations.
 */
interface IOperator {
    /**
     * @notice Reserves a fixed payment for a retrieval.
     * @param payer The address of the payer
     * @param payee The address of the payee
     * @param fixedLockupAmount The fixed lockup amount for the payment rail
     */
    function reserveRetrievalPayment(address payer, address payee, uint256 fixedLockupAmount) external;

    /**
     * @notice Pays the reserved retrieval amount and finalizes the Filecoin Pay rail.
     * @param railId The ID of the rail to pay.
     */
    function payRetrieval(uint256 railId) external;

    /**
     * @notice Cancels a retrieval payment and releases the reserved lockup.
     * @param railId The ID of the rail to cancel.
     */
    function cancelRetrieval(uint256 railId) external;
}

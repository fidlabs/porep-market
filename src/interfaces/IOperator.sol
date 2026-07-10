// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title IOperator
 * @notice Interface for operator functions to create and manage payment rails in the FilecoinPayV1 system
 */
interface IOperator {
    /**
     * @notice Creates the payment rail using the deal's frozen payment token.
     */
    function createRail() external;

    /**
     * @notice Updates the lockup period of a payment rail
     * @param newLockupPeriod New lockup period to set
     */
    function updateLockupPeriod(uint256 newLockupPeriod) external;

    /**
     * @notice Modifies the payment rate and optionally makes a one-time payment.
     * @param newRate The new payment rate per epoch
     */
    function modifyRailPayment(uint256 newRate) external;

    /**
     * @notice Terminates the payment rail early after the PoRepMarket terminates the deal.
     * @dev After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced
     */
    function earlyRailTermination() external;

    /**
     * @notice Terminates the payment rail after the PoRepMarket finalizes the deal.
     */
    function finalizeDeal() external;
}

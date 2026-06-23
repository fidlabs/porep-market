// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IOperator
 * @notice Interface for operator functions to create and manage payment rails in the FilecoinPayV1 system
 */
interface IOperator {
    /**
     * @notice Creates a payment rail
     * @param token The ERC20 token to use for the payment rail
     */
    function createRail(IERC20 token) external;

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
     * @notice Terminates a payment rail, preventing further payments after the rail's lockup period. After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced.
     */
    function terminateRail() external;
}

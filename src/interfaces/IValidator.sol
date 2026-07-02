// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title Interface for Validator
 * @notice Defines the interface for the part of the Validator contract that is exposed to the Operator
 */
interface IValidator {
    /**
     * @notice Retrieves the current status of the payment rail
     * @return railStatus Current status of the payment rail
     */
    function getRailStatus() external view returns (uint8 railStatus);
}

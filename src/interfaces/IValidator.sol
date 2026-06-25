// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title Interface for Validator
 * @notice Defines the interface for the part of the Validator contract that is exposed to the Operator
 *  allowing the Operator to terminate a rail early, as well as configure and retrieve the minimum time between settlements in epochs.
 */
interface IValidator {
    /**
     * @notice Sets the minimum time between settlements in epochs
     * @dev Only callable by the admin
     * @param minEpochs Minimum time between settlements in epochs
     */
    function setMinEpochsBetweenSettlements(uint256 minEpochs) external;

    /**
     * @notice Retrieves the minimum time between settlements in epochs
     * @return minTimeBetweenSettlementsInEpochs Minimum time between settlements in epochs
     */
    function getMinEpochsBetweenSettlements() external view returns (uint256 minTimeBetweenSettlementsInEpochs);

    /**
     * @notice Retrieves the current status of the payment rail
     * @return railStatus Current status of the payment rail
     */
    function getRailStatus() external view returns (uint8 railStatus);
}

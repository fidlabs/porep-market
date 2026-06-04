// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

/**
 * @title Interface for Validator
 * @notice Defines the interface for the part of the Validator contract that is exposed to the Operator
 *  allowing the Operator to disable future payments for a rail and set deal end epochs, as well as configure and retrieve the minimum time between settlements in epochs.
 */
interface IValidator {
    /**
     * @notice Disables future payments for a payment rail by terminating the rail
     * @dev Only callable by POREP_SERVICE bot
     * @dev After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced
     */
    function disableFutureRailPayments() external;

    /**
     * @notice Sets the end epoch for the deal associated with this validator
     * @dev Only callable by POREP_SERVICE bot
     * @param endEpoch The Filecoin epoch at which the deal ended
     */
    function setDealEndEpoch(CommonTypes.ChainEpoch endEpoch) external;

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
     * @notice Verifies that the client has deposited enough funds on FilecoinPay to cover allocations
     * @dev Only callable by the poRepMarket contract
     * @param client Address of the client
     * @param requiredFunds The amount of funds required to cover the allocations
     */
    function verifyClientFunds(address client, uint256 requiredFunds) external view;
}

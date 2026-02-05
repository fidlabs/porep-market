// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Interface for Validator
 * @notice Defines the interface for payment validation in Filecoin Pay rails
 */
interface IValidator {
    /**
     * @notice Result structure for validation during rail settlement
     * @param modifiedAmount The actual payment amount determined by the validator after validation of a rail during settlement
     * @param settleUpto The epoch up to and including which settlement should occur
     * @param note A placeholder note for any additional information the validator wants to send to the caller of `settleRail`
     */
    struct ValidationResult {
        // The actual payment amount determined by the validator after validation of a rail during settlement
        uint256 modifiedAmount;
        // The epoch up to and including which settlement should occur.
        uint256 settleUpto;
        // A placeholder note for any additional information the validator wants to send to the caller of `settleRail`
        string note;
    }

    /**
     * @notice Validates a proposed payment amount for a payment rail
     * @param railId ID of the payment rail
     * @param proposedAmount Proposed payment amount to validate
     * @param fromEpoch The epoch up to and including which the rail has already been settled
     * @param toEpoch The epoch up to and including which validation is requested; payment will be validated for (toEpoch - fromEpoch) epochs
     * @param rate Rate used for payment calculation
     * @return result ValidationResult struct containing validation outcome
     */
    function validatePayment(
        uint256 railId,
        uint256 proposedAmount,
        // the epoch up to and including which the rail has already been settled
        uint256 fromEpoch,
        // the epoch up to and including which validation is requested; payment will be validated for (toEpoch - fromEpoch) epochs
        uint256 toEpoch,
        uint256 rate
    ) external returns (ValidationResult memory result);

    /**
     * @notice Invoked when a payment rail is terminated
     * @param railId The ID of the terminated rail
     * @param terminator Address that initiated the termination
     * @param endEpoch Filecoin epoch at which the rail was terminated
     */
    function railTerminated(uint256 railId, address terminator, uint256 endEpoch) external;
}

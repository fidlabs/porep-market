// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {SharedTypes} from "../types/SharedTypes.sol";

/**
 * @title ISLIScorer
 * @notice Interface for calculating SLI-based scores
 * @dev Compares required thresholds against actual measured values.
 */
interface ISLIScorer {
    /**
     * @notice Returns the deal's health, aggregated over its sectors, from a current measurement of the scorer's oracle.
     * @dev Reverts when the measurement is missing, future-dated or older than 30 days.
     * @param dealId The id of the deal.
     * @return sectorsHealthBps Deal health in basis points.
     */
    function getDealHealth(uint256 dealId) external view returns (uint16 sectorsHealthBps);

    /**
     * @notice Calculate score based on required vs actual thresholds
     * @dev Fields with required value of 0 are skipped (not evaluated)
     * @param dealId The id of the deal
     * @param required What the deal requires
     * @return score 0-100, where 100 = fully met requirements
     */
    function calculateScore(uint256 dealId, SharedTypes.SLIThresholds calldata required)
        external
        view
        returns (uint256 score);

    /**
     * @notice Calculate score from the deal's last attestation regardless of its age
     * @dev For settling windows of a deal that has ended, after which the oracle stops attesting. A deal without an
     *      attestation fails every defined requirement instead of reverting.
     * @param dealId The id of the deal
     * @param required What the deal requires
     * @return score 0-100, where 100 = fully met requirements
     */
    function calculateLastScore(uint256 dealId, SharedTypes.SLIThresholds calldata required)
        external
        view
        returns (uint256 score);
}

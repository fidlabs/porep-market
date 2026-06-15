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
}

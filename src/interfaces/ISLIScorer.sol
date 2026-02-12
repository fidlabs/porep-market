// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SLIThresholds} from "../types/SLITypes.sol";

/**
 * @title ISLIScorer
 * @notice Interface for calculating SLI-based scores
 * @dev Compares required thresholds against actual measured values.
 */
interface ISLIScorer {
    /**
     * @notice Calculate score based on required vs actual thresholds
     * @dev Fields with required value of 0 are skipped (not evaluated)
     * @param required What the deal requires
     * @param actual What the Oracle measured
     * @return score 0-100, where 100 = fully met requirements
     */
    function calculateScore(SLIThresholds calldata required, SLIThresholds calldata actual)
        external
        view
        returns (uint256 score);
}

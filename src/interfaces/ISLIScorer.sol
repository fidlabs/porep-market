// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SLITypes} from "../types/SLITypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

/**
 * @title ISLIScorer
 * @notice Interface for calculating SLI-based scores
 * @dev Compares required thresholds against actual measured values.
 */
interface ISLIScorer {
    /**
     * @notice Calculate score based on required vs actual thresholds
     * @dev Fields with required value of 0 are skipped (not evaluated)
     * @param provider The ID of the provider to score
     * @param required What the deal requires
     * @return score 0-100, where 100 = fully met requirements
     */
    function calculateScore(CommonTypes.FilActorId provider, SLITypes.SLIThresholds calldata required)
        external
        view
        returns (uint256 score);
}

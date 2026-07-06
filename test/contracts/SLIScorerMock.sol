// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {ISLIScorer} from "../../src/interfaces/ISLIScorer.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";

/**
 * @title SLIScorerMock
 * @notice Test helper that returns configured scores by deal id.
 */
contract SLIScorerMock is ISLIScorer {
    /// @notice Score returned for each deal id.
    mapping(uint256 dealId => uint256 score) public scores;

    /**
     * @notice Sets the score returned for a deal id.
     * @param dealId Deal id to configure.
     * @param score Score to return.
     */
    function setScore(uint256 dealId, uint256 score) external {
        scores[dealId] = score;
    }

    /**
     * @notice Returns the configured score for a deal id.
     * @param dealId The deal id.
     * @param sliThresholds Unused SLI thresholds.
     * @return score Configured score for the deal id.
     */
    function calculateScore(uint256 dealId, SharedTypes.SLIThresholds calldata sliThresholds)
        external
        view
        returns (uint256 score)
    {
        sliThresholds;
        return scores[dealId];
    }
}

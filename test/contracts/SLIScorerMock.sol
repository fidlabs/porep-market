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
     * @notice Thrown by calculateScore for a deal marked as having an expired attestation
     * @param dealId The deal id
     */
    error AttestationExpired(uint256 dealId);

    /// @notice Whether calculateScore reverts as if the deal's attestation had expired.
    mapping(uint256 dealId => bool expired) public attestationExpired;

    /**
     * @notice Sets the score returned for a deal id.
     * @param dealId Deal id to configure.
     * @param score Score to return.
     */
    function setScore(uint256 dealId, uint256 score) external {
        scores[dealId] = score;
    }

    /**
     * @notice Makes calculateScore revert for a deal id, as the real scorer does for an expired attestation.
     * @param dealId Deal id to configure.
     * @param expired Whether the attestation is treated as expired.
     */
    function setAttestationExpired(uint256 dealId, bool expired) external {
        attestationExpired[dealId] = expired;
    }

    /**
     * @notice Returns the configured score for a deal id.
     * @param dealId Deal id to score.
     * @param thresholds SLI thresholds ignored by this mock.
     * @return score Configured score for the deal id.
     */
    function calculateScore(uint256 dealId, SharedTypes.SLIThresholds calldata thresholds)
        external
        view
        returns (uint256 score)
    {
        thresholds; // unused parameter, kept for interface compatibility
        if (attestationExpired[dealId]) revert AttestationExpired(dealId);
        return scores[dealId];
    }

    /**
     * @notice Returns the configured score for a deal id, ignoring attestation expiry.
     * @param dealId Deal id to score.
     * @param thresholds SLI thresholds ignored by this mock.
     * @return score Configured score for the deal id.
     */
    function calculateLastScore(uint256 dealId, SharedTypes.SLIThresholds calldata thresholds)
        external
        view
        returns (uint256 score)
    {
        thresholds; // unused parameter, kept for interface compatibility
        return scores[dealId];
    }
}

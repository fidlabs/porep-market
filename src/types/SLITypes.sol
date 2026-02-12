// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SLI Types
 * @notice Shared types for SLI-based deal requirements, capabilities, and attestations
 */

/**
 * @notice Unified SLI thresholds for requirements, capabilities, and attestations
 * @dev STRUCT EXTENSION PROTOCOL:
 *      - This struct may be extended by appending new fields
 *      - New fields MUST be added at the end only
 *      - Field value of 0 means "do not evaluate this dimension"
 *      - Existing field order and types MUST NOT change
 *      - Contracts MUST handle 0 values as "don't care" in comparisons
 *
 * @dev Storage compatibility:
 *      - Old data reads 0 for new fields (uninitialized storage)
 *      - Old deals automatically skip new SLI dimensions
 *
 * @dev Extension example:
 *      V1: { retrievabilityPct, bandwidthMbps, latencyMs }
 *      V2: { retrievabilityPct, bandwidthMbps, latencyMs, indexingPct }
 */
// forge-lint: disable-next-line(pascal-case-struct)
struct SLIThresholds {
    /// @dev Valid range: 0-100. 0 means "don't care". Values above 100 are invalid.
    uint8 retrievabilityPct;
    /// @dev Capped at ~64 Gbps
    uint16 bandwidthMbps;
    uint16 latencyMs;
    /// @dev Valid range: 0-100. 0 means "don't care".
    uint8 indexingPct;
}

/**
 * @notice Commercial terms for a deal (not Oracle-measured)
 */
struct DealTerms {
    uint256 dealSizeBytes;
    uint256 priceForDeal;
    uint32 durationDays;
}

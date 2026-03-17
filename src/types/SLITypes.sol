// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title SLI Types
 * @notice Shared types for SLI-based deal requirements, capabilities, and attestations
 */
library SLITypes {
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
     *      V1: { retrievabilityBps, bandwidthMbps, latencyMs }
     *      V2: { retrievabilityBps, bandwidthMbps, latencyMs, indexingPct }
     */
    // forge-lint: disable-next-line(pascal-case-struct)
    struct SLIThresholds {
        /// @dev Valid range: 0-10000 (basis points, e.g. 7550 = 75.50%). 0 means "don't care".
        uint16 retrievabilityBps;
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
        /// @notice Price per 32 GiB sector in USDFC smallest units (wei-equivalent)
        uint256 pricePerSector;
        uint32 durationDays;
    }

    /**
     * @notice Represents an attestation record for SLI (Service Level Indicator) tracking
     * @dev Stores the timestamp of the last update and the associated SLI thresholds
     */
    struct Attestation {
        uint256 lastUpdate;
        SLIThresholds slis;
    }
}


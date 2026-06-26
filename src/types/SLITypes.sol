// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title SLI Types
 * @notice Shared types for SLI-based deal requirements and commercial terms
 */
library SLITypes {
    /**
     * @notice Commercial terms for a deal (not Oracle-measured)
     */
    struct DealTerms {
        uint256 dealSizeBytes;
        /// @notice Monthly price per 32 GiB sector in USDFC smallest units (wei-equivalent)
        uint256 pricePerSectorPerMonth;
        uint32 durationDays;
    }
}

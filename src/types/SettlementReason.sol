// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title SettlementReason
 * @notice Settlement-specific reason code constants for PoRepMarket decisions
 */
library SettlementReason {
    uint16 internal constant OK = 0;
    uint16 internal constant DEAL_ENDED = 10;
    uint16 internal constant DEAL_TERMINATED = 20;
    uint16 internal constant SCORE_BELOW_THRESHOLD = 30;
    uint16 internal constant DATA_SIZE_MISMATCH = 40;
}

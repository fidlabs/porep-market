// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title SettlementResult
 * @notice Settlement-specific result constants for PoRepMarket decisions
 */
library SettlementResult {
    uint8 internal constant NONE = 0;
    uint8 internal constant ACCEPTED = 10;
    uint8 internal constant MODIFIED = 20;
    uint8 internal constant REJECTED = 30;
}

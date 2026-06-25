// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title Deal State
 * @notice Gapped, append-only deal lifecycle state codes.
 * @dev Adapter and rail progress are represented separately from the core deal lifecycle.
 */
library DealState {
    uint8 internal constant NONE = 0;
    uint8 internal constant PROPOSED = 10;
    uint8 internal constant ACCEPTED = 20;
    uint8 internal constant ACTIVE = 30;
    uint8 internal constant FINALIZED = 40;
    uint8 internal constant REJECTED = 50;
    uint8 internal constant EXPIRED = 60;
    uint8 internal constant TERMINATED = 70;
}

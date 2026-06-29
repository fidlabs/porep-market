// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title OfferMatch
 * @notice Reason codes returned by SPRegistry offer matching
 * @dev OK (0) means the offer is eligible. Any nonzero value is the first failing check.
 *      Preview functions surface the code; reserve functions revert with it.
 */
library OfferMatch {
    uint16 internal constant OK = 0;
    uint16 internal constant OFFER_NOT_FOUND = 1;
    uint16 internal constant OFFER_INACTIVE = 2;
    uint16 internal constant PROVIDER_BLOCKED = 3;
    uint16 internal constant PROVIDER_PAUSED = 4;
    uint16 internal constant SIZE_OUT_OF_BOUNDS = 5;
    uint16 internal constant DURATION_OUT_OF_BOUNDS = 6;
    uint16 internal constant SLIS_NOT_MET = 7;
    uint16 internal constant TOKEN_NOT_ALLOWED = 8;
    uint16 internal constant PRICE_BELOW_TOKEN_MIN = 9;
    uint16 internal constant PRICE_ABOVE_CLIENT_MAX = 10;
    uint16 internal constant INSUFFICIENT_CAPACITY = 11;
    uint16 internal constant MANIFEST_ALREADY_ASSIGNED = 12;
}

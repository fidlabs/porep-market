// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title RailStatus
 * @notice Defines status codes for a FilecoinPay rail lifecycle
 */
library RailStatus {
    uint8 internal constant NONE = 0;
    // Rail is authorized and ready, but payment cannot accrue until storage activates.
    uint8 internal constant PREPARED = 10;
    uint8 internal constant ACTIVE = 20;
    // FilecoinPay rail termination has been observed by Validator and settlement
    // is capped at earlyTerminatedEpoch.
    uint8 internal constant TERMINATED = 100;
}

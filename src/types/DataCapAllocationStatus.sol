// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title DataCapAllocationStatus
 * @notice Lifecycle status of a DataCap allocation per deal tracked by the adapter
 */
library DataCapAllocationStatus {
    uint8 internal constant NONE = 0;
    uint8 internal constant ALLOCATED = 10;
    uint8 internal constant CLAIMED = 20;
    uint8 internal constant INACTIVE = 30;
}

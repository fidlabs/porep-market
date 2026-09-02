// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {DataCapEvidenceAdapter} from "./DataCapEvidenceAdapter.sol";

/**
 * @title Calibnet DataCap Adapter
 * @notice DataCap evidence adapter for Calibnet tests that do not require full allocation coverage
 * @dev This implementation can only be deployed on Filecoin Calibration.
 */
contract CalibnetDataCapAdapter is DataCapEvidenceAdapter {
    uint256 internal constant CALIBNET_CHAIN_ID = 314159;

    /**
     * @notice Error thrown when this implementation is deployed outside Calibnet
     * @dev 0xa5dab5fe
     */
    error UnsupportedChainId(uint256 chainId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        if (block.chainid != CALIBNET_CHAIN_ID) {
            revert UnsupportedChainId(block.chainid);
        }
    }

    // solhint-disable-next-line no-empty-blocks
    function _ensureAllocationCoverage(uint256, uint256) internal view override {}
}

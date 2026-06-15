// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {SharedTypes} from "../types/SharedTypes.sol";

/**
 * @title ISLIOracle
 * @notice Interface for managing and retrieving SLI values for deals
 */
interface ISLIOracle {
    /**
     * @notice Sets SLI values for a deal
     * @param dealId The id of the deal
     * @param slis New slis values for a deal
     */
    function setSLI(uint256 dealId, SharedTypes.SLIThresholds calldata slis) external;

    /**
     * @notice Retrieves the SLI values for a deal
     * @param dealId The id of the deal
     * @return attestation The attestation values for the deal
     */
    function getAttestation(uint256 dealId) external view returns (SharedTypes.Attestation memory attestation);
}

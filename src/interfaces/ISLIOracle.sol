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

    /**
     * @notice Stores a sector health measurement supplied by an authorized oracle.
     * @dev Records block.number as the update epoch; the external oracle system validates the measurement period.
     * @param dealId The id of the deal.
     * @param sectorsHealthBps Share of time without faults, from 0 to 10_000 basis points.
     */
    function setDealHealth(uint256 dealId, uint16 sectorsHealthBps) external;

    /**
     * @notice Gets the latest oracle-measured sector health for a deal.
     * @param dealId The id of the deal.
     * @return health Latest measurement, zeroed when none has been submitted.
     */
    function getDealHealth(uint256 dealId) external view returns (SharedTypes.DealHealth memory health);
}

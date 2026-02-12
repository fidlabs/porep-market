// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SLIThresholds} from "../types/SLITypes.sol";

/**
 * @title ISLIOracle
 * @notice Interface for retrieving measured SLI values for storage providers
 */
interface ISLIOracle {
    /**
     * @notice Get measured SLI values for a provider
     * @param provider The storage provider actor ID
     * @return Current attestation as SLIThresholds
     */
    function getAttestation(CommonTypes.FilActorId provider) external view returns (SLIThresholds memory);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SLITypes} from "../types/SLITypes.sol";

/**
 * @title ISLIOracle
 * @notice Interface for managing and retrieving SLI values for storage providers
 */
interface ISLIOracle {
    /**
     * @notice Sets SLI values for a provider
     * @param provider ID of the provider
     * @param slis New slis values for a provider
     */
    function setSLI(CommonTypes.FilActorId provider, SLITypes.SLIThresholds calldata slis) external;

    /**
     * @notice Retrieves the SLI values for a provider
     * @param provider ID of the provider
     * @return attestation The attestation values for the provider
     */
    function getAttestation(CommonTypes.FilActorId provider)
        external
        view
        returns (SLITypes.Attestation memory attestation);
}

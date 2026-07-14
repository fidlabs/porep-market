// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {SharedTypes} from "../types/SharedTypes.sol";

/**
 * @title Storage evidence adapter interface
 * @notice Defines the adapter used by PoRepMarket to submit, activate, refresh,
 * and query deal evidence for different evidence sources
 */
interface IStorageEvidenceAdapter {
    /**
     * @notice Returns the adapter's evidence type identifier
     * @return evidence type as a uint8; PoRepMarket uses this to route evidence to the correct adapter
     */
    function getEvidenceType() external pure returns (uint8);

    /**
     * @notice Returns whether the adapter can still process new evidence
     * @dev Returns false when the adapter is no longer operational, for example
     * when the DataCap adapter can no longer accept allocations or claims
     * @return True if the adapter can process new evidence, false if it is no longer operational
     */
    function isOperational() external view returns (bool);

    /**
     * @notice Submit one bounded batch of adapter-specific evidence for a deal
     * @dev Only callable by the PoRepMarket contract
     * @dev `evidenceData` is opaque to PoRepMarket; the selected adapter defines,
     * decodes, and validates its contents
     * @param context Activation context for the deal and market state
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Activation decision for the submitted evidence batch
     */
    function submitEvidenceBatch(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (SharedTypes.ActivationDecision memory decision);

    /**
     * @notice Return the adapter's activation decision after submitted evidence
     * covers enough bytes for the frozen deal
     * @dev Only callable by the PoRepMarket contract
     * @dev This function does not set payment terms; PoRepMarket consumes the
     * returned covered bytes and derives committed bytes, billed units, service
     * start/end, rail ceiling, and deal state
     * @param context Activation context for the deal and market state
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Activation decision for the provided evidence
     */
    function activateEvidence(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (SharedTypes.ActivationDecision memory decision);

    /**
     * @notice Refresh current evidence health from adapter-specific source data
     * @dev The caller supplies only the bounded batch to check; the adapter
     * verifies state itself before updating stored active covered bytes
     * @param context Activation context for the deal and market state
     * @param evidenceData Bounded batch of evidence used to verify current status
     * @return status Updated evidence status
     */
    function refreshEvidenceStatus(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (SharedTypes.EvidenceStatus memory status);

    /**
     * @notice Read current evidence status from adapter storage only
     * @dev Must not call Filecoin actors or refresh live state
     * @param context Activation context for the deal and market state
     * @return status Current adapter-local evidence status
     */
    function currentEvidenceStatus(SharedTypes.ActivationContext calldata context)
        external
        returns (SharedTypes.EvidenceStatus memory status);
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SharedTypes} from "../types/SharedTypes.sol";

/**
 * @title Storage evidence adapter
 * @notice Keeps PoRepMarket independent from DataCap and the storage-checking
 * system that replaces it.
 * @dev DataCap and VerifReg are the current path, but they are not permanent.
 * Each adapter converts one Filecoin storage-checking path into the activation
 * and refresh results used by PoRepMarket. A deal keeps the adapter selected
 * when it is created.
 *
 * "Evidence" means the on-chain facts used to check storage coverage. It does
 * not mean that every adapter returns a cryptographic proof.
 */
interface IStorageEvidenceAdapter {
    /**
     * @notice Returns the identifier of the storage-checking mechanism implemented by this adapter
     * @dev PoRepMarket routes calls through the adapter address stored on the deal, not through this identifier
     * @return Adapter type identifier
     */
    function getEvidenceType() external pure returns (uint8);

    /**
     * @notice Returns whether operators should assign this adapter to new deals
     * @dev An adapter may stop new deal setup while keeping reads and refreshes available for existing deals
     * @return True when the adapter is available for new deals
     */
    function isOperational() external view returns (bool);

    /**
     * @notice Returns whether evidence has been submitted for a deal, locking its manifest
     * @dev Includes unclaimed allocations or accepted piece placements, not only active coverage.
     * Once true, must remain true even if the evidence later expires or becomes inactive.
     * @param dealId The id of the deal
     * @return True when the deal's manifest must no longer be replaced
     */
    function hasSubmittedEvidence(uint256 dealId) external view returns (bool);

    /**
     * @notice Retrieves the expiration epoch for a deal's submitted evidence
     * @param dealId The id of the deal
     * @return expiration The evidence expiration epoch
     */
    function getExpiration(uint256 dealId) external view returns (CommonTypes.ChainEpoch expiration);

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

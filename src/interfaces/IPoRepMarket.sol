// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {PoRepTypes} from "../types/PoRepTypes.sol";
import {SLITypes} from "../types/SLITypes.sol";
import {SharedTypes} from "../types/SharedTypes.sol";

/**
 * @title IPoRepMarket interface
 * @notice IPoRepMarket interface for interacting with PoRepMarket contract
 */
interface IPoRepMarket {
    /**
     * @notice Sets the global evidence adapter
     * @dev New deals snapshot this adapter at proposal time
     * @param _globalEvidenceAdapter The address of the global evidence adapter
     */
    function setGlobalEvidenceAdapter(address _globalEvidenceAdapter) external;

    /**
     * @notice Proposes a deal
     * @param requirements The SLI thresholds for the deal
     * @param terms The commercial terms for the deal
     * @param manifestLocation The location of the manifest for the deal
     */
    function proposeDeal(
        SLITypes.SLIThresholds calldata requirements,
        SLITypes.DealTerms calldata terms,
        string calldata manifestLocation
    ) external;

    /**
     * @notice Updates the validator for a deal proposal
     * @param dealId The id of the deal proposal
     */
    function updateValidator(uint256 dealId) external;

    /**
     * @notice Updates the rail id for a deal proposal
     * @dev Updates the rail id for a deal proposal
     * @param dealId The id of the deal proposal
     * @param railId The id of the rail
     */
    function updateRailId(uint256 dealId, uint256 railId) external;

    /**
     * @notice Gets a deal proposal
     * @param dealId The id of the deal proposal
     * @return DealProposal The deal proposal
     */
    function getDealProposal(uint256 dealId) external view returns (PoRepTypes.DealProposal memory);

    /**
     * @notice Accepts a deal
     * @param dealId The id of the deal proposal
     */
    function acceptDeal(uint256 dealId) external;

    /**
     * @notice Completes a deal
     * @param dealId The id of the deal proposal
     */
    function completeDeal(uint256 dealId) external;

    /**
     * @notice Terminate a deal
     * @dev Terminates a deal by setting the deal state to terminated
     * @param dealId The id of the deal proposal
     * @param terminator The address that terminated the deal
     * @param endEpoch The Filecoin epoch at which the deal was terminated
     */
    function terminateDeal(uint256 dealId, address terminator, uint256 endEpoch) external;

    /**
     * @notice Rejects a deal
     * @param dealId The id of the deal proposal
     */
    function rejectDeal(uint256 dealId) external;

    /**
     * @notice Rejects a deal in Accepted state before rail is set
     * @dev Only callable by the admin
     * @param dealId The id of the deal proposal
     */
    function rejectAcceptedDeal(uint256 dealId) external;

    /**
     * @notice Gets all completed deals
     * @return completedDeals Array of completed deal proposals
     */
    function getCompletedDeals() external view returns (PoRepTypes.DealProposal[] memory completedDeals);

    /**
     * @notice Retrieves the manifest location URL for a specific deal proposal
     * @param dealId The unique identifier of the deal proposal
     * @return manifestLocation The manifest location URL for a specific deal proposal
     */
    function getManifestLocation(uint256 dealId) external view returns (string memory manifestLocation);

    /**
     * @notice Updates the manifest location for a specific deal proposal
     * @dev Only callable by the admin
     * @param dealId The unique identifier of the deal proposal
     * @param newManifestLocation The new manifest location URL to be updated for the deal proposal
     */
    function updateManifestLocation(uint256 dealId, string calldata newManifestLocation) external;

    /**
     * @notice Gets deals for a specific organization by state
     * @param organization The address of the organization
     * @param state The state of the deals to retrieve
     * @return deals Array of deal proposals for the organization in the specified state (from all providers associated with the organization)
     */
    function getDealsForOrganizationByState(address organization, PoRepTypes.DealState state)
        external
        view
        returns (PoRepTypes.DealProposal[] memory deals);

    /**
     * @notice Gets the SPRegistry contract address from storage
     * @return ISPRegistry The SPRegistry contract address
     */
    function getSPRegistryContract() external view returns (address);

    /**
     * @notice Gets the global evidence adapter address from storage
     * @return The global evidence adapter address
     */
    function getGlobalEvidenceAdapter() external view returns (address);

    /**
     * @notice Gets the evidence adapter assigned to a deal
     * @param dealId The id of the deal proposal
     * @return The deal evidence adapter address
     */
    function getDealEvidenceAdapter(uint256 dealId) external view returns (address);

    /**
     * @notice Submit evidence to the adapter assigned to a deal
     * @param dealId The id of the deal proposal
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Adapter activation decision for the submitted batch
     */
    function submitEvidenceBatch(uint256 dealId, bytes calldata evidenceData)
        external
        returns (SharedTypes.ActivationDecision memory decision);

    /**
     * @notice Activate evidence for a deal through its assigned adapter
     * @param dealId The id of the deal proposal
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Adapter activation decision
     */
    function activateEvidence(uint256 dealId, bytes calldata evidenceData)
        external
        returns (SharedTypes.ActivationDecision memory decision);

    /**
     * @notice Refresh evidence status for a deal through its assigned adapter
     * @param dealId The id of the deal proposal
     * @param evidenceData Adapter-specific evidence payload
     * @return status Updated evidence status
     */
    function refreshEvidenceStatus(uint256 dealId, bytes calldata evidenceData)
        external
        returns (SharedTypes.EvidenceStatus memory status);

    /**
     * @notice Reads current evidence status for a deal through its assigned adapter
     * @param dealId The id of the deal proposal
     * @return status Current evidence status
     */
    function currentEvidenceStatus(uint256 dealId) external view returns (SharedTypes.EvidenceStatus memory status);

    /**
     * @notice Gets the validator factory contract address from storage
     * @return IValidatorFactory The validator factory contract adddress
     */
    function getValidatorFactoryContract() external view returns (address);

    /**
     * @notice Gets all deals
     * @return deals Array of all deal proposals
     */
    function getDeals() external view returns (PoRepTypes.DealProposal[] memory deals);

    /**
     * @notice Rejects expired deal
     * @param dealId The id of the deal proposal
     * @dev A deal proposal is considered expired if it has been in the proposed state for more than the dealProposalExpiration
     * @dev Deal proposal expiration is set to 5_760 epochs (2 days) by default, but can be updated by the admin using setNewDealProposalExpiration function
     */
    function rejectExpiredDeal(uint256 dealId) external;

    /**
     * @notice Sets new deal proposal expiration
     * @dev Only callable by the admin
     * @param newDealProposalExpiration The new deal proposal expiration in epochs
     */
    function setNewDealProposalExpiration(uint256 newDealProposalExpiration) external;

    /**
     * @notice Retrieves the deal proposal expiration
     * @return dealProposalExpiration The deal proposal expiration in epochs
     */
    function getDealProposalExpiration() external view returns (uint256);
}

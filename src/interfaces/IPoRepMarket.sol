// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {PoRepTypes} from "../types/PoRepTypes.sol";
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
     * @param request The client deal request
     */
    function proposeDeal(SharedTypes.DealRequest calldata request) external;

    /**
     * @notice Updates the validator for a deal
     * @param dealId The id of the deal
     */
    function updateValidator(uint256 dealId) external;

    /**
     * @notice Updates the rail id for a deal
     * @dev Updates the rail id for a deal
     * @param dealId The id of the deal
     * @param railId The id of the rail
     */
    function updateRailId(uint256 dealId, uint256 railId) external;

    /**
     * @notice Gets a deal
     * @param dealId The id of the deal
     * @return deal The deal
     */
    function getDeal(uint256 dealId) external view returns (PoRepTypes.Deal memory deal);

    /**
     * @notice Gets the data fields for a deal
     * @param dealId The id of the deal
     * @return dealData The deal data
     */
    function getDealData(uint256 dealId) external view returns (SharedTypes.DealData memory dealData);

    /**
     * @notice Gets the frozen size and duration terms for a deal
     * @param dealId The id of the deal
     * @return terms The deal terms
     */
    function getDealTerms(uint256 dealId) external view returns (PoRepTypes.DealTerms memory terms);

    /**
     * @notice Gets the proposal timing for a deal
     * @param dealId The id of the deal
     * @return timing The deal timing
     */
    function getDealTiming(uint256 dealId) external view returns (PoRepTypes.DealTiming memory timing);

    /**
     * @notice Gets the service window for a deal
     * @param dealId The id of the deal
     * @return service The deal service window
     */
    function getDealService(uint256 dealId) external view returns (PoRepTypes.DealService memory service);

    /**
     * @notice Gets the reserved and committed capacity for a deal
     * @param dealId The id of the deal
     * @return capacity The deal capacity
     */
    function getDealCapacity(uint256 dealId) external view returns (PoRepTypes.DealCapacity memory capacity);

    /**
     * @notice Gets payment terms and rail accounting for a deal
     * @param dealId The id of the deal
     * @return payment The deal payment data
     */
    function getDealPayment(uint256 dealId) external view returns (PoRepTypes.DealPayment memory payment);

    /**
     * @notice Gets SLI thresholds for a deal
     * @param dealId The id of the deal
     * @return slis The deal SLI thresholds
     */
    function getDealSLIs(uint256 dealId) external view returns (SharedTypes.SLIThresholds memory slis);

    /**
     * @notice Accepts a deal
     * @param dealId The id of the deal
     */
    function acceptDeal(uint256 dealId) external;

    /**
     * @notice Completes a deal
     * @param dealId The id of the deal
     */
    function completeDeal(uint256 dealId) external;

    /**
     * @notice Terminate a deal
     * @dev Terminates a deal by setting the deal state to terminated
     * @param dealId The id of the deal
     * @param terminator The address that terminated the deal
     * @param endEpoch The Filecoin epoch at which the deal was terminated
     */
    function terminateDeal(uint256 dealId, address terminator, uint256 endEpoch) external;

    /**
     * @notice Rejects a deal
     * @param dealId The id of the deal
     */
    function rejectDeal(uint256 dealId) external;

    /**
     * @notice Rejects a deal in Accepted state before rail is set
     * @dev Only callable by the admin
     * @param dealId The id of the deal
     */
    function rejectAcceptedDeal(uint256 dealId) external;

    /**
     * @notice Gets all completed deals
     * @return activeDeals Array of active deals
     */
    function getCompletedDeals() external view returns (PoRepTypes.Deal[] memory activeDeals);

    /**
     * @notice Retrieves the manifest location URL for a specific deal
     * @param dealId The unique identifier of the deal
     * @return manifestLocation The manifest location URL for a specific deal
     */
    function getManifestLocation(uint256 dealId) external view returns (string memory manifestLocation);

    /**
     * @notice Updates the manifest location for a specific deal
     * @dev Only callable by the admin
     * @param dealId The unique identifier of the deal
     * @param newManifestLocation The new manifest location URL to be updated for the deal
     */
    function updateManifestLocation(uint256 dealId, string calldata newManifestLocation) external;

    /**
     * @notice Gets deals for a specific organization by state
     * @param organization The address of the organization
     * @param state The state of the deals to retrieve
     * @return deals Array of deals for the organization in the specified state (from all providers associated with the organization)
     */
    function getDealsForOrganizationByState(address organization, PoRepTypes.DealState state)
        external
        view
        returns (PoRepTypes.Deal[] memory deals);

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
     * @param dealId The id of the deal
     * @return The deal evidence adapter address
     */
    function getDealEvidenceAdapter(uint256 dealId) external view returns (address);

    /**
     * @notice Submit evidence to the adapter assigned to a deal
     * @param dealId The id of the deal
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Adapter activation decision for the submitted batch
     */
    function submitEvidenceBatch(uint256 dealId, bytes calldata evidenceData)
        external
        returns (SharedTypes.ActivationDecision memory decision);

    /**
     * @notice Activate evidence for a deal through its assigned adapter
     * @param dealId The id of the deal
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Adapter activation decision
     */
    function activateEvidence(uint256 dealId, bytes calldata evidenceData)
        external
        returns (SharedTypes.ActivationDecision memory decision);

    /**
     * @notice Refresh evidence status for a deal through its assigned adapter
     * @param dealId The id of the deal
     * @param evidenceData Adapter-specific evidence payload
     * @return status Updated evidence status
     */
    function refreshEvidenceStatus(uint256 dealId, bytes calldata evidenceData)
        external
        returns (SharedTypes.EvidenceStatus memory status);

    /**
     * @notice Reads current evidence status for a deal through its assigned adapter
     * @param dealId The id of the deal
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
     * @return deals Array of all deals
     */
    function getDeals() external view returns (PoRepTypes.Deal[] memory deals);

    /**
     * @notice Rejects expired deal
     * @param dealId The id of the deal
     * @dev A deal is considered expired if it has been in the proposed state past the configured expiration
     */
    function rejectExpiredDeal(uint256 dealId) external;

    /**
     * @notice Sets new proposed deal expiration
     * @dev Only callable by the admin
     * @param newDealExpiration The new proposed deal expiration in epochs
     */
    function setNewDealExpiration(uint256 newDealExpiration) external;

    /**
     * @notice Retrieves the proposed deal expiration
     * @return dealExpiration The proposed deal expiration in epochs
     */
    function getDealExpiration() external view returns (uint256);
}

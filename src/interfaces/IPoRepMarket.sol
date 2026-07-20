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
     * @notice Proposes a deal against a specific provider offer
     * @dev Only admins can bypass automatic matching and reserve a specific offer
     * @param offerId The provider offer to reserve for the deal
     * @param request The client deal request
     */
    function proposeDealWithSpecificOffer(uint256 offerId, SharedTypes.DealRequest calldata request) external;

    /**
     * @notice Previews the provider offer automatic matching would select for a deal request
     * @param request The client deal request
     * @return selection The selected provider offer snapshot, or zeroed fields when no offer matches
     */
    function previewProviderForDeal(SharedTypes.DealRequest calldata request)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory selection);

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
     * @notice Sets the minimum time between settlements for a deal
     * @param dealId The id of the deal
     * @param minEpochs Minimum time between settlements in epochs
     */
    function setMinEpochsBetweenSettlements(uint256 dealId, uint256 minEpochs) external;

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
     * @notice Gets the number of deals created by PoRepMarket.
     * @dev Offchain tools and oracle jobs use this to size full scans and detect
     * whether new deals appeared while a scan was running.
     * @return count Total number of created deal IDs.
     */
    function getDealCount() external view returns (uint256 count);

    /**
     * @notice Gets a creation-order page of deal IDs.
     * @dev This exists for ID-first backfills, queue construction, retry logic,
     * and large oracle scans that should avoid returning nested structs and strings
     * before a worker knows which deals it needs to process. The caller chooses
     * `limit` based on RPC gas, timeout, and response-size limits.
     * @param offset Zero-based index in the creation-order deal ID list.
     * @param limit Maximum number of deal IDs to return.
     * @return dealIds Page of deal IDs in creation order.
     * @return total Total number of created deal IDs at call time.
     */
    function getDealIds(uint256 offset, uint256 limit) external view returns (uint256[] memory dealIds, uint256 total);

    /**
     * @notice Gets a page of deal IDs for one lifecycle state.
     * @dev Oracle jobs use this for recurring scans over active or finalized deals
     * without scanning every historical deal. The caller chooses `limit` based on
     * RPC gas, timeout, and response-size limits.
     * @param state Deal lifecycle state code.
     * @param offset Zero-based index in the state's deal ID list.
     * @param limit Maximum number of deal IDs to return.
     * @return dealIds Page of deal IDs in the state's existing index order.
     * @return total Total number of deal IDs in this state at call time.
     */
    function getDealIdsByState(uint8 state, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory dealIds, uint256 total);

    /**
     * @notice Gets the organization selected for a provider when a deal was proposed.
     * @param dealId The id of the deal.
     * @return organization The provider organization.
     */
    function getDealOrganization(uint256 dealId) external view returns (address organization);

    /**
     * @notice Accepts a deal
     * @param dealId The id of the deal
     */
    function acceptDeal(uint256 dealId) external;

    /**
     * @notice Finalizes an active deal after service has ended and asks its validator to terminate the rail.
     * @param dealId The id of the deal
     */
    function finalizeDeal(uint256 dealId) external;

    /**
     * @notice Activates payment for an active deal
     * @param dealId The id of the deal
     */
    function activatePayment(uint256 dealId) external;

    /**
     * @notice Terminates an active deal early and asks its validator to terminate the rail.
     * @param dealId The id of the deal
     */
    function terminateDeal(uint256 dealId) external;

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
     * @notice Updates the manifest location for a specific deal
     * @dev Only callable by the admin
     * @param dealId The unique identifier of the deal
     * @param newManifestLocation The new manifest location URL to be updated for the deal
     */
    function updateManifestLocation(uint256 dealId, string calldata newManifestLocation) external;

    /**
     * @notice Updates the deal activation padding
     * @param padding The new padding value
     */
    function setDealActivationPadding(uint256 padding) external;

    /**
     * @notice Getter for deal activation padding
     * @return padding Current padding value
     */
    function getDealActivationPadding() external view returns (uint256);

    /**
     * @notice Gets deals for a specific organization by state
     * @param organization The address of the organization
     * @param state The state of the deals to retrieve
     * @return deals Array of deals for the organization in the specified state (from all providers associated with the organization)
     */
    function getDealsForOrganizationByState(address organization, uint8 state)
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
    function currentEvidenceStatus(uint256 dealId) external returns (SharedTypes.EvidenceStatus memory status);

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

    /**
     * @notice Validates deal settlement for a deal
     * @param dealId The id of the deal
     * @param fromEpoch The starting epoch for settlement validation
     * @param toEpoch The ending epoch for settlement validation
     * @return decision Settlement decision based on evidence and deal terms
     */
    function validateDealSettlement(uint256 dealId, uint256 fromEpoch, uint256 toEpoch)
        external
        returns (SharedTypes.SettlementDecision memory decision);
}

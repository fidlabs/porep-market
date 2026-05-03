// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {PoRepTypes} from "../types/PoRepTypes.sol";
import {SLITypes} from "../types/SLITypes.sol";

/**
 * @title IPoRepMarket interface
 * @notice IPoRepMarket interface for interacting with PoRepMarket contract
 */
interface IPoRepMarket {
    /**
     * @notice Sets the client smart contract
     * @dev Sets the client smart contract
     * @param _clientSmartContract The address of the client smart contract
     */
    function setClientSmartContract(address _clientSmartContract) external;

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
     * @param actualSizeBytes The actual size of the deal in bytes
     */
    function completeDeal(uint256 dealId, uint256 actualSizeBytes) external;

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
     * @dev Rejects a deal in Proposed state, or in Accepted state before validator and rail id are set
     * @param dealId The id of the deal proposal
     */
    function rejectDeal(uint256 dealId) external;

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
}

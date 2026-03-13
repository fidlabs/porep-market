// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SLITypes} from "../types/SLITypes.sol";

/**
 * @title ISPRegistry
 * @notice Interface for storage provider registration, matching, and capacity management
 */
interface ISPRegistry {
    struct ProviderInfo {
        address organization;
        address payee;
        bool paused;
        bool blocked;
        SLITypes.SLIThresholds capabilities;
        uint256 availableBytes;
        uint256 committedBytes;
        uint256 pendingBytes;
        /// @notice USDFC price per 32 GiB sector in smallest units (0 = manual approval)
        uint256 pricePerSector;
    }

    /**
     * @notice Get all registered providers
     * @return Array of all registered provider actor IDs
     */
    function getProviders() external view returns (CommonTypes.FilActorId[] memory);

    /**
     * @notice Get providers that have committed capacity (committedBytes > 0)
     * @return Array of provider actor IDs with permanently allocated storage
     */
    function getCommittedProviders() external view returns (CommonTypes.FilActorId[] memory);

    /**
     * @notice Get all providers registered under an organization
     * @param organization The organization address
     * @return Array of provider actor IDs belonging to the organization
     */
    function getProvidersByOrganization(address organization) external view returns (CommonTypes.FilActorId[] memory);

    /**
     * @notice Get full information about a provider
     * @param provider The provider actor ID
     * @return info The provider's registration info
     */
    function getProviderInfo(CommonTypes.FilActorId provider) external view returns (ProviderInfo memory info);

    /**
     * @notice Check if a provider is registered
     * @param provider The provider actor ID
     * @return True if the provider is registered
     */
    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool);

    /**
     * @notice Find a provider matching requirements and reserve pending capacity
     * @dev Selects the least-committed eligible provider. Reserves `pendingBytes` atomically
     *      so capacity is held between matching and commitment.
     *      Returns FilActorId(0) if no provider matches.
     * @param requirements SLI thresholds the client needs
     * @param terms Commercial terms (size, price, duration)
     * @return provider The matched provider, or FilActorId(0) if none found
     * @return autoApprove True if the provider's price per sector is met by the deal terms
     */
    function getProviderForDeal(SLITypes.SLIThresholds calldata requirements, SLITypes.DealTerms calldata terms)
        external
        returns (CommonTypes.FilActorId provider, bool autoApprove);

    /**
     * @notice Release committed capacity (called on deal rejection)
     * @dev Decrements committedBytes for the provider. Reverts on underflow.
     * @param provider The provider whose capacity to release
     * @param sizeBytes Amount of capacity to release
     */
    function releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes) external;

    /**
     * @notice Release pending capacity (called on deal rejection before commitment)
     * @dev Decrements pendingBytes for the provider. Reverts if sizeBytes > pendingBytes.
     * @param provider The provider whose pending capacity to release
     * @param sizeBytes Amount of pending capacity to release
     */
    function releasePendingCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes) external;

    /**
     * @notice Check if address is authorized to act on behalf of a provider
     * @dev Admin always returns true. Otherwise checks MinerUtils.isControllingAddress.
     * @param caller Address to check
     * @param provider Provider to check against
     * @return True if caller is authorized for provider
     */
    function isAuthorizedForProvider(address caller, CommonTypes.FilActorId provider) external view returns (bool);

    /**
     * @notice Block a provider (admin only, excluded from matching)
     * @param provider The provider to block
     */
    function blockProvider(CommonTypes.FilActorId provider) external;

    /**
     * @notice Unblock a provider (admin only)
     * @param provider The provider to unblock
     */
    function unblockProvider(CommonTypes.FilActorId provider) external;

    /**
     * @notice Commit actual capacity after DDO allocation
     * @dev Releases estimated pending bytes, then commits actual bytes.
     *      Enforces sector padding tolerance if configured.
     * @param provider The provider whose capacity to commit
     * @param estimatedSizeBytes Estimated size from the original deal proposal
     * @param actualSizeBytes Actual deal size from DDO allocation
     */
    function commitCapacity(CommonTypes.FilActorId provider, uint256 estimatedSizeBytes, uint256 actualSizeBytes)
        external;

    /**
     * @notice Register a new provider under caller's ownership
     * @param provider The provider actor ID to register
     */
    function registerProvider(CommonTypes.FilActorId provider) external;

    /**
     * @notice Pause a provider (excluded from matching)
     * @param provider The provider to pause
     */
    function pauseProvider(CommonTypes.FilActorId provider) external;

    /**
     * @notice Unpause a provider (available for matching)
     * @param provider The provider to unpause
     */
    function unpauseProvider(CommonTypes.FilActorId provider) external;

    /**
     * @notice Update provider's available storage capacity
     * @param provider The provider to update
     * @param availableBytes New available capacity in bytes
     */
    function updateAvailableSpace(CommonTypes.FilActorId provider, uint256 availableBytes) external;

    /**
     * @notice Set SLI capabilities for a provider
     * @param provider The provider to update
     * @param capabilities The SLI capabilities this provider guarantees
     */
    function setCapabilities(CommonTypes.FilActorId provider, SLITypes.SLIThresholds calldata capabilities) external;

    /**
     * @notice Set the price per sector for a provider
     * @param provider The provider to update
     * @param pricePerSector The USDFC price per 32 GiB sector in smallest units (0 to disable auto-approve)
     */
    function setPrice(CommonTypes.FilActorId provider, uint256 pricePerSector) external;

    /**
     * @notice Set the payment recipient address for a provider
     * @param provider The provider to update
     * @param payee The address that will receive payments for this provider
     */
    function setPayee(CommonTypes.FilActorId provider, address payee) external;

    /**
     * @notice Get the payment recipient address for a provider
     * @param provider The provider actor ID
     * @return The payee address
     */
    function getPayee(CommonTypes.FilActorId provider) external view returns (address);

    /**
     * @notice Set the sector padding tolerance in basis points (admin only)
     * @param bps Tolerance in basis points (e.g., 1000 = 10%)
     */
    function setToleranceBps(uint256 bps) external;

    /**
     * @notice Get the current sector padding tolerance
     * @return Tolerance in basis points
     */
    function getToleranceBps() external view returns (uint256);
}

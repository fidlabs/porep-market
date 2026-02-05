// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SLIThresholds, DealTerms} from "../types/SLITypes.sol";

/**
 * @title ISPRegistry
 * @notice Interface for storage provider registration, matching, and capacity management
 */
interface ISPRegistry {
    // ============ Provider Matching (called by PoRepMarket) ============

    /**
     * @notice Find and reserve a provider matching requirements
     * @dev Reserves capacity atomically. Selection uses closest-match + weighted round-robin.
     * @param requirements SLI thresholds the client needs
     * @param terms Commercial terms (size, price, duration)
     * @return provider The matched provider (reverts if none found)
     */
    function getProviderForDeal(SLIThresholds calldata requirements, DealTerms calldata terms)
        external
        returns (CommonTypes.FilActorId provider);

    /**
     * @notice Release reserved capacity (called on deal rejection)
     * @param provider The provider whose capacity to release
     * @param sizeBytes Amount of capacity to release
     */
    function releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes) external;

    /**
     * @notice Check if address owns/controls a provider
     * @param ownerAddress Address to check
     * @param provider Provider to check against
     * @return True if ownerAddress owns/controls provider
     */
    function isStorageProviderOwner(address ownerAddress, CommonTypes.FilActorId provider) external view returns (bool);

    // ============ Admin Functions ============

    /**
     * @notice Add an approved owner (admin only)
     * @param owner Address to approve as owner
     */
    function addOwner(address owner) external;

    /**
     * @notice Remove an owner (admin only)
     * @param owner Address to remove
     */
    function removeOwner(address owner) external;

    // ============ Owner Self-Management ============

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
     * @param thresholds The SLI thresholds this provider guarantees
     */
    function setCapabilities(CommonTypes.FilActorId provider, SLIThresholds calldata thresholds) external;
}

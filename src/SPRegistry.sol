// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {SLITypes} from "./types/SLITypes.sol";
import {MinerUtils} from "./libs/MinerUtils.sol";

/**
 * @title SPRegistry
 * @dev Storage provider registry for registration, matching, and capacity management
 * @notice SPRegistry contract manages storage provider lifecycle for PoRepMarket
 */
contract SPRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ISPRegistry {
    using EnumerableSet for EnumerableSet.UintSet;

    /**
     * @notice Role to manage contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice Role for PoRepMarket to call matching and capacity functions
     */
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    struct ProviderData {
        address organization;
        bool paused;
        SLITypes.SLIThresholds capabilities;
        uint256 availableBytes;
        uint256 committedBytes;
        uint256 pendingBytes;
        uint256 pricePerSector;
    }

    /// @custom:storage-location erc7201:porepmarket.storage.SPRegistryStorage
    // forge-lint: disable-next-line(pascal-case-struct)
    struct SPRegistryStorage {
        EnumerableSet.UintSet _providerIds;
        mapping(address => EnumerableSet.UintSet) _orgProviders;
        mapping(uint64 => ProviderData) _providers;
        uint256 sectorPaddingToleranceBps;
    }

    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.SPRegistryStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SP_REGISTRY_STORAGE_LOCATION =
        0x29a3c97291f1bc298e74d2ad6fe62e764c2656f8f0c161acf9b2bd013019df00;

    // solhint-disable-next-line use-natspec
    function _getSPRegistryStorage() private pure returns (SPRegistryStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := SP_REGISTRY_STORAGE_LOCATION
        }
    }

    /**
     * @notice OrganizationAdded event
     * @param organization The address of the organization
     */
    event OrganizationAdded(address indexed organization);

    /**
     * @notice ProviderRegistered event
     * @param provider The provider actor ID
     * @param organization The address of the organization
     */
    event ProviderRegistered(CommonTypes.FilActorId indexed provider, address indexed organization);

    /**
     * @notice CapabilitiesUpdated event
     * @param provider The provider actor ID
     * @param capabilities The updated SLI capabilities
     */
    event CapabilitiesUpdated(CommonTypes.FilActorId indexed provider, SLITypes.SLIThresholds capabilities);

    /**
     * @notice AvailableSpaceUpdated event
     * @param provider The provider actor ID
     * @param availableBytes The new available space in bytes
     */
    event AvailableSpaceUpdated(CommonTypes.FilActorId indexed provider, uint256 availableBytes);

    /**
     * @notice CapacityCommitted event
     * @param provider The provider actor ID
     * @param committedBytes The amount of bytes committed
     */
    event CapacityCommitted(CommonTypes.FilActorId indexed provider, uint256 committedBytes);

    /**
     * @notice CapacityReleased event
     * @param provider The provider actor ID
     * @param releasedBytes The amount of bytes released
     */
    event CapacityReleased(CommonTypes.FilActorId indexed provider, uint256 releasedBytes);

    /**
     * @notice PriceUpdated event
     * @param provider The provider actor ID
     * @param oldPrice The previous price per sector
     * @param newPrice The new price per sector
     */
    event PriceUpdated(CommonTypes.FilActorId indexed provider, uint256 oldPrice, uint256 newPrice);

    /**
     * @notice PendingCapacityReserved event
     * @param provider The provider actor ID
     * @param sizeBytes The amount of bytes reserved
     */
    event PendingCapacityReserved(CommonTypes.FilActorId indexed provider, uint256 sizeBytes);

    /**
     * @notice PendingCapacityReleased event
     * @param provider The provider actor ID
     * @param sizeBytes The amount of bytes released
     */
    event PendingCapacityReleased(CommonTypes.FilActorId indexed provider, uint256 sizeBytes);

    /**
     * @notice ToleranceBpsUpdated event
     * @param oldBps The previous tolerance in basis points
     * @param newBps The new tolerance in basis points
     */
    event ToleranceBpsUpdated(uint256 indexed oldBps, uint256 indexed newBps);

    error ProviderAlreadyRegistered(CommonTypes.FilActorId provider);
    error ProviderNotRegistered(CommonTypes.FilActorId provider);
    error NotProviderControllerOrAdmin(address caller, CommonTypes.FilActorId provider);
    error InvalidRetrievabilityPct(uint8 value);
    error InvalidIndexingPct(uint8 value);
    error InvalidAdminAddress();
    error InvalidPoRepMarketAddress();
    error InvalidProviderActorId();
    error InvalidOrganizationAddress();
    error NotImplemented();
    error ReleaseExceedsCommitted(CommonTypes.FilActorId provider, uint256 sizeBytes, uint256 committedBytes);
    error CommitExceedsAvailable(CommonTypes.FilActorId provider, uint256 newCommitted, uint256 availableBytes);
    error ActualSizeExceedsTolerance(CommonTypes.FilActorId provider, uint256 actualSize, uint256 maxAllowed);
    error ReleasePendingExceedsPending(CommonTypes.FilActorId provider, uint256 sizeBytes, uint256 pendingBytes);
    error AvailableBelowCommittedPlusPending(
        CommonTypes.FilActorId provider, uint256 availableBytes, uint256 committedBytes, uint256 pendingBytes
    );

    /**
     * @notice Constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @param _admin The address of the admin
     * @param _poRepMarket The address of the PoRepMarket contract
     */
    function initialize(address _admin, address _poRepMarket) public initializer {
        if (_admin == address(0)) revert InvalidAdminAddress();
        if (_poRepMarket == address(0)) revert InvalidPoRepMarketAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(MARKET_ROLE, _poRepMarket);
    }

    /// @inheritdoc ISPRegistry
    function registerProvider(CommonTypes.FilActorId) external pure {
        revert NotImplemented();
    }

    /// @inheritdoc ISPRegistry
    function pauseProvider(CommonTypes.FilActorId provider) external {
        _ensureProviderRegistered(provider);
        _onlyProviderControllerOrAdmin(provider);
        _getSPRegistryStorage()._providers[CommonTypes.FilActorId.unwrap(provider)].paused = true;
    }

    /// @inheritdoc ISPRegistry
    function unpauseProvider(CommonTypes.FilActorId provider) external {
        _ensureProviderRegistered(provider);
        _onlyProviderControllerOrAdmin(provider);
        _getSPRegistryStorage()._providers[CommonTypes.FilActorId.unwrap(provider)].paused = false;
    }

    /// @inheritdoc ISPRegistry
    function updateAvailableSpace(CommonTypes.FilActorId provider, uint256 availableBytes) external {
        _ensureProviderRegistered(provider);
        _onlyProviderControllerOrAdmin(provider);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        ProviderData storage p = $._providers[CommonTypes.FilActorId.unwrap(provider)];
        uint256 minRequired = p.committedBytes + p.pendingBytes;
        if (availableBytes < minRequired) {
            revert AvailableBelowCommittedPlusPending(provider, availableBytes, p.committedBytes, p.pendingBytes);
        }
        p.availableBytes = availableBytes;
        emit AvailableSpaceUpdated(provider, availableBytes);
    }

    /// @inheritdoc ISPRegistry
    function setCapabilities(CommonTypes.FilActorId provider, SLITypes.SLIThresholds calldata capabilities) external {
        _ensureProviderRegistered(provider);
        _onlyProviderControllerOrAdmin(provider);
        if (capabilities.retrievabilityPct > 100) revert InvalidRetrievabilityPct(capabilities.retrievabilityPct);
        if (capabilities.indexingPct > 100) revert InvalidIndexingPct(capabilities.indexingPct);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        $._providers[CommonTypes.FilActorId.unwrap(provider)].capabilities = capabilities;
        emit CapabilitiesUpdated(provider, capabilities);
    }

    /// @inheritdoc ISPRegistry
    function setPrice(CommonTypes.FilActorId provider, uint256 pricePerSector) external {
        _ensureProviderRegistered(provider);
        _onlyProviderControllerOrAdmin(provider);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        uint256 oldPrice = $._providers[id].pricePerSector;
        $._providers[id].pricePerSector = pricePerSector;
        emit PriceUpdated(provider, oldPrice, pricePerSector);
    }

    /// @inheritdoc ISPRegistry
    function getProviders() external view returns (CommonTypes.FilActorId[] memory) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        return _toFilActorIdArray($._providerIds);
    }

    /// @inheritdoc ISPRegistry
    function getCommittedProviders() external view returns (CommonTypes.FilActorId[] memory) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint256 length = $._providerIds.length();
        uint256 count = 0;

        for (uint256 i = 0; i < length; i++) {
            uint64 id = uint64($._providerIds.at(i));
            if ($._providers[id].committedBytes > 0) count++;
        }

        CommonTypes.FilActorId[] memory result = new CommonTypes.FilActorId[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < length; i++) {
            uint64 id = uint64($._providerIds.at(i));
            if ($._providers[id].committedBytes > 0) {
                result[idx++] = CommonTypes.FilActorId.wrap(id);
            }
        }
        return result;
    }

    /// @inheritdoc ISPRegistry
    function getProviderInfo(CommonTypes.FilActorId provider) external view returns (ProviderInfo memory info) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        ProviderData storage p = $._providers[CommonTypes.FilActorId.unwrap(provider)];
        info = ProviderInfo({
            organization: p.organization,
            paused: p.paused,
            capabilities: p.capabilities,
            availableBytes: p.availableBytes,
            committedBytes: p.committedBytes,
            pendingBytes: p.pendingBytes,
            pricePerSector: p.pricePerSector
        });
    }

    /// @inheritdoc ISPRegistry
    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        return $._providerIds.contains(uint256(CommonTypes.FilActorId.unwrap(provider)));
    }

    /// @inheritdoc ISPRegistry
    function isStorageProviderOwner(address caller, CommonTypes.FilActorId provider) external view returns (bool) {
        if (hasRole(DEFAULT_ADMIN_ROLE, caller)) return true;
        return MinerUtils.isControllingAddress(provider, caller);
    }

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
        onlyRole(MARKET_ROLE)
        returns (CommonTypes.FilActorId, bool)
    {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint256 length = $._providerIds.length();

        CommonTypes.FilActorId bestProvider;
        uint256 lowestCommitted = type(uint256).max;
        uint256 bestProviderPrice;

        for (uint256 i = 0; i < length; i++) {
            uint64 id = uint64($._providerIds.at(i));
            ProviderData storage p = $._providers[id];

            if (p.paused) continue;

            {
                uint256 used = p.committedBytes + p.pendingBytes;
                uint256 remaining = p.availableBytes > used ? p.availableBytes - used : 0;
                if (remaining < terms.dealSizeBytes) continue;
            }

            if (!_meetsRequirements(p.capabilities, requirements)) continue;

            if (p.committedBytes < lowestCommitted) {
                lowestCommitted = p.committedBytes;
                bestProvider = CommonTypes.FilActorId.wrap(id);
                bestProviderPrice = p.pricePerSector;
                if (lowestCommitted == 0) break;
            }
        }

        if (CommonTypes.FilActorId.unwrap(bestProvider) != 0) {
            uint64 bestId = CommonTypes.FilActorId.unwrap(bestProvider);
            $._providers[bestId].pendingBytes += terms.dealSizeBytes;
            emit PendingCapacityReserved(bestProvider, terms.dealSizeBytes);
        }

        // solhint-disable gas-strict-inequalities
        bool autoApprove = bestProviderPrice > 0 && CommonTypes.FilActorId.unwrap(bestProvider) != 0
            && terms.pricePerSector >= bestProviderPrice;
        // solhint-enable gas-strict-inequalities

        return (bestProvider, autoApprove);
    }

    /// @inheritdoc ISPRegistry
    function releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes) external onlyRole(MARKET_ROLE) {
        _ensureProviderRegistered(provider);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint256 committed = $._providers[CommonTypes.FilActorId.unwrap(provider)].committedBytes;
        if (sizeBytes > committed) revert ReleaseExceedsCommitted(provider, sizeBytes, committed);
        $._providers[CommonTypes.FilActorId.unwrap(provider)].committedBytes = committed - sizeBytes;
        emit CapacityReleased(provider, sizeBytes);
    }

    /// @inheritdoc ISPRegistry
    function releasePendingCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes) external onlyRole(MARKET_ROLE) {
        _ensureProviderRegistered(provider);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        uint256 pending = $._providers[id].pendingBytes;
        if (sizeBytes > pending) revert ReleasePendingExceedsPending(provider, sizeBytes, pending);
        $._providers[id].pendingBytes = pending - sizeBytes;
        emit PendingCapacityReleased(provider, sizeBytes);
    }

    /// @inheritdoc ISPRegistry
    function commitCapacity(CommonTypes.FilActorId provider, uint256 estimatedSizeBytes, uint256 actualSizeBytes)
        external
        onlyRole(MARKET_ROLE)
    {
        _ensureProviderRegistered(provider);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        ProviderData storage p = $._providers[CommonTypes.FilActorId.unwrap(provider)];

        if ($.sectorPaddingToleranceBps > 0) {
            uint256 maxAllowed = (estimatedSizeBytes * (10_000 + $.sectorPaddingToleranceBps)) / 10_000;
            if (actualSizeBytes > maxAllowed) {
                revert ActualSizeExceedsTolerance(provider, actualSizeBytes, maxAllowed);
            }
        }

        uint256 pendingReleased;
        // solhint-disable-next-line gas-strict-inequalities
        if (estimatedSizeBytes <= p.pendingBytes) {
            pendingReleased = estimatedSizeBytes;
            p.pendingBytes -= estimatedSizeBytes;
        } else {
            pendingReleased = p.pendingBytes;
            p.pendingBytes = 0;
        }

        uint256 newCommitted = p.committedBytes + actualSizeBytes;
        if (newCommitted > p.availableBytes) revert CommitExceedsAvailable(provider, newCommitted, p.availableBytes);
        p.committedBytes = newCommitted;
        emit PendingCapacityReleased(provider, pendingReleased);
        emit CapacityCommitted(provider, actualSizeBytes);
    }

    /// @inheritdoc ISPRegistry
    function setToleranceBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint256 oldBps = $.sectorPaddingToleranceBps;
        $.sectorPaddingToleranceBps = bps;
        emit ToleranceBpsUpdated(oldBps, bps);
    }

    /// @inheritdoc ISPRegistry
    function getToleranceBps() external view returns (uint256) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        return $.sectorPaddingToleranceBps;
    }

    /**
     * @notice Register a provider with full configuration in one call
     * @dev Admin convenience function for testnet onboarding. NOT in ISPRegistry interface.
     * @param provider The provider actor ID to register
     * @param organization The address of the provider's organization
     * @param capabilities The SLI thresholds this provider guarantees
     * @param availableBytes The provider's available storage capacity
     * @param pricePerSector The provider's auto-approve price per sector (0 to skip)
     */
    function registerProviderFor(
        CommonTypes.FilActorId provider,
        address organization,
        SLITypes.SLIThresholds calldata capabilities,
        uint256 availableBytes,
        uint256 pricePerSector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (organization == address(0)) revert InvalidOrganizationAddress();
        _registerProvider(provider, organization);

        if (capabilities.retrievabilityPct > 100) revert InvalidRetrievabilityPct(capabilities.retrievabilityPct);
        if (capabilities.indexingPct > 100) revert InvalidIndexingPct(capabilities.indexingPct);

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        $._providers[id].capabilities = capabilities;
        $._providers[id].availableBytes = availableBytes;
        $._providers[id].pricePerSector = pricePerSector;
        emit CapabilitiesUpdated(provider, capabilities);
        emit AvailableSpaceUpdated(provider, availableBytes);
        emit PriceUpdated(provider, 0, pricePerSector);
    }

    /**
     * @notice Registers a provider under the given organization
     * @param provider The provider actor ID to register
     * @param organization The address of the provider's organization
     */
    function _registerProvider(CommonTypes.FilActorId provider, address organization) internal {
        if (CommonTypes.FilActorId.unwrap(provider) == 0) revert InvalidProviderActorId();
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint256 id256 = uint256(CommonTypes.FilActorId.unwrap(provider));
        if (!$._providerIds.add(id256)) revert ProviderAlreadyRegistered(provider);

        $._providers[CommonTypes.FilActorId.unwrap(provider)].organization = organization;
        $._orgProviders[organization].add(id256);

        emit ProviderRegistered(provider, organization);
    }

    /**
     * @notice Ensures the caller is a miner controlling address or admin
     * @dev Uses MinerUtils.isControllingAddress to verify on-chain miner ownership
     * @param provider The provider actor ID to check against
     */
    function _onlyProviderControllerOrAdmin(CommonTypes.FilActorId provider) internal view {
        if (hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) return;
        if (!MinerUtils.isControllingAddress(provider, msg.sender)) {
            revert NotProviderControllerOrAdmin(msg.sender, provider);
        }
    }

    /**
     * @notice Ensures a provider is registered
     * @param provider The provider actor ID to check
     */
    function _ensureProviderRegistered(CommonTypes.FilActorId provider) internal view {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        if (!$._providerIds.contains(uint256(CommonTypes.FilActorId.unwrap(provider)))) {
            revert ProviderNotRegistered(provider);
        }
    }

    /**
     * @notice Checks if capabilities meet the given requirements
     * @param caps The provider's SLI capabilities
     * @param reqs The required SLI thresholds
     * @return True if all non-zero requirement dimensions are met
     */
    function _meetsRequirements(SLITypes.SLIThresholds memory caps, SLITypes.SLIThresholds calldata reqs)
        internal
        pure
        returns (bool)
    {
        if (reqs.retrievabilityPct != 0 && caps.retrievabilityPct < reqs.retrievabilityPct) return false;
        if (reqs.bandwidthMbps != 0 && caps.bandwidthMbps < reqs.bandwidthMbps) return false;
        if (reqs.latencyMs != 0 && caps.latencyMs > reqs.latencyMs) return false; // lower is better
        if (reqs.indexingPct != 0 && caps.indexingPct < reqs.indexingPct) return false;
        return true;
    }

    /**
     * @notice Converts a UintSet to a FilActorId array
     * @param set The UintSet to convert
     * @return Array of FilActorId values
     */
    function _toFilActorIdArray(EnumerableSet.UintSet storage set)
        internal
        view
        returns (CommonTypes.FilActorId[] memory)
    {
        uint256 length = set.length();
        CommonTypes.FilActorId[] memory result = new CommonTypes.FilActorId[](length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = CommonTypes.FilActorId.wrap(uint64(set.at(i)));
        }
        return result;
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Authorizes an upgrade
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

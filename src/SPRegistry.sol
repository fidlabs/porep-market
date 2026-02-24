// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {SLIThresholds, DealTerms} from "./types/SLITypes.sol";

/**
 * @title SPRegistry
 * @dev Storage provider registry for registration, matching, and capacity management
 * @notice SPRegistry contract manages storage provider lifecycle for PoRepMarket
 */
contract SPRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ISPRegistry {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @notice Role to manage contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice Role for PoRepMarket to call matching and capacity functions
     */
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    struct ProviderData {
        address owner;
        bool paused;
        SLIThresholds capabilities;
        uint256 availableBytes;
        uint256 committedBytes;
        uint256 defaultPricePerDeal;
    }

    /// @custom:storage-location erc7201:porepmarket.storage.SPRegistryStorage
    struct SPRegistryStorage {
        EnumerableSet.UintSet _providerIds;
        EnumerableSet.AddressSet _approvedOwners;
        mapping(address => EnumerableSet.UintSet) _ownerProviders;
        mapping(uint64 => ProviderData) _providers;
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
     * @notice OwnerAdded event
     * @dev OwnerAdded event is emitted when an owner is approved
     * @param owner The address of the approved owner
     */
    event OwnerAdded(address indexed owner);

    /**
     * @notice ProviderRegistered event
     * @dev ProviderRegistered event is emitted when a provider is registered
     * @param provider The provider actor ID
     * @param owner The address of the owner
     */
    event ProviderRegistered(CommonTypes.FilActorId indexed provider, address indexed owner);

    /**
     * @notice CapabilitiesUpdated event
     * @dev CapabilitiesUpdated event is emitted when a provider's capabilities are updated
     * @param provider The provider actor ID
     * @param capabilities The updated SLI capabilities
     */
    event CapabilitiesUpdated(CommonTypes.FilActorId indexed provider, SLIThresholds capabilities);

    /**
     * @notice AvailableSpaceUpdated event
     * @dev AvailableSpaceUpdated event is emitted when a provider's available space is updated
     * @param provider The provider actor ID
     * @param availableBytes The new available space in bytes
     */
    event AvailableSpaceUpdated(CommonTypes.FilActorId indexed provider, uint256 availableBytes);

    /**
     * @notice CapacityCommitted event
     * @dev CapacityCommitted event is emitted when capacity is committed for a provider
     * @param provider The provider actor ID
     * @param committedBytes The amount of bytes committed
     */
    event CapacityCommitted(CommonTypes.FilActorId indexed provider, uint256 committedBytes);

    /**
     * @notice CapacityReleased event
     * @dev CapacityReleased event is emitted when capacity is released for a provider
     * @param provider The provider actor ID
     * @param releasedBytes The amount of bytes released
     */
    event CapacityReleased(CommonTypes.FilActorId indexed provider, uint256 releasedBytes);

    /**
     * @notice DefaultPriceUpdated event
     * @dev DefaultPriceUpdated event is emitted when a provider's default price is updated
     * @param provider The provider actor ID
     * @param oldPrice The previous default price per deal
     * @param newPrice The new default price per deal
     */
    event DefaultPriceUpdated(CommonTypes.FilActorId indexed provider, uint256 oldPrice, uint256 newPrice);

    error ProviderAlreadyRegistered(CommonTypes.FilActorId provider);
    error ProviderNotRegistered(CommonTypes.FilActorId provider);
    error NotProviderOwnerOrAdmin(address caller, CommonTypes.FilActorId provider);
    error InvalidRetrievabilityPct(uint8 value);
    error InvalidIndexingPct(uint8 value);
    error InvalidAdminAddress();
    error InvalidPoRepMarketAddress();
    error InvalidProviderActorId();
    error InvalidOwnerAddress();
    error NotImplemented();
    error ReleaseExceedsCommitted(CommonTypes.FilActorId provider, uint256 sizeBytes, uint256 committedBytes);
    error CommitExceedsAvailable(CommonTypes.FilActorId provider, uint256 newCommitted, uint256 availableBytes);

    /**
     * @notice Constructor
     * @dev Constructor disables initializers
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @dev Initializes the contract by setting admin roles and market role
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
    function addOwner(address) external pure {
        revert NotImplemented();
    }

    /// @inheritdoc ISPRegistry
    function removeOwner(address) external pure {
        revert NotImplemented();
    }

    /// @inheritdoc ISPRegistry
    function registerProvider(CommonTypes.FilActorId) external pure {
        revert NotImplemented();
    }

    /// @inheritdoc ISPRegistry
    function pauseProvider(CommonTypes.FilActorId) external pure {
        revert NotImplemented();
    }

    /// @inheritdoc ISPRegistry
    function unpauseProvider(CommonTypes.FilActorId) external pure {
        revert NotImplemented();
    }

    /// @inheritdoc ISPRegistry
    function updateAvailableSpace(CommonTypes.FilActorId provider, uint256 availableBytes) external {
        _ensureProviderRegistered(provider);
        _onlyProviderOwnerOrAdmin(provider);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        $._providers[CommonTypes.FilActorId.unwrap(provider)].availableBytes = availableBytes;
        emit AvailableSpaceUpdated(provider, availableBytes);
    }

    /// @inheritdoc ISPRegistry
    function setCapabilities(CommonTypes.FilActorId provider, SLIThresholds calldata capabilities) external {
        _ensureProviderRegistered(provider);
        _onlyProviderOwnerOrAdmin(provider);
        if (capabilities.retrievabilityPct > 100) revert InvalidRetrievabilityPct(capabilities.retrievabilityPct);
        if (capabilities.indexingPct > 100) revert InvalidIndexingPct(capabilities.indexingPct);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        $._providers[CommonTypes.FilActorId.unwrap(provider)].capabilities = capabilities;
        emit CapabilitiesUpdated(provider, capabilities);
    }

    /// @inheritdoc ISPRegistry
    function setDefaultPrice(CommonTypes.FilActorId, uint256) external pure {
        revert NotImplemented();
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

        // First pass: count committed providers
        for (uint256 i = 0; i < length; i++) {
            uint64 id = uint64($._providerIds.at(i));
            if ($._providers[id].committedBytes > 0) count++;
        }

        // Second pass: populate array
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
            owner: p.owner,
            paused: p.paused,
            capabilities: p.capabilities,
            availableBytes: p.availableBytes,
            committedBytes: p.committedBytes,
            defaultPricePerDeal: p.defaultPricePerDeal
        });
    }

    /// @inheritdoc ISPRegistry
    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        return $._providerIds.contains(uint256(CommonTypes.FilActorId.unwrap(provider)));
    }

    /// @inheritdoc ISPRegistry
    function isStorageProviderOwner(address ownerAddress, CommonTypes.FilActorId provider)
        external
        view
        returns (bool)
    {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        return $._providers[CommonTypes.FilActorId.unwrap(provider)].owner == ownerAddress;
    }

    /**
     * @notice Find a provider matching requirements for a deal
     * @dev Capacity is NOT reserved atomically by this function. Between the time a provider
     *      is selected here and when `commitCapacity` is called, other deals may consume the
     *      same capacity (TOCTOU race). This is acceptable for now because `commitCapacity`
     *      enforces the upper bound and will revert if capacity is exceeded.
     *      Future improvement: consider implementing `pendingBytes` reservation to hold
     *      capacity between matching and commitment, preventing optimistic over-selection.
     * @param requirements SLI thresholds the client needs
     * @param terms Commercial terms (size, price, duration)
     * @return provider The matched provider, or FilActorId(0) if none found
     * @return autoApprove True if the provider's default price is met by the deal terms
     */
    function getProviderForDeal(SLIThresholds calldata requirements, DealTerms calldata terms)
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

            uint256 remaining = p.availableBytes > p.committedBytes ? p.availableBytes - p.committedBytes : 0;
            if (remaining < terms.dealSizeBytes) continue;

            if (!_meetsRequirements(p.capabilities, requirements)) continue;

            if (p.committedBytes < lowestCommitted) {
                lowestCommitted = p.committedBytes;
                bestProvider = CommonTypes.FilActorId.wrap(id);
                bestProviderPrice = p.defaultPricePerDeal;
                if (lowestCommitted == 0) break;
            }
        }

        // solhint-disable gas-strict-inequalities
        bool autoApprove = bestProviderPrice > 0 && CommonTypes.FilActorId.unwrap(bestProvider) != 0
            && terms.priceForDeal >= bestProviderPrice;
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
    function commitCapacity(CommonTypes.FilActorId provider, uint256 actualSizeBytes) external onlyRole(MARKET_ROLE) {
        _ensureProviderRegistered(provider);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        ProviderData storage p = $._providers[CommonTypes.FilActorId.unwrap(provider)];
        uint256 newCommitted = p.committedBytes + actualSizeBytes;
        if (newCommitted > p.availableBytes) revert CommitExceedsAvailable(provider, newCommitted, p.availableBytes);
        p.committedBytes = newCommitted;
        emit CapacityCommitted(provider, actualSizeBytes);
    }

    /**
     * @notice Register a provider with full configuration in one call
     * @dev Admin convenience function for testnet onboarding. NOT in ISPRegistry interface.
     * @param provider The provider actor ID to register
     * @param owner The address of the provider's owner
     * @param capabilities The SLI thresholds this provider guarantees
     * @param availableBytes The provider's available storage capacity
     * @param defaultPricePerDeal The provider's default auto-approve price (0 to skip)
     */
    function registerProviderFor(
        CommonTypes.FilActorId provider,
        address owner,
        SLIThresholds calldata capabilities,
        uint256 availableBytes,
        uint256 defaultPricePerDeal
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (owner == address(0)) revert InvalidOwnerAddress();
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        if (!$._approvedOwners.contains(owner)) {
            $._approvedOwners.add(owner);
            emit OwnerAdded(owner);
        }
        _registerProvider(provider, owner);

        if (capabilities.retrievabilityPct > 100) revert InvalidRetrievabilityPct(capabilities.retrievabilityPct);
        if (capabilities.indexingPct > 100) revert InvalidIndexingPct(capabilities.indexingPct);

        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        $._providers[id].capabilities = capabilities;
        $._providers[id].availableBytes = availableBytes;
        $._providers[id].defaultPricePerDeal = defaultPricePerDeal;
        emit CapabilitiesUpdated(provider, capabilities);
        emit AvailableSpaceUpdated(provider, availableBytes);
        emit DefaultPriceUpdated(provider, 0, defaultPricePerDeal);
    }

    /**
     * @notice Registers a provider under the given owner
     * @dev Registers a provider by adding it to the provider set and storing ownership
     * @param provider The provider actor ID to register
     * @param owner The address of the provider's owner
     */
    function _registerProvider(CommonTypes.FilActorId provider, address owner) internal {
        if (CommonTypes.FilActorId.unwrap(provider) == 0) revert InvalidProviderActorId();
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint256 id256 = uint256(CommonTypes.FilActorId.unwrap(provider));
        if (!$._providerIds.add(id256)) revert ProviderAlreadyRegistered(provider);

        $._providers[CommonTypes.FilActorId.unwrap(provider)].owner = owner;
        $._ownerProviders[owner].add(id256);

        emit ProviderRegistered(provider, owner);
    }

    /**
     * @notice Ensures the caller is the provider owner or admin
     * @dev Ensures the caller is the provider owner or admin by checking ownership and role
     * @param provider The provider actor ID to check against
     */
    function _onlyProviderOwnerOrAdmin(CommonTypes.FilActorId provider) internal view {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        if (msg.sender != $._providers[id].owner && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotProviderOwnerOrAdmin(msg.sender, provider);
        }
    }

    /**
     * @notice Ensures a provider is registered
     * @dev Ensures a provider is registered by checking the provider set
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
     * @dev Checks if capabilities meet the given requirements by comparing each non-zero dimension
     * @param capabilities The provider's SLI capabilities
     * @param requirements The required SLI thresholds
     * @return True if all non-zero requirement dimensions are met
     */
    function _meetsRequirements(SLIThresholds storage capabilities, SLIThresholds calldata requirements)
        internal
        view
        returns (bool)
    {
        if (requirements.retrievabilityPct != 0 && capabilities.retrievabilityPct < requirements.retrievabilityPct) {
            return false;
        }
        if (requirements.bandwidthMbps != 0 && capabilities.bandwidthMbps < requirements.bandwidthMbps) {
            return false;
        }
        if (requirements.latencyMs != 0 && capabilities.latencyMs > requirements.latencyMs) return false;
        if (requirements.indexingPct != 0 && capabilities.indexingPct < requirements.indexingPct) return false;
        return true;
    }

    /**
     * @notice Converts a UintSet to a FilActorId array
     * @dev Converts a UintSet to a FilActorId array by iterating and wrapping each element
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
     * @dev Authorizes an upgrade by checking if the caller has the upgrader role
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

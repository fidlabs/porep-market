// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {SLITypes} from "./types/SLITypes.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {MinerUtils} from "./lib/MinerUtils.sol";

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

    /**
     * @notice Role for trusted operators to register providers
     */
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /**
     * @notice Maximum sector padding tolerance in basis points (100% = 10000)
     */
    uint256 public constant MAX_TOLERANCE_BPS = 10_000;

    /**
     * @notice Maximum number of providers that can be registered
     */
    uint256 public constant MAX_PROVIDERS = 500;

    /**
     * @notice Maximum deal duration in days, sourced from PoRepTypes.MAX_DEAL_DURATION_DAYS.
     * @dev Any provider limit above this is unreachable: PoRepMarket rejects deals with durationDays > 1278.
     */
    uint32 public constant MAX_DEAL_DURATION_DAYS = PoRepTypes.MAX_DEAL_DURATION_DAYS;

    // solhint-disable-next-line gas-struct-packing
    struct ProviderData {
        address organization;
        address payee;
        bool paused;
        bool blocked;
        SLITypes.SLIThresholds capabilities;
        uint256 availableBytes;
        uint256 committedBytes;
        uint256 pendingBytes;
        uint256 pricePerSectorPerMonth;
        uint32 minDealDurationDays;
        uint32 maxDealDurationDays;
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

    /**
     * @notice ProviderBlocked event
     * @dev ProviderBlocked event is emitted when an admin blocks a provider
     * @param provider The provider actor ID
     */
    event ProviderBlocked(CommonTypes.FilActorId indexed provider);

    /**
     * @notice ProviderUnblocked event
     * @dev ProviderUnblocked event is emitted when an admin unblocks a provider
     * @param provider The provider actor ID
     */
    event ProviderUnblocked(CommonTypes.FilActorId indexed provider);

    /**
     * @notice ProviderPaused event
     * @dev ProviderPaused event is emitted when a provider is paused
     * @param provider The provider actor ID
     */
    event ProviderPaused(CommonTypes.FilActorId indexed provider);

    /**
     * @notice ProviderUnpaused event
     * @dev ProviderUnpaused event is emitted when a provider is unpaused
     * @param provider The provider actor ID
     */
    event ProviderUnpaused(CommonTypes.FilActorId indexed provider);

    /**
     * @notice PayeeUpdated event
     * @dev PayeeUpdated event is emitted when a provider's payee address changes
     * @param provider The provider actor ID
     * @param oldPayee The previous payee address
     * @param newPayee The new payee address
     */
    event PayeeUpdated(CommonTypes.FilActorId indexed provider, address indexed oldPayee, address indexed newPayee);

    /**
     * @notice DealDurationLimitsUpdated event
     * @dev DealDurationLimitsUpdated event is emitted when a provider's deal duration limits change
     * @param provider The provider actor ID
     * @param minDealDurationDays The minimum deal duration in days (0 = no minimum)
     * @param maxDealDurationDays The maximum deal duration in days (0 = no maximum)
     */
    event DealDurationLimitsUpdated(
        CommonTypes.FilActorId indexed provider, uint32 minDealDurationDays, uint32 maxDealDurationDays
    );

    /**
     * @notice Error indicating that a provider is already registered
     * @dev 0xf91794e7
     */
    error ProviderAlreadyRegistered(CommonTypes.FilActorId provider);

    /**
     * @notice Error indicating that a provider is not registered
     * @dev 0x2b87b09e
     */
    error ProviderNotRegistered(CommonTypes.FilActorId provider);

    /**
     * @notice Error indicating that a provider is blocked
     * @dev 0x5c675853
     */
    error ProviderIsBlocked(CommonTypes.FilActorId provider);

    /**
     * @notice Error indicating that bps is above the maximum allowed value
     * @dev 0xb25e9f7b
     */
    error ToleranceBpsTooHigh(uint256 bps, uint256 maxBps);

    /**
     * @notice Error indicating that the caller is not authorized to manage the provider
     * @dev 0xf3da36ec
     */
    error NotProviderControllerOrAdmin(address caller, CommonTypes.FilActorId provider);

    /**
     * @notice Error indicating that the caller is not an admin or operator
     * @dev 0xe525bbbc
     */
    error NotAdminOrOperator(address caller);

    /**
     * @notice Error indicating that the retrievabilityBps value is above the maximum allowed value
     * @dev 0x26f456b9
     */
    error InvalidRetrievabilityBps(uint16 value);

    /**
     * @notice Error indicating that the indexingPct value is above the maximum allowed value
     * @dev 0xad23dabc
     */
    error InvalidIndexingPct(uint8 value);

    /**
     * @notice Error indicating that the admin address provided is invalid
     * @dev 0x05bb467c
     */
    error InvalidAdminAddress();

    /**
     * @notice Error indicating that the PoRepMarket address provided is invalid
     * @dev 0xc9cc4a06
     */
    error InvalidPoRepMarketAddress();

    /**
     * @notice Error indicating that the provider actor ID is invalid
     * @dev 0x7599e239
     */
    error InvalidProviderActorId();

    /**
     * @notice Error indicating that the organization address provided is invalid
     * @dev 0x98fd3e14
     */
    error InvalidOrganizationAddress();

    /**
     * @notice Error indicating that the payee address provided is invalid
     * @dev 0xf25dd3b6
     */
    error InvalidPayeeAddress();

    /**
     * @notice Error indicating that the maximum number of providers has been reached
     * @dev 0xce14fdbb
     */
    error MaxProvidersReached(uint256 maxProviders);

    /**
     * @notice Error indicating that size bytes being released exceeds the committed bytes for the provider
     * @dev 0x014d0038
     */
    error ReleaseExceedsCommitted(CommonTypes.FilActorId provider, uint256 sizeBytes, uint256 committedBytes);

    /**
     * @notice Error indicating that the new committed size exceeds the provider's available bytes
     * @dev 0x2578fa12
     */
    error CommitExceedsAvailable(CommonTypes.FilActorId provider, uint256 newCommitted, uint256 availableBytes);

    /**
     * @notice Error indicating that the actual size of a deal exceeds the maximum allowed size based on tolerance
     * @dev 0xc7fee2cc
     */
    error ActualSizeExceedsTolerance(CommonTypes.FilActorId provider, uint256 actualSize, uint256 maxAllowed);

    /**
     * @notice Error indicating that the size bytes being released exceeds the pending bytes for the provider
     * @dev 0xe8ac622c
     */
    error ReleasePendingExceedsPending(CommonTypes.FilActorId provider, uint256 sizeBytes, uint256 pendingBytes);

    /**
     * @notice Error indicating that the available bytes for a provider is below the sum of committed and pending bytes
     * @dev 0x708e0591
     */
    error AvailableBelowCommittedPlusPending(
        CommonTypes.FilActorId provider, uint256 availableBytes, uint256 committedBytes, uint256 pendingBytes
    );
    error MinDurationExceedsMax(uint32 minDays, uint32 maxDays);
    error DurationExceedsProtocolMax(uint32 durationDays, uint32 maxDays);

    /**
     * @notice Constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with admin roles only
     * @dev Phase 1 of two-phase initialization. Call initialize2 after PoRepMarket is deployed.
     * @param _admin The address of the admin
     */
    function initialize(address _admin) public initializer {
        if (_admin == address(0)) revert InvalidAdminAddress();

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    /**
     * @notice Completes initialization by granting MARKET_ROLE to PoRepMarket
     * @dev Phase 2 of two-phase initialization. Called after PoRepMarket is deployed.
     * @param _poRepMarket The address of the PoRepMarket contract
     */
    function initialize2(address _poRepMarket) public reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_poRepMarket == address(0)) revert InvalidPoRepMarketAddress();

        _grantRole(MARKET_ROLE, _poRepMarket);
    }

    /// @inheritdoc ISPRegistry
    function pauseProvider(CommonTypes.FilActorId provider) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);

        _getSPRegistryStorage()._providers[CommonTypes.FilActorId.unwrap(provider)].paused = true;

        emit ProviderPaused(provider);
    }

    /// @inheritdoc ISPRegistry
    function unpauseProvider(CommonTypes.FilActorId provider) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);

        _getSPRegistryStorage()._providers[CommonTypes.FilActorId.unwrap(provider)].paused = false;

        emit ProviderUnpaused(provider);
    }

    /// @inheritdoc ISPRegistry
    function blockProvider(CommonTypes.FilActorId provider) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ensureProviderRegistered(provider);

        _getSPRegistryStorage()._providers[CommonTypes.FilActorId.unwrap(provider)].blocked = true;

        emit ProviderBlocked(provider);
    }

    /// @inheritdoc ISPRegistry
    function unblockProvider(CommonTypes.FilActorId provider) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ensureProviderRegistered(provider);

        _getSPRegistryStorage()._providers[CommonTypes.FilActorId.unwrap(provider)].blocked = false;

        emit ProviderUnblocked(provider);
    }

    /// @inheritdoc ISPRegistry
    function updateAvailableSpace(CommonTypes.FilActorId provider, uint256 availableBytes) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
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
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);
        if (capabilities.retrievabilityBps > 10_000) revert InvalidRetrievabilityBps(capabilities.retrievabilityBps);
        if (capabilities.indexingPct > 100) revert InvalidIndexingPct(capabilities.indexingPct);

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        $._providers[CommonTypes.FilActorId.unwrap(provider)].capabilities = capabilities;

        emit CapabilitiesUpdated(provider, capabilities);
    }

    /// @inheritdoc ISPRegistry
    function setPrice(CommonTypes.FilActorId provider, uint256 pricePerSectorPerMonth) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        uint256 oldPrice = $._providers[id].pricePerSectorPerMonth;
        $._providers[id].pricePerSectorPerMonth = pricePerSectorPerMonth;

        emit PriceUpdated(provider, oldPrice, pricePerSectorPerMonth);
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
            payee: p.payee,
            paused: p.paused,
            blocked: p.blocked,
            capabilities: p.capabilities,
            availableBytes: p.availableBytes,
            committedBytes: p.committedBytes,
            pendingBytes: p.pendingBytes,
            pricePerSectorPerMonth: p.pricePerSectorPerMonth,
            minDealDurationDays: p.minDealDurationDays,
            maxDealDurationDays: p.maxDealDurationDays
        });
    }

    /// @inheritdoc ISPRegistry
    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        return $._providerIds.contains(uint256(CommonTypes.FilActorId.unwrap(provider)));
    }

    /// @inheritdoc ISPRegistry
    function isAuthorizedForProvider(address caller, CommonTypes.FilActorId provider) external view returns (bool) {
        if (hasRole(DEFAULT_ADMIN_ROLE, caller)) return true;
        return MinerUtils.isControllingAddress(provider, caller);
    }

    /**
     * @notice Find a provider matching requirements and reserve pending capacity
     * @dev Selects the least-pending eligible provider. Reserves `pendingBytes` atomically
     *      so capacity is held between matching and commitment.
     *      Returns FilActorId(0) if no provider matches.
     * @param requirements SLI thresholds the client needs
     * @param terms Commercial terms (size, price, duration)
     * @return provider The matched provider, or FilActorId(0) if none found
     * @return autoApprove True if the provider's price per sector is met by the deal terms
     * @return organization The address of the matched provider
     */
    function getProviderForDeal(SLITypes.SLIThresholds calldata requirements, SLITypes.DealTerms calldata terms)
        external
        onlyRole(MARKET_ROLE)
        returns (CommonTypes.FilActorId, bool, address)
    {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint256 length = $._providerIds.length();
        CommonTypes.FilActorId bestProvider;
        uint256 lowestPending = type(uint256).max;
        uint256 bestProviderPrice;

        for (uint256 i = 0; i < length; i++) {
            uint64 id = uint64($._providerIds.at(i));
            ProviderData storage p = $._providers[id];

            if (p.paused || p.blocked) continue;

            {
                uint256 used = p.committedBytes + p.pendingBytes;
                uint256 remaining = p.availableBytes > used ? p.availableBytes - used : 0;
                if (remaining < terms.dealSizeBytes) continue;
            }

            if (!_meetsRequirements(p.capabilities, requirements)) continue;

            if (p.minDealDurationDays != 0 && terms.durationDays < p.minDealDurationDays) continue;
            if (p.maxDealDurationDays != 0 && terms.durationDays > p.maxDealDurationDays) continue;

            if (p.pendingBytes < lowestPending) {
                lowestPending = p.pendingBytes;
                bestProvider = CommonTypes.FilActorId.wrap(id);
                bestProviderPrice = p.pricePerSectorPerMonth;
                if (lowestPending == 0) break;
            }
        }

        address organization;

        if (CommonTypes.FilActorId.unwrap(bestProvider) != 0) {
            uint64 bestId = CommonTypes.FilActorId.unwrap(bestProvider);
            $._providers[bestId].pendingBytes += terms.dealSizeBytes;
            organization = $._providers[bestId].organization;
            emit PendingCapacityReserved(bestProvider, terms.dealSizeBytes);
        }

        // solhint-disable gas-strict-inequalities
        bool autoApprove = bestProviderPrice > 0 && CommonTypes.FilActorId.unwrap(bestProvider) != 0
            && terms.pricePerSectorPerMonth >= bestProviderPrice;
        // solhint-enable gas-strict-inequalities

        return (bestProvider, autoApprove, organization);
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
        if (bps > MAX_TOLERANCE_BPS) revert ToleranceBpsTooHigh(bps, MAX_TOLERANCE_BPS);

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
     * @param pricePerSectorPerMonth The provider's auto-approve price per sector per month (0 to skip)
     * @param payee The payment recipient address (address(0) defaults to organization)
     * @param minDealDurationDays Minimum deal duration in days (0 = no minimum)
     * @param maxDealDurationDays Maximum deal duration in days (0 = no maximum)
     */
    function registerProviderFor(
        CommonTypes.FilActorId provider,
        address organization,
        SLITypes.SLIThresholds calldata capabilities,
        uint256 availableBytes,
        uint256 pricePerSectorPerMonth,
        address payee,
        uint32 minDealDurationDays,
        uint32 maxDealDurationDays
    ) external {
        _onlyAdminOrOperator();
        if (organization == address(0)) revert InvalidOrganizationAddress();
        if (capabilities.retrievabilityBps > 10_000) revert InvalidRetrievabilityBps(capabilities.retrievabilityBps);
        if (capabilities.indexingPct > 100) revert InvalidIndexingPct(capabilities.indexingPct);
        _ensureDurationLimitsValid(minDealDurationDays, maxDealDurationDays);

        _registerProvider(provider, organization, payee);

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        $._providers[id].capabilities = capabilities;
        $._providers[id].availableBytes = availableBytes;
        $._providers[id].pricePerSectorPerMonth = pricePerSectorPerMonth;
        $._providers[id].minDealDurationDays = minDealDurationDays;
        $._providers[id].maxDealDurationDays = maxDealDurationDays;

        emit CapabilitiesUpdated(provider, capabilities);
        emit AvailableSpaceUpdated(provider, availableBytes);
        emit PriceUpdated(provider, 0, pricePerSectorPerMonth);
        emit DealDurationLimitsUpdated(provider, minDealDurationDays, maxDealDurationDays);
    }

    /// @inheritdoc ISPRegistry
    function getProvidersByOrganization(address organization) external view returns (CommonTypes.FilActorId[] memory) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        return _toFilActorIdArray($._orgProviders[organization]);
    }

    /// @inheritdoc ISPRegistry
    function setPayee(CommonTypes.FilActorId provider, address payee) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);
        if (payee == address(0)) revert InvalidPayeeAddress();

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        address oldPayee = $._providers[id].payee;
        $._providers[id].payee = payee;

        emit PayeeUpdated(provider, oldPayee, payee);
    }

    /// @inheritdoc ISPRegistry
    function setDealDurationLimits(
        CommonTypes.FilActorId provider,
        uint32 minDealDurationDays,
        uint32 maxDealDurationDays
    ) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);
        _ensureDurationLimitsValid(minDealDurationDays, maxDealDurationDays);

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        $._providers[id].minDealDurationDays = minDealDurationDays;
        $._providers[id].maxDealDurationDays = maxDealDurationDays;

        emit DealDurationLimitsUpdated(provider, minDealDurationDays, maxDealDurationDays);
    }

    /// @inheritdoc ISPRegistry
    function getPayee(CommonTypes.FilActorId provider) external view returns (address) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        return $._providers[CommonTypes.FilActorId.unwrap(provider)].payee;
    }

    /**
     * @notice Registers a provider under the given organization
     * @param provider The provider actor ID to register
     * @param organization The address of the provider's organization
     * @param payee The payment recipient address (address(0) defaults to organization)
     */
    function _registerProvider(CommonTypes.FilActorId provider, address organization, address payee) internal {
        if (CommonTypes.FilActorId.unwrap(provider) == 0) revert InvalidProviderActorId();

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        // solhint-disable-next-line gas-strict-inequalities
        if ($._providerIds.length() >= MAX_PROVIDERS) revert MaxProvidersReached(MAX_PROVIDERS);

        uint256 id256 = uint256(CommonTypes.FilActorId.unwrap(provider));
        if (!$._providerIds.add(id256)) revert ProviderAlreadyRegistered(provider);

        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        $._providers[id].organization = organization;
        $._providers[id].payee = payee == address(0) ? organization : payee;
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
     * @notice Ensures the caller has DEFAULT_ADMIN_ROLE or OPERATOR_ROLE
     */
    function _onlyAdminOrOperator() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAdminOrOperator(msg.sender);
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
     * @notice Ensures deal duration limits are within the protocol maximum and internally consistent
     * @param minDealDurationDays The minimum deal duration to validate
     * @param maxDealDurationDays The maximum deal duration to validate
     */
    function _ensureDurationLimitsValid(uint32 minDealDurationDays, uint32 maxDealDurationDays) internal pure {
        if (minDealDurationDays > MAX_DEAL_DURATION_DAYS) {
            revert DurationExceedsProtocolMax(minDealDurationDays, MAX_DEAL_DURATION_DAYS);
        }
        if (maxDealDurationDays != 0 && maxDealDurationDays > MAX_DEAL_DURATION_DAYS) {
            revert DurationExceedsProtocolMax(maxDealDurationDays, MAX_DEAL_DURATION_DAYS);
        }
        if (minDealDurationDays != 0 && maxDealDurationDays != 0 && minDealDurationDays > maxDealDurationDays) {
            revert MinDurationExceedsMax(minDealDurationDays, maxDealDurationDays);
        }
    }

    /**
     * @notice Ensures a provider is not blocked
     * @param provider The provider actor ID to check
     */
    function _ensureProviderNotBlocked(CommonTypes.FilActorId provider) internal view {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        if ($._providers[CommonTypes.FilActorId.unwrap(provider)].blocked) {
            revert ProviderIsBlocked(provider);
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
        if (reqs.retrievabilityBps != 0 && caps.retrievabilityBps < reqs.retrievabilityBps) return false;
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

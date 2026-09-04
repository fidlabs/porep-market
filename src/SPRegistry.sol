// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {SharedTypes} from "./types/SharedTypes.sol";
import {OfferMatch} from "./types/OfferMatch.sol";
import {MinerUtils} from "./lib/MinerUtils.sol";
import {AccessControlledUpgradeable} from "./abstracts/AccessControlledUpgradeable.sol";
import {Roles} from "./lib/Roles.sol";

/**
 * @title SPRegistry
 * @notice Storage provider registry for provider offers, matching, and capacity management
 */
contract SPRegistry is AccessControlledUpgradeable, UUPSUpgradeable, ISPRegistry {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Maximum number of registered providers.
    uint256 public constant MAX_PROVIDERS = 100;
    /// @notice Maximum active offers per provider.
    uint256 public constant MAX_ACTIVE_OFFERS_PER_PROVIDER = 5;
    /// @notice Price band above the cheapest matching offer within which auto-match balances load, in basis points.
    uint256 public constant MATCH_PRICE_BAND_BPS = 100;
    /// @notice One hundred percent in basis points.
    uint256 public constant MAX_BPS = 10_000;

    struct Provider {
        address organization;
        address payee;
        bool paused;
        bool blocked;
    }

    struct ProviderCapacity {
        uint256 availableBytes;
        uint256 committedBytes;
        uint256 pendingBytes;
    }

    struct Offer {
        CommonTypes.FilActorId provider;
        bool active;
    }

    struct RegistryOfferPayment {
        bool active;
        uint256 pricePer32GiBPerMonth;
    }

    /// @custom:storage-location erc7201:porepmarket.storage.SPRegistryStorage
    // forge-lint: disable-next-line(pascal-case-struct)
    struct SPRegistryStorage {
        EnumerableSet.UintSet _providerIds;
        mapping(uint64 => Provider) _providers;
        mapping(uint64 => ProviderCapacity) _providerCapacity;
        uint256 nextOfferId;
        EnumerableSet.UintSet _activeOfferIds;
        EnumerableSet.AddressSet _paymentTokens;
        mapping(address => ISPRegistry.TokenConfig) _tokenConfig;
        mapping(uint64 => EnumerableSet.UintSet) _offerIdsByProvider;
        mapping(uint64 => uint256) _activeOfferCountByProvider;
        mapping(uint256 => Offer) _offers;
        mapping(uint256 => SharedTypes.OfferTerms) _offerTerms;
        mapping(uint256 => SharedTypes.SLIThresholds) _offerSLIs;
        mapping(uint256 => mapping(address => RegistryOfferPayment)) _offerPayments;
        mapping(address client => mapping(bytes32 manifestHash => mapping(address organization => bool)))
            _clientManifestDealWithOrganization;
        mapping(uint256 => EnumerableSet.AddressSet) _offerPaymentTokens;
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

    // solhint-disable-next-line use-natspec
    function s() internal pure returns (SPRegistryStorage storage) {
        return _getSPRegistryStorage();
    }

    function _providerId(CommonTypes.FilActorId provider) internal pure returns (uint64) {
        return CommonTypes.FilActorId.unwrap(provider);
    }

    /**
     * @notice Emitted when a provider is registered.
     * @param provider Registered provider actor ID.
     * @param organization Organization that owns the provider.
     */
    event ProviderRegistered(CommonTypes.FilActorId indexed provider, address indexed organization);

    /**
     * @notice Emitted when provider available capacity changes.
     * @param provider Provider actor ID.
     * @param availableBytes New available capacity in bytes.
     */
    event AvailableSpaceUpdated(CommonTypes.FilActorId indexed provider, uint256 availableBytes);

    /**
     * @notice Emitted when provider capacity is committed.
     * @param provider Provider actor ID.
     * @param committedBytes Bytes committed by the operation.
     */
    event CapacityCommitted(CommonTypes.FilActorId indexed provider, uint256 committedBytes);

    /**
     * @notice Emitted when committed provider capacity is released.
     * @param provider Provider actor ID.
     * @param releasedBytes Bytes released by the operation.
     */
    event CapacityReleased(CommonTypes.FilActorId indexed provider, uint256 releasedBytes);

    /**
     * @notice Emitted when provider pending capacity is reserved.
     * @param provider Provider actor ID.
     * @param sizeBytes Bytes reserved.
     */
    event PendingCapacityReserved(CommonTypes.FilActorId indexed provider, uint256 sizeBytes);

    /**
     * @notice Emitted when provider pending capacity is released.
     * @param provider Provider actor ID.
     * @param sizeBytes Bytes released.
     */
    event PendingCapacityReleased(CommonTypes.FilActorId indexed provider, uint256 sizeBytes);

    /**
     * @notice Emitted when a provider is blocked.
     * @param provider Provider actor ID.
     */
    event ProviderBlocked(CommonTypes.FilActorId indexed provider);

    /**
     * @notice Emitted when a provider is unblocked.
     * @param provider Provider actor ID.
     */
    event ProviderUnblocked(CommonTypes.FilActorId indexed provider);

    /**
     * @notice Emitted when a provider is paused.
     * @param provider Provider actor ID.
     */
    event ProviderPaused(CommonTypes.FilActorId indexed provider);

    /**
     * @notice Emitted when a provider is unpaused.
     * @param provider Provider actor ID.
     */
    event ProviderUnpaused(CommonTypes.FilActorId indexed provider);

    /**
     * @notice Emitted when provider payee changes.
     * @param provider Provider actor ID.
     * @param oldPayee Previous payee address.
     * @param newPayee New payee address.
     */
    event PayeeUpdated(CommonTypes.FilActorId indexed provider, address indexed oldPayee, address indexed newPayee);

    /* solhint-disable gas-indexed-events */
    /**
     * @notice Emitted when payment token policy changes.
     * @param token ERC20 token address.
     * @param allowed True when the token is allowed.
     * @param minPricePer32GiBPerMonth Minimum monthly price per 32 GiB in token smallest units.
     */
    event PaymentTokenUpdated(address indexed token, bool allowed, uint256 minPricePer32GiBPerMonth);
    /* solhint-enable gas-indexed-events */

    /**
     * @notice Emitted when an offer is created.
     * @param offerId Created offer ID.
     * @param provider Provider actor ID that owns the offer.
     */
    event OfferCreated(uint256 indexed offerId, CommonTypes.FilActorId indexed provider);

    /* solhint-disable gas-indexed-events */
    /**
     * @notice Emitted when an offer is enabled or disabled.
     * @param offerId Offer ID.
     * @param active True when the offer is active.
     */
    event OfferActiveUpdated(uint256 indexed offerId, bool active);
    /* solhint-enable gas-indexed-events */

    /* solhint-disable gas-indexed-events */
    /**
     * @notice Emitted when an offer payment row changes.
     * @param offerId Offer ID.
     * @param token ERC20 token address.
     * @param active True when the token row can be selected.
     * @param pricePer32GiBPerMonth Monthly price per 32 GiB in token smallest units.
     */
    event OfferPaymentUpdated(
        uint256 indexed offerId, address indexed token, bool active, uint256 pricePer32GiBPerMonth
    );
    /* solhint-enable gas-indexed-events */

    /**
     * @notice Emitted when matching reserves an offer for a deal request.
     * @param offerId Selected offer ID.
     * @param provider Selected provider actor ID.
     * @param token Selected payment token.
     * @param pricePer32GiBPerMonth Selected monthly price per 32 GiB in token smallest units.
     * @param reservedBytes Bytes reserved from provider capacity.
     */
    event OfferSelected(
        uint256 indexed offerId,
        CommonTypes.FilActorId indexed provider,
        address indexed token,
        uint256 pricePer32GiBPerMonth,
        uint256 reservedBytes
    );

    /**
     * @notice Emitted when a pending deal replaces its manifest assignment.
     * @param client Client whose assignment changes.
     * @param organization Organization holding the assignment.
     * @param oldManifestHash Released manifest hash.
     * @param newManifestHash Assigned manifest hash.
     */
    event ManifestAssignmentUpdated(
        address indexed client, address indexed organization, bytes32 oldManifestHash, bytes32 indexed newManifestHash
    );

    /**
     * @notice Error thrown when a provider is already registered
     * @dev 0xf91794e7
     */
    error ProviderAlreadyRegistered(CommonTypes.FilActorId provider);

    /**
     * @notice Error thrown when a provider is not registered
     * @dev 0x2b87b09e
     */
    error ProviderNotRegistered(CommonTypes.FilActorId provider);

    /**
     * @notice Error thrown when a provider is blocked
     * @dev 0x5c675853
     */
    error ProviderIsBlocked(CommonTypes.FilActorId provider);

    /**
     * @notice Error thrown when a paused provider attempts to create or activate an offer
     * @dev 0x02ffe7e3
     */
    error ProviderIsPaused(CommonTypes.FilActorId provider);

    /**
     * @notice Error thrown when caller is neither provider controller nor admin
     * @dev 0xf3da36ec
     */
    error NotProviderControllerOrAdmin(address caller, CommonTypes.FilActorId provider);

    /**
     * @notice Error thrown when caller is neither admin nor operator
     * @dev 0xe525bbbc
     */
    error NotAdminOrOperator(address caller);

    /**
     * @notice Error thrown when retrievability basis points exceed 10_000
     * @dev 0x26f456b9
     */
    error InvalidRetrievabilityBps(uint16 value);

    /**
     * @notice Error thrown when indexing percentage exceeds 100
     * @dev 0xad23dabc
     */
    error InvalidIndexingPct(uint8 value);

    /**
     * @notice Error thrown when provider actor ID is invalid
     * @dev 0x7599e239
     */
    error InvalidProviderActorId();

    /**
     * @notice Error thrown when organization address is invalid
     * @dev 0x98fd3e14
     */
    error InvalidOrganizationAddress();

    /**
     * @notice Error thrown when payee address is invalid
     * @dev 0xf25dd3b6
     */
    error InvalidPayeeAddress();

    /**
     * @notice Error thrown when payment token address is invalid
     * @dev 0x56e7ec5f
     */
    error InvalidPaymentToken();

    /**
     * @notice Error thrown when payment token is not allowed
     * @dev 0xfa51aec6
     */
    error PaymentTokenNotAllowed(address token);

    /**
     * @notice Error thrown when an offer price is below the token minimum
     * @dev 0x9dbfbcab
     */
    error PriceBelowTokenMinimum(address token, uint256 price, uint256 minimum);

    /**
     * @notice Error thrown when provider registration would exceed the provider cap
     * @dev 0xce14fdbb
     */
    error MaxProvidersReached(uint256 maxProviders);

    /**
     * @notice Error thrown when committed capacity release exceeds committed bytes
     * @dev 0x014d0038
     */
    error ReleaseExceedsCommitted(CommonTypes.FilActorId provider, uint256 sizeBytes, uint256 committedBytes);

    /**
     * @notice Error thrown when committing capacity would exceed available bytes
     * @dev 0x2578fa12
     */
    error CommitExceedsAvailable(CommonTypes.FilActorId provider, uint256 newCommitted, uint256 availableBytes);

    /**
     * @notice Error thrown when pending capacity release exceeds pending bytes
     * @dev 0xe8ac622c
     */
    error ReleasePendingExceedsPending(CommonTypes.FilActorId provider, uint256 sizeBytes, uint256 pendingBytes);

    /**
     * @notice Error thrown when available bytes fall below committed plus pending bytes
     * @dev 0x708e0591
     */
    error AvailableBelowCommittedPlusPending(
        CommonTypes.FilActorId provider, uint256 availableBytes, uint256 committedBytes, uint256 pendingBytes
    );

    /**
     * @notice Error thrown when an offer does not exist
     * @dev 0x1f376e4c
     */
    error OfferNotFound(uint256 offerId);

    /**
     * @notice Error thrown when a provider would exceed the active offer cap
     * @dev 0x01da340d
     */
    error TooManyActiveOffers(CommonTypes.FilActorId provider, uint256 maxOffers);

    /**
     * @notice Error thrown when offer size bounds are invalid
     * @dev 0x5aece97e
     */
    error InvalidOfferSizeBounds(uint256 minSizeBytes, uint256 maxSizeBytes);

    /**
     * @notice Error thrown when offer duration bounds are invalid
     * @dev 0xe6b89fa4
     */
    error InvalidOfferDurationBounds(uint64 minDurationEpochs, uint64 maxDurationEpochs);

    /**
     * @notice Error thrown when a specific offer is not eligible for a deal request
     * @dev 0x9e014588
     * @param offerId Offer that failed matching.
     * @param reason OfferMatch reason code identifying the first failing check.
     */
    error OfferNotEligible(uint256 offerId, uint16 reason);

    /**
     * @notice Error thrown when a replacement manifest hash is zero.
     * @dev 0x03d0cf2a
     */
    error InvalidManifestHash();

    /**
     * @notice Error thrown when the client's previous manifest is not assigned to the selected organization.
     * @dev 0xb0e04a53
     */
    error ManifestNotAssignedToOrganizationAndClient(address client, bytes32 manifestHash, address organization);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the protocol AccessManager.
     * @param _accessManager Protocol AccessManager address.
     */
    function initialize(address _accessManager) public initializer {
        __AccessControlled_init(_accessManager);
    }

    /// @inheritdoc ISPRegistry
    function registerProviderFor(
        CommonTypes.FilActorId provider,
        address organization,
        uint256 availableBytes,
        address payee
    ) external {
        _onlyAdminOrOperator();
        if (organization == address(0)) revert InvalidOrganizationAddress();

        _registerProvider(provider, organization, payee);

        SPRegistryStorage storage $ = s();
        $._providerCapacity[_providerId(provider)].availableBytes = availableBytes;

        emit AvailableSpaceUpdated(provider, availableBytes);
    }

    /// @inheritdoc ISPRegistry
    function pauseProvider(CommonTypes.FilActorId provider) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);

        s()._providers[_providerId(provider)].paused = true;

        emit ProviderPaused(provider);
    }

    /// @inheritdoc ISPRegistry
    function unpauseProvider(CommonTypes.FilActorId provider) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);

        s()._providers[_providerId(provider)].paused = false;

        emit ProviderUnpaused(provider);
    }

    /// @inheritdoc ISPRegistry
    function blockProvider(CommonTypes.FilActorId provider) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        _ensureProviderRegistered(provider);

        s()._providers[_providerId(provider)].blocked = true;

        emit ProviderBlocked(provider);
    }

    /// @inheritdoc ISPRegistry
    function unblockProvider(CommonTypes.FilActorId provider) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        _ensureProviderRegistered(provider);

        s()._providers[_providerId(provider)].blocked = false;

        emit ProviderUnblocked(provider);
    }

    /// @inheritdoc ISPRegistry
    function updateAvailableSpace(CommonTypes.FilActorId provider, uint256 availableBytes) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);

        SPRegistryStorage storage $ = s();
        ProviderCapacity storage c = $._providerCapacity[_providerId(provider)];

        uint256 minRequired = c.committedBytes + c.pendingBytes;
        if (availableBytes < minRequired) {
            revert AvailableBelowCommittedPlusPending(provider, availableBytes, c.committedBytes, c.pendingBytes);
        }
        c.availableBytes = availableBytes;

        emit AvailableSpaceUpdated(provider, availableBytes);
    }

    /// @inheritdoc ISPRegistry
    function getProviders(uint256 offset, uint256 limit)
        external
        view
        returns (CommonTypes.FilActorId[] memory providers, uint256 total)
    {
        EnumerableSet.UintSet storage providerIds = s()._providerIds;
        total = providerIds.length();
        uint256 length = _pageLength(total, offset, limit);
        providers = new CommonTypes.FilActorId[](length);

        for (uint256 i = 0; i < length; i++) {
            providers[i] = CommonTypes.FilActorId.wrap(uint64(providerIds.at(offset + i)));
        }
    }

    /// @inheritdoc ISPRegistry
    function getProviderView(CommonTypes.FilActorId provider) external view returns (ProviderView memory view_) {
        uint64 id = _providerId(provider);
        SPRegistryStorage storage $ = s();
        Provider storage p = $._providers[id];
        ProviderCapacity storage c = $._providerCapacity[id];

        view_ = ProviderView({
            provider: provider,
            organization: p.organization,
            payee: p.payee,
            paused: p.paused,
            blocked: p.blocked,
            availableBytes: c.availableBytes,
            committedBytes: c.committedBytes,
            pendingBytes: c.pendingBytes
        });
    }

    /// @inheritdoc ISPRegistry
    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool) {
        return s()._providerIds.contains(uint256(_providerId(provider)));
    }

    /// @inheritdoc ISPRegistry
    function isAuthorizedForProvider(address caller, CommonTypes.FilActorId provider) external view returns (bool) {
        if (_hasRole(Roles.OPERATOR_ROLE, caller) || _hasRole(Roles.DEFAULT_ADMIN_ROLE, caller)) return true;
        return MinerUtils.isControllingAddress(provider, caller);
    }

    /// @inheritdoc ISPRegistry
    function setPayee(CommonTypes.FilActorId provider, address payee) external {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _onlyProviderControllerOrAdmin(provider);
        if (payee == address(0)) revert InvalidPayeeAddress();

        SPRegistryStorage storage $ = s();
        uint64 id = _providerId(provider);
        address oldPayee = $._providers[id].payee;
        $._providers[id].payee = payee;

        emit PayeeUpdated(provider, oldPayee, payee);
    }

    /// @inheritdoc ISPRegistry
    function setPaymentToken(address token, bool allowed, uint256 minPricePer32GiBPerMonth)
        external
        onlyRole(Roles.DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert InvalidPaymentToken();

        SPRegistryStorage storage $ = s();
        $._tokenConfig[token] =
            ISPRegistry.TokenConfig({allowed: allowed, minPricePer32GiBPerMonth: minPricePer32GiBPerMonth});
        if (allowed) {
            $._paymentTokens.add(token);
        } else {
            $._paymentTokens.remove(token);
        }

        emit PaymentTokenUpdated(token, allowed, minPricePer32GiBPerMonth);
    }

    /// @inheritdoc ISPRegistry
    function getPaymentTokenConfig(address token) external view returns (ISPRegistry.TokenConfig memory config) {
        return s()._tokenConfig[token];
    }

    /// @inheritdoc ISPRegistry
    function getPaymentTokens() external view returns (address[] memory tokens) {
        return s()._paymentTokens.values();
    }

    /// @inheritdoc ISPRegistry
    function createOffer(
        CommonTypes.FilActorId provider,
        SharedTypes.OfferTerms calldata terms,
        SharedTypes.SLIThresholds calldata slis,
        SharedTypes.OfferPaymentInput[] calldata payments
    ) external returns (uint256 offerId) {
        _ensureProviderRegistered(provider);
        _ensureProviderNotBlocked(provider);
        _ensureProviderNotPaused(provider);
        _onlyProviderControllerOrAdmin(provider);
        _ensureOfferTermsValid(terms);
        _ensureSLIsValid(slis);

        SPRegistryStorage storage $ = s();
        uint64 providerId = _providerId(provider);
        // solhint-disable-next-line gas-strict-inequalities
        if ($._activeOfferCountByProvider[providerId] >= MAX_ACTIVE_OFFERS_PER_PROVIDER) {
            revert TooManyActiveOffers(provider, MAX_ACTIVE_OFFERS_PER_PROVIDER);
        }

        offerId = ++$.nextOfferId;
        $._offers[offerId] = Offer({provider: provider, active: true});
        $._offerTerms[offerId] = terms;
        $._offerSLIs[offerId] = slis;
        $._offerIdsByProvider[providerId].add(offerId);
        $._activeOfferCountByProvider[providerId]++;
        $._activeOfferIds.add(offerId);

        for (uint256 i = 0; i < payments.length; i++) {
            _setOfferPayment(offerId, payments[i].token, payments[i].active, payments[i].pricePer32GiBPerMonth);
        }

        emit OfferCreated(offerId, provider);
    }

    /// @inheritdoc ISPRegistry
    function setOfferActive(uint256 offerId, bool active) external {
        SPRegistryStorage storage $ = s();
        Offer storage offer = $._offers[offerId];
        _ensureOfferExists(offerId);
        _ensureProviderNotBlocked(offer.provider);
        if (active) _ensureProviderNotPaused(offer.provider);
        _onlyProviderControllerOrAdmin(offer.provider);

        if (offer.active == active) return;

        uint64 providerId = _providerId(offer.provider);
        if (active) {
            // solhint-disable-next-line gas-strict-inequalities
            if ($._activeOfferCountByProvider[providerId] >= MAX_ACTIVE_OFFERS_PER_PROVIDER) {
                revert TooManyActiveOffers(offer.provider, MAX_ACTIVE_OFFERS_PER_PROVIDER);
            }
            $._activeOfferCountByProvider[providerId]++;
            $._activeOfferIds.add(offerId);
        } else {
            $._activeOfferCountByProvider[providerId]--;
            $._activeOfferIds.remove(offerId);
        }

        offer.active = active;
        emit OfferActiveUpdated(offerId, active);
    }

    /// @inheritdoc ISPRegistry
    function setOfferPayment(uint256 offerId, address token, bool active, uint256 pricePer32GiBPerMonth) external {
        _ensureOfferExists(offerId);

        Offer storage offer = s()._offers[offerId];
        _ensureProviderNotBlocked(offer.provider);
        _onlyProviderControllerOrAdmin(offer.provider);

        _setOfferPayment(offerId, token, active, pricePer32GiBPerMonth);
    }

    /// @inheritdoc ISPRegistry
    function getOfferView(uint256 offerId) external view returns (OfferView memory view_) {
        _ensureOfferExists(offerId);
        SPRegistryStorage storage $ = s();
        Offer storage offer = $._offers[offerId];

        address[] memory tokens = $._offerPaymentTokens[offerId].values();
        OfferPaymentView[] memory payments = new OfferPaymentView[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            RegistryOfferPayment storage payment = $._offerPayments[offerId][tokens[i]];
            payments[i] = OfferPaymentView({
                token: tokens[i], active: payment.active, pricePer32GiBPerMonth: payment.pricePer32GiBPerMonth
            });
        }

        view_ = OfferView({
            offerId: offerId,
            provider: offer.provider,
            active: offer.active,
            terms: $._offerTerms[offerId],
            slis: $._offerSLIs[offerId],
            payments: payments
        });
    }

    /// @inheritdoc ISPRegistry
    function getOffersByProvider(CommonTypes.FilActorId provider) external view returns (uint256[] memory offerIds) {
        return s()._offerIdsByProvider[_providerId(provider)].values();
    }

    /// @inheritdoc ISPRegistry
    function previewProviderForDeal(address client, SharedTypes.DealRequest calldata request)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory selection)
    {
        return _selectProviderForDeal(client, request);
    }

    /// @inheritdoc ISPRegistry
    function isManifestAssignedToOrganizationAndClient(address client, bytes32 manifestHash, address organization)
        external
        view
        returns (bool)
    {
        return s()._clientManifestDealWithOrganization[client][manifestHash][organization];
    }

    /// @inheritdoc ISPRegistry
    function reserveProviderForDeal(address client, SharedTypes.DealRequest calldata request)
        external
        onlyRole(Roles.MARKET_ROLE)
        returns (SharedTypes.ProviderDealSelection memory selection)
    {
        selection = _selectProviderForDeal(client, request);
        if (_providerId(selection.provider) == 0) revert NoOfferMatched();
        _reserveSelection(client, request.manifestHash, selection);
    }

    /// @inheritdoc ISPRegistry
    function previewOfferForDeal(uint256 offerId, address client, SharedTypes.DealRequest calldata request)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory selection, uint16 reason)
    {
        return _evaluateOffer(offerId, client, request);
    }

    /// @inheritdoc ISPRegistry
    function reserveOfferForDeal(uint256 offerId, address client, SharedTypes.DealRequest calldata request)
        external
        onlyRole(Roles.MARKET_ROLE)
        returns (SharedTypes.ProviderDealSelection memory selection)
    {
        uint16 reason;
        (selection, reason) = _evaluateOffer(offerId, client, request);
        if (reason != OfferMatch.OK) revert OfferNotEligible(offerId, reason);
        _reserveSelection(client, request.manifestHash, selection);
    }

    /// @inheritdoc ISPRegistry
    function updatePendingReservation(
        uint256 offerId,
        address client,
        bytes32 oldManifestHash,
        bytes32 newManifestHash,
        uint256 oldSizeBytes,
        uint256 newSizeBytes
    ) external onlyRole(Roles.MARKET_ROLE) {
        _ensureOfferExists(offerId);
        if (newManifestHash == bytes32(0)) revert InvalidManifestHash();

        SPRegistryStorage storage $ = s();
        CommonTypes.FilActorId provider = $._offers[offerId].provider;
        address organization = $._providers[_providerId(provider)].organization;
        if (!$._clientManifestDealWithOrganization[client][oldManifestHash][organization]) {
            revert ManifestNotAssignedToOrganizationAndClient(client, oldManifestHash, organization);
        }
        ProviderCapacity storage c = $._providerCapacity[_providerId(provider)];
        if (oldSizeBytes > c.pendingBytes) {
            revert ReleasePendingExceedsPending(provider, oldSizeBytes, c.pendingBytes);
        }
        SharedTypes.OfferTerms storage terms = $._offerTerms[offerId];
        if (
            oldSizeBytes == 0 || newSizeBytes == 0 || newSizeBytes < terms.minSizeBytes
                || (terms.maxSizeBytes != 0 && newSizeBytes > terms.maxSizeBytes)
        ) revert OfferNotEligible(offerId, OfferMatch.SIZE_OUT_OF_BOUNDS);
        if (
            newManifestHash != oldManifestHash
                && $._clientManifestDealWithOrganization[client][newManifestHash][organization]
        ) revert OfferNotEligible(offerId, OfferMatch.MANIFEST_ALREADY_ASSIGNED);

        if (newSizeBytes > oldSizeBytes) {
            uint256 increase = newSizeBytes - oldSizeBytes;
            if (increase > _remainingCapacity(provider)) {
                revert OfferNotEligible(offerId, OfferMatch.INSUFFICIENT_CAPACITY);
            }
            _reservePending(provider, increase);
        } else if (newSizeBytes < oldSizeBytes) {
            uint256 decrease = oldSizeBytes - newSizeBytes;
            c.pendingBytes -= decrease;
            emit PendingCapacityReleased(provider, decrease);
        }
        if (newManifestHash != oldManifestHash) {
            $._clientManifestDealWithOrganization[client][oldManifestHash][organization] = false;
            $._clientManifestDealWithOrganization[client][newManifestHash][organization] = true;
            emit ManifestAssignmentUpdated(client, organization, oldManifestHash, newManifestHash);
        }
    }

    /// @inheritdoc ISPRegistry
    function releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, address client, bytes32 manifestHash)
        external
        onlyRole(Roles.MARKET_ROLE)
    {
        _releaseCapacity(provider, sizeBytes, client, manifestHash);
    }

    /// @inheritdoc ISPRegistry
    function releasePendingCapacity(
        CommonTypes.FilActorId provider,
        uint256 sizeBytes,
        address client,
        bytes32 manifestHash
    ) external onlyRole(Roles.MARKET_ROLE) {
        _releasePendingCapacity(provider, sizeBytes, client, manifestHash);
    }

    /// @inheritdoc ISPRegistry
    function commitCapacity(CommonTypes.FilActorId provider, uint256 estimatedSizeBytes, uint256 actualSizeBytes)
        external
        onlyRole(Roles.MARKET_ROLE)
    {
        _ensureProviderRegistered(provider);

        ProviderCapacity storage c = s()._providerCapacity[_providerId(provider)];

        uint256 pendingReleased;
        // solhint-disable-next-line gas-strict-inequalities
        if (estimatedSizeBytes <= c.pendingBytes) {
            pendingReleased = estimatedSizeBytes;
            c.pendingBytes -= estimatedSizeBytes;
        } else {
            pendingReleased = c.pendingBytes;
            c.pendingBytes = 0;
        }

        uint256 newCommitted = c.committedBytes + actualSizeBytes;
        if (newCommitted > c.availableBytes) revert CommitExceedsAvailable(provider, newCommitted, c.availableBytes);
        c.committedBytes = newCommitted;

        emit PendingCapacityReleased(provider, pendingReleased);
        emit CapacityCommitted(provider, actualSizeBytes);
    }

    /**
     * @notice Registers a provider and records its organization and payee.
     * @param provider Provider actor ID to register.
     * @param organization Organization that owns the provider.
     * @param payee Address that receives provider payments. Falls back to organization when zero.
     */
    function _registerProvider(CommonTypes.FilActorId provider, address organization, address payee) internal {
        if (_providerId(provider) == 0) revert InvalidProviderActorId();

        SPRegistryStorage storage $ = s();
        // solhint-disable-next-line gas-strict-inequalities
        if ($._providerIds.length() >= MAX_PROVIDERS) revert MaxProvidersReached(MAX_PROVIDERS);

        uint64 id = _providerId(provider);
        uint256 id256 = uint256(id);
        if (!$._providerIds.add(id256)) revert ProviderAlreadyRegistered(provider);

        $._providers[id].organization = organization;
        $._providers[id].payee = payee == address(0) ? organization : payee;

        emit ProviderRegistered(provider, organization);
    }

    function _onlyProviderControllerOrAdmin(CommonTypes.FilActorId provider) internal view {
        if (_hasRole(Roles.OPERATOR_ROLE, msg.sender) || _hasRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender)) return;
        if (!MinerUtils.isControllingAddress(provider, msg.sender)) {
            revert NotProviderControllerOrAdmin(msg.sender, provider);
        }
    }

    function _onlyAdminOrOperator() internal view {
        if (!_hasRole(Roles.OPERATOR_ROLE, msg.sender) && !_hasRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotAdminOrOperator(msg.sender);
        }
    }

    /**
     * @notice Ensures the provider is registered.
     * @param provider Provider actor ID to check.
     */
    function _ensureProviderRegistered(CommonTypes.FilActorId provider) internal view {
        if (!s()._providerIds.contains(uint256(_providerId(provider)))) {
            revert ProviderNotRegistered(provider);
        }
    }

    /**
     * @notice Ensures the provider is not blocked.
     * @param provider Provider actor ID to check.
     */
    function _ensureProviderNotBlocked(CommonTypes.FilActorId provider) internal view {
        if (s()._providers[_providerId(provider)].blocked) {
            revert ProviderIsBlocked(provider);
        }
    }

    /**
     * @notice Ensures the provider is not paused.
     * @param provider Provider actor ID to check.
     */
    function _ensureProviderNotPaused(CommonTypes.FilActorId provider) internal view {
        if (s()._providers[_providerId(provider)].paused) {
            revert ProviderIsPaused(provider);
        }
    }

    /**
     * @notice Ensures the offer exists.
     * @param offerId Offer ID to check.
     */
    function _ensureOfferExists(uint256 offerId) internal view {
        if (offerId == 0 || _providerId(s()._offers[offerId].provider) == 0) {
            revert OfferNotFound(offerId);
        }
    }

    /**
     * @notice Ensures SLI thresholds stay within allowed bounds.
     * @param slis SLI thresholds to validate.
     */
    function _ensureSLIsValid(SharedTypes.SLIThresholds memory slis) internal pure {
        if (slis.retrievabilityBps > MAX_BPS) revert InvalidRetrievabilityBps(slis.retrievabilityBps);
        if (slis.indexingPct > 100) revert InvalidIndexingPct(slis.indexingPct);
    }

    /**
     * @notice Ensures offer size and duration bounds are internally consistent.
     * @param terms Offer terms to validate.
     */
    function _ensureOfferTermsValid(SharedTypes.OfferTerms memory terms) internal pure {
        if (terms.maxSizeBytes != 0 && terms.minSizeBytes > terms.maxSizeBytes) {
            revert InvalidOfferSizeBounds(terms.minSizeBytes, terms.maxSizeBytes);
        }
        if (terms.maxDurationEpochs != 0 && terms.minDurationEpochs > terms.maxDurationEpochs) {
            revert InvalidOfferDurationBounds(terms.minDurationEpochs, terms.maxDurationEpochs);
        }
    }

    function _setOfferPayment(uint256 offerId, address token, bool active, uint256 pricePer32GiBPerMonth) internal {
        if (token == address(0)) revert InvalidPaymentToken();

        SPRegistryStorage storage $ = s();
        ISPRegistry.TokenConfig storage config = $._tokenConfig[token];
        if (!config.allowed) revert PaymentTokenNotAllowed(token);
        uint256 minimum = config.minPricePer32GiBPerMonth == 0 ? 1 : config.minPricePer32GiBPerMonth;
        if (active && pricePer32GiBPerMonth < minimum) {
            revert PriceBelowTokenMinimum(token, pricePer32GiBPerMonth, minimum);
        }

        $._offerPayments[offerId][token] =
            RegistryOfferPayment({active: active, pricePer32GiBPerMonth: pricePer32GiBPerMonth});
        $._offerPaymentTokens[offerId].add(token);

        emit OfferPaymentUpdated(offerId, token, active, pricePer32GiBPerMonth);
    }

    /**
     * @notice Selects the best matching active offer for a deal request.
     * @param client Client the manifest assignment is scoped to.
     * @param request Deal request to evaluate.
     * @return best Selected provider offer snapshot, or zeroed fields when no offer matches.
     */
    function _selectProviderForDeal(address client, SharedTypes.DealRequest calldata request)
        internal
        view
        returns (SharedTypes.ProviderDealSelection memory best)
    {
        SPRegistryStorage storage $ = s();
        uint256 length = $._activeOfferIds.length();
        uint256[] memory eligibleOfferIds = new uint256[](length);
        CommonTypes.FilActorId[] memory eligibleProviders = new CommonTypes.FilActorId[](length);
        uint256[] memory eligiblePrices = new uint256[](length);
        uint256 count;
        uint256 cheapest = type(uint256).max;

        for (uint256 i = 0; i < length; i++) {
            (SharedTypes.ProviderDealSelection memory candidate, uint16 reason) =
                _evaluateOffer($._activeOfferIds.at(i), client, request);
            if (reason != OfferMatch.OK) continue;
            eligibleOfferIds[count] = candidate.offerId;
            eligibleProviders[count] = candidate.provider;
            eligiblePrices[count++] = candidate.pricePer32GiBPerMonth;
            if (candidate.pricePer32GiBPerMonth < cheapest) cheapest = candidate.pricePer32GiBPerMonth;
        }
        if (count == 0) return best;

        uint256 bestOfferId = _pickBestOfferId(eligibleOfferIds, eligibleProviders, eligiblePrices, count, cheapest);
        (best,) = _evaluateOffer(bestOfferId, client, request);
    }

    function _pickBestOfferId(
        uint256[] memory eligibleOfferIds,
        CommonTypes.FilActorId[] memory eligibleProviders,
        uint256[] memory eligiblePrices,
        uint256 count,
        uint256 cheapest
    ) internal view returns (uint256 bestOfferId) {
        uint256 maxBandPrice = (cheapest * (MAX_BPS + MATCH_PRICE_BAND_BPS)) / MAX_BPS;
        CommonTypes.FilActorId bestProvider;
        uint256 bestPrice;
        uint256 bestLoad = type(uint256).max;
        for (uint256 i = 0; i < count; i++) {
            uint256 price = eligiblePrices[i];
            if (price > maxBandPrice) continue;
            CommonTypes.FilActorId provider = eligibleProviders[i];
            uint256 offerId = eligibleOfferIds[i];
            uint256 load = _matchLoad(provider);
            if (_isLeastLoaded(bestProvider, bestLoad, bestPrice, bestOfferId, load, price, offerId)) {
                bestProvider = provider;
                bestLoad = load;
                bestPrice = price;
                bestOfferId = offerId;
            }
        }
    }

    /**
     * @notice Compares the current best candidate against a new candidate.
     * @param bestProvider Current best provider.
     * @param bestLoad Match load for the current best selection.
     * @param bestPrice Current best price.
     * @param bestOfferId Current best offer ID.
     * @param load Match load for the new candidate.
     * @param price New candidate price.
     * @param offerId New candidate offer ID.
     * @return True when the new candidate should replace the current best selection.
     */
    function _isLeastLoaded(
        CommonTypes.FilActorId bestProvider,
        uint256 bestLoad,
        uint256 bestPrice,
        uint256 bestOfferId,
        uint256 load,
        uint256 price,
        uint256 offerId
    ) internal pure returns (bool) {
        if (_providerId(bestProvider) == 0) return true;
        if (load != bestLoad) return load < bestLoad;
        if (price != bestPrice) return price < bestPrice;
        return offerId < bestOfferId;
    }

    /**
     * @notice Evaluates a single offer against a deal request.
     * @param offerId Offer ID to evaluate.
     * @param client Client the manifest assignment is scoped to.
     * @param request Deal request to evaluate against the offer.
     * @return selection Offer snapshot returned when the offer is eligible.
     * @return reason Match result code describing eligibility or the first rejection reason.
     */
    function _evaluateOffer(uint256 offerId, address client, SharedTypes.DealRequest calldata request)
        internal
        view
        returns (SharedTypes.ProviderDealSelection memory selection, uint16 reason)
    {
        CommonTypes.FilActorId provider;
        address payee;
        uint256 pricePer32GiBPerMonth;
        (reason, provider, payee, pricePer32GiBPerMonth) = _checkOfferEligibility(offerId, client, request);
        if (reason != OfferMatch.OK) return (selection, reason);

        selection = SharedTypes.ProviderDealSelection({
            provider: provider,
            offerId: offerId,
            paymentToken: request.paymentToken,
            payee: payee,
            pricePer32GiBPerMonth: pricePer32GiBPerMonth,
            promisedSLIs: s()._offerSLIs[offerId],
            reservedBytes: request.requestedSizeBytes
        });
    }

    /**
     * @notice Checks whether an offer is eligible for a deal request.
     * @param offerId Offer ID to evaluate.
     * @param client Client the manifest assignment is scoped to.
     * @param request Deal request to evaluate against the offer.
     * @return reason Match result code; OfferMatch.OK when the offer is eligible.
     * @return provider Offer provider, set when reason is OfferMatch.OK.
     * @return payee Provider payee, set when reason is OfferMatch.OK.
     * @return pricePer32GiBPerMonth Offer price, set when reason is OfferMatch.OK.
     */
    // solhint-disable-next-line function-max-lines
    function _checkOfferEligibility(uint256 offerId, address client, SharedTypes.DealRequest calldata request)
        internal
        view
        returns (uint16 reason, CommonTypes.FilActorId provider, address payee, uint256 pricePer32GiBPerMonth)
    {
        SPRegistryStorage storage $ = s();
        Offer storage offer = $._offers[offerId];
        if (offerId == 0 || _providerId(offer.provider) == 0) {
            return (OfferMatch.OFFER_NOT_FOUND, provider, payee, pricePer32GiBPerMonth);
        }
        if (!offer.active) return (OfferMatch.OFFER_INACTIVE, provider, payee, pricePer32GiBPerMonth);

        Provider storage providerInfo = $._providers[_providerId(offer.provider)];
        if (providerInfo.blocked) return (OfferMatch.PROVIDER_BLOCKED, provider, payee, pricePer32GiBPerMonth);
        if (providerInfo.paused) return (OfferMatch.PROVIDER_PAUSED, provider, payee, pricePer32GiBPerMonth);
        if ($._clientManifestDealWithOrganization[client][request.manifestHash][providerInfo.organization]) {
            return (OfferMatch.MANIFEST_ALREADY_ASSIGNED, provider, payee, pricePer32GiBPerMonth);
        }

        SharedTypes.OfferTerms storage terms = $._offerTerms[offerId];
        if (
            request.requestedSizeBytes < terms.minSizeBytes
                || (terms.maxSizeBytes != 0 && request.requestedSizeBytes > terms.maxSizeBytes)
        ) {
            return (OfferMatch.SIZE_OUT_OF_BOUNDS, provider, payee, pricePer32GiBPerMonth);
        }

        uint64 durationEpochs = uint64(uint256(request.durationDays) * SharedTypes.EPOCHS_IN_DAY);
        if (
            durationEpochs < terms.minDurationEpochs
                || (terms.maxDurationEpochs != 0 && durationEpochs > terms.maxDurationEpochs)
        ) {
            return (OfferMatch.DURATION_OUT_OF_BOUNDS, provider, payee, pricePer32GiBPerMonth);
        }

        if (!_meetsRequirements($._offerSLIs[offerId], request.requiredSLIs)) {
            return (OfferMatch.SLIS_NOT_MET, provider, payee, pricePer32GiBPerMonth);
        }

        ISPRegistry.TokenConfig storage config = $._tokenConfig[request.paymentToken];
        RegistryOfferPayment storage payment = $._offerPayments[offerId][request.paymentToken];
        if (!config.allowed || !payment.active) {
            return (OfferMatch.TOKEN_NOT_ALLOWED, provider, payee, pricePer32GiBPerMonth);
        }
        uint256 minimum = config.minPricePer32GiBPerMonth == 0 ? 1 : config.minPricePer32GiBPerMonth;
        if (payment.pricePer32GiBPerMonth < minimum) {
            return (OfferMatch.PRICE_BELOW_TOKEN_MIN, provider, payee, pricePer32GiBPerMonth);
        }
        if (payment.pricePer32GiBPerMonth > request.maxPricePer32GiBPerMonth) {
            return (OfferMatch.PRICE_ABOVE_CLIENT_MAX, provider, payee, pricePer32GiBPerMonth);
        }

        if (_remainingCapacity(offer.provider) < request.requestedSizeBytes) {
            return (OfferMatch.INSUFFICIENT_CAPACITY, provider, payee, pricePer32GiBPerMonth);
        }

        reason = OfferMatch.OK;
        provider = offer.provider;
        payee = providerInfo.payee;
        pricePer32GiBPerMonth = payment.pricePer32GiBPerMonth;
    }

    /**
     * @notice Reserves pending capacity for a provider.
     * @param provider Provider actor ID whose pending capacity increases.
     * @param sizeBytes Bytes to reserve.
     */
    function _reservePending(CommonTypes.FilActorId provider, uint256 sizeBytes) internal {
        s()._providerCapacity[_providerId(provider)].pendingBytes += sizeBytes;
        emit PendingCapacityReserved(provider, sizeBytes);
    }

    function _reserveSelection(address client, bytes32 manifestHash, SharedTypes.ProviderDealSelection memory selection)
        internal
    {
        _reservePending(selection.provider, selection.reservedBytes);
        SPRegistryStorage storage $ = s();
        uint64 providerId = _providerId(selection.provider);
        $._clientManifestDealWithOrganization[client][manifestHash][$._providers[providerId].organization] = true;
        emit OfferSelected(
            selection.offerId,
            selection.provider,
            selection.paymentToken,
            selection.pricePer32GiBPerMonth,
            selection.reservedBytes
        );
    }

    function _releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, address client, bytes32 manifestHash)
        internal
    {
        _ensureProviderRegistered(provider);

        SPRegistryStorage storage $ = s();
        uint64 providerId = _providerId(provider);
        ProviderCapacity storage c = $._providerCapacity[providerId];
        if (sizeBytes > c.committedBytes) revert ReleaseExceedsCommitted(provider, sizeBytes, c.committedBytes);
        c.committedBytes -= sizeBytes;
        $._clientManifestDealWithOrganization[client][manifestHash][$._providers[providerId].organization] = false;

        emit CapacityReleased(provider, sizeBytes);
    }

    function _releasePendingCapacity(
        CommonTypes.FilActorId provider,
        uint256 sizeBytes,
        address client,
        bytes32 manifestHash
    ) internal {
        _ensureProviderRegistered(provider);

        SPRegistryStorage storage $ = s();
        uint64 providerId = _providerId(provider);
        ProviderCapacity storage c = $._providerCapacity[providerId];
        if (sizeBytes > c.pendingBytes) revert ReleasePendingExceedsPending(provider, sizeBytes, c.pendingBytes);
        c.pendingBytes -= sizeBytes;
        $._clientManifestDealWithOrganization[client][manifestHash][$._providers[providerId].organization] = false;

        emit PendingCapacityReleased(provider, sizeBytes);
    }

    function _remainingCapacity(CommonTypes.FilActorId provider) internal view returns (uint256) {
        ProviderCapacity storage c = s()._providerCapacity[_providerId(provider)];
        uint256 used = c.committedBytes + c.pendingBytes;
        return c.availableBytes > used ? c.availableBytes - used : 0;
    }

    function _matchLoad(CommonTypes.FilActorId provider) internal view returns (uint256) {
        return s()._providerCapacity[_providerId(provider)].pendingBytes;
    }

    /**
     * @notice Checks whether an offer's promised thresholds satisfy a client's required thresholds.
     * @param caps Offer's promised SLI thresholds.
     * @param reqs Client's required SLI thresholds.
     * @return True when every requested dimension is satisfied.
     * @dev A zero threshold means "unset" on both sides. For latency, lower is better, so an unset
     *      offer latency would otherwise compare as the best possible value and satisfy any request;
     *      it is rejected explicitly instead. The other dimensions need no such guard because a zero
     *      promise is already their worst value.
     */
    function _meetsRequirements(SharedTypes.SLIThresholds memory caps, SharedTypes.SLIThresholds calldata reqs)
        internal
        pure
        returns (bool)
    {
        if (reqs.retrievabilityBps != 0 && caps.retrievabilityBps < reqs.retrievabilityBps) return false;
        if (reqs.bandwidthBytesPerSecond != 0 && caps.bandwidthBytesPerSecond < reqs.bandwidthBytesPerSecond) {
            return false;
        }
        if (reqs.latencyMs != 0 && (caps.latencyMs == 0 || caps.latencyMs > reqs.latencyMs)) return false;
        if (reqs.indexingPct != 0 && caps.indexingPct < reqs.indexingPct) return false;
        return true;
    }

    function _pageLength(uint256 total, uint256 offset, uint256 limit) internal pure returns (uint256 length) {
        // solhint-disable-next-line gas-strict-inequalities
        if (offset >= total || limit == 0) {
            return 0;
        }

        uint256 remaining = total - offset;
        return limit < remaining ? limit : remaining;
    }

    // solhint-disable no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}

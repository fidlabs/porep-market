// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {SharedTypes} from "./types/SharedTypes.sol";
import {OfferMatch} from "./types/OfferMatch.sol";
import {MinerUtils} from "./lib/MinerUtils.sol";

/**
 * @title SPRegistry
 * @notice Storage provider registry for provider offers, matching, and capacity management
 */
contract SPRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ISPRegistry {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Role allowed to authorize contract upgrades.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @notice Role allowed to reserve, release, and commit provider capacity.
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");
    /// @notice Role allowed to register providers and manage provider offers.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Maximum number of registered providers.
    uint256 public constant MAX_PROVIDERS = 100;
    /// @notice Maximum active offers per provider.
    uint256 public constant MAX_ACTIVE_OFFERS_PER_PROVIDER = 5;
    /// @notice Price band above the cheapest matching offer within which auto-match balances load, in basis points.
    uint256 public constant MATCH_PRICE_BAND_BPS = 100;
    /// @notice One hundred percent in basis points.
    uint256 public constant MAX_BPS = 10_000;
    /// @notice Filecoin sector size used for per-epoch payment floor checks.
    uint256 public constant SECTOR_SIZE = 32 * 1024 * 1024 * 1024;

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

    struct RegistryTokenConfig {
        bool allowed;
        uint256 minPricePer32GiBPerMonth;
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
        uint256 maxActiveOffersPerProvider;
        EnumerableSet.UintSet _activeOfferIds;
        EnumerableSet.AddressSet _paymentTokens;
        mapping(address => RegistryTokenConfig) _tokenConfig;
        mapping(uint64 => EnumerableSet.UintSet) _offerIdsByProvider;
        mapping(uint64 => EnumerableSet.UintSet) _activeOfferIdsByProvider;
        mapping(uint256 => Offer) _offers;
        mapping(uint256 => SharedTypes.OfferTerms) _offerTerms;
        mapping(uint256 => SharedTypes.SLIThresholds) _offerSLIs;
        mapping(uint256 => mapping(address => RegistryOfferPayment)) _offerPayments;
        mapping(bytes32 manifestHash => mapping(uint64 provider => bool)) _manifestAssignedToProvider;
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
     * @notice Error thrown when admin address is invalid
     * @dev 0x05bb467c
     */
    error InvalidAdminAddress();

    /**
     * @notice Error thrown when PoRepMarket address is invalid
     * @dev 0xc9cc4a06
     */
    error InvalidPoRepMarketAddress();

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

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes SPRegistry roles and default offer-matching configuration.
     * @param _admin Address receiving admin and upgrader roles.
     */
    function initialize(address _admin) public initializer {
        if (_admin == address(0)) revert InvalidAdminAddress();

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        $.maxActiveOffersPerProvider = MAX_ACTIVE_OFFERS_PER_PROVIDER;
    }

    /**
     * @notice Grants market-only capacity and matching access to PoRepMarket.
     * @param _poRepMarket PoRepMarket contract address.
     */
    function initialize2(address _poRepMarket) public reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_poRepMarket == address(0)) revert InvalidPoRepMarketAddress();

        _grantRole(MARKET_ROLE, _poRepMarket);
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

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        $._providerCapacity[CommonTypes.FilActorId.unwrap(provider)].availableBytes = availableBytes;

        emit AvailableSpaceUpdated(provider, availableBytes);
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
        ProviderCapacity storage c = $._providerCapacity[CommonTypes.FilActorId.unwrap(provider)];

        uint256 minRequired = c.committedBytes + c.pendingBytes;
        if (availableBytes < minRequired) {
            revert AvailableBelowCommittedPlusPending(provider, availableBytes, c.committedBytes, c.pendingBytes);
        }
        c.availableBytes = availableBytes;

        emit AvailableSpaceUpdated(provider, availableBytes);
    }

    /// @inheritdoc ISPRegistry
    function getProviders() external view returns (CommonTypes.FilActorId[] memory) {
        return _toFilActorIdArray(_getSPRegistryStorage()._providerIds);
    }

    /// @inheritdoc ISPRegistry
    function getProviderView(CommonTypes.FilActorId provider) external view returns (ProviderView memory view_) {
        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        SPRegistryStorage storage $ = _getSPRegistryStorage();
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
        return _getSPRegistryStorage()._providerIds.contains(uint256(CommonTypes.FilActorId.unwrap(provider)));
    }

    /// @inheritdoc ISPRegistry
    function isAuthorizedForProvider(address caller, CommonTypes.FilActorId provider) external view returns (bool) {
        if (hasRole(DEFAULT_ADMIN_ROLE, caller) || hasRole(OPERATOR_ROLE, caller)) return true;
        return MinerUtils.isControllingAddress(provider, caller);
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
    function setPaymentToken(address token, bool allowed, uint256 minPricePer32GiBPerMonth)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert InvalidPaymentToken();

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        $._tokenConfig[token] =
            RegistryTokenConfig({allowed: allowed, minPricePer32GiBPerMonth: minPricePer32GiBPerMonth});
        if (allowed) {
            $._paymentTokens.add(token);
        } else {
            $._paymentTokens.remove(token);
        }

        emit PaymentTokenUpdated(token, allowed, minPricePer32GiBPerMonth);
    }

    /// @inheritdoc ISPRegistry
    function getPaymentTokenConfig(address token) external view returns (ISPRegistry.TokenConfig memory config) {
        RegistryTokenConfig storage c = _getSPRegistryStorage()._tokenConfig[token];
        config = ISPRegistry.TokenConfig({allowed: c.allowed, minPricePer32GiBPerMonth: c.minPricePer32GiBPerMonth});
    }

    /// @inheritdoc ISPRegistry
    function getPaymentTokens() external view returns (address[] memory tokens) {
        return _getSPRegistryStorage()._paymentTokens.values();
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
        _onlyProviderControllerOrAdmin(provider);
        _ensureOfferTermsValid(terms);
        _ensureSLIsValid(slis);

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint64 providerId = CommonTypes.FilActorId.unwrap(provider);
        // solhint-disable-next-line gas-strict-inequalities
        if ($._activeOfferIdsByProvider[providerId].length() >= $.maxActiveOffersPerProvider) {
            revert TooManyActiveOffers(provider, $.maxActiveOffersPerProvider);
        }

        offerId = ++$.nextOfferId;
        $._offers[offerId] = Offer({provider: provider, active: true});
        $._offerTerms[offerId] = terms;
        $._offerSLIs[offerId] = slis;
        $._offerIdsByProvider[providerId].add(offerId);
        $._activeOfferIdsByProvider[providerId].add(offerId);
        $._activeOfferIds.add(offerId);

        for (uint256 i = 0; i < payments.length; i++) {
            _setOfferPayment(offerId, payments[i].token, payments[i].active, payments[i].pricePer32GiBPerMonth);
        }

        emit OfferCreated(offerId, provider);
    }

    /// @inheritdoc ISPRegistry
    function setOfferActive(uint256 offerId, bool active) external {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        Offer storage offer = $._offers[offerId];
        _ensureOfferExists(offerId);
        _ensureProviderNotBlocked(offer.provider);
        _onlyProviderControllerOrAdmin(offer.provider);

        if (offer.active == active) return;

        uint64 providerId = CommonTypes.FilActorId.unwrap(offer.provider);
        if (active) {
            // solhint-disable-next-line gas-strict-inequalities
            if ($._activeOfferIdsByProvider[providerId].length() >= $.maxActiveOffersPerProvider) {
                revert TooManyActiveOffers(offer.provider, $.maxActiveOffersPerProvider);
            }
            $._activeOfferIdsByProvider[providerId].add(offerId);
            $._activeOfferIds.add(offerId);
        } else {
            $._activeOfferIdsByProvider[providerId].remove(offerId);
            $._activeOfferIds.remove(offerId);
        }

        offer.active = active;
        emit OfferActiveUpdated(offerId, active);
    }

    /// @inheritdoc ISPRegistry
    function setOfferPayment(uint256 offerId, address token, bool active, uint256 pricePer32GiBPerMonth) external {
        _ensureOfferExists(offerId);

        Offer storage offer = _getSPRegistryStorage()._offers[offerId];
        _ensureProviderNotBlocked(offer.provider);
        _onlyProviderControllerOrAdmin(offer.provider);

        _setOfferPayment(offerId, token, active, pricePer32GiBPerMonth);
    }

    /// @inheritdoc ISPRegistry
    function getOfferView(uint256 offerId, address paymentToken) external view returns (OfferView memory view_) {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        Offer storage offer = $._offers[offerId];
        RegistryOfferPayment storage payment = $._offerPayments[offerId][paymentToken];

        view_ = OfferView({
            offerId: offerId,
            provider: offer.provider,
            active: offer.active,
            terms: $._offerTerms[offerId],
            slis: $._offerSLIs[offerId],
            paymentToken: paymentToken,
            paymentActive: payment.active,
            pricePer32GiBPerMonth: payment.pricePer32GiBPerMonth
        });
    }

    /// @inheritdoc ISPRegistry
    function getOffersByProvider(CommonTypes.FilActorId provider) external view returns (uint256[] memory offerIds) {
        return _toUintArray(_getSPRegistryStorage()._offerIdsByProvider[CommonTypes.FilActorId.unwrap(provider)]);
    }

    /// @inheritdoc ISPRegistry
    function previewProviderForDeal(SharedTypes.DealRequest calldata request)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory selection)
    {
        return _selectProviderForDeal(request);
    }

    /// @inheritdoc ISPRegistry
    function isManifestAssignedToProvider(bytes32 manifestHash, CommonTypes.FilActorId provider)
        external
        view
        returns (bool)
    {
        return
            _getSPRegistryStorage()._manifestAssignedToProvider[manifestHash][CommonTypes.FilActorId.unwrap(provider)];
    }

    /// @inheritdoc ISPRegistry
    function reserveProviderForDeal(SharedTypes.DealRequest calldata request)
        external
        onlyRole(MARKET_ROLE)
        returns (SharedTypes.ProviderDealSelection memory selection)
    {
        selection = _selectProviderForDeal(request);
        if (CommonTypes.FilActorId.unwrap(selection.provider) == 0) revert NoOfferMatched();
        _reservePending(selection.provider, selection.reservedBytes);
        _getSPRegistryStorage()
        ._manifestAssignedToProvider[request.manifestHash][CommonTypes.FilActorId.unwrap(selection.provider)] = true;
        emit OfferSelected(
            selection.offerId,
            selection.provider,
            selection.paymentToken,
            selection.pricePer32GiBPerMonth,
            selection.reservedBytes
        );
    }

    /// @inheritdoc ISPRegistry
    function previewOfferForDeal(uint256 offerId, SharedTypes.DealRequest calldata request)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory selection, uint16 reason)
    {
        return _evaluateOffer(offerId, request);
    }

    /// @inheritdoc ISPRegistry
    function reserveOfferForDeal(uint256 offerId, SharedTypes.DealRequest calldata request)
        external
        onlyRole(MARKET_ROLE)
        returns (SharedTypes.ProviderDealSelection memory selection)
    {
        uint16 reason;
        (selection, reason) = _evaluateOffer(offerId, request);
        if (reason != OfferMatch.OK) revert OfferNotEligible(offerId, reason);
        _reservePending(selection.provider, selection.reservedBytes);
        _getSPRegistryStorage()
        ._manifestAssignedToProvider[request.manifestHash][CommonTypes.FilActorId.unwrap(selection.provider)] = true;
        emit OfferSelected(
            selection.offerId,
            selection.provider,
            selection.paymentToken,
            selection.pricePer32GiBPerMonth,
            selection.reservedBytes
        );
    }

    /// @inheritdoc ISPRegistry
    function releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash)
        external
        onlyRole(MARKET_ROLE)
    {
        _releaseCapacity(provider, sizeBytes, manifestHash);
    }

    /// @inheritdoc ISPRegistry
    function releasePendingCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash)
        external
        onlyRole(MARKET_ROLE)
    {
        _releasePendingCapacity(provider, sizeBytes, manifestHash);
    }

    /// @inheritdoc ISPRegistry
    function commitCapacity(CommonTypes.FilActorId provider, uint256 estimatedSizeBytes, uint256 actualSizeBytes)
        external
        onlyRole(MARKET_ROLE)
    {
        _ensureProviderRegistered(provider);

        ProviderCapacity storage c = _getSPRegistryStorage()._providerCapacity[CommonTypes.FilActorId.unwrap(provider)];

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
        if (CommonTypes.FilActorId.unwrap(provider) == 0) revert InvalidProviderActorId();

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        // solhint-disable-next-line gas-strict-inequalities
        if ($._providerIds.length() >= MAX_PROVIDERS) revert MaxProvidersReached(MAX_PROVIDERS);

        uint256 id256 = uint256(CommonTypes.FilActorId.unwrap(provider));
        if (!$._providerIds.add(id256)) revert ProviderAlreadyRegistered(provider);

        uint64 id = CommonTypes.FilActorId.unwrap(provider);
        $._providers[id].organization = organization;
        $._providers[id].payee = payee == address(0) ? organization : payee;

        emit ProviderRegistered(provider, organization);
    }

    function _onlyProviderControllerOrAdmin(CommonTypes.FilActorId provider) internal view {
        if (hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(OPERATOR_ROLE, msg.sender)) return;
        if (!MinerUtils.isControllingAddress(provider, msg.sender)) {
            revert NotProviderControllerOrAdmin(msg.sender, provider);
        }
    }

    function _onlyAdminOrOperator() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAdminOrOperator(msg.sender);
        }
    }

    /**
     * @notice Ensures the provider is registered.
     * @param provider Provider actor ID to check.
     */
    function _ensureProviderRegistered(CommonTypes.FilActorId provider) internal view {
        if (!_getSPRegistryStorage()._providerIds.contains(uint256(CommonTypes.FilActorId.unwrap(provider)))) {
            revert ProviderNotRegistered(provider);
        }
    }

    /**
     * @notice Ensures the provider is not blocked.
     * @param provider Provider actor ID to check.
     */
    function _ensureProviderNotBlocked(CommonTypes.FilActorId provider) internal view {
        if (_getSPRegistryStorage()._providers[CommonTypes.FilActorId.unwrap(provider)].blocked) {
            revert ProviderIsBlocked(provider);
        }
    }

    /**
     * @notice Ensures the offer exists.
     * @param offerId Offer ID to check.
     */
    function _ensureOfferExists(uint256 offerId) internal view {
        if (offerId == 0 || CommonTypes.FilActorId.unwrap(_getSPRegistryStorage()._offers[offerId].provider) == 0) {
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

        SPRegistryStorage storage $ = _getSPRegistryStorage();
        RegistryTokenConfig storage config = $._tokenConfig[token];
        if (!config.allowed) revert PaymentTokenNotAllowed(token);
        uint256 minimum = config.minPricePer32GiBPerMonth == 0 ? 1 : config.minPricePer32GiBPerMonth;
        if (active && pricePer32GiBPerMonth < minimum) {
            revert PriceBelowTokenMinimum(token, pricePer32GiBPerMonth, minimum);
        }

        $._offerPayments[offerId][token] =
            RegistryOfferPayment({active: active, pricePer32GiBPerMonth: pricePer32GiBPerMonth});

        emit OfferPaymentUpdated(offerId, token, active, pricePer32GiBPerMonth);
    }

    /**
     * @notice Selects the best matching active offer for a deal request.
     * @param request Deal request to evaluate.
     * @return best Selected provider offer snapshot, or zeroed fields when no offer matches.
     */
    function _selectProviderForDeal(SharedTypes.DealRequest calldata request)
        internal
        view
        returns (SharedTypes.ProviderDealSelection memory best)
    {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        uint256 length = $._activeOfferIds.length();
        uint256[] memory eligibleOfferIds = new uint256[](length);
        CommonTypes.FilActorId[] memory eligibleProviders = new CommonTypes.FilActorId[](length);
        uint256[] memory eligiblePrices = new uint256[](length);
        uint256 count;
        uint256 cheapest = type(uint256).max;

        for (uint256 i = 0; i < length; i++) {
            (SharedTypes.ProviderDealSelection memory candidate, uint16 reason) =
                _evaluateOffer($._activeOfferIds.at(i), request);
            if (reason != OfferMatch.OK) continue;
            eligibleOfferIds[count] = candidate.offerId;
            eligibleProviders[count] = candidate.provider;
            eligiblePrices[count++] = candidate.pricePer32GiBPerMonth;
            if (candidate.pricePer32GiBPerMonth < cheapest) cheapest = candidate.pricePer32GiBPerMonth;
        }
        if (count == 0) return best;

        uint256 maxBandPrice = (cheapest * (MAX_BPS + MATCH_PRICE_BAND_BPS)) / MAX_BPS;
        CommonTypes.FilActorId bestProvider;
        uint256 bestOfferId;
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
        (best,) = _evaluateOffer(bestOfferId, request);
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
        if (CommonTypes.FilActorId.unwrap(bestProvider) == 0) return true;
        if (load != bestLoad) return load < bestLoad;
        if (price != bestPrice) return price < bestPrice;
        return offerId < bestOfferId;
    }

    /**
     * @notice Evaluates a single offer against a deal request.
     * @param offerId Offer ID to evaluate.
     * @param request Deal request to evaluate against the offer.
     * @return selection Offer snapshot returned when the offer is eligible.
     * @return reason Match result code describing eligibility or the first rejection reason.
     */
    // solhint-disable-next-line function-max-lines
    function _evaluateOffer(uint256 offerId, SharedTypes.DealRequest calldata request)
        internal
        view
        returns (SharedTypes.ProviderDealSelection memory selection, uint16 reason)
    {
        SPRegistryStorage storage $ = _getSPRegistryStorage();
        Offer storage offer = $._offers[offerId];
        if (offerId == 0 || CommonTypes.FilActorId.unwrap(offer.provider) == 0) {
            return (selection, OfferMatch.OFFER_NOT_FOUND);
        }
        if (!offer.active) return (selection, OfferMatch.OFFER_INACTIVE);

        Provider storage providerInfo = $._providers[CommonTypes.FilActorId.unwrap(offer.provider)];
        if (providerInfo.blocked) return (selection, OfferMatch.PROVIDER_BLOCKED);
        if (providerInfo.paused) return (selection, OfferMatch.PROVIDER_PAUSED);
        if ($._manifestAssignedToProvider[request.manifestHash][CommonTypes.FilActorId.unwrap(offer.provider)]) {
            return (selection, OfferMatch.MANIFEST_ALREADY_ASSIGNED);
        }

        SharedTypes.OfferTerms storage terms = $._offerTerms[offerId];
        if (
            request.requestedSizeBytes < terms.minSizeBytes
                || (terms.maxSizeBytes != 0 && request.requestedSizeBytes > terms.maxSizeBytes)
        ) {
            return (selection, OfferMatch.SIZE_OUT_OF_BOUNDS);
        }

        uint64 durationEpochs = uint64(uint256(request.durationDays) * SharedTypes.EPOCHS_IN_DAY);
        if (
            durationEpochs < terms.minDurationEpochs
                || (terms.maxDurationEpochs != 0 && durationEpochs > terms.maxDurationEpochs)
        ) {
            return (selection, OfferMatch.DURATION_OUT_OF_BOUNDS);
        }

        if (!_meetsRequirements($._offerSLIs[offerId], request.requiredSLIs)) {
            return (selection, OfferMatch.SLIS_NOT_MET);
        }

        RegistryTokenConfig storage config = $._tokenConfig[request.paymentToken];
        RegistryOfferPayment storage payment = $._offerPayments[offerId][request.paymentToken];
        if (!config.allowed || !payment.active) return (selection, OfferMatch.TOKEN_NOT_ALLOWED);
        uint256 minimum = config.minPricePer32GiBPerMonth == 0 ? 1 : config.minPricePer32GiBPerMonth;
        if (payment.pricePer32GiBPerMonth < minimum) {
            return (selection, OfferMatch.PRICE_BELOW_TOKEN_MIN);
        }
        if (payment.pricePer32GiBPerMonth > request.maxPricePer32GiBPerMonth) {
            return (selection, OfferMatch.PRICE_ABOVE_CLIENT_MAX);
        }

        if (_remainingCapacity(offer.provider) < request.requestedSizeBytes) {
            return (selection, OfferMatch.INSUFFICIENT_CAPACITY);
        }

        selection = SharedTypes.ProviderDealSelection({
            provider: offer.provider,
            offerId: offerId,
            paymentToken: request.paymentToken,
            payee: providerInfo.payee,
            pricePer32GiBPerMonth: payment.pricePer32GiBPerMonth,
            promisedSLIs: $._offerSLIs[offerId],
            reservedBytes: request.requestedSizeBytes
        });
        reason = OfferMatch.OK;
    }

    /**
     * @notice Reserves pending capacity for a provider.
     * @param provider Provider actor ID whose pending capacity increases.
     * @param sizeBytes Bytes to reserve.
     */
    function _reservePending(CommonTypes.FilActorId provider, uint256 sizeBytes) internal {
        _getSPRegistryStorage()._providerCapacity[CommonTypes.FilActorId.unwrap(provider)].pendingBytes += sizeBytes;
        emit PendingCapacityReserved(provider, sizeBytes);
    }

    function _releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash) internal {
        _ensureProviderRegistered(provider);

        ProviderCapacity storage c = _getSPRegistryStorage()._providerCapacity[CommonTypes.FilActorId.unwrap(provider)];
        if (sizeBytes > c.committedBytes) revert ReleaseExceedsCommitted(provider, sizeBytes, c.committedBytes);
        c.committedBytes -= sizeBytes;
        _getSPRegistryStorage()._manifestAssignedToProvider[manifestHash][CommonTypes.FilActorId.unwrap(provider)] =
        false;

        emit CapacityReleased(provider, sizeBytes);
    }

    function _releasePendingCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash)
        internal
    {
        _ensureProviderRegistered(provider);

        ProviderCapacity storage c = _getSPRegistryStorage()._providerCapacity[CommonTypes.FilActorId.unwrap(provider)];
        if (sizeBytes > c.pendingBytes) revert ReleasePendingExceedsPending(provider, sizeBytes, c.pendingBytes);
        c.pendingBytes -= sizeBytes;
        _getSPRegistryStorage()._manifestAssignedToProvider[manifestHash][CommonTypes.FilActorId.unwrap(provider)] =
        false;

        emit PendingCapacityReleased(provider, sizeBytes);
    }

    function _remainingCapacity(CommonTypes.FilActorId provider) internal view returns (uint256) {
        ProviderCapacity storage c = _getSPRegistryStorage()._providerCapacity[CommonTypes.FilActorId.unwrap(provider)];
        uint256 used = c.committedBytes + c.pendingBytes;
        return c.availableBytes > used ? c.availableBytes - used : 0;
    }

    function _matchLoad(CommonTypes.FilActorId provider) internal view returns (uint256) {
        return _getSPRegistryStorage()._providerCapacity[CommonTypes.FilActorId.unwrap(provider)].pendingBytes;
    }

    function _meetsRequirements(SharedTypes.SLIThresholds memory caps, SharedTypes.SLIThresholds calldata reqs)
        internal
        pure
        returns (bool)
    {
        if (reqs.retrievabilityBps != 0 && caps.retrievabilityBps < reqs.retrievabilityBps) return false;
        if (reqs.bandwidthBytesPerSecond != 0 && caps.bandwidthBytesPerSecond < reqs.bandwidthBytesPerSecond) {
            return false;
        }
        if (reqs.latencyMs != 0 && caps.latencyMs > reqs.latencyMs) return false;
        if (reqs.indexingPct != 0 && caps.indexingPct < reqs.indexingPct) return false;
        return true;
    }

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

    function _toUintArray(EnumerableSet.UintSet storage set) internal view returns (uint256[] memory) {
        uint256 length = set.length();
        uint256[] memory result = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = set.at(i);
        }
        return result;
    }

    // solhint-disable no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

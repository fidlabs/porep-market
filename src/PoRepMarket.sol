// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {IValidatorFactory} from "./interfaces/IValidatorFactory.sol";
import {IOperator} from "./interfaces/IOperator.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {IStorageEvidenceAdapter} from "./interfaces/IStorageEvidenceAdapter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SharedTypes} from "./types/SharedTypes.sol";
import {DealState} from "./types/DealState.sol";
import {DealType} from "./types/DealType.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {RailStatus} from "./types/RailStatus.sol";
import {EvidenceResult} from "./types/EvidenceResult.sol";
import {SettlementReason} from "./types/SettlementReason.sol";
import {SettlementResult} from "./types/SettlementResult.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISLIScorer} from "./interfaces/ISLIScorer.sol";
import {AccessControlledUpgradeable} from "./abstracts/AccessControlledUpgradeable.sol";
import {Roles} from "./lib/Roles.sol";

/**
 * @title PoRepMarket contract
 * @dev PoRepMarket contract is a contract that allows users to create and manage PoRep deals
 * @notice PoRepMarket contract
 */
contract PoRepMarket is AccessControlledUpgradeable, UUPSUpgradeable, IPoRepMarket {
    using EnumerableSet for EnumerableSet.UintSet;

    /**
     * @notice Number of epochs in one month
     * @dev 30 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 86_400 epochs
     */
    uint256 public constant EPOCHS_IN_MONTH = 86_400;

    /**
     * @notice Maximum settlement lead allowed beyond the latest verified evidence refresh
     * @dev 8 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 23_040 epochs
     */
    uint256 private constant EVIDENCE_REFRESH_GRACE_EPOCHS = 23_040;

    /**
     * @notice Number of epochs in one year
     * @dev 365 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 1_051_200 epochs
     */
    uint256 private constant EPOCHS_IN_YEAR = 1_051_200;

    /**
     * @notice Size of a single Filecoin sector in bytes (32 GiB)
     */
    uint256 public constant SECTOR_SIZE = 32 * 1024 * 1024 * 1024;

    /**
     * @notice The maximum value allowed for deal activation padding, in basis points.
     * @dev 2000 basis points equals 20%.
     */
    uint256 private constant MAX_DEAL_ACTIVATION_PADDING = 2_000;

    /**
     * @notice Minimum Filecoin deal duration equals 180 days (6 months)
     */
    uint32 public constant MIN_DEAL_DURATION_DAYS = 180;

    /**
     * @notice Maximum deal duration in days. See PoRepTypes.MAX_DEAL_DURATION_DAYS.
     * @dev Any provider limit above this is unreachable: PoRepMarket rejects deals with durationDays > 1278.
     */
    uint32 public constant MAX_DEAL_DURATION_DAYS = PoRepTypes.MAX_DEAL_DURATION_DAYS;

    /// @custom:storage-location erc7201:porepmarket.storage.PoRepMarket
    struct PoRepMarketStorage {
        mapping(uint256 dealId => PoRepTypes.Deal) _deals;
        mapping(uint256 dealId => SharedTypes.DealData) _dealData;
        mapping(uint256 dealId => PoRepTypes.DealTerms) _dealTerms;
        mapping(uint256 dealId => PoRepTypes.DealService) _dealService;
        mapping(uint256 dealId => PoRepTypes.DealCapacity) _dealCapacity;
        mapping(uint256 dealId => PoRepTypes.DealPayment) _dealPayments;
        mapping(uint256 dealId => SharedTypes.SLIThresholds) _dealSLIs;
        mapping(uint256 dealId => address organization) _dealOrganization;
        mapping(uint8 state => mapping(address organization => EnumerableSet.UintSet dealIds))
            _dealIdsByStateByOrganization;
        mapping(uint8 state => EnumerableSet.UintSet dealIds) _dealIdsByState;
        mapping(address client => EnumerableSet.UintSet dealIds) _dealIdsByClient;
        mapping(CommonTypes.FilActorId provider => EnumerableSet.UintSet dealIds) _dealIdsByProvider;
        ISPRegistry _SPRegistryContract;
        IValidatorFactory _validatorFactoryContract;
        IStorageEvidenceAdapter _globalEvidenceAdapter;
        ISLIScorer _SLIScorer;
        uint256 _dealIdCounter;
        uint256 _dealActivationPadding;
        uint256 _dealExpiration;
    }
    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.PoRepMarket")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant POREP_MARKET_STORAGE_LOCATION =
        0x0abde292d09529f8839f1c315101bb9805017b92f1e5d27b754124ac2f3da000;

    // solhint-disable-next-line use-natspec
    function s() private pure returns (PoRepMarketStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := POREP_MARKET_STORAGE_LOCATION
        }
    }

    /**
     * @notice DealCreated event
     * @param dealId The id of the deal
     * @param client The address of the client
     * @param provider The address of the provider
     * @param requirements The SLI thresholds for the deal
     * @param manifestHash The manifest hash for the deal
     * @param manifestLocation The location of the manifest for the deal
     * @param totalDealSize The total size of the deal in bytes
     * @param proposedAtBlock The block number when the deal was proposed
     */
    event DealCreated(
        uint256 indexed dealId,
        address indexed client,
        CommonTypes.FilActorId indexed provider,
        SharedTypes.SLIThresholds requirements,
        bytes32 manifestHash,
        string manifestLocation,
        uint256 totalDealSize,
        uint256 proposedAtBlock
    );

    /**
     * @notice DealAccepted event
     * @param dealId The id of the deal
     * @param owner The address of the owner
     * @param provider The address of the provider
     */
    event DealAccepted(uint256 indexed dealId, address indexed owner, CommonTypes.FilActorId indexed provider);

    /**
     * @notice ValidatorUpdated event
     * @dev ValidatorUpdated event is emitted when a validator is updated
     * @param dealId The id of the deal
     * @param validator The address of the validator
     */
    event ValidatorUpdated(uint256 indexed dealId, address indexed validator);

    /**
     * @notice RailIdUpdated event
     * @dev RailIdUpdated event is emitted when a rail id is updated
     * @param dealId The id of the deal
     * @param railId The id of the rail
     */
    event RailIdUpdated(uint256 indexed dealId, uint256 indexed railId);

    /**
     * @notice DealFinalized event
     * @param dealId The id of the deal
     * @param validator The address of the validator
     */
    event DealFinalized(uint256 indexed dealId, address indexed validator);

    /**
     * @notice DealTerminated event
     * @dev DealTerminated event is emitted when a deal is terminated
     * @param dealId The id of the deal
     * @param endEpoch The Filecoin epoch at which the deal was terminated
     */
    event DealTerminated(uint256 indexed dealId, CommonTypes.ChainEpoch indexed endEpoch);

    /**
     * @notice DealRejected event
     * @param dealId The id of the deal
     * @param rejector The address of the rejector
     */
    event DealRejected(uint256 indexed dealId, address indexed rejector);

    // solhint-disable gas-indexed-events
    /**
     * @notice ManifestUpdated event
     * @dev Emitted when the manifest, piece-set commitment, and reserved size are replaced
     * @param dealId The id of the deal
     * @param oldManifestLocation The old manifest location
     * @param newManifestLocation The new manifest location
     * @param oldRequestedSizeBytes The old requested size in bytes
     * @param newRequestedSizeBytes The new requested size in bytes
     * @param oldManifestHash The old piece-set commitment
     * @param newManifestHash The new piece-set commitment
     */
    event ManifestUpdated(
        uint256 indexed dealId,
        string oldManifestLocation,
        string newManifestLocation,
        uint256 oldRequestedSizeBytes,
        uint256 newRequestedSizeBytes,
        bytes32 oldManifestHash,
        bytes32 newManifestHash
    );

    // solhint-enable gas-indexed-events

    /**
     * @notice GlobalEvidenceAdapterUpdated event
     * @dev Emitted when the global evidence adapter is updated
     * @param evidenceAdapter The address of the global evidence adapter
     */
    event GlobalEvidenceAdapterUpdated(address indexed evidenceAdapter);

    /**
     * @notice DealActivationPaddingUpdated event
     * @dev DealActivationPaddingUpdated event is emitted when the deal activation padding is updated
     * @param oldPadding old padding for deal activation
     * @param newPadding new padding for deal activation
     */
    event DealActivationPaddingUpdated(uint256 indexed oldPadding, uint256 indexed newPadding);

    /**
     * @notice PaymentActivated event
     * @dev Emitted when payment is activated for a deal
     * @param dealId The id of the deal
     * @param railMaxRatePerEpoch The maximum payment rate per epoch
     * @param serviceStartEpoch The epoch at which service starts
     * @param serviceEndEpoch The epoch at which service ends
     */
    event PaymentActivated(
        uint256 indexed dealId,
        uint256 indexed railMaxRatePerEpoch,
        CommonTypes.ChainEpoch serviceStartEpoch,
        CommonTypes.ChainEpoch serviceEndEpoch
    );

    /**
     * @notice Emitted when the minimum time between settlements is updated
     * @param dealId The id of the deal
     * @param minTimeBetweenSettlementsInEpochs The new minimum time between settlements in epochs
     */
    event MinEpochsBetweenSettlementsUpdated(uint256 indexed dealId, uint256 indexed minTimeBetweenSettlementsInEpochs);

    /**
     * @notice Error thrown when caller is not the registered validator for the deal
     * @dev 0x64544c54
     */
    error NotTheRegisteredValidator(uint256 dealId, address validator);

    /**
     * @notice Error thrown when caller is not the validator for the deal
     * @dev 0xbfbc5a6b
     */
    error NotTheDealValidator(uint256 dealId, address validator);

    /**
     * @notice Error thrown when caller is not the controlling address for the provider
     * @dev 0xf91c5b99
     */
    error NotTheControllingAddress(uint256 dealId, address msgSender, CommonTypes.FilActorId provider);

    /**
     * @notice Error thrown when a deal is not in the expected state for an action
     * @dev 0x023e4e7c
     */
    error DealNotInExpectedState(uint256 dealId, uint8 currentState, uint8 expectedState);

    /**
     * @notice Error thrown when caller is not the validator for the deal
     * @dev 0xd325131b
     */
    error CallerIsNotValidator(uint256 dealId, address caller);

    /**
     * @notice Error thrown when a deal has no validator assigned
     */
    error ValidatorNotSet(uint256 dealId);

    /**
     * @notice Error thrown when a deal does not exist for a given id
     * @dev 0xa72c631d
     */
    error DealDoesNotExist();

    /**
     * @notice Error thrown when trying to set a validator that is already set for the deal
     * @dev 0xfb35e366
     */
    error ValidatorAlreadySet(uint256 dealId);

    /**
     * @notice Error thrown when retrievabilityBps in requirements is greater than 10_000
     * @dev 0x26f456b9
     */
    error InvalidRetrievabilityBps(uint16 value);

    /**
     * @notice Error thrown when indexingPct in requirements is greater than 100
     * @dev 0xad23dabc
     */
    error InvalidIndexingPct(uint8 value);

    /**
     * @notice Error thrown when rail id is invalid
     * @dev 0x9b721aad
     */
    error InvalidRailId();

    /**
     * @notice Error thrown when trying to set a rail id that is already set for the deal
     * @dev 0x23c224b6
     */
    error RailIdAlreadySet();

    /**
     * @notice Error thrown when empty manifest location is provided
     * @dev 0x323de5da
     */
    error EmptyManifestLocation();

    /**
     * @notice Error thrown when a deal request has no manifest hash.
     * @dev 0x03d0cf2a
     */
    error InvalidManifestHash();

    /**
     * @notice Error thrown when a deal request uses the NONE deal type.
     */
    error InvalidDealType();

    /**
     * @notice Error thrown when manifest location is too long
     * @dev 0xa76fb58b
     */
    error TooLongManifestLocation();

    /**
     * @notice Error thrown when trying to set an invalid evidence adapter address
     * @dev 0x39ee49ba
     */
    error InvalidEvidenceAdapterAddress();

    /**
     * @notice Error indicating that the SLI scorer address is invalid
     * @dev 0x91d3d465
     */
    error InvalidSLIScorerAddress();

    /**
     * @notice Error thrown when trying to propose a deal for an invalid client address
     * @dev 0x4d9c0a3f
     */
    error InvalidClientAddress();

    /**
     * @notice Error indicating that a deal has not started its service window
     * @dev 0xf73df7ce
     */
    error DealServiceNotStarted(uint256 dealId);

    /**
     * @notice Error indicating that the requested settlement window is too short
     * @param requestedToEpoch The requested settlement end epoch
     * @param earliestSettlementEpoch The earliest epoch at which settlement may end
     * @dev 0xf5342533
     */
    error SettlementTooEarly(uint256 requestedToEpoch, uint256 earliestSettlementEpoch);

    /**
     * @notice Error indicating that the deal evidence is too stale for settlement
     * @dev 0x5e885a2d
     */
    error EvidenceTooStale();

    /**
     * @notice Error indicating that the minimum time between settlements is invalid
     * @dev 0xf90f5b8f
     */
    error InvalidMinEpochsBetweenSettlements();

    /**
     * @notice Error indicating that the maximum time between settlements is exceeded
     * @dev 0xb0c81e57
     */
    error MinEpochsBetweenSettlementsExceeded();

    /**
     * @notice Error thrown when deal duration in terms is invalid
     * @dev 0xab1a0367
     */
    error InvalidDealDuration();

    /**
     * @notice Error thrown when organization address provided is invalid
     * @dev 0x98fd3e14
     */
    error InvalidOrganizationAddress();

    /**
     * @notice Error thrown when deal size is zero
     * @dev 0xdbe015a7
     */
    error InvalidDealSize();

    /**
     * @notice Error thrown when the manifest is updated after evidence has been submitted
     * @dev 0x6976a1e6
     */
    error ManifestUpdateNotAllowedAfterEvidence();

    /**
     * @notice Error thrown when a deal is not in a state that allows it to be rejected
     * @param dealId The id of the deal
     * @dev 0x507b3029
     */
    error DealNotRejectable(uint256 dealId);

    /**
     * @notice Error indicating that the deal price would result in zero per-epoch payment
     * @dev 0x1fbc910d
     * @param totalPerMonth pricePerSectorPerMonth * estimated sector count
     * @param epochsInMonth the divisor that would produce zero
     */
    error InvalidDealPricePerSectorPerMonth(uint256 totalPerMonth, uint256 epochsInMonth);

    /**
     * @notice Error indicating that a deal is not ready to be finalized
     * @param serviceEndEpoch The epoch at which the deal service ends
     * @param currentEpoch The current block epoch
     */
    error ServiceNotEnded(uint256 serviceEndEpoch, uint256 currentEpoch);

    /**
     * @notice Error indicating that a deal can no longer be terminated early because its service has ended
     * @param serviceEndEpoch The epoch at which the deal service ended
     * @param currentEpoch The current block epoch
     * @dev 0x284d2b90
     */
    error ServiceAlreadyEnded(int64 serviceEndEpoch, int64 currentEpoch);

    /**
     * @notice Error thrown when there are no billable 32 GiB units for a deal
     * @dev 0x418600bd
     */
    error InvalidBilled32GiBUnits();

    /**
     * @notice Error thrown when the calculated amount per epoch is zero
     * @dev 0xdd484e70
     */
    error InvalidZeroAmount();

    /**
     * @notice Error thrown when trying to activate a payment rail that is not prepared
     * @param railStatus Current rail status reported by the validator
     */
    error InvalidRailState(uint8 railStatus);

    /**
     * @notice Error thrown when trying to set the padding value higher than maximum
     * @dev 0x6e8e586a
     */
    error DealActivationPaddingTooHigh(uint256 padding, uint256 maxPadding);

    /**
     * @notice Error thrown when a deal's submitted evidence has not expired
     * @dev 0x597bec1a
     */
    error EvidenceNotExpired(uint256 dealId);

    /**
     * @notice Error thrown when an unsupported terminal deal state is requested
     * @dev 0x73a2ca71
     */
    error InvalidTerminationState(uint8 state);

    /**
     * @notice Constructor
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @param _accessManager The protocol AccessManager address
     * @param _validatorFactory The address of the validator registry
     * @param _spRegistry The address of the SP registry
     * @param _globalEvidenceAdapter The address of the default evidence adapter
     * @param _SLIScorer The address of the SLI scorer
     */
    function initialize(
        address _accessManager,
        address _validatorFactory,
        address _spRegistry,
        address _globalEvidenceAdapter,
        address _SLIScorer
    ) external initializer {
        if (_globalEvidenceAdapter == address(0)) {
            revert InvalidEvidenceAdapterAddress();
        }
        if (_SLIScorer == address(0)) revert InvalidSLIScorerAddress();

        __AccessControlled_init(_accessManager);

        PoRepMarketStorage storage $ = s();
        $._validatorFactoryContract = IValidatorFactory(_validatorFactory);
        $._SPRegistryContract = ISPRegistry(_spRegistry);
        $._globalEvidenceAdapter = IStorageEvidenceAdapter(_globalEvidenceAdapter);
        $._SLIScorer = ISLIScorer(_SLIScorer);
        $._dealActivationPadding = 1_000; // 10% default padding

        emit GlobalEvidenceAdapterUpdated(_globalEvidenceAdapter);
    }

    /// @inheritdoc IPoRepMarket
    function setGlobalEvidenceAdapter(address _globalEvidenceAdapter)
        public
        override
        onlyRole(Roles.DEFAULT_ADMIN_ROLE)
    {
        if (_globalEvidenceAdapter == address(0)) {
            revert InvalidEvidenceAdapterAddress();
        }
        PoRepMarketStorage storage $ = s();
        $._globalEvidenceAdapter = IStorageEvidenceAdapter(_globalEvidenceAdapter);
        emit GlobalEvidenceAdapterUpdated(_globalEvidenceAdapter);
    }

    /**
     * @notice Proposes a deal
     * @param request The client deal request
     */
    function proposeDeal(SharedTypes.DealRequest calldata request) external override {
        PoRepMarketStorage storage $ = s();
        _ensureValidProposalRequest(request);
        SharedTypes.ProviderDealSelection memory selection =
            $._SPRegistryContract.reserveProviderForDeal(msg.sender, request);

        _createDeal(request, selection, $, msg.sender);
    }

    /**
     * @notice Proposes a deal against a specific provider offer
     * @dev Only admins can bypass automatic matching and reserve a specific offer
     * @param offerId The provider offer to reserve for the deal
     * @param request The client deal request
     * @param client The address of the client for which the deal is proposed
     */
    function proposeDealWithSpecificOffer(uint256 offerId, SharedTypes.DealRequest calldata request, address client)
        external
        override
        onlyRole(Roles.DEFAULT_ADMIN_ROLE)
    {
        if (client == address(0)) revert InvalidClientAddress();
        PoRepMarketStorage storage $ = s();
        _ensureValidProposalRequest(request);
        SharedTypes.ProviderDealSelection memory reservedProvider =
            $._SPRegistryContract.reserveOfferForDeal(offerId, client, request);

        _createDeal(request, reservedProvider, $, client);
    }

    /**
     * @notice Ensures a deal proposal request is valid
     * @param request The client deal request
     */
    function _ensureValidProposalRequest(SharedTypes.DealRequest calldata request) internal pure {
        _ensureCorrectManifestLocation(request.manifestLocation);
        _ensureCorrectRequirements(request.requiredSLIs);
        if (request.manifestHash == bytes32(0)) revert InvalidManifestHash();
        if (request.dealType == DealType.NONE) revert InvalidDealType();

        _ensureCorrectTerms(request);
    }

    /**
     * @notice Stores a new accepted deal from an already reserved provider selection
     * @param request The client deal request
     * @param selection The reserved provider offer selection
     * @param marketStorage PoRepMarket storage pointer
     * @param client The address of the client for which the deal is proposed
     */
    // solhint-disable-next-line function-max-lines
    function _createDeal(
        SharedTypes.DealRequest calldata request,
        SharedTypes.ProviderDealSelection memory selection,
        PoRepMarketStorage storage marketStorage,
        address client
    ) internal {
        CommonTypes.FilActorId provider = selection.provider;

        uint256 dealId = ++marketStorage._dealIdCounter;
        uint8 initialState = DealState.ACCEPTED;
        {
            IStorageEvidenceAdapter evidenceAdapter = marketStorage._globalEvidenceAdapter;
            if (address(evidenceAdapter) == address(0)) {
                revert InvalidEvidenceAdapterAddress();
            }
            int64 proposedAtEpoch = int64(uint64(block.number));

            marketStorage._deals[dealId] = PoRepTypes.Deal({
                dealId: dealId,
                client: client,
                provider: provider,
                offerId: selection.offerId,
                state: initialState,
                evidenceAdapter: address(evidenceAdapter),
                validator: address(0),
                railId: 0,
                proposedAtEpoch: CommonTypes.ChainEpoch.wrap(proposedAtEpoch),
                dealType: request.dealType
            });
        }
        marketStorage._dealSLIs[dealId] = selection.promisedSLIs;
        {
            uint64 durationEpochs = uint64(uint256(request.durationDays) * (EPOCHS_IN_MONTH / 30));
            marketStorage._dealTerms[dealId] =
                PoRepTypes.DealTerms({requestedSizeBytes: request.requestedSizeBytes, durationEpochs: durationEpochs});
        }
        marketStorage._dealService[dealId] = PoRepTypes.DealService({
            serviceStartEpoch: CommonTypes.ChainEpoch.wrap(0),
            serviceEndEpoch: CommonTypes.ChainEpoch.wrap(0),
            earlyTerminationEpoch: CommonTypes.ChainEpoch.wrap(0),
            minTimeBetweenSettlementsInEpochs: EPOCHS_IN_MONTH,
            lastSettledEpoch: CommonTypes.ChainEpoch.wrap(0)
        });
        marketStorage._dealCapacity[dealId] =
            PoRepTypes.DealCapacity({reservedBytes: selection.reservedBytes, committedBytes: 0});
        marketStorage._dealPayments[dealId] = PoRepTypes.DealPayment({
            paymentToken: selection.paymentToken,
            payee: selection.payee,
            pricePer32GiBPerMonth: selection.pricePer32GiBPerMonth,
            billed32GiBUnits: 0,
            railMaxRatePerEpoch: 0
        });
        marketStorage._dealData[dealId] =
            SharedTypes.DealData({manifestHash: request.manifestHash, manifestLocation: request.manifestLocation});
        emit DealCreated(
            dealId,
            client,
            provider,
            request.requiredSLIs,
            request.manifestHash,
            request.manifestLocation,
            request.requestedSizeBytes,
            block.number
        );
        address organization = marketStorage._SPRegistryContract.getProviderView(provider).organization;
        marketStorage._dealOrganization[dealId] = organization;
        marketStorage._dealIdsByStateByOrganization[initialState][organization].add(dealId);
        marketStorage._dealIdsByClient[client].add(dealId);
        marketStorage._dealIdsByProvider[provider].add(dealId);
        marketStorage._dealIdsByState[initialState].add(dealId);
        emit DealAccepted(dealId, client, provider);
    }

    // solhint-enable function-max-lines

    /// @inheritdoc IPoRepMarket
    function previewProviderForDeal(address client, SharedTypes.DealRequest calldata request)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory selection)
    {
        _ensureValidProposalRequest(request);
        return s()._SPRegistryContract.previewProviderForDeal(client, request);
    }

    /**
     * @notice Updates the validator for a deal
     * @param dealId The id of the deal
     */
    function updateValidator(uint256 dealId) external override {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, DealState.ACCEPTED);

        if (deal.validator != address(0)) {
            revert ValidatorAlreadySet(dealId);
        }

        if (!$._validatorFactoryContract.isValidatorContract(msg.sender)) {
            revert NotTheRegisteredValidator(dealId, msg.sender);
        }

        deal.validator = msg.sender;
        emit ValidatorUpdated(dealId, msg.sender);
    }

    /**
     * @notice Updates the rail id for a deal
     * @dev Updates the rail id for a deal
     * @param dealId The id of the deal
     * @param railId The id of the rail
     */
    function updateRailId(uint256 dealId, uint256 railId) external override {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, DealState.ACCEPTED);

        if (deal.railId != 0) {
            revert RailIdAlreadySet();
        }

        if (railId == 0) {
            revert InvalidRailId();
        }

        if (deal.validator != msg.sender) {
            revert NotTheDealValidator(dealId, msg.sender);
        }

        deal.railId = railId;
        emit RailIdUpdated(dealId, railId);
    }

    /**
     * @notice Gets a deal
     * @param dealId The id of the deal
     * @return deal The deal
     */
    function getDeal(uint256 dealId) external view override returns (PoRepTypes.Deal memory deal) {
        PoRepMarketStorage storage $ = s();
        return $._deals[dealId];
    }

    /**
     * @notice Gets the data fields for a deal
     * @param dealId The id of the deal
     * @return dealData The deal data
     */
    function getDealData(uint256 dealId) external view override returns (SharedTypes.DealData memory dealData) {
        PoRepMarketStorage storage $ = s();
        return $._dealData[dealId];
    }

    /**
     * @notice Gets the frozen size and duration terms for a deal
     * @param dealId The id of the deal
     * @return terms The deal terms
     */
    function getDealTerms(uint256 dealId) external view override returns (PoRepTypes.DealTerms memory terms) {
        PoRepMarketStorage storage $ = s();
        return $._dealTerms[dealId];
    }

    /**
     * @notice Gets the service window for a deal
     * @param dealId The id of the deal
     * @return service The deal service window
     */
    function getDealService(uint256 dealId) external view override returns (PoRepTypes.DealService memory service) {
        PoRepMarketStorage storage $ = s();
        return $._dealService[dealId];
    }

    /**
     * @notice Gets the reserved and committed capacity for a deal
     * @param dealId The id of the deal
     * @return capacity The deal capacity
     */
    function getDealCapacity(uint256 dealId) external view override returns (PoRepTypes.DealCapacity memory capacity) {
        PoRepMarketStorage storage $ = s();
        return $._dealCapacity[dealId];
    }

    /**
     * @notice Gets payment terms and rail accounting for a deal
     * @param dealId The id of the deal
     * @return payment The deal payment data
     */
    function getDealPayment(uint256 dealId) external view override returns (PoRepTypes.DealPayment memory payment) {
        PoRepMarketStorage storage $ = s();
        return $._dealPayments[dealId];
    }

    /**
     * @notice Gets SLI thresholds for a deal
     * @param dealId The id of the deal
     * @return slis The deal SLI thresholds
     */
    function getDealSLIs(uint256 dealId) external view override returns (SharedTypes.SLIThresholds memory slis) {
        PoRepMarketStorage storage $ = s();
        return $._dealSLIs[dealId];
    }

    /// @inheritdoc IPoRepMarket
    function getDealCount() external view override returns (uint256 count) {
        count = s()._dealIdCounter;
    }

    /// @inheritdoc IPoRepMarket
    function getDealIds(uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint256[] memory dealIds, uint256 total)
    {
        total = s()._dealIdCounter;
        uint256 length = _pageLength(total, offset, limit);
        dealIds = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            dealIds[i] = offset + i + 1;
        }
    }

    /// @inheritdoc IPoRepMarket
    function getDealIdsByState(uint8 state, uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint256[] memory dealIds, uint256 total)
    {
        EnumerableSet.UintSet storage ids = s()._dealIdsByState[state];
        total = ids.length();
        uint256 length = _pageLength(total, offset, limit);
        dealIds = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            dealIds[i] = ids.at(offset + i);
        }
    }

    /// @inheritdoc IPoRepMarket
    function getDealOrganization(uint256 dealId) external view override returns (address organization) {
        organization = s()._dealOrganization[dealId];
    }

    /**
     * @notice Finalizes an active deal after service has finished
     * @param dealId The id of the deal
     */
    function finalizeDeal(uint256 dealId) external override {
        _ensurePoRepServiceOrAdmin();
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, DealState.ACTIVE);

        if (deal.validator == address(0)) {
            revert ValidatorNotSet(dealId);
        }

        PoRepTypes.DealService memory service = $._dealService[dealId];
        uint256 serviceEndEpoch = uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch)));
        bool serviceEnded = serviceEndEpoch < block.number;
        if (!serviceEnded) {
            revert ServiceNotEnded(serviceEndEpoch, block.number);
        }

        IOperator(deal.validator).finalizeDeal();
        _changeDealState(dealId, DealState.FINALIZED);
        $._SPRegistryContract
            .releaseCapacity(
                deal.provider, $._dealCapacity[dealId].committedBytes, deal.client, $._dealData[dealId].manifestHash
            );
        emit DealFinalized(dealId, deal.validator);
    }

    /**
     * @notice Starts a prepared payment for a deal
     * @dev Validates rail id and rail status, computes per-epoch payment rate,
     *      sets up service start/end epochs, informs the operator to modify
     *      the rail payment and emits PaymentActivated.
     * @param marketStorage Storage pointer to PoRepMarket storage
     * @param dealId The id of the deal to start payment for
     * @param deal The deal struct associated with dealId
     */
    function _startPreparedPayment(
        PoRepMarketStorage storage marketStorage,
        uint256 dealId,
        PoRepTypes.Deal storage deal
    ) internal {
        if (deal.railId == 0) {
            revert InvalidRailId();
        }

        uint8 railStatus = IValidator(deal.validator).getRailStatus();
        if (railStatus != RailStatus.PREPARED) {
            revert InvalidRailState(railStatus);
        }

        PoRepTypes.DealPayment storage payment = marketStorage._dealPayments[dealId];
        uint256 railMaxRatePerEpoch = _calculateAmountPerEpoch(payment);
        payment.railMaxRatePerEpoch = railMaxRatePerEpoch;

        PoRepTypes.DealService storage service = marketStorage._dealService[dealId];
        int64 serviceStartEpoch = int64(uint64(block.number));
        service.serviceStartEpoch = CommonTypes.ChainEpoch.wrap(serviceStartEpoch);
        service.serviceEndEpoch = CommonTypes.ChainEpoch
            .wrap(serviceStartEpoch + int64(uint64(marketStorage._dealTerms[dealId].durationEpochs)));
        IOperator(deal.validator).modifyRailPayment(railMaxRatePerEpoch);
        emit PaymentActivated(dealId, railMaxRatePerEpoch, service.serviceStartEpoch, service.serviceEndEpoch);
    }

    /**
     * @notice Terminates a deal with the requested terminal state
     * @param dealId The id of the deal
     * @param state The terminal state to assign to the deal
     */
    function terminateDeal(uint256 dealId, uint8 state) external override {
        _ensurePoRepServiceOrAdmin();
        PoRepTypes.Deal storage deal = s()._deals[dealId];
        _ensureDealExists(deal);
        if (deal.validator == address(0)) {
            revert ValidatorNotSet(dealId);
        }
        if (state == DealState.EXPIRED) {
            _ensureDealCorrectState(deal, DealState.ACCEPTED);

            IStorageEvidenceAdapter adapter = IStorageEvidenceAdapter(deal.evidenceAdapter);
            int64 expiration = CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(dealId));
            bool evidenceExpired = expiration != 0 && expiration < int64(uint64(block.number));
            if (!evidenceExpired) {
                revert EvidenceNotExpired(dealId);
            }
        } else if (state != DealState.EARLY_TERMINATED) {
            revert InvalidTerminationState(state);
        }
        _terminateDeal(deal, state);
    }

    /**
     * @notice Terminates a deal and its payment rail
     * @param deal The deal to terminate
     * @param state The terminal state to assign to the deal
     */
    function _terminateDeal(PoRepTypes.Deal storage deal, uint8 state) internal {
        PoRepMarketStorage storage $ = s();
        uint256 dealId = deal.dealId;
        uint8 previousState = deal.state;
        int64 blockNumber = int64(uint64(block.number));
        int64 serviceEndEpoch = CommonTypes.ChainEpoch.unwrap($._dealService[dealId].serviceEndEpoch);
        if (serviceEndEpoch != 0 && blockNumber > serviceEndEpoch) {
            revert ServiceAlreadyEnded(serviceEndEpoch, blockNumber);
        }
        _changeDealState(dealId, state);
        if (previousState == DealState.ACCEPTED) {
            $._SPRegistryContract
                .releasePendingCapacity(
                    deal.provider, $._dealCapacity[dealId].reservedBytes, deal.client, $._dealData[dealId].manifestHash
                );
        } else {
            $._SPRegistryContract
                .releaseCapacity(
                    deal.provider, $._dealCapacity[dealId].committedBytes, deal.client, $._dealData[dealId].manifestHash
                );
        }
        IOperator(deal.validator).earlyRailTermination();
        $._dealService[dealId].earlyTerminationEpoch = CommonTypes.ChainEpoch.wrap(blockNumber);
        emit DealTerminated(dealId, $._dealService[dealId].earlyTerminationEpoch);
    }

    /**
     * @notice Rejects a deal in Accepted state before rail is set
     * @dev Only callable by the admin
     * @param dealId The id of the deal
     */
    function rejectAcceptedDeal(uint256 dealId) external override onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, DealState.ACCEPTED);

        if (deal.railId != 0) {
            revert DealNotRejectable(dealId);
        }

        $._SPRegistryContract
            .releasePendingCapacity(
                deal.provider, $._dealCapacity[dealId].reservedBytes, deal.client, $._dealData[dealId].manifestHash
            );
        _changeDealState(dealId, DealState.REJECTED);
        emit DealRejected(dealId, msg.sender);
    }

    /**
     * @notice Gets deals for a specific organization by state
     * @param organization The address of the organization
     * @param state The state of the deals to retrieve
     * @param offset Zero-based index in the organization's state-specific deal list
     * @param limit Maximum number of deals to return
     * @return deals Array of deals for the organization in the specified state
     * @return total Total number of deals for the organization in the specified state
     */
    function getDealsForOrganizationByState(address organization, uint8 state, uint256 offset, uint256 limit)
        external
        view
        override
        returns (PoRepTypes.Deal[] memory deals, uint256 total)
    {
        if (organization == address(0)) {
            revert InvalidOrganizationAddress();
        }

        PoRepMarketStorage storage $ = s();
        EnumerableSet.UintSet storage ids = $._dealIdsByStateByOrganization[state][organization];

        total = ids.length();
        uint256 length = _pageLength(total, offset, limit);
        deals = new PoRepTypes.Deal[](length);

        for (uint256 i = 0; i < length; i++) {
            deals[i] = $._deals[ids.at(offset + i)];
        }
    }

    /**
     * @notice Gets a page of all deals in creation order
     * @param offset Zero-based index in the creation-order deal list
     * @param limit Maximum number of deals to return
     * @return deals Array of deals in creation order
     * @return total Total number of created deals
     */
    function getDeals(uint256 offset, uint256 limit)
        external
        view
        override
        returns (PoRepTypes.Deal[] memory deals, uint256 total)
    {
        PoRepMarketStorage storage $ = s();
        total = $._dealIdCounter;
        uint256 length = _pageLength(total, offset, limit);
        deals = new PoRepTypes.Deal[](length);

        for (uint256 i = 0; i < length; i++) {
            deals[i] = $._deals[offset + i + 1];
        }
    }

    /**
     * @notice Gets the SPRegistry contract address from storage
     * @return ISPRegistry The SPRegistry contract address
     */
    function getSPRegistryContract() external view override returns (address) {
        PoRepMarketStorage storage $ = s();
        return address($._SPRegistryContract);
    }

    /**
     * @notice Gets the global evidence adapter address from storage
     * @return The global evidence adapter address
     */
    function getGlobalEvidenceAdapter() external view override returns (address) {
        PoRepMarketStorage storage $ = s();
        return address($._globalEvidenceAdapter);
    }

    /**
     * @notice Gets the evidence adapter address assigned to a deal
     * @param dealId The id of the deal
     * @return The evidence adapter address for the deal
     */
    function getDealEvidenceAdapter(uint256 dealId) external view override returns (address) {
        PoRepTypes.Deal storage deal = s()._deals[dealId];
        _ensureDealExists(deal);
        return deal.evidenceAdapter;
    }

    /**
     * @notice Submit evidence to the adapter assigned to a deal
     * @param dealId The id of the deal
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Adapter activation decision for the submitted batch
     */
    function submitEvidenceBatch(uint256 dealId, bytes calldata evidenceData)
        external
        override
        returns (SharedTypes.ActivationDecision memory decision)
    {
        _ensurePoRepServiceOrAdmin();
        PoRepTypes.Deal storage deal = s()._deals[dealId];
        _ensureDealExists(deal);

        return IStorageEvidenceAdapter(deal.evidenceAdapter).submitEvidenceBatch(_activationContext(deal), evidenceData);
    }

    /**
     * @notice Activate evidence for a deal through its assigned adapter
     * @param dealId The id of the deal
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Adapter activation decision
     */
    function activateEvidence(uint256 dealId, bytes calldata evidenceData)
        external
        override
        returns (SharedTypes.ActivationDecision memory decision)
    {
        PoRepTypes.Deal storage deal = s()._deals[dealId];
        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, DealState.ACCEPTED);

        PoRepMarketStorage storage $ = s();
        decision =
            IStorageEvidenceAdapter(deal.evidenceAdapter).activateEvidence(_activationContext(deal), evidenceData);
        if (decision.result != EvidenceResult.ACCEPTED) {
            return decision;
        }

        PoRepTypes.DealCapacity storage capacity = $._dealCapacity[dealId];
        PoRepTypes.DealPayment storage payment = $._dealPayments[dealId];
        uint256 committedBytes = decision.coveredBytes;

        capacity.committedBytes = committedBytes;
        payment.billed32GiBUnits = Math.ceilDiv(committedBytes, SECTOR_SIZE);
        $._SPRegistryContract.commitCapacity(deal.provider, capacity.reservedBytes, committedBytes);
        _changeDealState(dealId, DealState.ACTIVE);
        _startPreparedPayment($, dealId, deal);
    }

    /**
     * @notice Refresh evidence status for a deal through its assigned adapter
     * @param dealId The id of the deal
     * @param evidenceData Adapter-specific evidence payload
     * @return status Updated evidence status
     */
    function refreshEvidenceStatus(uint256 dealId, bytes calldata evidenceData)
        external
        override
        returns (SharedTypes.EvidenceStatus memory status)
    {
        PoRepTypes.Deal storage deal = s()._deals[dealId];
        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, DealState.ACTIVE);

        return
            IStorageEvidenceAdapter(deal.evidenceAdapter).refreshEvidenceStatus(_activationContext(deal), evidenceData);
    }

    /**
     * @notice Reads current evidence status for a deal through its assigned adapter
     * @param dealId The id of the deal
     * @return status Current evidence status
     */
    function currentEvidenceStatus(uint256 dealId) external returns (SharedTypes.EvidenceStatus memory status) {
        return _currentEvidenceStatus(dealId);
    }

    /**
     * @notice Reads current evidence status for a deal through its assigned adapter
     * @param dealId The id of the deal
     * @return status Current evidence status
     */
    function _currentEvidenceStatus(uint256 dealId) internal returns (SharedTypes.EvidenceStatus memory status) {
        PoRepTypes.Deal storage deal = s()._deals[dealId];
        _ensureDealExists(deal);

        return IStorageEvidenceAdapter(deal.evidenceAdapter).currentEvidenceStatus(_activationContext(deal));
    }

    /**
     * @notice Gets the validator factory contract address from storage
     * @return IValidatorFactory The validator factory contract address
     */
    function getValidatorFactoryContract() external view override returns (address) {
        PoRepMarketStorage storage $ = s();
        return address($._validatorFactoryContract);
    }

    /// @inheritdoc IPoRepMarket
    function updateManifestLocation(
        uint256 dealId,
        string calldata newManifestLocation,
        uint256 newRequestedSizeBytes,
        bytes32 newManifestHash
    ) external override onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];
        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, DealState.ACCEPTED);
        _ensureCorrectManifestLocation(newManifestLocation);
        if (newRequestedSizeBytes == 0) revert InvalidDealSize();
        if (newManifestHash == bytes32(0)) revert InvalidManifestHash();
        if (IStorageEvidenceAdapter(deal.evidenceAdapter).hasSubmittedEvidence(dealId)) {
            revert ManifestUpdateNotAllowedAfterEvidence();
        }

        _updateManifestReservation(dealId, newRequestedSizeBytes, newManifestHash);
        SharedTypes.DealData memory oldData = $._dealData[dealId];
        uint256 oldRequestedSizeBytes = $._dealTerms[dealId].requestedSizeBytes;
        $._dealData[dealId] =
            SharedTypes.DealData({manifestHash: newManifestHash, manifestLocation: newManifestLocation});
        $._dealTerms[dealId].requestedSizeBytes = newRequestedSizeBytes;
        $._dealCapacity[dealId].reservedBytes = newRequestedSizeBytes;

        emit ManifestUpdated(
            dealId,
            oldData.manifestLocation,
            newManifestLocation,
            oldRequestedSizeBytes,
            newRequestedSizeBytes,
            oldData.manifestHash,
            newManifestHash
        );
    }

    /**
     * @notice Updates the selected offer's reservation before replacing the stored manifest
     * @param dealId The deal whose pending reservation changes
     * @param newRequestedSizeBytes The replacement manifest size
     * @param newManifestHash The replacement manifest hash
     */
    function _updateManifestReservation(uint256 dealId, uint256 newRequestedSizeBytes, bytes32 newManifestHash)
        internal
    {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];
        $._SPRegistryContract
            .updatePendingReservation(
                deal.offerId,
                deal.client,
                $._dealData[dealId].manifestHash,
                newManifestHash,
                $._dealCapacity[dealId].reservedBytes,
                newRequestedSizeBytes
            );
    }

    /**
     * @notice Updates the deal activation padding
     * @param padding The new padding value
     */
    function setDealActivationPadding(uint256 padding) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (padding > MAX_DEAL_ACTIVATION_PADDING) {
            revert DealActivationPaddingTooHigh(padding, MAX_DEAL_ACTIVATION_PADDING);
        }

        PoRepMarketStorage storage $ = s();
        uint256 oldPadding = $._dealActivationPadding;
        $._dealActivationPadding = padding;

        emit DealActivationPaddingUpdated(oldPadding, padding);
    }

    /**
     * @notice Getter for deal activation padding
     * @return padding Current padding value
     */
    function getDealActivationPadding() external view returns (uint256) {
        PoRepMarketStorage storage $ = s();
        return $._dealActivationPadding;
    }

    /**
     * @notice Sets the minimum time between settlements for a deal
     * @dev Only the admin may update the settlement cadence.
     * @param dealId The deal being configured
     * @param minEpochs Minimum time between settlements in epochs
     */
    function setMinEpochsBetweenSettlements(uint256 dealId, uint256 minEpochs)
        external
        onlyRole(Roles.DEFAULT_ADMIN_ROLE)
    {
        if (minEpochs == 0) {
            revert InvalidMinEpochsBetweenSettlements();
        }

        if (minEpochs > EPOCHS_IN_YEAR) {
            revert MinEpochsBetweenSettlementsExceeded();
        }

        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];
        _ensureDealExists(deal);

        $._dealService[dealId].minTimeBetweenSettlementsInEpochs = minEpochs;
        emit MinEpochsBetweenSettlementsUpdated(dealId, minEpochs);
    }

    // solhint-disable function-max-lines, gas-strict-inequalities, gas-small-strings
    /**
     * @notice Validates the settlement amount for a deal's service window
     * @dev Only the deal's validator may request a settlement decision. settleUpto controls how far FilecoinPay may
     * advance its cursor, including for rejected zero-payment windows.
     * @param dealId The deal being settled
     * @param fromEpoch The epoch at which the settlement window starts
     * @param toEpoch The epoch at which the settlement window ends
     * @return decision The amount and epoch accepted for settlement
     */
    function validateDealSettlement(uint256 dealId, uint256 fromEpoch, uint256 toEpoch)
        external
        returns (SharedTypes.SettlementDecision memory decision)
    {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];
        _ensureDealExists(deal);
        if (deal.validator != msg.sender) {
            revert CallerIsNotValidator(dealId, msg.sender);
        }

        PoRepTypes.DealService storage service = $._dealService[dealId];
        uint256 serviceEndEpoch = _epochToUint(service.serviceEndEpoch);

        if (serviceEndEpoch == 0) {
            revert DealServiceNotStarted(dealId);
        }

        if (fromEpoch > serviceEndEpoch) {
            return _rejectedSettlement(toEpoch, SettlementReason.DEAL_ENDED, "deal ended");
        }

        // Resolve the payable window before making external quality calls.
        bool settlementWasCapped;
        // Requested end epoch after limiting it to the deal's termination or service end.
        uint256 effectiveToEpoch = toEpoch;
        uint256 earlyTerminationEpoch = _epochToUint(service.earlyTerminationEpoch);
        // Terminated deals are capped at termination; active deals must also satisfy the minimum settlement interval.
        if (earlyTerminationEpoch > 0) {
            if (fromEpoch >= earlyTerminationEpoch) {
                return _rejectedSettlement(toEpoch, SettlementReason.DEAL_TERMINATED, "deal terminated");
            }
            if (effectiveToEpoch > earlyTerminationEpoch) {
                effectiveToEpoch = earlyTerminationEpoch;
                decision.note = "payment limited to deal termination epoch";
                settlementWasCapped = true;
            }
        } else {
            uint256 earliestSettlementEpoch = fromEpoch + service.minTimeBetweenSettlementsInEpochs;
            if (effectiveToEpoch < earliestSettlementEpoch) {
                revert SettlementTooEarly(effectiveToEpoch, earliestSettlementEpoch);
            }

            if (effectiveToEpoch > serviceEndEpoch) {
                effectiveToEpoch = serviceEndEpoch;
                decision.note = "payment limited to deal endepoch";
                settlementWasCapped = true;
            }
        }

        // Score and size failures advance the cursor to effectiveToEpoch; stale evidence reverts for a later retry.
        {
            SharedTypes.SLIThresholds memory slis = $._dealSLIs[dealId];
            if ($._SLIScorer.calculateScore(dealId, slis) != 100) {
                return _rejectedSettlement(
                    effectiveToEpoch, SettlementReason.SCORE_BELOW_THRESHOLD, "score below required threshold"
                );
            }
        }
        {
            SharedTypes.EvidenceStatus memory evidenceStatus =
                IStorageEvidenceAdapter(deal.evidenceAdapter).currentEvidenceStatus(_activationContext(deal));
            uint256 lastRefreshEpoch = _epochToUint(evidenceStatus.lastEvidenceRefreshEpoch);
            if (
                evidenceStatus.result == EvidenceResult.INACTIVE
                    || lastRefreshEpoch + EVIDENCE_REFRESH_GRACE_EPOCHS < effectiveToEpoch
            ) {
                revert EvidenceTooStale();
            }

            if (evidenceStatus.activeCoveredBytes != $._dealCapacity[dealId].committedBytes) {
                return _rejectedSettlement(
                    effectiveToEpoch, SettlementReason.DATA_SIZE_MISMATCH, "data size does not match the deal"
                );
            }
        }

        // Only successful validation updates the market's settlement tracking.
        PoRepTypes.DealPayment memory payment = $._dealPayments[dealId];
        uint256 serviceStartEpoch = _epochToUint(service.serviceStartEpoch);
        // Subtract cumulative amounts at both boundaries to price only the accepted settlement window.
        decision.settlementAmount = _calculateDueAmount(payment, serviceStartEpoch, effectiveToEpoch)
            - _calculateDueAmount(payment, serviceStartEpoch, fromEpoch);

        decision.settleUpto = settlementWasCapped ? toEpoch : effectiveToEpoch;
        decision.reasonCode = SettlementReason.OK;
        decision.result = settlementWasCapped ? SettlementResult.MODIFIED : SettlementResult.ACCEPTED;
        if (!settlementWasCapped) {
            decision.note = "payment validated successfully";
        }
        int64 lastSettledEpoch = int64(uint64(decision.settleUpto));
        service.lastSettledEpoch = CommonTypes.ChainEpoch.wrap(lastSettledEpoch);
        return decision;
    }

    // solhint-enable function-max-lines, gas-strict-inequalities, gas-small-strings

    /**
     * @notice Changes the state of a deal
     * @param dealId The id of the deal
     * @param toState The new state of the deal
     */
    function _changeDealState(uint256 dealId, uint8 toState) internal {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];
        address organization = $._dealOrganization[dealId];

        $._dealIdsByStateByOrganization[deal.state][organization].remove(dealId);
        $._dealIdsByStateByOrganization[toState][organization].add(dealId);
        $._dealIdsByState[deal.state].remove(dealId);
        $._dealIdsByState[toState].add(dealId);
        deal.state = toState;
    }

    /**
     * @notice Builds adapter activation context for a deal
     * @param deal The deal
     * @return context The adapter activation context
     */
    function _activationContext(PoRepTypes.Deal memory deal)
        internal
        view
        returns (SharedTypes.ActivationContext memory context)
    {
        PoRepTypes.DealTerms memory terms = s()._dealTerms[deal.dealId];
        return SharedTypes.ActivationContext({
            dealId: deal.dealId,
            requestedSizeBytes: terms.requestedSizeBytes,
            client: deal.client,
            durationEpochs: terms.durationEpochs,
            activationToleranceBps: uint16(s()._dealActivationPadding),
            provider: deal.provider
        });
    }

    function _pageLength(uint256 total, uint256 offset, uint256 limit) internal pure returns (uint256 length) {
        // solhint-disable-next-line gas-strict-inequalities
        if (offset >= total || limit == 0) {
            return 0;
        }

        uint256 remaining = total - offset;
        return limit < remaining ? limit : remaining;
    }

    /**
     * @notice Ensures caller has admin or PoRep service role
     */
    function _ensurePoRepServiceOrAdmin() internal view {
        if (_hasRole(Roles.POREP_SERVICE_ROLE, msg.sender)) return;
        if (_hasRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender)) return;
        revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, Roles.POREP_SERVICE_ROLE);
    }

    /**
     * @notice Calculates the amount to be paid per epoch for a deal
     * @param payment The deal payment data
     * @return amount Amount to be paid per epoch
     */
    function _calculateAmountPerEpoch(PoRepTypes.DealPayment memory payment) internal pure returns (uint256 amount) {
        if (payment.billed32GiBUnits == 0) {
            revert InvalidBilled32GiBUnits();
        }
        amount = Math.ceilDiv(payment.pricePer32GiBPerMonth * payment.billed32GiBUnits, EPOCHS_IN_MONTH);
        if (amount == 0) {
            revert InvalidZeroAmount();
        }
    }

    /**
     * @notice Calculates cumulative earned payment due at an epoch using frozen deal pricing
     * @param payment The deal payment data
     * @param serviceStartEpoch The epoch at which service started
     * @param epoch The epoch at which cumulative due amount is calculated
     * @return amount Cumulative amount due at the epoch
     */
    function _calculateDueAmount(PoRepTypes.DealPayment memory payment, uint256 serviceStartEpoch, uint256 epoch)
        internal
        pure
        returns (uint256 amount)
    {
        // solhint-disable-next-line gas-strict-inequalities
        if (epoch <= serviceStartEpoch) {
            return 0;
        }

        uint256 monthlyTotal = payment.pricePer32GiBPerMonth * payment.billed32GiBUnits;
        amount = Math.mulDiv(monthlyTotal, epoch - serviceStartEpoch, EPOCHS_IN_MONTH);
    }

    /**
     * @notice Builds a zero-payment settlement rejection with an explicit cursor position
     * @param settleUpto Epoch FilecoinPay may advance to
     * @param reasonCode Settlement rejection reason
     * @param note Human-readable rejection reason
     * @return decision Rejected settlement decision
     */
    function _rejectedSettlement(uint256 settleUpto, uint16 reasonCode, string memory note)
        private
        pure
        returns (SharedTypes.SettlementDecision memory decision)
    {
        decision.settleUpto = settleUpto;
        decision.reasonCode = reasonCode;
        decision.result = SettlementResult.REJECTED;
        decision.note = note;
    }

    //  solhint-enable

    /**
     * @notice Ensures a deal exists
     * @param deal The deal
     */
    function _ensureDealExists(PoRepTypes.Deal storage deal) internal view {
        if (deal.dealId == 0) revert DealDoesNotExist();
    }

    /**
     * @notice Ensures a deal is in the correct state
     * @param deal The deal
     * @param expectedState The expected state
     */
    function _ensureDealCorrectState(PoRepTypes.Deal storage deal, uint8 expectedState) internal view {
        if (deal.state != expectedState) {
            revert DealNotInExpectedState(deal.dealId, deal.state, expectedState);
        }
    }

    /**
     * @notice Ensures the requirements are correct
     * @param requirements The SLI thresholds for the deal
     */
    function _ensureCorrectRequirements(SharedTypes.SLIThresholds calldata requirements) internal pure {
        if (requirements.retrievabilityBps > 10_000) {
            revert InvalidRetrievabilityBps(requirements.retrievabilityBps);
        }
        if (requirements.indexingPct > 100) {
            revert InvalidIndexingPct(requirements.indexingPct);
        }
    }

    /**
     * @notice Ensures the terms are correct
     * @param request The client deal request
     */
    function _ensureCorrectTerms(SharedTypes.DealRequest calldata request) internal pure {
        if (request.durationDays < MIN_DEAL_DURATION_DAYS) {
            revert InvalidDealDuration();
        }
        if (request.durationDays > MAX_DEAL_DURATION_DAYS) {
            revert InvalidDealDuration();
        }
        if (request.durationDays % 30 != 0) {
            revert InvalidDealDuration();
        }
        if (request.requestedSizeBytes == 0) {
            revert InvalidDealSize();
        }
        uint256 minSectors = Math.ceilDiv(request.requestedSizeBytes, SECTOR_SIZE);
        uint256 totalPerMonth = request.maxPricePer32GiBPerMonth * minSectors;
        if (totalPerMonth < EPOCHS_IN_MONTH) {
            revert InvalidDealPricePerSectorPerMonth(totalPerMonth, EPOCHS_IN_MONTH);
        }
    }

    /**
     * @notice Ensures the manifest location is correct
     * @param manifestLocation The manifest location for the deal
     */
    function _ensureCorrectManifestLocation(string calldata manifestLocation) internal pure {
        if (bytes(manifestLocation).length == 0) {
            revert EmptyManifestLocation();
        }
        if (bytes(manifestLocation).length > 2048) {
            revert TooLongManifestLocation();
        }
    }

    /**
     * @notice Converts a non-negative Filecoin epoch to uint256
     * @param epoch The epoch to convert
     * @return epochAsUint The epoch converted to uint256
     */
    function _epochToUint(CommonTypes.ChainEpoch epoch) internal pure returns (uint256 epochAsUint) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint64(CommonTypes.ChainEpoch.unwrap(epoch)));
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Authorizes an upgrade
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}

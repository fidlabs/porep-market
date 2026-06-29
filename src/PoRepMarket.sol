// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {IValidatorFactory} from "./interfaces/IValidatorFactory.sol";
import {IOperator} from "./interfaces/IOperator.sol";
import {IValidator} from "./interfaces/IValidator.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {IStorageEvidenceAdapter} from "./interfaces/IStorageEvidenceAdapter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SLITypes} from "./types/SLITypes.sol";
import {SharedTypes} from "./types/SharedTypes.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {RailStatus} from "./types/RailStatus.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PoRepMarket contract
 * @dev PoRepMarket contract is a contract that allows users to create and manage PoRep deals
 * @notice PoRepMarket contract
 */
contract PoRepMarket is IPoRepMarket, Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;
    /**
     * @notice role to manage contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice role to manage PoRep service operations
     */
    bytes32 public constant POREP_SERVICE_ROLE = keccak256("POREP_SERVICE_ROLE");

    /**
     * @notice Number of epochs in one month
     * @dev 30 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 86_400 epochs
     */
    uint256 public constant EPOCHS_IN_MONTH = 86_400;

    /**
     * @notice Size of a single Filecoin sector in bytes (32 GiB)
     */
    uint256 public constant SECTOR_SIZE = 32 * 1024 * 1024 * 1024;

    /**
     * @notice The maximum value allowed for deal completion padding.
     */
    uint256 private constant MAX_DEAL_COMPLETION_PADDING = 100;

    /**
     * @notice Default number of epochs after which a proposed deal expires if not accepted
     * @dev 2 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 5_760 epochs
     */
    uint256 private constant DEFAULT_DEAL_PROPOSAL_EXPIRATION = 5_760;

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
        mapping(uint256 dealId => PoRepTypes.DealTiming) _dealTiming;
        mapping(uint256 dealId => PoRepTypes.DealService) _dealService;
        mapping(uint256 dealId => PoRepTypes.DealCapacity) _dealCapacity;
        mapping(uint256 dealId => PoRepTypes.DealPayment) _dealPayments;
        mapping(uint256 dealId => SharedTypes.SLIThresholds) _dealSLIs;
        mapping(uint256 dealId => address organization) _dealOrganization;
        mapping(PoRepTypes.DealState state => mapping(address organization => EnumerableSet.UintSet dealIds))
            _dealIdsByStateByOrganization;
        mapping(PoRepTypes.DealState state => EnumerableSet.UintSet dealIds) _dealIdsByState;
        mapping(address client => EnumerableSet.UintSet dealIds) _dealIdsByClient;
        mapping(CommonTypes.FilActorId provider => EnumerableSet.UintSet dealIds) _dealIdsByProvider;
        EnumerableSet.UintSet _dealIdsReadyForPayment;
        ISPRegistry _SPRegistryContract;
        IValidatorFactory _validatorFactoryContract;
        IStorageEvidenceAdapter _globalEvidenceAdapter;
        uint256 _dealIdCounter;
        uint256 _dealCompletionPadding;
        uint256 _dealExpiration;
    }
    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.PoRepMarket")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant POREP_MARKET_STORAGE_LOCATION =
        0x0abde292d09529f8839f1c315101bb9805017b92f1e5d27b754124ac2f3da000;

    // solhint-disable-next-line use-natspec
    function _getPoRepMarketStorage() private pure returns (PoRepMarketStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := POREP_MARKET_STORAGE_LOCATION
        }
    }

    /**
     * @notice function to allow acess to storage
     * @return PoRepMarketStorage storage struct
     */
    function s() private pure returns (PoRepMarketStorage storage) {
        return _getPoRepMarketStorage();
    }

    /**
     * @notice DealCreated event
     * @param dealId The id of the deal
     * @param client The address of the client
     * @param provider The address of the provider
     * @param requirements The SLI thresholds for the deal
     * @param manifestLocation The location of the manifest for the deal
     * @param totalDealSize The total size of the deal in bytes
     * @param proposedAtBlock The block number when the deal was proposed
     */
    event DealCreated(
        uint256 indexed dealId,
        address indexed client,
        CommonTypes.FilActorId indexed provider,
        SharedTypes.SLIThresholds requirements,
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
     * @notice DealCompleted event
     * @param dealId The id of the deal
     * @param client The address of the client
     * @param actualSizeBytes The actual size of the data in bytes
     * @param provider The address of the provider
     */
    event DealCompleted(
        uint256 indexed dealId, address indexed client, uint256 actualSizeBytes, CommonTypes.FilActorId indexed provider
    );

    /**
     * @notice DealTerminated event
     * @dev DealTerminated event is emitted when a deal is terminated
     * @param dealId The id of the deal
     * @param terminator The address that terminated the deal
     * @param endEpoch The Filecoin epoch at which the deal was terminated
     */
    event DealTerminated(uint256 indexed dealId, address indexed terminator, uint256 indexed endEpoch);

    /**
     * @notice DealRejected event
     * @param dealId The id of the deal
     * @param rejector The address of the rejector
     */
    event DealRejected(uint256 indexed dealId, address indexed rejector);

    /**
     * @notice ManifestLocationUpdated event
     * @dev ManifestLocationUpdated event is emitted when a manifest location is updated
     * @param dealId The id of the deal
     * @param oldManifestLocation The old manifest location
     * @param newManifestLocation The new manifest location
     */
    event ManifestLocationUpdated(uint256 indexed dealId, string oldManifestLocation, string newManifestLocation);

    /**
     * @notice GlobalEvidenceAdapterUpdated event
     * @dev Emitted when the global evidence adapter is updated
     * @param evidenceAdapter The address of the global evidence adapter
     */
    event GlobalEvidenceAdapterUpdated(address indexed evidenceAdapter);

    /**
     * @notice DealCompletionPaddingUpdated event
     * @dev DealCompletionPaddingUpdated event is emitted when the deal completion padding is updated
     * @param oldPadding old padding for the deal completion
     * @param newPadding new padding for the deal completion
     */
    event DealCompletionPaddingUpdated(uint256 indexed oldPadding, uint256 indexed newPadding);

    /**
     * @notice DealExpired event
     * @dev DealExpired event is emitted when a deal expires
     * @param dealId The id of the deal
     * @param expiredAtBlock The block number at which the deal expired
     */
    event DealExpired(uint256 indexed dealId, uint256 indexed expiredAtBlock);

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
     * @notice DealExpirationUpdated event
     * @dev DealExpirationUpdated event is emitted when the deal expiration is updated
     * @param newDealExpiration The new deal expiration in epochs
     */
    event DealExpirationUpdated(uint256 indexed newDealExpiration);

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
    error DealNotInExpectedState(uint256 dealId, PoRepTypes.DealState currentState, PoRepTypes.DealState expectedState);

    /**
     * @notice Error thrown when caller is not the validator for the deal or validator is not set
     * @dev 0xd325131b
     */
    error CallerIsNotValidator(uint256 dealId, address caller);

    /**
     * @notice Error thrown when a deal does not exist for a given id
     * @dev 0xa72c631d
     */
    error DealDoesNotExist();

    /**
     * @notice Error thrown when caller is not the client, admin or storage provider for the deal
     * @dev 0x24801438
     */
    error NotTheClientOrStorageProviderOrAdmin(uint256 dealId, address rejector);

    /**
     * @notice Error thrown when no provider is found for the deal
     * @dev 0x66dab3aa
     */
    error NoProviderFoundForDeal();

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
     * @notice Error indicating that the allocated size for a deal is too small to change its state to complete
     * @dev 0x39d70eaf
     */
    error InvalidAllocationSizeForDealCompletion();

    /**
     * @notice Error thrown when trying to use an invalid client address
     * @dev 0xa75bd1dd
     */
    error NotTheClientAddress();

    /**
     * @notice Error thrown when trying to set the padding value higher than maximum
     * @dev 0x6e8e586a
     */
    error DealCompletionPaddingTooHigh(uint256 padding, uint256 maxPadding);

    /**
     * @notice Error thrown when trying to set a deal expiration that is invalid
     * @dev 0x25d11a26
     */
    error InvalidDealExpiration();

    /**
     * @notice Error thrown when trying to reject a deal that is not expired yet
     * @dev 0x37e8d391
     */
    error DealNotExpiredYet(uint256 dealId, uint256 currentBlock, uint256 expirationBlock);

    /**
     * @notice Constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @param _admin The address of the admin
     * @param _validatorFactory The address of the validator registry
     * @param _spRegistry The address of the SP registry
     * @param _globalEvidenceAdapter The address of the default evidence adapter
     */
    function initialize(address _admin, address _validatorFactory, address _spRegistry, address _globalEvidenceAdapter)
        public
        initializer
    {
        if (_globalEvidenceAdapter == address(0)) {
            revert InvalidEvidenceAdapterAddress();
        }

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(POREP_SERVICE_ROLE, _admin);

        PoRepMarketStorage storage $ = s();
        $._validatorFactoryContract = IValidatorFactory(_validatorFactory);
        $._SPRegistryContract = ISPRegistry(_spRegistry);
        $._globalEvidenceAdapter = IStorageEvidenceAdapter(_globalEvidenceAdapter);
        $._dealExpiration = DEFAULT_DEAL_PROPOSAL_EXPIRATION;

        emit GlobalEvidenceAdapterUpdated(_globalEvidenceAdapter);
    }

    /**
     * @notice Sets the global evidence adapter
     * @dev New deals snapshot this adapter at proposal time
     * @param _globalEvidenceAdapter The address of the global evidence adapter
     */
    function setGlobalEvidenceAdapter(address _globalEvidenceAdapter) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_globalEvidenceAdapter == address(0)) {
            revert InvalidEvidenceAdapterAddress();
        }
        PoRepMarketStorage storage $ = _getPoRepMarketStorage();
        $._globalEvidenceAdapter = IStorageEvidenceAdapter(_globalEvidenceAdapter);
        emit GlobalEvidenceAdapterUpdated(_globalEvidenceAdapter);
    }

    // solhint-disable function-max-lines
    /**
     * @notice Proposes a deal
     * @param request The client deal request
     */
    function proposeDeal(SharedTypes.DealRequest calldata request) external {
        _ensureCorrectManifestLocation(request.manifestLocation);
        _ensureCorrectRequirements(request.requiredSLIs);

        PoRepMarketStorage storage $ = s();
        IStorageEvidenceAdapter evidenceAdapter = $._globalEvidenceAdapter;
        if (address(evidenceAdapter) == address(0)) {
            revert InvalidEvidenceAdapterAddress();
        }

        CommonTypes.FilActorId provider;
        bool autoApprove;
        address organization;
        {
            SLITypes.DealTerms memory terms = SLITypes.DealTerms({
                dealSizeBytes: request.requestedSizeBytes,
                pricePerSectorPerMonth: request.maxPricePer32GiBPerMonth,
                durationDays: request.durationDays
            });
            _ensureCorrectTerms(terms);
            (provider, autoApprove, organization) =
                $._SPRegistryContract.getProviderForDeal(request.requiredSLIs, terms);
        }
        if (CommonTypes.FilActorId.unwrap(provider) == 0) {
            revert NoProviderFoundForDeal();
        }

        uint256 dealId = ++$._dealIdCounter;
        PoRepTypes.DealState initialState = autoApprove ? PoRepTypes.DealState.Accepted : PoRepTypes.DealState.Proposed;

        $._deals[dealId] = PoRepTypes.Deal({
            dealId: dealId,
            client: msg.sender,
            provider: provider,
            offerId: 0,
            state: initialState,
            evidenceAdapter: address(evidenceAdapter),
            validator: address(0),
            railId: 0
        });
        $._dealSLIs[dealId] = request.requiredSLIs;
        {
            uint64 durationEpochs = uint64(uint256(request.durationDays) * (EPOCHS_IN_MONTH / 30));
            $._dealTerms[dealId] =
                PoRepTypes.DealTerms({requestedSizeBytes: request.requestedSizeBytes, durationEpochs: durationEpochs});
        }
        {
            int64 proposedAtEpoch = int64(uint64(block.number));
            int64 expiresAtEpoch = int64(uint64(block.number + _getDealExpiration($)));
            $._dealTiming[dealId] = PoRepTypes.DealTiming({
                proposedAtEpoch: CommonTypes.ChainEpoch.wrap(proposedAtEpoch),
                expiresAtEpoch: CommonTypes.ChainEpoch.wrap(expiresAtEpoch)
            });
        }
        $._dealService[dealId] = PoRepTypes.DealService({
            serviceStartEpoch: CommonTypes.ChainEpoch.wrap(0), serviceEndEpoch: CommonTypes.ChainEpoch.wrap(0)
        });
        $._dealCapacity[dealId] =
            PoRepTypes.DealCapacity({reservedBytes: request.requestedSizeBytes, committedBytes: 0});
        $._dealPayments[dealId] = PoRepTypes.DealPayment({
            paymentToken: request.paymentToken,
            payee: address(0),
            pricePer32GiBPerMonth: request.maxPricePer32GiBPerMonth,
            billed32GiBUnits: 0,
            railMaxRatePerEpoch: 0
        });
        $._dealData[dealId] =
            SharedTypes.DealData({manifestHash: request.manifestHash, manifestLocation: request.manifestLocation});
        {
            emit DealCreated(
                dealId,
                msg.sender,
                provider,
                request.requiredSLIs,
                request.manifestLocation,
                request.requestedSizeBytes,
                block.number
            );
        }
        $._dealOrganization[dealId] = organization;
        $._dealIdsByStateByOrganization[initialState][organization].add(dealId);
        $._dealIdsByClient[msg.sender].add(dealId);
        $._dealIdsByProvider[provider].add(dealId);
        $._dealIdsByState[initialState].add(dealId);

        if (autoApprove) {
            emit DealAccepted(dealId, msg.sender, provider);
        }
    }

    // solhint-enable function-max-lines

    /**
     * @notice Updates the validator for a deal
     * @param dealId The id of the deal
     */
    function updateValidator(uint256 dealId) external {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, PoRepTypes.DealState.Accepted);

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
    function updateRailId(uint256 dealId, uint256 railId) external {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, PoRepTypes.DealState.Accepted);

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
    function getDeal(uint256 dealId) external view returns (PoRepTypes.Deal memory deal) {
        PoRepMarketStorage storage $ = s();
        return $._deals[dealId];
    }

    /**
     * @notice Gets the data fields for a deal
     * @param dealId The id of the deal
     * @return dealData The deal data
     */
    function getDealData(uint256 dealId) external view returns (SharedTypes.DealData memory dealData) {
        PoRepMarketStorage storage $ = s();
        return $._dealData[dealId];
    }

    /**
     * @notice Gets the frozen size and duration terms for a deal
     * @param dealId The id of the deal
     * @return terms The deal terms
     */
    function getDealTerms(uint256 dealId) external view returns (PoRepTypes.DealTerms memory terms) {
        PoRepMarketStorage storage $ = s();
        return $._dealTerms[dealId];
    }

    /**
     * @notice Gets the proposal timing for a deal
     * @param dealId The id of the deal
     * @return timing The deal timing
     */
    function getDealTiming(uint256 dealId) external view returns (PoRepTypes.DealTiming memory timing) {
        PoRepMarketStorage storage $ = s();
        return $._dealTiming[dealId];
    }

    /**
     * @notice Gets the service window for a deal
     * @param dealId The id of the deal
     * @return service The deal service window
     */
    function getDealService(uint256 dealId) external view returns (PoRepTypes.DealService memory service) {
        PoRepMarketStorage storage $ = s();
        return $._dealService[dealId];
    }

    /**
     * @notice Gets the reserved and committed capacity for a deal
     * @param dealId The id of the deal
     * @return capacity The deal capacity
     */
    function getDealCapacity(uint256 dealId) external view returns (PoRepTypes.DealCapacity memory capacity) {
        PoRepMarketStorage storage $ = s();
        return $._dealCapacity[dealId];
    }

    /**
     * @notice Gets payment terms and rail accounting for a deal
     * @param dealId The id of the deal
     * @return payment The deal payment data
     */
    function getDealPayment(uint256 dealId) external view returns (PoRepTypes.DealPayment memory payment) {
        PoRepMarketStorage storage $ = s();
        return $._dealPayments[dealId];
    }

    /**
     * @notice Gets SLI thresholds for a deal
     * @param dealId The id of the deal
     * @return slis The deal SLI thresholds
     */
    function getDealSLIs(uint256 dealId) external view returns (SharedTypes.SLIThresholds memory slis) {
        PoRepMarketStorage storage $ = s();
        return $._dealSLIs[dealId];
    }

    /**
     * @notice Accepts a deal
     * @param dealId The id of the deal
     */
    function acceptDeal(uint256 dealId) external {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, PoRepTypes.DealState.Proposed);

        if (!$._SPRegistryContract.isAuthorizedForProvider(msg.sender, deal.provider)) {
            revert NotTheControllingAddress(dealId, msg.sender, deal.provider);
        }

        _changeDealState(dealId, PoRepTypes.DealState.Accepted);
        emit DealAccepted(dealId, msg.sender, deal.provider);
    }

    /**
     * @notice Completes a deal
     * @param dealId The id of the deal
     */
    function completeDeal(uint256 dealId) external {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, PoRepTypes.DealState.Accepted);

        if (msg.sender != deal.client) revert NotTheClientAddress();
        SharedTypes.EvidenceStatus memory status =
            IStorageEvidenceAdapter(deal.evidenceAdapter).currentEvidenceStatus(_activationContext(deal));
        uint256 allocatedSize = status.activeCoveredBytes;
        uint256 proposedSize = $._dealTerms[dealId].requestedSizeBytes;

        _ensureAllocationSizeWithinTolerance(allocatedSize, proposedSize);

        $._dealIdsReadyForPayment.add(dealId);
        $._SPRegistryContract.commitCapacity(deal.provider, proposedSize, allocatedSize);
        $._dealCapacity[dealId].committedBytes = allocatedSize;
        $._dealPayments[dealId].billed32GiBUnits = Math.ceilDiv(allocatedSize, SECTOR_SIZE); // do not add this, it will be initialized in other function in fututre tasks

        _changeDealState(dealId, PoRepTypes.DealState.Completed);
        emit DealCompleted(dealId, msg.sender, allocatedSize, deal.provider);
    }

    /**
     * @notice Activates payment for a completed deal
     * @dev Calculates the rail max rate, initializes the service window, and asks the validator to update the rail.
     * @param dealId The id of the deal
     */
    function activatePayment(uint256 dealId) external onlyRole(POREP_SERVICE_ROLE) {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, PoRepTypes.DealState.Completed);

        if (deal.railId == 0) {
            revert InvalidRailId();
        }

        uint8 railStatus = IValidator(deal.validator).getRailStatus();
        if (railStatus != RailStatus.PREPARED) {
            revert InvalidRailState(railStatus);
        }

        PoRepTypes.DealPayment storage payment = $._dealPayments[dealId];
        uint256 railMaxRatePerEpoch = _calculateAmountPerEpoch(payment);
        payment.railMaxRatePerEpoch = railMaxRatePerEpoch;

        PoRepTypes.DealService storage service = $._dealService[dealId];
        int64 serviceStartEpoch = int64(uint64(block.number));
        service.serviceStartEpoch = CommonTypes.ChainEpoch.wrap(serviceStartEpoch);
        service.serviceEndEpoch =
            CommonTypes.ChainEpoch.wrap(serviceStartEpoch + int64(uint64($._dealTerms[dealId].durationEpochs)));

        IOperator(deal.validator).modifyRailPayment(railMaxRatePerEpoch);
        emit PaymentActivated(dealId, railMaxRatePerEpoch, service.serviceStartEpoch, service.serviceEndEpoch);
    }

    /**
     * @notice Terminate a deal
     * @dev Terminates a deal by setting the deal state to terminated
     * @param dealId The id of the deal
     * @param terminator The address that terminated the deal
     * @param endEpoch The Filecoin epoch at which the deal was terminated
     */
    function terminateDeal(uint256 dealId, address terminator, uint256 endEpoch) external {
        PoRepMarketStorage storage $ = _getPoRepMarketStorage();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, PoRepTypes.DealState.Completed);

        if (msg.sender != deal.validator || deal.validator == address(0)) {
            revert CallerIsNotValidator(dealId, msg.sender);
        }

        $._SPRegistryContract.releaseCapacity(deal.provider, $._dealTerms[dealId].requestedSizeBytes);
        $._dealIdsReadyForPayment.remove(dealId);

        _changeDealState(dealId, PoRepTypes.DealState.Terminated);
        emit DealTerminated(dealId, terminator, endEpoch);
    }

    /**
     * @notice Rejects a deal
     * @param dealId The id of the deal
     */
    function rejectDeal(uint256 dealId) external {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, PoRepTypes.DealState.Proposed);

        if (
            msg.sender != deal.client && !$._SPRegistryContract.isAuthorizedForProvider(msg.sender, deal.provider)
                && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
        ) {
            revert NotTheClientOrStorageProviderOrAdmin(dealId, msg.sender);
        }

        $._SPRegistryContract.releasePendingCapacity(deal.provider, $._dealTerms[dealId].requestedSizeBytes);
        _changeDealState(dealId, PoRepTypes.DealState.Rejected);
        emit DealRejected(dealId, msg.sender);
    }

    /**
     * @notice Rejects a deal in Accepted state before rail is set
     * @dev Only callable by the admin
     * @param dealId The id of the deal
     */
    function rejectAcceptedDeal(uint256 dealId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, PoRepTypes.DealState.Accepted);

        if (deal.railId != 0) {
            revert DealNotRejectable(dealId);
        }

        $._SPRegistryContract.releasePendingCapacity(deal.provider, $._dealTerms[dealId].requestedSizeBytes);
        _changeDealState(dealId, PoRepTypes.DealState.Rejected);
        emit DealRejected(dealId, msg.sender);
    }

    /**
     * @notice Rejects expired deal
     * @param dealId The id of the deal
     * @dev A deal is considered expired after its proposed-state expiration epoch
     */
    function rejectExpiredDeal(uint256 dealId) external {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];

        _ensureDealExists(deal);
        _ensureDealCorrectState(deal, PoRepTypes.DealState.Proposed);

        // solhint-disable  gas-strict-inequalities
        uint256 expiresAtBlock = uint256(uint64(CommonTypes.ChainEpoch.unwrap($._dealTiming[dealId].expiresAtEpoch)));
        if (block.number <= expiresAtBlock) {
            revert DealNotExpiredYet(dealId, block.number, expiresAtBlock);
        }
        // solhint-enable  gas-strict-inequalities

        $._SPRegistryContract.releasePendingCapacity(deal.provider, $._dealTerms[dealId].requestedSizeBytes);
        _changeDealState(dealId, PoRepTypes.DealState.Rejected);
        emit DealExpired(dealId, block.number);
    }

    /**
     * @notice Sets new proposed deal expiration
     * @dev Only callable by the admin
     * @param newDealExpiration The new proposed deal expiration in epochs
     */
    function setNewDealExpiration(uint256 newDealExpiration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDealExpiration == 0) {
            revert InvalidDealExpiration();
        }
        PoRepMarketStorage storage $ = s();
        $._dealExpiration = newDealExpiration;

        emit DealExpirationUpdated(newDealExpiration);
    }

    /**
     * @notice Gets all active deals
     * @return activeDeals Array of active deals
     */
    function getCompletedDeals() external view returns (PoRepTypes.Deal[] memory activeDeals) {
        PoRepMarketStorage storage $ = s();
        uint256[] memory activeDealIds = $._dealIdsReadyForPayment.values();
        activeDeals = new PoRepTypes.Deal[](activeDealIds.length);
        uint256 dealCounter = 0;

        for (uint256 i = 0; i < activeDealIds.length; i++) {
            PoRepTypes.Deal memory deal = $._deals[activeDealIds[i]];
            if (deal.state == PoRepTypes.DealState.Completed) {
                activeDeals[dealCounter] = deal;
                dealCounter++;
            }
        }

        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(activeDeals, dealCounter)
        }
    }

    /**
     * @notice Gets deals for a specific organization by state
     * @param organization The address of the organization
     * @param state The state of the deals to retrieve
     * @return deals Array of deals for the organization in the specified state (from all providers associated with the organization)
     */
    function getDealsForOrganizationByState(address organization, PoRepTypes.DealState state)
        external
        view
        returns (PoRepTypes.Deal[] memory deals)
    {
        if (organization == address(0)) {
            revert InvalidOrganizationAddress();
        }

        PoRepMarketStorage storage $ = s();
        EnumerableSet.UintSet storage ids = $._dealIdsByStateByOrganization[state][organization];

        uint256 lengthOfDeals = ids.length();
        deals = new PoRepTypes.Deal[](lengthOfDeals);

        for (uint256 i = 0; i < lengthOfDeals; i++) {
            deals[i] = $._deals[ids.at(i)];
        }
    }

    /**
     * @notice Gets all deals
     * @return deals Array of all deals
     */
    function getDeals() external view returns (PoRepTypes.Deal[] memory deals) {
        PoRepMarketStorage storage $ = s();
        uint256 totalDeals = $._dealIdCounter;
        deals = new PoRepTypes.Deal[](totalDeals);

        for (uint256 deal = 0; deal < totalDeals; deal++) {
            deals[deal] = $._deals[deal + 1];
        }
    }

    /**
     * @notice Gets the SPRegistry contract address from storage
     * @return ISPRegistry The SPRegistry contract address
     */
    function getSPRegistryContract() external view returns (address) {
        PoRepMarketStorage storage $ = s();
        return address($._SPRegistryContract);
    }

    /**
     * @notice Gets the global evidence adapter address from storage
     * @return The global evidence adapter address
     */
    function getGlobalEvidenceAdapter() external view returns (address) {
        PoRepMarketStorage storage $ = s();
        return address($._globalEvidenceAdapter);
    }

    /**
     * @notice Gets the evidence adapter address assigned to a deal
     * @param dealId The id of the deal
     * @return The evidence adapter address for the deal
     */
    function getDealEvidenceAdapter(uint256 dealId) external view returns (address) {
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
        returns (SharedTypes.ActivationDecision memory decision)
    {
        _ensurePoRepServiceOrAdmin();
        PoRepTypes.Deal storage deal = s()._deals[dealId];
        _ensureDealExists(deal);

        return IStorageEvidenceAdapter(deal.evidenceAdapter).activateEvidence(_activationContext(deal), evidenceData);
    }

    /**
     * @notice Refresh evidence status for a deal through its assigned adapter
     * @param dealId The id of the deal
     * @param evidenceData Adapter-specific evidence payload
     * @return status Updated evidence status
     */
    function refreshEvidenceStatus(uint256 dealId, bytes calldata evidenceData)
        external
        returns (SharedTypes.EvidenceStatus memory status)
    {
        _ensurePoRepServiceOrAdmin();
        PoRepTypes.Deal storage deal = s()._deals[dealId];
        _ensureDealExists(deal);

        return
            IStorageEvidenceAdapter(deal.evidenceAdapter).refreshEvidenceStatus(_activationContext(deal), evidenceData);
    }

    /**
     * @notice Reads current evidence status for a deal through its assigned adapter
     * @param dealId The id of the deal
     * @return status Current evidence status
     */
    function currentEvidenceStatus(uint256 dealId) external view returns (SharedTypes.EvidenceStatus memory status) {
        PoRepTypes.Deal storage deal = s()._deals[dealId];
        _ensureDealExists(deal);

        return IStorageEvidenceAdapter(deal.evidenceAdapter).currentEvidenceStatus(_activationContext(deal));
    }

    /**
     * @notice Gets the validator factory contract address from storage
     * @return IValidatorFactory The validator factory contract address
     */
    function getValidatorFactoryContract() external view returns (address) {
        PoRepMarketStorage storage $ = s();
        return address($._validatorFactoryContract);
    }

    /**
     * @notice Retrieves the manifest location URL for a specific deal
     * @param dealId The unique identifier of the deal
     * @return manifestLocation The manifest location URL for a specific deal
     */
    function getManifestLocation(uint256 dealId) external view returns (string memory manifestLocation) {
        PoRepMarketStorage storage $ = s();
        _ensureDealExists($._deals[dealId]);
        return $._dealData[dealId].manifestLocation;
    }

    /**
     * @notice Retrieves the proposed deal expiration
     * @return dealExpiration The proposed deal expiration in epochs
     */
    function getDealExpiration() external view returns (uint256 dealExpiration) {
        PoRepMarketStorage storage $ = s();
        return _getDealExpiration($);
    }

    /**
     * @notice Updates the manifest location for a specific deal
     * @dev Only callable by the admin
     * @param dealId The unique identifier of the deal
     * @param newManifestLocation The new manifest location URL to be updated for the deal
     */
    function updateManifestLocation(uint256 dealId, string calldata newManifestLocation)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        PoRepMarketStorage storage $ = s();
        _ensureDealExists($._deals[dealId]);

        if (bytes(newManifestLocation).length == 0) {
            revert EmptyManifestLocation();
        }

        if (bytes(newManifestLocation).length > 2048) {
            revert TooLongManifestLocation();
        }

        string memory oldManifestLocation = $._dealData[dealId].manifestLocation;
        $._dealData[dealId].manifestLocation = newManifestLocation;
        emit ManifestLocationUpdated(dealId, oldManifestLocation, newManifestLocation);
    }

    /**
     * @notice Updates the deal completion padding
     * @param padding The new padding value
     */
    function setDealCompletionPadding(uint256 padding) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (padding > MAX_DEAL_COMPLETION_PADDING) {
            revert DealCompletionPaddingTooHigh(padding, MAX_DEAL_COMPLETION_PADDING);
        }

        PoRepMarketStorage storage $ = s();
        uint256 oldPadding = $._dealCompletionPadding;
        $._dealCompletionPadding = padding;

        emit DealCompletionPaddingUpdated(oldPadding, padding);
    }

    /**
     * @notice Getter for deal completion padding
     * @return padding Current padding value
     */
    function getDealCompletionPadding() external view returns (uint256) {
        PoRepMarketStorage storage $ = s();
        return $._dealCompletionPadding;
    }

    /**
     * @notice Changes the state of a deal
     * @param dealId The id of the deal
     * @param toState The new state of the deal
     */
    function _changeDealState(uint256 dealId, PoRepTypes.DealState toState) internal {
        PoRepMarketStorage storage $ = s();
        PoRepTypes.Deal storage deal = $._deals[dealId];
        address organization = $._dealOrganization[dealId];

        $._dealIdsByStateByOrganization[deal.state][organization].remove(dealId);
        $._dealIdsByStateByOrganization[toState][organization].add(dealId);
        $._dealIdsByState[deal.state].remove(dealId);
        $._dealIdsByState[toState].add(dealId);
        deal.state = toState;
    }

    // solhint-disable
    /**
     * @notice Gets the proposed deal expiration
     * @dev If the expiration is not set (contract already deployed), it returns the default expiration
     * @param $ The market storage
     * @return The proposed deal expiration in epochs
     */
    function _getDealExpiration(PoRepMarketStorage storage $) internal view returns (uint256) {
        return $._dealExpiration == 0 ? DEFAULT_DEAL_PROPOSAL_EXPIRATION : $._dealExpiration;
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
            activationToleranceBps: uint16(s()._dealCompletionPadding),
            provider: deal.provider
        });
    }

    /**
     * @notice Ensures caller has admin or PoRep service role
     */
    function _ensurePoRepServiceOrAdmin() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(POREP_SERVICE_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, POREP_SERVICE_ROLE);
        }
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

    //  solhint-enable

    /**
     * @notice Ensures a deal exists
     * @param deal The deal
     */
    function _ensureDealExists(PoRepTypes.Deal memory deal) internal pure {
        if (deal.client == address(0)) revert DealDoesNotExist();
    }

    /**
     * @notice Ensures a deal is in the correct state
     * @param deal The deal
     * @param expectedState The expected state
     */
    function _ensureDealCorrectState(PoRepTypes.Deal memory deal, PoRepTypes.DealState expectedState) internal pure {
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
     * @param terms The terms for the deal
     */
    function _ensureCorrectTerms(SLITypes.DealTerms memory terms) internal pure {
        if (terms.durationDays < MIN_DEAL_DURATION_DAYS) {
            revert InvalidDealDuration();
        }
        if (terms.durationDays > MAX_DEAL_DURATION_DAYS) {
            revert InvalidDealDuration();
        }
        if (terms.durationDays % 30 != 0) {
            revert InvalidDealDuration();
        }
        if (terms.dealSizeBytes == 0) {
            revert InvalidDealSize();
        }
        uint256 minSectors = Math.ceilDiv(terms.dealSizeBytes, SECTOR_SIZE);
        uint256 totalPerMonth = terms.pricePerSectorPerMonth * minSectors;
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
     * @notice Ensures if allocations size is within padding
     * @param actualDealSize size of the deal
     * @param expectedDealSize expecetd size from proposal
     */
    function _ensureAllocationSizeWithinTolerance(uint256 actualDealSize, uint256 expectedDealSize) internal view {
        if (actualDealSize == 0) {
            revert InvalidAllocationSizeForDealCompletion();
        }

        uint256 padding = s()._dealCompletionPadding;
        uint256 delta =
            actualDealSize > expectedDealSize ? actualDealSize - expectedDealSize : expectedDealSize - actualDealSize;

        if (delta * 100 > expectedDealSize * padding) {
            revert InvalidAllocationSizeForDealCompletion();
        }
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Authorizes an upgrade
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

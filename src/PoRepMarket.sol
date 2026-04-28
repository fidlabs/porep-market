// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {IValidatorFactory} from "./interfaces/IValidatorFactory.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {IClient} from "./interfaces/IClient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SLITypes} from "./types/SLITypes.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PoRepMarket contract
 * @dev PoRepMarket contract is a contract that allows users to create and manage deal proposals for PoRep deals
 * @notice PoRepMarket contract
 */
contract PoRepMarket is IPoRepMarket, Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;
    /**
     * @notice role to manage contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

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
     * @notice Default number of epochs after which a deal proposal expires if not accepted
     * @dev 2 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 5_760 epochs
     */
    uint256 private constant EPOCHS_IN_TO_DAYS = 5_760;

    /**
     * @notice Maximum deal duration in days. See PoRepTypes.MAX_DEAL_DURATION_DAYS.
     * @dev Any provider limit above this is unreachable: PoRepMarket rejects deals with durationDays > 1278.
     */
    uint32 public constant MAX_DEAL_DURATION_DAYS = PoRepTypes.MAX_DEAL_DURATION_DAYS;

    /// @custom:storage-location erc7201:porepmarket.storage.DealProposalsStorage
    struct DealProposalsStorage {
        mapping(uint256 dealId => PoRepTypes.DealProposal) _dealProposals;
        mapping(uint256 dealId => address organization) _dealOrganization;
        mapping(PoRepTypes.DealState state => mapping(address organization => EnumerableSet.UintSet dealIds))
            _dealIdsByStateByOrganization;
        EnumerableSet.UintSet _dealIdsReadyForPayment;
        ISPRegistry _SPRegistryContract;
        IValidatorFactory _validatorFactoryContract;
        IClient _clientSmartContract;
        uint256 _dealIdCounter;
        uint256 _dealCompletionPadding;
        uint256 _dealProposalExpiration;
    }
    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.DealProposalsStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DEAL_PROPOSALS_STORAGE_LOCATION =
        0xea093611145db18b250f1cd58e07fc50de512902beb662a10f8e6d1dd55f6700;

    // solhint-disable-next-line use-natspec
    function _getDealProposalsStorage() private pure returns (DealProposalsStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := DEAL_PROPOSALS_STORAGE_LOCATION
        }
    }

    /**
     * @notice function to allow acess to storage
     * @return DealProposalsStorage storage struct
     */
    function s() private pure returns (DealProposalsStorage storage) {
        return _getDealProposalsStorage();
    }

    /**
     * @notice DealProposalCreated event
     * @param dealId The id of the deal proposal
     * @param client The address of the client
     * @param provider The address of the provider
     * @param requirements The SLI thresholds for the deal
     * @param manifestLocation The location of the manifest for the deal
     * @param totalDealSize The total size of the deal in bytes
     * @param proposedAtBlock The block number when the deal was proposed
     */
    event DealProposalCreated(
        uint256 indexed dealId,
        address indexed client,
        CommonTypes.FilActorId indexed provider,
        SLITypes.SLIThresholds requirements,
        string manifestLocation,
        uint256 totalDealSize,
        uint256 proposedAtBlock
    );

    /**
     * @notice DealAccepted event
     * @param dealId The id of the deal proposal
     * @param owner The address of the owner
     * @param provider The address of the provider
     */
    event DealAccepted(uint256 indexed dealId, address indexed owner, CommonTypes.FilActorId indexed provider);

    /**
     * @notice ValidatorUpdated event
     * @dev ValidatorUpdated event is emitted when a validator is updated
     * @param dealId The id of the deal proposal
     * @param validator The address of the validator
     */
    event ValidatorUpdated(uint256 indexed dealId, address indexed validator);

    /**
     * @notice RailIdUpdated event
     * @dev RailIdUpdated event is emitted when a rail id is updated
     * @param dealId The id of the deal proposal
     * @param railId The id of the rail
     */
    event RailIdUpdated(uint256 indexed dealId, uint256 indexed railId);

    /**
     * @notice DealCompleted event
     * @param dealId The id of the deal proposal
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
     * @param dealId The id of the deal proposal
     * @param terminator The address that terminated the deal
     * @param endEpoch The Filecoin epoch at which the deal was terminated
     */
    event DealTerminated(uint256 indexed dealId, address indexed terminator, uint256 indexed endEpoch);

    /**
     * @notice DealRejected event
     * @param dealId The id of the deal proposal
     * @param rejector The address of the rejector
     */
    event DealRejected(uint256 indexed dealId, address indexed rejector);

    /**
     * @notice ManifestLocationUpdated event
     * @dev ManifestLocationUpdated event is emitted when a manifest location is updated
     * @param dealId The id of the deal proposal
     * @param oldManifestLocation The old manifest location
     * @param newManifestLocation The new manifest location
     */
    event ManifestLocationUpdated(uint256 indexed dealId, string oldManifestLocation, string newManifestLocation);

    /**
     * @notice ClientSmartContractUpdated event
     * @dev ClientSmartContractUpdated event is emitted when the client smart contract is updated
     * @param clientSmartContract The address of the client smart contract
     */
    event ClientSmartContractUpdated(address indexed clientSmartContract);

    /**
     * @notice DealCompletionPaddingUpdated event
     * @dev DealCompletionPaddingUpdated event is emitted when the deal completion padding is updated
     * @param oldPadding old padding for the deal completion
     * @param newPadding new padding for the deal completion
     */
    event DealCompletionPaddingUpdated(uint256 indexed oldPadding, uint256 indexed newPadding);

    /**
     * @notice DealProposalExpired event
     * @dev DealProposalExpired event is emitted when a deal proposal expires
     * @param dealId The id of the deal proposal
     */
    event DealProposalExpired(uint256 indexed dealId);

    /**
     * @notice DealProposalExpirationUpdated event
     * @dev DealProposalExpirationUpdated event is emitted when the deal proposal expiration is updated
     * @param newDealProposalExpiration The new deal proposal expiration in epochs
     */
    event DealProposalExpirationUpdated(uint256 indexed newDealProposalExpiration);

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
     * @notice Error thrown when a deal proposal does not exist for a given id
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
     * @notice Error thrown when trying to set an invalid client smart contract address
     * @dev 0x39ee49ba
     */
    error InvalidClientSmartContractAddress();

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
     * @param dealId The id of the deal proposal
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
     * @notice Error thrown when trying to set a deal proposal expiration that is invalid
     * @dev 0x37f6e867
     */
    error InvalidDealProposalExpiration();

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
     */
    function initialize(address _admin, address _validatorFactory, address _spRegistry) public initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        DealProposalsStorage storage $ = s();
        $._validatorFactoryContract = IValidatorFactory(_validatorFactory);
        $._SPRegistryContract = ISPRegistry(_spRegistry);
        $._dealProposalExpiration = EPOCHS_IN_TO_DAYS;
    }

    /**
     * @notice Sets the client smart contract
     * @dev Sets the client smart contract
     * @param _clientSmartContract The address of the client smart contract
     */
    function setClientSmartContract(address _clientSmartContract) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_clientSmartContract == address(0)) revert InvalidClientSmartContractAddress();
        DealProposalsStorage storage $ = _getDealProposalsStorage();
        $._clientSmartContract = IClient(_clientSmartContract);
        emit ClientSmartContractUpdated(_clientSmartContract);
    }

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
    ) external {
        _ensureCorrectManifestLocation(manifestLocation);
        _ensureCorrectRequirements(requirements);
        _ensureCorrectTerms(terms);

        DealProposalsStorage storage $ = s();

        (CommonTypes.FilActorId provider, bool autoApprove, address organization) =
            $._SPRegistryContract.getProviderForDeal(requirements, terms);
        if (CommonTypes.FilActorId.unwrap(provider) == 0) {
            revert NoProviderFoundForDeal();
        }

        uint256 dealId = ++$._dealIdCounter;
        PoRepTypes.DealState initialState = autoApprove ? PoRepTypes.DealState.Accepted : PoRepTypes.DealState.Proposed;

        $._dealProposals[dealId] = PoRepTypes.DealProposal({
            dealId: dealId,
            client: msg.sender,
            provider: provider,
            requirements: requirements,
            terms: terms,
            validator: address(0),
            state: initialState,
            railId: 0,
            proposedAtBlock: block.number,
            manifestLocation: manifestLocation
        });

        emit DealProposalCreated(
            dealId, msg.sender, provider, requirements, manifestLocation, terms.dealSizeBytes, block.number
        );

        $._dealOrganization[dealId] = organization;
        $._dealIdsByStateByOrganization[initialState][organization].add(dealId);

        if (autoApprove) {
            emit DealAccepted(dealId, msg.sender, provider);
        }
    }

    /**
     * @notice Updates the validator for a deal proposal
     * @param dealId The id of the deal proposal
     */
    function updateValidator(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        PoRepTypes.DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, PoRepTypes.DealState.Accepted);

        if (dp.validator != address(0)) {
            revert ValidatorAlreadySet(dealId);
        }

        if (!$._validatorFactoryContract.isValidatorContract(msg.sender)) {
            revert NotTheRegisteredValidator(dealId, msg.sender);
        }

        dp.validator = msg.sender;
        emit ValidatorUpdated(dealId, msg.sender);
    }

    /**
     * @notice Updates the rail id for a deal proposal
     * @dev Updates the rail id for a deal proposal
     * @param dealId The id of the deal proposal
     * @param railId The id of the rail
     */
    function updateRailId(uint256 dealId, uint256 railId) external {
        DealProposalsStorage storage $ = s();
        PoRepTypes.DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, PoRepTypes.DealState.Accepted);

        if (dp.railId != 0) {
            revert RailIdAlreadySet();
        }

        if (railId == 0) {
            revert InvalidRailId();
        }

        if (dp.validator != msg.sender) {
            revert NotTheDealValidator(dealId, msg.sender);
        }

        dp.railId = railId;
        emit RailIdUpdated(dealId, railId);
    }

    /**
     * @notice Gets a deal proposal
     * @param dealId The id of the deal proposal
     * @return DealProposal The deal proposal
     */
    function getDealProposal(uint256 dealId) external view returns (PoRepTypes.DealProposal memory) {
        DealProposalsStorage storage $ = s();
        return $._dealProposals[dealId];
    }

    /**
     * @notice Accepts a deal
     * @param dealId The id of the deal proposal
     */
    function acceptDeal(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        PoRepTypes.DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, PoRepTypes.DealState.Proposed);

        if (!$._SPRegistryContract.isAuthorizedForProvider(msg.sender, dp.provider)) {
            revert NotTheControllingAddress(dealId, msg.sender, dp.provider);
        }

        _changeDealState(dealId, PoRepTypes.DealState.Accepted);
        emit DealAccepted(dealId, msg.sender, dp.provider);
    }

    /**
     * @notice Completes a deal
     * @param dealId The id of the deal proposal
     */
    function completeDeal(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        PoRepTypes.DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, PoRepTypes.DealState.Accepted);

        if (msg.sender != dp.client) revert NotTheClientAddress();
        uint256 allocatedSize = $._clientSmartContract.getSizeOfAllocations(dealId);
        uint256 proposedSize = dp.terms.dealSizeBytes;

        _ensureAllocationSizeWithinTolerance(allocatedSize, proposedSize);

        $._dealIdsReadyForPayment.add(dealId);
        $._SPRegistryContract.commitCapacity(dp.provider, proposedSize, allocatedSize);

        _changeDealState(dealId, PoRepTypes.DealState.Completed);
        emit DealCompleted(dealId, msg.sender, allocatedSize, dp.provider);
    }

    /**
     * @notice Terminate a deal
     * @dev Terminates a deal by setting the deal state to terminated
     * @param dealId The id of the deal proposal
     * @param terminator The address that terminated the deal
     * @param endEpoch The Filecoin epoch at which the deal was terminated
     */
    function terminateDeal(uint256 dealId, address terminator, uint256 endEpoch) external {
        DealProposalsStorage storage $ = _getDealProposalsStorage();
        PoRepTypes.DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, PoRepTypes.DealState.Completed);

        if (msg.sender != dp.validator || dp.validator == address(0)) {
            revert CallerIsNotValidator(dealId, msg.sender);
        }

        $._SPRegistryContract.releaseCapacity(dp.provider, dp.terms.dealSizeBytes);
        $._dealIdsReadyForPayment.remove(dealId);

        _changeDealState(dealId, PoRepTypes.DealState.Terminated);
        emit DealTerminated(dealId, terminator, endEpoch);
    }

    /**
     * @notice Rejects a deal
     * @param dealId The id of the deal proposal
     */
    function rejectDeal(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        PoRepTypes.DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, PoRepTypes.DealState.Proposed);

        if (
            msg.sender != dp.client && !$._SPRegistryContract.isAuthorizedForProvider(msg.sender, dp.provider)
                && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
        ) {
            revert NotTheClientOrStorageProviderOrAdmin(dealId, msg.sender);
        }

        $._SPRegistryContract.releasePendingCapacity(dp.provider, dp.terms.dealSizeBytes);
        _changeDealState(dealId, PoRepTypes.DealState.Rejected);
        emit DealRejected(dealId, msg.sender);
    }

    /**
     * @notice Rejects a deal in Accepted state before rail is set
     * @dev Only callable by the admin
     * @param dealId The id of the deal proposal
     */
    function rejectAcceptedDeal(uint256 dealId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DealProposalsStorage storage $ = s();
        PoRepTypes.DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, PoRepTypes.DealState.Accepted);

        if (dp.railId != 0) {
            revert DealNotRejectable(dealId);
        }

        $._SPRegistryContract.releasePendingCapacity(dp.provider, dp.terms.dealSizeBytes);
        _changeDealState(dealId, PoRepTypes.DealState.Rejected);
        emit DealRejected(dealId, msg.sender);
    }

    /**
     * @notice Iterates through deals in proposed state and rejects those that have expired
     * @dev A deal proposal is considered expired if it has been in the proposed state for more than the deal proposal expiration
     * @dev Deal proposal expiration is set to 5_760 epochs (2 days) by default, but can be updated by the admin using setDefaultDealProposalExpiration function
     */
    function rejectExpiredDeals() external {
        DealProposalsStorage storage $ = s();
        uint256 totalDeals = $._dealIdCounter;

        for (uint256 dealId = 1; dealId < totalDeals + 1; dealId++) {
            PoRepTypes.DealProposal storage dp = $._dealProposals[dealId];
            if (
                dp.state == PoRepTypes.DealState.Proposed
                    && block.number > dp.proposedAtBlock + $._dealProposalExpiration
            ) {
                $._SPRegistryContract.releasePendingCapacity(dp.provider, dp.terms.dealSizeBytes);
                _changeDealState(dealId, PoRepTypes.DealState.Rejected);
                emit DealProposalExpired(dealId);
            }
        }
    }

    /**
     * @notice Sets default deal proposal expiration
     * @param newDealProposalExpiration The new default deal proposal expiration in epochs
     */
    function setDefaultDealProposalExpiration(uint256 newDealProposalExpiration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDealProposalExpiration == 0) {
            revert InvalidDealProposalExpiration();
        }
        DealProposalsStorage storage $ = s();
        $._dealProposalExpiration = newDealProposalExpiration;

        emit DealProposalExpirationUpdated(newDealProposalExpiration);
    }

    /**
     * @notice Gets all completed deals
     * @return completedDeals Array of completed deal proposals
     */
    function getCompletedDeals() external view returns (PoRepTypes.DealProposal[] memory completedDeals) {
        DealProposalsStorage storage $ = s();
        uint256[] memory completedDealsIds = $._dealIdsReadyForPayment.values();
        completedDeals = new PoRepTypes.DealProposal[](completedDealsIds.length);
        uint256 dealCounter = 0;

        for (uint256 i = 0; i < completedDealsIds.length; i++) {
            PoRepTypes.DealProposal memory dp = $._dealProposals[completedDealsIds[i]];
            if (dp.state == PoRepTypes.DealState.Completed) {
                completedDeals[dealCounter] = dp;
                dealCounter++;
            }
        }

        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(completedDeals, dealCounter)
        }
    }

    /**
     * @notice Gets deals for a specific organization by state
     * @param organization The address of the organization
     * @param state The state of the deals to retrieve
     * @return deals Array of deal proposals for the organization in the specified state (from all providers associated with the organization)
     */
    function getDealsForOrganizationByState(address organization, PoRepTypes.DealState state)
        external
        view
        returns (PoRepTypes.DealProposal[] memory deals)
    {
        if (organization == address(0)) {
            revert InvalidOrganizationAddress();
        }

        DealProposalsStorage storage $ = s();
        EnumerableSet.UintSet storage ids = $._dealIdsByStateByOrganization[state][organization];

        uint256 lengthOfDeals = ids.length();
        deals = new PoRepTypes.DealProposal[](lengthOfDeals);

        for (uint256 i = 0; i < lengthOfDeals; i++) {
            deals[i] = $._dealProposals[ids.at(i)];
        }
    }

    /**
     * @notice Gets all deals
     * @return deals Array of all deal proposals
     */
    function getDeals() external view returns (PoRepTypes.DealProposal[] memory deals) {
        DealProposalsStorage storage $ = s();
        uint256 totalDeals = $._dealIdCounter;
        deals = new PoRepTypes.DealProposal[](totalDeals);

        for (uint256 deal = 0; deal < totalDeals; deal++) {
            deals[deal] = $._dealProposals[deal + 1];
        }
    }

    /**
     * @notice Gets the SPRegistry contract address from storage
     * @return ISPRegistry The SPRegistry contract address
     */
    function getSPRegistryContract() external view returns (address) {
        DealProposalsStorage storage $ = s();
        return address($._SPRegistryContract);
    }

    /**
     * @notice Gets the client smart contract address from storage
     * @return IClient The client smart contract address
     */
    function getClientSmartContract() external view returns (address) {
        DealProposalsStorage storage $ = s();
        return address($._clientSmartContract);
    }

    /**
     * @notice Gets the validator factory contract address from storage
     * @return IValidatorFactory The validator factory contract address
     */
    function getValidatorFactoryContract() external view returns (address) {
        DealProposalsStorage storage $ = s();
        return address($._validatorFactoryContract);
    }

    /**
     * @notice Retrieves the manifest location URL for a specific deal proposal
     * @param dealId The unique identifier of the deal proposal
     * @return manifestLocation The manifest location URL for a specific deal proposal
     */
    function getManifestLocation(uint256 dealId) external view returns (string memory manifestLocation) {
        DealProposalsStorage storage $ = s();
        PoRepTypes.DealProposal storage dealProposal = $._dealProposals[dealId];
        _ensureDealExists(dealProposal);
        return dealProposal.manifestLocation;
    }

    /**
     * @notice Retrieves the deal proposal expiration
     * @return dealProposalExpiration The deal proposal expiration in epochs
     */
    function getDealProposalExpiration() external view returns (uint256) {
        DealProposalsStorage storage $ = s();
        return $._dealProposalExpiration;
    }

    /**
     * @notice Updates the manifest location for a specific deal proposal
     * @dev Only callable by the admin
     * @param dealId The unique identifier of the deal proposal
     * @param newManifestLocation The new manifest location URL to be updated for the deal proposal
     */
    function updateManifestLocation(uint256 dealId, string calldata newManifestLocation)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        DealProposalsStorage storage $ = s();
        PoRepTypes.DealProposal storage dealProposal = $._dealProposals[dealId];
        _ensureDealExists(dealProposal);

        if (bytes(newManifestLocation).length == 0) {
            revert EmptyManifestLocation();
        }

        if (bytes(newManifestLocation).length > 2048) {
            revert TooLongManifestLocation();
        }

        string memory oldManifestLocation = dealProposal.manifestLocation;
        dealProposal.manifestLocation = newManifestLocation;
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

        DealProposalsStorage storage $ = s();
        uint256 oldPadding = $._dealCompletionPadding;
        $._dealCompletionPadding = padding;

        emit DealCompletionPaddingUpdated(oldPadding, padding);
    }

    /**
     * @notice Getter for deal completion padding
     * @return padding Current padding value
     */
    function getDealCompletionPadding() external view returns (uint256) {
        DealProposalsStorage storage $ = s();
        return $._dealCompletionPadding;
    }

    /**
     * @notice Changes the state of a deal
     * @param dealId The id of the deal
     * @param toState The new state of the deal
     */
    function _changeDealState(uint256 dealId, PoRepTypes.DealState toState) internal {
        DealProposalsStorage storage $ = s();
        PoRepTypes.DealProposal storage dp = $._dealProposals[dealId];
        address organization = $._dealOrganization[dealId];

        $._dealIdsByStateByOrganization[dp.state][organization].remove(dealId);
        $._dealIdsByStateByOrganization[toState][organization].add(dealId);
        dp.state = toState;
    }

    /**
     * @notice Ensures a deal exists
     * @param dealProposal The id of the deal proposal
     */
    function _ensureDealExists(PoRepTypes.DealProposal memory dealProposal) internal pure {
        if (dealProposal.dealId == 0) revert DealDoesNotExist();
    }

    /**
     * @notice Ensures a deal is in the correct state
     * @param dp The deal proposal
     * @param expectedState The expected state
     */
    function _ensureDealCorrectState(PoRepTypes.DealProposal memory dp, PoRepTypes.DealState expectedState)
        internal
        pure
    {
        if (dp.state != expectedState) revert DealNotInExpectedState(dp.dealId, dp.state, expectedState);
    }

    /**
     * @notice Ensures the requirements are correct
     * @param requirements The SLI thresholds for the deal
     */
    function _ensureCorrectRequirements(SLITypes.SLIThresholds calldata requirements) internal pure {
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
    function _ensureCorrectTerms(SLITypes.DealTerms calldata terms) internal pure {
        if (terms.durationDays == 0) {
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
    function _ensureAllocationSizeWithinTolerance(uint256 actualDealSize, uint256 expectedDealSize) internal {
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

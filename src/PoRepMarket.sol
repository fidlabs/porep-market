// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ISPRegistry} from "./interfaces/ISPRegistry.sol";
import {ValidatorFactory} from "./ValidatorFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SLITypes} from "./types/SLITypes.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title PoRepMarket contract
 * @dev PoRepMarket contract is a contract that allows users to create and manage deal proposals for PoRep deals
 * @notice PoRepMarket contract
 */
contract PoRepMarket is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;
    /**
     * @notice role to manage contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @custom:storage-location erc7201:porepmarket.storage.DealProposalsStorage
    struct DealProposalsStorage {
        mapping(uint256 dealId => DealProposal) _dealProposals;
        EnumerableSet.UintSet _dealIdsReadyForPayment;
        ISPRegistry _SPRegistryContract;
        ValidatorFactory _validatorFactoryContract;
        address _clientSmartContract;
        uint256 _dealIdCounter;
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
     * @notice DealState enum
     */
    enum DealState {
        Proposed,
        Accepted,
        Completed,
        Rejected
    }

    /**
     * @notice DealProposal struct
     */
    struct DealProposal {
        uint256 dealId;
        address client;
        CommonTypes.FilActorId provider;
        SLITypes.SLIThresholds requirements;
        SLITypes.DealTerms terms;
        address validator;
        DealState state;
        uint256 railId;
    }

    /**
     * @notice DealProposalCreated event
     * @param dealId The id of the deal proposal
     * @param client The address of the client
     * @param provider The address of the provider
     * @param requirements The SLI thresholds for the deal
     */
    event DealProposalCreated(
        uint256 indexed dealId,
        address indexed client,
        CommonTypes.FilActorId indexed provider,
        SLITypes.SLIThresholds requirements
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
     * @param provider The address of the provider
     */
    event DealCompleted(uint256 indexed dealId, address indexed client, CommonTypes.FilActorId indexed provider);

    /**
     * @notice DealRejected event
     * @param dealId The id of the deal proposal
     * @param rejector The address of the rejector
     */
    event DealRejected(uint256 indexed dealId, address indexed rejector);

    error NotTheRegisteredValidator(uint256 dealId, address validator);
    error NotTheClientSmartContract(uint256 dealId, address clientSmartContract);
    error NotTheControllingAddress(uint256 dealId, address msgSender, CommonTypes.FilActorId provider);
    error DealNotInExpectedState(uint256 dealId, DealState currentState, DealState expectedState);
    error DealDoesNotExist();
    error NotTheClientOrStorageProvider(uint256 dealId, address rejector);
    error NoProviderFoundForDeal();
    error ValidatorAlreadySet(uint256 dealId);
    error InvalidRetrievabilityPct(uint8 value);
    error InvalidIndexingPct(uint8 value);
    error InvalidRailId();
    error RailIdAlreadySet();

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
     * @param _clientSmartContract The address of the client smart contract
     */
    function initialize(address _admin, address _validatorFactory, address _spRegistry, address _clientSmartContract)
        public
        initializer
    {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        DealProposalsStorage storage $ = s();
        $._validatorFactoryContract = ValidatorFactory(_validatorFactory);
        $._SPRegistryContract = ISPRegistry(_spRegistry);
        $._clientSmartContract = _clientSmartContract;
    }

    /**
     * @notice Proposes a deal
     * @param requirements The SLI thresholds for the deal
     * @param terms The commercial terms for the deal
     */
    function proposeDeal(SLITypes.SLIThresholds calldata requirements, SLITypes.DealTerms calldata terms) external {
        if (requirements.retrievabilityPct > 100) {
            revert InvalidRetrievabilityPct(requirements.retrievabilityPct);
        }
        if (requirements.indexingPct > 100) {
            revert InvalidIndexingPct(requirements.indexingPct);
        }

        DealProposalsStorage storage $ = s();

        (CommonTypes.FilActorId provider, bool autoApprove) =
            $._SPRegistryContract.getProviderForDeal(requirements, terms);
        if (CommonTypes.FilActorId.unwrap(provider) == 0) {
            revert NoProviderFoundForDeal();
        }

        uint256 dealId = ++$._dealIdCounter;
        DealState initialState = autoApprove ? DealState.Accepted : DealState.Proposed;

        $._dealProposals[dealId] = DealProposal({
            dealId: dealId,
            client: msg.sender,
            provider: provider,
            requirements: requirements,
            terms: terms,
            validator: address(0),
            state: initialState,
            railId: 0
        });

        emit DealProposalCreated(dealId, msg.sender, provider, requirements);
        if (autoApprove) {
            emit DealAccepted(dealId, msg.sender, provider);
        }
    }

    /**
     * @notice Updates the validator and rail id for a deal proposal
     * @param dealId The id of the deal proposal
     */
    function updateValidator(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, DealState.Accepted);

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
        DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, DealState.Accepted);

        if (dp.railId != 0) {
            revert RailIdAlreadySet();
        }

        if (railId == 0) {
            revert InvalidRailId();
        }

        if (dp.validator != msg.sender) {
            revert NotTheRegisteredValidator(dealId, msg.sender);
        }

        dp.railId = railId;
        emit RailIdUpdated(dealId, railId);
    }

    /**
     * @notice Gets a deal proposal
     * @param dealId The id of the deal proposal
     * @return DealProposal The deal proposal
     */
    function getDealProposal(uint256 dealId) external view returns (DealProposal memory) {
        DealProposalsStorage storage $ = s();
        return $._dealProposals[dealId];
    }

    /**
     * @notice Accepts a deal
     * @param dealId The id of the deal proposal
     */
    function acceptDeal(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, DealState.Proposed);

        if (!$._SPRegistryContract.isAuthorizedForProvider(msg.sender, dp.provider)) {
            revert NotTheControllingAddress(dealId, msg.sender, dp.provider);
        }

        dp.state = DealState.Accepted;
        emit DealAccepted(dealId, msg.sender, dp.provider);
    }

    /**
     * @notice Completes a deal
     * @param dealId The id of the deal proposal
     */
    function completeDeal(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, DealState.Accepted);

        if (msg.sender != $._clientSmartContract) revert NotTheClientSmartContract(dealId, msg.sender);

        dp.state = DealState.Completed;
        $._dealIdsReadyForPayment.add(dealId);
        // TODO: actualSizeBytes should come from Client contract's allocation tracking
        // For now, use estimated size (no tolerance delta)
        $._SPRegistryContract.commitCapacity(dp.provider, dp.terms.dealSizeBytes, dp.terms.dealSizeBytes);

        emit DealCompleted(dealId, msg.sender, dp.provider);
    }

    /**
     * @notice Rejects a deal
     * @param dealId The id of the deal proposal
     */
    function rejectDeal(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, DealState.Proposed);

        if (msg.sender != dp.client && !$._SPRegistryContract.isAuthorizedForProvider(msg.sender, dp.provider)) {
            revert NotTheClientOrStorageProvider(dealId, msg.sender);
        }

        dp.state = DealState.Rejected;
        $._SPRegistryContract.releasePendingCapacity(dp.provider, dp.terms.dealSizeBytes);
        emit DealRejected(dealId, msg.sender);
    }

    /**
     * @notice Gets all completed deals
     * @return completedDeals Array of completed deal proposals
     */
    function getCompletedDeals() external view returns (DealProposal[] memory completedDeals) {
        DealProposalsStorage storage $ = s();
        uint256[] memory completedDealsIds = $._dealIdsReadyForPayment.values();
        completedDeals = new DealProposal[](completedDealsIds.length);
        uint256 dealCounter = 0;

        for (uint256 i = 0; i < completedDealsIds.length; i++) {
            DealProposal memory dp = $._dealProposals[completedDealsIds[i]];
            if (dp.state == DealState.Completed) {
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
     * @notice Ensures a deal exists
     * @param dealProposal The id of the deal proposal
     */
    function _ensureDealExists(DealProposal memory dealProposal) internal pure {
        if (dealProposal.dealId == 0) revert DealDoesNotExist();
    }

    /**
     * @notice Ensures a deal is in the correct state
     * @param dp The deal proposal
     * @param expectedState The expected state
     */
    function _ensureDealCorrectState(DealProposal memory dp, DealState expectedState) internal pure {
        if (dp.state != expectedState) revert DealNotInExpectedState(dp.dealId, dp.state, expectedState);
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Authorizes an upgrade
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

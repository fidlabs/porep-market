// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ISPRegistry} from "./interfaces/SPRegistry.sol";
import {IValidatorRegistry} from "./interfaces/ValidatorRegistry.sol";

/**
 * @title PoRepMarket contract
 * @dev PoRepMarket contract is a contract that allows users to create and manage deal proposals for PoRep deals
 * @notice PoRepMarket contract
 */
contract PoRepMarket is Initializable, AccessControlUpgradeable {
    /**
     * @notice dealProposals mapping
     * @dev dealProposals mapping is a mapping that contains the details of a deal proposal
     */
    mapping(uint256 dealId => DealProposal) public dealProposals;

    /**
     * @notice SPRegistry address
     * @dev SPRegistry address is the address of the SPRegistry contract
     */
    ISPRegistry public SPRegistryContract;

    /**
     * @notice ValidatorRegistry address
     * @dev ValidatorRegistry address is the address of the ValidatorRegistry contract
     */
    IValidatorRegistry public validatorRegistryContract;

    /**
     * @notice DealIdCounter
     * @dev DealIdCounter is the counter for the deal id
     */
    uint256 public dealIdCounter = 1;

    /**
     * @notice DealState enum
     * @dev DealState enum is an enum that contains the states of a deal
     */
    enum DealState {
        Proposed,
        Accepted,
        Completed,
        Rejected
    }

    /**
     * @notice DealProposal struct
     * @dev DealProposal struct is a struct that contains the details of a deal proposal
     */
    struct DealProposal {
        uint256 dealId;
        address client;
        CommonTypes.FilActorId provider;
        address SLC;
        address validator;
        DealState state;
        uint256 railId;
    }

    /**
     * @notice DealProposalCreated event
     * @dev DealProposalCreated event is emitted when a deal proposal is created
     * @param dealId The id of the deal proposal
     * @param client The address of the client
     * @param provider The address of the provider
     * @param SLC The address of the SLC
     */
    event DealProposalCreated(
        uint256 indexed dealId, address indexed client, CommonTypes.FilActorId indexed provider, address SLC
    );

    /**
     * @notice DealAccepted event
     * @dev DealAccepted event is emitted when a deal is accepted
     * @param dealId The id of the deal proposal
     * @param owner The address of the owner
     * @param provider The address of the provider
     */
    event DealAccepted(uint256 indexed dealId, address indexed owner, CommonTypes.FilActorId indexed provider);

    /**
     * @notice ValidatorAndRailIdUpdated event
     * @dev ValidatorAndRailIdUpdated event is emitted when a validator and rail id are updated
     * @param dealId The id of the deal proposal
     * @param validator The address of the validator
     * @param railId The id of the rail
     */
    event ValidatorAndRailIdUpdated(uint256 indexed dealId, address indexed validator, uint256 indexed railId);

    /**
     * @notice DealCompleted event
     * @dev DealCompleted event is emitted when a deal is completed
     * @param dealId The id of the deal proposal
     * @param client The address of the client
     * @param provider The address of the provider
     */
    event DealCompleted(uint256 indexed dealId, address indexed client, CommonTypes.FilActorId indexed provider);

    /**
     * @notice DealRejected event
     * @dev DealRejected event is emitted when a deal is rejected
     * @param dealId The id of the deal proposal
     * @param rejector The address of the rejector
     */
    event DealRejected(uint256 indexed dealId, address indexed rejector);

    error NotTheRegisteredValidator(uint256 dealId, address validator);
    error NotTheRegisteredClient(uint256 dealId, address client);
    error NotTheStorageProviderOwner(uint256 dealId, address owner, CommonTypes.FilActorId provider);
    error DealNotInExpectedState(uint256 dealId, DealState currentState, DealState expectedState);
    error DealAlreadyFinished(uint256 dealId, DealState state);
    error DealDoesNotExist(uint256 dealId);
    error NotTheClientOrStorageProvider(uint256 dealId, address rejector);
    error NoProviderFoundForDeal(uint256 expectedDealSize, uint256 priceForDeal, address SLC);

    /**
     * @notice Constructor
     * @dev Constructor disables initializers
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @dev Initializes the contract by setting a default admin role and a UUPS upgradeable role
     * @param _validatorRegistry The address of the validator registry
     * @param _spRegistry The address of the SP registry
     */
    function initialize(address _validatorRegistry, address _spRegistry) public initializer {
        __AccessControl_init();
        validatorRegistryContract = IValidatorRegistry(_validatorRegistry);
        SPRegistryContract = ISPRegistry(_spRegistry);
    }

    /**
     * @notice Proposes a deal
     * @dev Proposes a deal by creating a new deal proposal
     * @param expectedDealSize The expected size of the deal
     * @param priceForDeal The price for the deal
     * @param SLC The SLC address
     */
    function proposeDeal(uint256 expectedDealSize, uint256 priceForDeal, address SLC) external {
        CommonTypes.FilActorId provider = SPRegistryContract.getProviderForDeal(SLC, expectedDealSize, priceForDeal);
        if (CommonTypes.FilActorId.unwrap(provider) == 0) {
            revert NoProviderFoundForDeal(expectedDealSize, priceForDeal, SLC);
        }

        uint256 dealId = ++dealIdCounter;

        dealProposals[dealId] = DealProposal({
            dealId: dealId,
            client: msg.sender,
            provider: provider,
            SLC: SLC,
            validator: address(0),
            state: DealState.Proposed,
            railId: 0
        });

        emit DealProposalCreated(dealId, msg.sender, provider, SLC);
    }

    /**
     *
     * @notice Updates the validator and rail id for a deal proposal
     * @dev Updates the validator and rail id for a deal proposal
     * @param dealId The id of the deal proposal
     * @param railId The id of the rail
     */
    function updateValidatorAndRailId(uint256 dealId, uint256 railId) external {
        _ensureDealExists(dealId);

        if (!validatorRegistryContract.isCorrectValidator(msg.sender)) {
            revert NotTheRegisteredValidator(dealId, msg.sender);
        }

        DealProposal storage deal = dealProposals[dealId];
        deal.validator = msg.sender;
        deal.railId = railId;
        emit ValidatorAndRailIdUpdated(dealId, msg.sender, railId);
    }

    /**
     * @notice Gets a deal proposal
     * @dev Gets a deal proposal by deal id
     * @param dealId The id of the deal proposal
     * @return DealProposal The deal proposal
     */
    function getDealProposal(uint256 dealId) external view returns (DealProposal memory) {
        return dealProposals[dealId];
    }

    /**
     * @notice Accepts a deal
     * @dev Accepts a deal by setting the deal state to accepted
     * @param dealId The id of the deal proposal
     */
    function acceptDeal(uint256 dealId) external {
        _ensureDealExists(dealId);

        DealProposal storage deal = dealProposals[dealId];

        _ensureDealCorrectState(deal, DealState.Proposed);

        if (!SPRegistryContract.isStorageProviderOwner(msg.sender, deal.provider)) {
            revert NotTheStorageProviderOwner(dealId, msg.sender, deal.provider);
        }

        deal.state = DealState.Accepted;
        emit DealAccepted(dealId, msg.sender, deal.provider);
    }

    /**
     * @notice Completes a deal
     * @dev Completes a deal by setting the deal state to completed
     * @param dealId The id of the deal proposal
     */
    function completeDeal(uint256 dealId) external {
        _ensureDealExists(dealId);

        DealProposal storage deal = dealProposals[dealId];
        _ensureDealCorrectState(deal, DealState.Accepted);

        if (msg.sender != deal.client) revert NotTheRegisteredClient(dealId, msg.sender);

        deal.state = DealState.Completed;
        emit DealCompleted(dealId, msg.sender, deal.provider);
    }

    /**
     * @notice Accepts a deal
     * @dev Accepts a deal by setting the deal state to rejected
     * @param dealId The id of the deal proposal
     */
    function rejectDeal(uint256 dealId) external {
        _ensureDealExists(dealId);

        DealProposal storage deal = dealProposals[dealId];
        if (deal.state == DealState.Completed || deal.state == DealState.Rejected) {
            revert DealAlreadyFinished(dealId, deal.state);
        }

        if (msg.sender != deal.client && !SPRegistryContract.isStorageProviderOwner(msg.sender, deal.provider)) {
            revert NotTheClientOrStorageProvider(dealId, msg.sender);
        }

        deal.state = DealState.Rejected;
        emit DealRejected(dealId, msg.sender);
    }

    /**
     * @notice Ensures a deal exists
     * @dev Ensures a deal exists by checking if the deal id exists
     * @param dealId The id of the deal proposal
     */
    function _ensureDealExists(uint256 dealId) internal view {
        if (dealProposals[dealId].dealId == 0) revert DealDoesNotExist(dealId);
    }

    /**
     * @notice Ensures a deal is in the correct state
     * @dev Ensures a deal is in the correct state by checking if the deal state is the expected state
     * @param deal The deal proposal
     * @param expectedState The expected state
     */
    function _ensureDealCorrectState(DealProposal memory deal, DealState expectedState) internal pure {
        if (deal.state != expectedState) revert DealNotInExpectedState(deal.dealId, deal.state, expectedState);
    }
}

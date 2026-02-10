// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ISPRegistry} from "./interfaces/SPRegistry.sol";
import {ValidatorFactory} from "./ValidatorFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MinerUtils} from "./libs/MinerUtils.sol";

/**
 * @title PoRepMarket contract
 * @dev PoRepMarket contract is a contract that allows users to create and manage deal proposals for PoRep deals
 * @notice PoRepMarket contract
 */
contract PoRepMarket is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    /**
     * @notice role to manage contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // @custom:storage-location erc7201:porepmarket.storage.DealProposalsStorage
    struct DealProposalsStorage {
        mapping(uint256 dealId => DealProposal) _dealProposals;
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
     * @dev Returns the storage struct for the PoRepMarket contract.
     * @notice function to allow acess to storage for inheriting contracts
     * @return DealProposalsStorage storage struct
     */
    function s() internal pure returns (DealProposalsStorage storage) {
        return _getDealProposalsStorage();
    }

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
    error NotTheClientSmartContract(uint256 dealId, address clientSmartContract);
    error NotTheControllingAddress(uint256 dealId, address msgSender, CommonTypes.FilActorId provider);
    error DealNotInExpectedState(uint256 dealId, DealState currentState, DealState expectedState);
    error DealDoesNotExist();
    error NotTheClientOrStorageProvider(uint256 dealId, address rejector);
    error NoProviderFoundForDeal(uint256 expectedDealSize, uint256 priceForDeal, address SLC);
    error ValidatorAlreadySet(uint256 dealId);

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
     * @dev Proposes a deal by creating a new deal proposal
     * @param expectedDealSize The expected size of the deal
     * @param priceForDeal The price for the deal
     * @param SLC The SLC address
     */
    function proposeDeal(uint256 expectedDealSize, uint256 priceForDeal, address SLC) external {
        DealProposalsStorage storage $ = s();

        CommonTypes.FilActorId provider = $._SPRegistryContract.getProviderForDeal(SLC, expectedDealSize, priceForDeal);
        if (CommonTypes.FilActorId.unwrap(provider) == 0) {
            revert NoProviderFoundForDeal(expectedDealSize, priceForDeal, SLC);
        }

        uint256 dealId = ++$._dealIdCounter;

        $._dealProposals[dealId] = DealProposal({
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
        dp.railId = railId;
        emit ValidatorAndRailIdUpdated(dealId, msg.sender, railId);
    }

    /**
     * @notice Gets a deal proposal
     * @dev Gets a deal proposal by deal id
     * @param dealId The id of the deal proposal
     * @return DealProposal The deal proposal
     */
    function getDealProposal(uint256 dealId) external view returns (DealProposal memory) {
        DealProposalsStorage storage $ = s();
        return $._dealProposals[dealId];
    }

    /**
     * @notice Accepts a deal
     * @dev Accepts a deal by setting the deal state to accepted
     * @param dealId The id of the deal proposal
     */
    function acceptDeal(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, DealState.Proposed);

        if (!MinerUtils.isControllingAddress(dp.provider, msg.sender)) {
            revert NotTheControllingAddress(dealId, msg.sender, dp.provider);
        }

        dp.state = DealState.Accepted;
        emit DealAccepted(dealId, msg.sender, dp.provider);
    }

    /**
     * @notice Completes a deal
     * @dev Completes a deal by setting the deal state to completed
     * @param dealId The id of the deal proposal
     */
    function completeDeal(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, DealState.Accepted);

        if (msg.sender != $._clientSmartContract) revert NotTheClientSmartContract(dealId, msg.sender);

        dp.state = DealState.Completed;
        emit DealCompleted(dealId, msg.sender, dp.provider);
    }

    /**
     * @notice Rejects a deal
     * @dev Rejects a deal by setting the deal state to rejected
     * @param dealId The id of the deal proposal
     */
    function rejectDeal(uint256 dealId) external {
        DealProposalsStorage storage $ = s();
        DealProposal storage dp = $._dealProposals[dealId];

        _ensureDealExists(dp);
        _ensureDealCorrectState(dp, DealState.Proposed);

        if (msg.sender != dp.client && !$._SPRegistryContract.isStorageProviderOwner(msg.sender, dp.provider)) {
            revert NotTheClientOrStorageProvider(dealId, msg.sender);
        }

        dp.state = DealState.Rejected;
        emit DealRejected(dealId, msg.sender);
    }

    /**
     * @notice Gets all completed deals
     * @dev Iterates through all deals and returns only those with Completed state
     * @return completedDeals Array of completed deal proposals
     */
    function getCompletedDeals() external view returns (DealProposal[] memory completedDeals) {
        DealProposalsStorage storage $ = s();
        completedDeals = new DealProposal[]($._dealIdCounter);
        uint256 dealCounter = 0;

        for (uint256 i = 1; i < $._dealIdCounter + 1; i++) {
            if ($._dealProposals[i].state == DealState.Completed) {
                completedDeals[dealCounter] = $._dealProposals[i];
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
     * @dev Ensures a deal exists by checking if the deal id exists
     * @param dealProposal The id of the deal proposal
     */
    function _ensureDealExists(DealProposal memory dealProposal) internal pure {
        if (dealProposal.dealId == 0) revert DealDoesNotExist();
    }

    /**
     * @notice Ensures a deal is in the correct state
     * @dev Ensures a deal is in the correct state by checking if the deal state is the expected state
     * @param dp The deal proposal
     * @param expectedState The expected state
     */
    function _ensureDealCorrectState(DealProposal memory dp, DealState expectedState) internal pure {
        if (dp.state != expectedState) revert DealNotInExpectedState(dp.dealId, dp.state, expectedState);
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Authorizes an upgrade
     * @dev Authorizes an upgrade by checking if the caller has the upgrader role
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

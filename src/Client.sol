// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {DataCapAPI} from "filecoin-solidity/v0.8/DataCapAPI.sol";
import {DataCapTypes} from "filecoin-solidity/v0.8/types/DataCapTypes.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";
import {CBORDecoder} from "filecoin-solidity/v0.8/utils/CborDecode.sol";
import {VerifRegAPI} from "filecoin-solidity/v0.8/VerifRegAPI.sol";
import {UtilsHandlers} from "filecoin-solidity/v0.8/utils/UtilsHandlers.sol";
import {FilAddresses} from "filecoin-solidity/v0.8/utils/FilAddresses.sol";
import {AllocationResponseCbor} from "./lib/AllocationResponseCbor.sol";
import {PoRepMarket} from "./PoRepMarket.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMetaAllocator} from "./interfaces/IMetaAllocator.sol";

/**
 * @title Client
 * @notice Upgradeable contract for managing client allowances with role-based access control
 */
contract Client is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    using AllocationResponseCbor for DataCapTypes.TransferReturn;

    // @custom:storage-location erc7201:porepmarket.storage.ClientStorage
    struct ClientStorage {
        mapping(uint256 dealId => Deal deal) _deals;
        mapping(uint64 claim => bool isTerminated) _terminatedClaims;
        PoRepMarket _poRepMarketContract;
        IMetaAllocator _metaAllocatorContract;
    }

    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.ClientStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CLIENT_STORAGE_LOCATION =
        0x2b21b193d0cfac9c3a87c7f79dc75824e9816d95224b141c67bae6ec5621ea00;

    // solhint-disable-next-line use-natspec
    function _getClientStorage() private pure returns (ClientStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := CLIENT_STORAGE_LOCATION
        }
    }

    /**
     * @dev Returns the storage struct for the Client contract.
     * @notice function to allow acess to storage for inheriting contracts
     * @return ClientStorage storage struct
     */
    function s() internal pure returns (ClientStorage storage) {
        return _getClientStorage();
    }

    uint32 private constant _FRC46_TOKEN_TYPE = 2233613279; // method_hash!("FRC46") as u32;
    address private constant _DATACAP_ADDRESS = address(0xfF00000000000000000000000000000000000007);

    /**
     * @notice Upgradable role which allows for contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice The role to set terminated claims.
     */
    bytes32 public constant TERMINATION_ORACLE = keccak256("TERMINATION_ORACLE");

    // solhint-disable gas-indexed-events
    /**
     * @notice Emitted when DataCap is allocated to a SP.
     * @param client The address of the client.
     * @param amount The amount of DataCap allocated.
     */
    event DatacapSpent(address indexed client, uint256 amount);
    // solhint-enable gas-indexed-events

    /**
     * @notice Thrown if sender is not proposed client
     * @dev 0xda945128
     */
    error InvalidClient();

    /**
     * @notice Thrown if alloc provider is not proposed provider
     * @dev 0x7626db82
     */
    error InvalidProvider();

    /**
     * @notice Datacap transfer failed
     * @dev 0xef0ec453
     */
    error TransferFailed(int256 exitCode);

    /**
     * @notice Error thrown when claim extension request length is invalid
     * @dev 0x2edb7542
     */
    error InvalidClaimExtensionRequest();

    /**
     * @notice Error thrown when allocation request length is invalid
     * @dev 0x46ac3f35
     */
    error InvalidAllocationRequest();

    /**
     * @notice GetClaims call to VerifReg failed
     * @dev 0x9359037c
     */
    error GetClaimsCallFailed();

    /**
     * @notice Error thrown when operator_data length is invalid
     * @dev 0x5e9b2d53
     */
    error InvalidOperatorData();

    /**
     * @notice Thrown if trying to receive invalid token
     * @dev 0x6d5f86d5
     */
    error InvalidTokenReceived();

    /**
     * @notice Thrown if trying to receive unsupported token type
     * @dev 0xc6de466a
     */
    error UnsupportedType();

    /**
     * @notice Thrown if caller is invalid
     * @dev 0x16cece48
     */
    error InvalidCaller(address caller, address expectedCaller);

    /**
     * @notice Error thrown when deal state is invalid for transfer
     * @dev 0x804fe482
     */
    error InvalidDealStateForTransfer();

    /**
     * @notice Error thrown when validator is not set for the deal
     * @dev 0xcb304fac
     */
    error ValidatorNotSet(uint256 dealId);

    /**
     * @notice Error thrown when invalid admin address is provided
     * @dev 0x05bb467c
     */
    error InvalidAdminAddress();

    /**
     * @notice Error thrown when invalid termination oracle address is provided
     * @dev 0x2673f088
     */
    error InvalidTerminationOracleAddress();

    /**
     * @notice Error thrown when invalid PoRepMarket contract address is provided
     * @dev 0xcd041c17
     */
    error InvalidPoRepMarketContractAddress();

    /**
     * @notice Error thrown when invalid MetaAllocator contract address is provided
     * @dev 0x469f7a0a
     */
    error InvalidMetaAllocatorContractAddress();

    struct Deal {
        bool completed;
        address client;
        address validator;
        CommonTypes.FilActorId provider;
        uint256 dealId;
        uint256 railId;
        uint256 sizeOfAllocations;
        CommonTypes.FilActorId[] allocationIds;
    }

    struct ProviderAllocation {
        CommonTypes.FilActorId provider;
        uint64 size;
    }

    struct ProviderClaim {
        CommonTypes.FilActorId provider;
        CommonTypes.FilActorId claim;
    }

    /**
     * @notice Disabled constructor (proxy pattern)
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Contract initializator. Should be called during deployment
     * @param admin Contract owner
     * @param terminationOracle Address of the Termination Oracle
     * @param _poRepMarketContract Address of the PoRepMarket contract
     * @param _metaAllocatorContract Address of the MetaAllocator contract
     */
    function initialize(
        address admin,
        address terminationOracle,
        address _poRepMarketContract,
        address _metaAllocatorContract
    ) public initializer {
        _validateInitializeAddresses(admin, terminationOracle, _poRepMarketContract, _metaAllocatorContract);

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(TERMINATION_ORACLE, terminationOracle);

        ClientStorage storage $ = s();
        $._poRepMarketContract = PoRepMarket(_poRepMarketContract);
        $._metaAllocatorContract = IMetaAllocator(_metaAllocatorContract);
    }

    /**
     * @notice Validates the addresses passed to the initialize function
     * @param admin Contract owner
     * @param terminationOracle Address of the Termination Oracle
     * @param poRepMarketContract Address of the PoRepMarket contract
     * @param metaAllocatorContract Address of the MetaAllocator contract
     */
    function _validateInitializeAddresses(
        address admin,
        address terminationOracle,
        address poRepMarketContract,
        address metaAllocatorContract
    ) internal pure {
        if (admin == address(0)) {
            revert InvalidAdminAddress();
        }
        if (terminationOracle == address(0)) {
            revert InvalidTerminationOracleAddress();
        }
        if (poRepMarketContract == address(0)) {
            revert InvalidPoRepMarketContractAddress();
        }
        if (metaAllocatorContract == address(0)) {
            revert InvalidMetaAllocatorContractAddress();
        }
    }

    /**
     * @notice This function transfers DataCap tokens from the client to the storage provider
     * @dev This function can only be called by the client
     * @param params The parameters for the transfer
     * @param dealId The id of the deal
     * @param dealCompleted Whether the deal is completed
     */
    function transfer(DataCapTypes.TransferParams calldata params, uint256 dealId, bool dealCompleted)
        external
        nonReentrant
    {
        ClientStorage storage $ = s();
        if ($._deals[dealId].dealId == 0) {
            _registerDeal(dealId);
        }

        Deal storage deal = $._deals[dealId];
        if (deal.completed) {
            revert InvalidDealStateForTransfer();
        }

        if (msg.sender != deal.client) revert InvalidClient();
        (ProviderAllocation[] memory allocations, ProviderClaim[] memory claimExtensions) =
            _deserializeVerifregOperatorData(params.operator_data);

        uint256 sizeOfAllocations = _verifyAndRegisterAllocations(dealId, allocations);
        uint256 sizeOfClaims = _verifyAndRegisterClaimExtensions(dealId, claimExtensions);
        uint256 allocationsAndClaimsSize = sizeOfAllocations + sizeOfClaims;

        $._metaAllocatorContract
            .addVerifiedClient(FilAddresses.fromEthAddress(address(this)).data, allocationsAndClaimsSize);

        emit DatacapSpent(msg.sender, allocationsAndClaimsSize);
        /// @custom:oz-upgrades-unsafe-allow-reachable delegatecall
        (int256 exitCode, DataCapTypes.TransferReturn memory transferReturn) = DataCapAPI.transfer(params);
        if (exitCode != 0) {
            revert TransferFailed(exitCode);
        }
        if (allocations.length != 0) {
            CommonTypes.FilActorId[] memory allocationIds = transferReturn.decodeAllocationResponse();
            for (uint256 i = 0; i < allocationIds.length; i++) {
                CommonTypes.FilActorId allocId = allocationIds[i];
                deal.allocationIds.push(allocId);
            }
        }
        deal.sizeOfAllocations += allocationsAndClaimsSize;

        if (dealCompleted) {
            deal.completed = true;
            $._poRepMarketContract.completeDeal(dealId, deal.sizeOfAllocations);
        }
    }

    // solhint-disable func-name-mixedcase
    /**
     * @notice The handle_filecoin_method function is a universal entry point for calls
     * coming from built-in Filecoin actors. Datacap is an FRC-46 Token. Receiving FRC46
     * tokens requires implementing a Receiver Hook:
     * https://github.com/filecoin-project/FIPs/blob/master/FRCs/frc-0046.md#receiver-hook.
     * We use handle_filecoin_method to handle the receiver hook and make sure that the token
     * sent to our contract is freshly minted Datacap and reject all other calls and transfers.
     * @param method Method number
     * @param inputCodec Codec of the payload
     * @param params Params of the call
     * @return exitCode The exit code of the operation
     * @return codec The codec used for the response
     * @return data The response data
     * @dev Reverts if trying to send a unsupported token type
     * @dev Reverts if trying to receive invalid token
     */
    function handle_filecoin_method(uint64 method, uint64 inputCodec, bytes calldata params)
        external
        view
        returns (uint32 exitCode, uint64 codec, bytes memory data)
    {
        if (msg.sender != _DATACAP_ADDRESS) {
            revert InvalidCaller(msg.sender, _DATACAP_ADDRESS);
        }
        CommonTypes.UniversalReceiverParams memory receiverParams =
            UtilsHandlers.handleFilecoinMethod(method, inputCodec, params);
        if (receiverParams.type_ != _FRC46_TOKEN_TYPE) revert UnsupportedType();
        (uint256 tokenReceivedLength,) = CBORDecoder.readFixedArray(receiverParams.payload, 0);
        if (tokenReceivedLength != 6) revert InvalidTokenReceived();
        exitCode = 0;
        codec = 0;
        data = "";
    }

    // solhint-disable function-max-lines
    /**
     * @notice Deserialize Verifreg Operator Data.
     * @param cborData The cbor encoded operator data.
     * @return allocations Array of provider allocations.
     * @return claimExtensions Array of provider claims.
     */
    function _deserializeVerifregOperatorData(bytes memory cborData)
        internal
        pure
        returns (ProviderAllocation[] memory allocations, ProviderClaim[] memory claimExtensions)
    {
        uint256 resultLength;
        uint64 provider;
        uint256 byteIdx = 0;

        (resultLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
        if (resultLength != 2) revert InvalidOperatorData();

        {
            uint64 size;
            (resultLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
            allocations = new ProviderAllocation[](resultLength);
            for (uint256 i = 0; i < resultLength; i++) {
                uint256 allocationRequestLength;
                (allocationRequestLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);

                if (allocationRequestLength != 6) {
                    revert InvalidAllocationRequest();
                }

                {
                    (provider, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
                    allocations[i].provider = CommonTypes.FilActorId.wrap(provider);
                }
                // slither-disable-start unused-return
                (, byteIdx) = CBORDecoder.readBytes(cborData, byteIdx); // data (CID)
                {
                    (size, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
                    allocations[i].size = size;
                }
                (, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx); // termMin
                (, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx); // termMax
                (, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx); // expiration
                // slither-disable-end unused-return
            }
        }
        {
            uint64 claimId;
            (resultLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
            claimExtensions = new ProviderClaim[](resultLength);
            for (uint256 i = 0; i < resultLength; i++) {
                uint256 claimExtensionRequestLength;
                (claimExtensionRequestLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);

                if (claimExtensionRequestLength != 3) {
                    revert InvalidClaimExtensionRequest();
                }

                (provider, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
                (claimId, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
                // slither-disable-start unused-return
                (, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx);
                // slither-disable-end unused-return

                claimExtensions[i].provider = CommonTypes.FilActorId.wrap(provider);
                claimExtensions[i].claim = CommonTypes.FilActorId.wrap(claimId);
            }
        }
    }

    /**
     * @notice Verifies and registers a deal.
     * @param dealId The deal id.
     */
    function _registerDeal(uint256 dealId) internal {
        ClientStorage storage $ = s();

        PoRepTypes.DealProposal memory proposal = $._poRepMarketContract.getDealProposal(dealId);

        if (proposal.client != msg.sender) {
            revert InvalidClient();
        }

        if (proposal.state != PoRepTypes.DealState.Accepted) {
            revert InvalidDealStateForTransfer();
        }

        Deal storage deal = $._deals[dealId];
        deal.client = proposal.client;
        deal.provider = proposal.provider;
        deal.dealId = proposal.dealId;
        deal.validator = proposal.validator;
        deal.railId = proposal.railId;
        deal.completed = false;
    }

    /**
     * @notice Verifies and registers allocations.
     * @param dealId The deal id.
     * @param allocations The array of provider allocations.
     * @return sizeOfAllocations The total size of allocations
     */
    function _verifyAndRegisterAllocations(uint256 dealId, ProviderAllocation[] memory allocations)
        internal
        view
        returns (uint256 sizeOfAllocations)
    {
        Deal storage deal = _getStorageDeal(dealId);
        for (uint256 i = 0; i < allocations.length; i++) {
            ProviderAllocation memory alloc = allocations[i];
            if (CommonTypes.FilActorId.unwrap(alloc.provider) != CommonTypes.FilActorId.unwrap(deal.provider)) {
                revert InvalidProvider();
            }

            sizeOfAllocations += alloc.size;
        }
    }

    // solhint-disable function-max-lines
    /**
     * @notice Verifies and registers claim extensions.
     * @param dealId The id of the deal.
     * @param claimExtensions The array of provider claims.
     * @return sizeOfClaims The total size of claims
     */
    function _verifyAndRegisterClaimExtensions(uint256 dealId, ProviderClaim[] memory claimExtensions)
        internal
        returns (uint256 sizeOfClaims)
    {
        Deal storage deal = _getStorageDeal(dealId);
        CommonTypes.FilActorId[] memory claimIds = new CommonTypes.FilActorId[](claimExtensions.length);
        CommonTypes.FilActorId dealProvider = deal.provider;

        for (uint256 i = 0; i < claimExtensions.length; i++) {
            ProviderClaim memory claim = claimExtensions[i];

            if (CommonTypes.FilActorId.unwrap(claim.provider) != CommonTypes.FilActorId.unwrap(dealProvider)) {
                revert InvalidProvider();
            }

            claimIds[i] = claim.claim;
        }
        {
            int256 exitCode;
            VerifRegTypes.GetClaimsReturn memory claimsDetails;
            VerifRegTypes.GetClaimsParams memory getClaimsParams =
                VerifRegTypes.GetClaimsParams({provider: dealProvider, claim_ids: claimIds});
            (exitCode, claimsDetails) = VerifRegAPI.getClaims(getClaimsParams);
            if (exitCode != 0 || claimsDetails.batch_info.success_count != claimIds.length) {
                revert GetClaimsCallFailed();
            }

            for (uint256 i = 0; i < claimsDetails.claims.length; i++) {
                VerifRegTypes.Claim memory claim = claimsDetails.claims[i];
                deal.allocationIds.push(claimIds[i]);
                sizeOfClaims += claim.size;
            }
        }
    }

    /**
     * @notice custom getter to retrieve allocation ids per client and provider
     * @param dealId the id of the deal
     * @return allocationIds the allocation ids for the client and provider
     */
    function getClientAllocationIdsPerDeal(uint256 dealId) external view returns (CommonTypes.FilActorId[] memory) {
        return s()._deals[dealId].allocationIds;
    }

    /**
     * @notice custom getter to check if claim is terminated
     * @param claimId the id of the claim
     * @return isTerminated whether the claim is terminated
     */
    function terminatedClaims(uint64 claimId) external view returns (bool) {
        return s()._terminatedClaims[claimId];
    }

    /**
     * @notice Internal function used to retrieve a storage deal
     * @param dealId The id of the deal
     * @return deal The storage deal
     */
    function _getStorageDeal(uint256 dealId) internal view returns (Deal storage) {
        return s()._deals[dealId];
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Internal function used to implement new logic and check if upgrade is authorized
     * @dev Will revert (reject upgrade) if upgrade isn't called by UPGRADER_ROLE
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /**
     * @notice Checks if the total active data size for the client with the specified provider matches the expected size
     * @dev This function can only be called by the validator of the deal
     * @param dealId The id of the deal
     * @return totalSizePerSp The total active data size for the client with the specified provider
     */
    function isDataSizeMatching(uint256 dealId) external nonReentrant returns (bool) {
        Deal storage deal = _getStorageDeal(dealId);
        ClientStorage storage $ = s();

        if (deal.validator == address(0)) {
            revert ValidatorNotSet(dealId);
        }

        if (msg.sender != deal.validator) {
            revert InvalidCaller(msg.sender, deal.validator);
        }

        CommonTypes.FilActorId[] memory ids = deal.allocationIds;

        VerifRegTypes.GetClaimsParams memory getClaimsParams =
            VerifRegTypes.GetClaimsParams({provider: deal.provider, claim_ids: ids});

        (int256 getClaimsExitCode, VerifRegTypes.GetClaimsReturn memory getClaimsResult) =
            VerifRegAPI.getClaims(getClaimsParams);

        if (getClaimsExitCode != 0) revert GetClaimsCallFailed();

        uint256 activeSize = 0;
        uint256 failIterator = 0;
        int64 currentEpoch = int64(uint64(block.number));
        uint256[] memory toDelete = new uint256[](ids.length);
        uint256 deleteCount = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            if (
                getClaimsResult.batch_info.fail_codes.length > 0
                    && getClaimsResult.batch_info.fail_codes.length > failIterator
                    && i == getClaimsResult.batch_info.fail_codes[failIterator].idx
            ) {
                ++failIterator;
                continue;
            }
            VerifRegTypes.Claim memory claim = getClaimsResult.claims[i - failIterator];

            bool expired =
                (CommonTypes.ChainEpoch.unwrap(claim.term_start) + CommonTypes.ChainEpoch.unwrap(claim.term_max))
                    < currentEpoch;

            uint64 id = CommonTypes.FilActorId.unwrap(ids[i]);

            if (expired || $._terminatedClaims[id]) {
                toDelete[deleteCount++] = i;
                continue;
            }

            activeSize += claim.size;
        }

        for (uint256 i = deleteCount; i > 0; --i) {
            uint256 idx = toDelete[i - 1];
            _deleteDealAllocationIdByIndex(deal, idx);
        }

        return activeSize == deal.sizeOfAllocations;
    }

    /**
     * @notice Internal function to delete an allocation ID from a deal by its index
     * @param deal The storage reference to the deal
     * @param index The index of the allocation ID to delete
     */
    function _deleteDealAllocationIdByIndex(Deal storage deal, uint256 index) internal {
        CommonTypes.FilActorId[] storage ids = deal.allocationIds;
        uint256 last = ids.length - 1;
        if (index != last) ids[index] = ids[last];
        ids.pop();
    }

    /**
     * @notice Marks the given claims as terminated early.
     * @dev Only callable by TERMINATION_ORACLE role.
     * @param claims An array of claim IDs to mark as terminated.
     */
    function claimsTerminatedEarly(uint64[] calldata claims) external onlyRole(TERMINATION_ORACLE) {
        ClientStorage storage $ = s();
        for (uint256 i = 0; i < claims.length; ++i) {
            $._terminatedClaims[claims[i]] = true;
        }
    }
}

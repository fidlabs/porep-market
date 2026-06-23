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
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {IDataCapEvidenceAdapter} from "./interfaces/IDataCapEvidenceAdapter.sol";
import {DealState} from "./types/DealState.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMetaAllocator} from "./interfaces/IMetaAllocator.sol";
import {EvidenceTypes} from "./types/EvidenceTypes.sol";
import {SharedTypes} from "./types/SharedTypes.sol";

/**
 * @title DataCapEvidenceAdapter
 * @notice Contract for handling DataCap evidence interactions
 */
contract DataCapEvidenceAdapter is
    IDataCapEvidenceAdapter,
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using AllocationResponseCbor for DataCapTypes.TransferReturn;

    // @custom:storage-location erc7201:porepmarket.storage.DataCapEvidenceAdapterStorage
    struct DataCapEvidenceAdapterStorage {
        mapping(uint256 dealId => Deal deal) _deals;
        mapping(uint64 claim => bool isTerminated) _terminatedClaims;
        IPoRepMarket _poRepMarketContract;
        IMetaAllocator _metaAllocatorContract;
        bool _operational;
    }

    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.DataCapEvidenceAdapterStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DATA_CAP_EVIDENCE_ADAPTER_STORAGE_LOCATION =
        0x8787a3d80201bec4a7dca8768c3f8a033ced49efe06774bc65390680a2a0e900;

    // solhint-disable-next-line use-natspec
    function _getDataCapEvidenceAdapterStorage() private pure returns (DataCapEvidenceAdapterStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := DATA_CAP_EVIDENCE_ADAPTER_STORAGE_LOCATION
        }
    }

    /**
     * @dev Returns the storage struct for the DataCapEvidenceAdapter contract.
     * @notice function to allow acess to storage for inheriting contracts
     * @return DataCapEvidenceAdapterStorage storage struct
     */
    function s() internal pure returns (DataCapEvidenceAdapterStorage storage) {
        return _getDataCapEvidenceAdapterStorage();
    }

    uint32 private constant _FRC46_TOKEN_TYPE = 2233613279; // method_hash!("FRC46") as u32;
    address private constant _DATACAP_ADDRESS = address(0xfF00000000000000000000000000000000000007);

    /**
     * @notice Upgradable role which allows for contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice Role allowed to rescue broken allocation tracking for existing deals.
     */
    bytes32 public constant RESCUE_ROLE = keccak256("RESCUE_ROLE");

    /**
     * @notice The role to set terminated claims.
     */
    bytes32 public constant TERMINATION_ORACLE = keccak256("TERMINATION_ORACLE");

    /**
     * @notice Size of 32GiB sector in bytes
     * @dev 32 GiB = 32 * 1024 * 1024 * 1024 bytes
     */
    uint256 private constant SECTOR_SIZE = 32 * 1024 * 1024 * 1024;

    /**
     * @notice Minimum allowed allocation claim window in epochs.
     * @dev 4 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 11_520 epochs
     */
    uint64 internal constant MIN_CLAIM_WINDOW_EPOCHS = 11_520;

    // solhint-disable gas-indexed-events
    /**
     * @notice Emitted when DataCap is allocated to a SP.
     * @param client The address of the client.
     * @param amount The amount of DataCap allocated.
     */
    event DatacapSpent(address indexed client, uint256 amount);

    /**
     * @notice Emitted when tracked allocations are rescued for a deal.
     * @param dealId The rescued deal id.
     * @param rescuer The account that executed the rescue.
     * @param totalSize The total rescued allocation size.
     */
    event DealAllocationsRescued(uint256 indexed dealId, address indexed rescuer, uint256 totalSize);

    /**
     * @notice Emitted when the adapter is permanently non-operational
     * @param account The account that set the adapter non-operational
     * @param setAtBlock The block number at which the adapter was set non-operational
     */
    event AdapterNonOperational(address indexed account, uint256 setAtBlock);

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
     * @notice Error thrown when an allocation claim window is too small.
     * @param termMin The requested minimum claim term.
     * @param termMax The requested maximum claim term.
     * @dev 0x5e1fe755
     */
    error InvalidClaimWindow(int64 termMin, int64 termMax);

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

    /**
     * @notice Error thrown when rail id is invalid
     * @dev 0x9b721aad
     */
    error InvalidRailId();

    /**
     * @notice Error thrown when allocation size exceeds sector size
     * @dev 0x5f804a88
     */
    error InvalidAllocationSize();

    /**
     * @notice Error thrown when limit is invalid
     * @dev 0xe55fb509
     */
    error InvalidLimit();

    /**
     * @notice Error thrown when caller is not PoRepMarket contract
     * @dev 0x86807850
     */
    error CallerIsNotPoRepMarket();

    /**
     * @notice Error indicating that an invalid deal ID was provided
     * @dev 0xb06db32a
     */
    error InvalidDealId();

    /**
     * @notice Error indicating batch size is invalid
     * @dev 0x7862e959
     */
    error InvalidBatchSize();

    /**
     * @notice Error thrown when the adapter has already been set non-operational
     * @dev 0xcdc6b3ae
     */
    error AdapterAlreadyNonOperational();

    /**
     * @notice Error thrown when the adapter is non-operational and can no longer process new evidence
     * @dev 0x55637dd8
     */
    error AdapterNotOperational();

    struct Deal {
        // Deprecated; retained to preserve the deployed storage layout.
        bool completed;
        address client;
        address validator;
        CommonTypes.FilActorId provider;
        uint256 dealId;
        uint256 railId;
        uint256 sizeOfAllocations;
        CommonTypes.FilActorId[] allocationIds;
        CommonTypes.FilActorId[] claimIds;
        uint256 claimedBytes;
    }

    struct ProviderAllocation {
        CommonTypes.FilActorId provider;
        uint64 size;
        int64 termMin;
        int64 termMax;
        int64 expiration;
    }

    struct ProviderClaim {
        CommonTypes.FilActorId provider;
        CommonTypes.FilActorId claim;
    }

    /**
     * @notice Modifier to check that the caller is the PoRepMarket contract before executing the function
     */
    modifier onlyPoRepMarket() {
        _onlyPoRepMarket();
        _;
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
        _grantRole(RESCUE_ROLE, admin);
        _grantRole(TERMINATION_ORACLE, terminationOracle);

        DataCapEvidenceAdapterStorage storage $ = s();
        $._poRepMarketContract = IPoRepMarket(_poRepMarketContract);
        $._metaAllocatorContract = IMetaAllocator(_metaAllocatorContract);
        $._operational = true;
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
     */
    function submitDataCapBatch(DataCapTypes.TransferParams calldata params, uint256 dealId) external nonReentrant {
        DataCapEvidenceAdapterStorage storage $ = s();
        PoRepTypes.Deal memory dealSnapshot = $._poRepMarketContract.getDeal(dealId);

        if ($._operational == false) {
            revert AdapterNotOperational();
        }

        if (dealSnapshot.state != DealState.ACCEPTED) {
            revert InvalidDealStateForTransfer();
        }

        if (msg.sender != dealSnapshot.client) {
            revert InvalidClient();
        }

        if ($._deals[dealId].dealId == 0) {
            _registerDeal(dealSnapshot);
        }

        Deal storage deal = $._deals[dealId];

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
    }

    /**
     * @notice Submit one bounded batch of adapter-specific evidence for a deal
     * @dev Only callable by the PoRepMarket contract
     * @dev `evidenceData` is opaque to PoRepMarket; the selected adapter defines,
     * decodes, and validates its contents
     * @param context Activation context for the deal and market state
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Activation decision for the submitted evidence batch
     */
    function submitEvidenceBatch(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        nonReentrant
        onlyPoRepMarket
        returns (SharedTypes.ActivationDecision memory decision)
    {
        uint256 batchSize = abi.decode(evidenceData, (uint256));
        if (batchSize == 0) revert InvalidBatchSize();

        Deal storage deal = _getStorageDeal(context.dealId);
        CommonTypes.FilActorId[] memory batch = _loadAllocationBatch(deal.allocationIds, batchSize);
        if (batch.length == 0) {
            return SharedTypes.ActivationDecision({coveredBytes: 0, reasonCode: 0, result: 0});
        }

        VerifRegTypes.GetClaimsParams memory getClaimsParams =
            VerifRegTypes.GetClaimsParams({provider: deal.provider, claim_ids: batch});
        (int256 exitCode, VerifRegTypes.GetClaimsReturn memory result) = VerifRegAPI.getClaims(getClaimsParams);
        if (exitCode != 0) revert GetClaimsCallFailed();

        uint256 coveredBytes = 0;
        uint256 failPtr = result.batch_info.fail_codes.length;
        uint256 claimPtr = result.claims.length;

        for (uint256 i = batch.length; i > 0; i--) {
            uint256 idx = i - 1;
            if (failPtr > 0 && result.batch_info.fail_codes[failPtr - 1].idx == idx) {
                failPtr--;
                continue;
            }
            claimPtr--;
            deal.claimIds.push(batch[idx]);
            coveredBytes += result.claims[claimPtr].size;
            _deleteDealAllocationIdByIndex(deal, idx);
        }

        deal.claimedBytes += coveredBytes;

        return SharedTypes.ActivationDecision({coveredBytes: coveredBytes, reasonCode: 0, result: 0});
    }

    // solhint-disable no-unused-vars
    /// Note: this function is only added for testing purpose, will be implemented in the future
    /**
     * @notice Return the adapter's activation decision after submitted evidence
     * covers enough bytes for the frozen deal
     * @dev This function does not set payment terms; PoRepMarket consumes the
     * returned covered bytes and derives committed bytes, billed units, service
     * start/end, rail ceiling, and deal state
     * @param context Activation context for the deal and market state
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Activation decision for the provided evidence
     */
    function activateEvidence(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        pure
        returns (SharedTypes.ActivationDecision memory decision)
    {
        return SharedTypes.ActivationDecision({coveredBytes: 0, reasonCode: 0, result: 0});
    }

    /// Note: this function is only added for testing purpose, will be implemented in the future
    /**
     * @notice Refresh current evidence health from adapter-specific source data
     * @dev The caller supplies only the bounded batch to check; the adapter
     * verifies state itself before updating stored active covered bytes
     * @param context Activation context for the deal and market state
     * @param evidenceData Bounded batch of evidence used to verify current status
     * @return status Updated evidence status
     */
    function refreshEvidenceStatus(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        pure
        returns (SharedTypes.EvidenceStatus memory status)
    {
        return SharedTypes.EvidenceStatus({
            activeCoveredBytes: 0, lastEvidenceRefreshEpoch: CommonTypes.ChainEpoch.wrap(0), reasonCode: 0, result: 0
        });
    }

    /// Note: this function is only added for testing purpose, will be implemented in the future
    /**
     * @notice Read current evidence status from adapter storage only
     * @dev Must not call Filecoin actors or refresh live state
     * @param context Activation context for the deal and market state
     * @return status Current adapter-local evidence status
     */
    function currentEvidenceStatus(SharedTypes.ActivationContext calldata context)
        external
        pure
        returns (SharedTypes.EvidenceStatus memory status)
    {
        return SharedTypes.EvidenceStatus({
            activeCoveredBytes: 0, lastEvidenceRefreshEpoch: CommonTypes.ChainEpoch.wrap(0), reasonCode: 0, result: 0
        });
    }

    /**
     * @notice Returns whether the adapter can still process new evidence
     * @dev Returns false when the adapter is no longer operational, for example
     * when the DataCap adapter can no longer accept allocations or claims
     * @return True if the adapter can process new evidence, false if it is no longer operational
     */
    function isOperational() external view returns (bool) {
        return s()._operational;
    }

    // solhint-disable function-max-lines
    /**
     * @notice Replaces all broken tracked allocations for an active existing deal.
     * @param dealId The id of the deal to rescue.
     * @param params The DataCap transfer parameters that create replacement allocations.
     */
    function rescueDealAllocations(uint256 dealId, DataCapTypes.TransferParams calldata params)
        external
        nonReentrant
        onlyRole(RESCUE_ROLE)
    {
        DataCapEvidenceAdapterStorage storage $ = s();
        PoRepTypes.Deal memory dealSnapshot = $._poRepMarketContract.getDeal(dealId);
        if (dealSnapshot.state != DealState.ACTIVE || $._deals[dealId].dealId == 0) {
            revert InvalidDealStateForTransfer();
        }

        Deal storage deal = $._deals[dealId];
        CommonTypes.FilActorId[] memory oldAllocationIds = deal.allocationIds;
        if (oldAllocationIds.length == 0 || params.amount.neg) revert InvalidAllocationRequest();

        if (
            keccak256(params.to.data)
                != keccak256(FilAddresses.fromActorID(CommonTypes.FilActorId.unwrap(VerifRegTypes.ActorID)).data)
        ) {
            revert InvalidAllocationRequest();
        }

        (ProviderAllocation[] memory allocations, ProviderClaim[] memory claimExtensions) =
            _deserializeVerifregOperatorData(params.operator_data);
        if (allocations.length != oldAllocationIds.length || claimExtensions.length != 0) {
            revert InvalidAllocationRequest();
        }

        uint256 totalSize;
        for (uint256 i = 0; i < allocations.length; i++) {
            ProviderAllocation memory alloc = allocations[i];
            if (CommonTypes.FilActorId.unwrap(alloc.provider) != CommonTypes.FilActorId.unwrap(deal.provider)) {
                revert InvalidProvider();
            }
            _ensureValidAllocationTerms(alloc.termMin, alloc.termMax, alloc.expiration);
            if (alloc.size == 0) revert InvalidAllocationRequest();
            if (alloc.size > SECTOR_SIZE) revert InvalidAllocationSize();

            totalSize += alloc.size;
        }

        if (
            totalSize != deal.sizeOfAllocations
                || keccak256(params.amount.val) != keccak256(abi.encodePacked(totalSize * 1 ether))
        ) {
            revert InvalidAllocationRequest();
        }

        $._metaAllocatorContract
            .addVerifiedClient(FilAddresses.fromEthAddress(address(this)).data, deal.sizeOfAllocations);
        emit DatacapSpent(deal.client, deal.sizeOfAllocations);

        /// @custom:oz-upgrades-unsafe-allow-reachable delegatecall
        (int256 exitCode, DataCapTypes.TransferReturn memory transferReturn) = DataCapAPI.transfer(params);
        if (exitCode != 0) {
            revert TransferFailed(exitCode);
        }

        CommonTypes.FilActorId[] memory newAllocationIds = transferReturn.decodeAllocationResponse();
        if (newAllocationIds.length != oldAllocationIds.length) {
            revert InvalidAllocationRequest();
        }
        delete deal.allocationIds;
        for (uint256 i = 0; i < newAllocationIds.length; ++i) {
            deal.allocationIds.push(newAllocationIds[i]);
        }

        emit DealAllocationsRescued(dealId, msg.sender, totalSize);
    }

    // solhint-enable function-max-lines

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
                (allocations[i].termMin, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx);
                (allocations[i].termMax, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx);
                (allocations[i].expiration, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx);
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
     * @param dealSnapshot The deal snapshot.
     */
    function _registerDeal(PoRepTypes.Deal memory dealSnapshot) internal {
        DataCapEvidenceAdapterStorage storage $ = s();

        if (dealSnapshot.railId == 0) {
            revert InvalidRailId();
        }

        Deal storage deal = $._deals[dealSnapshot.dealId];
        deal.client = dealSnapshot.client;
        deal.provider = dealSnapshot.provider;
        deal.dealId = dealSnapshot.dealId;
        deal.validator = dealSnapshot.validator;
        deal.railId = dealSnapshot.railId;
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

            _ensureValidAllocationTerms(alloc.termMin, alloc.termMax, alloc.expiration);
            if (alloc.size == 0) {
                revert InvalidAllocationRequest();
            }

            if (alloc.size > SECTOR_SIZE) {
                revert InvalidAllocationSize();
            }

            sizeOfAllocations += alloc.size;
        }
    }

    /**
     * @notice Validates allocation term bounds.
     * @param termMin The requested minimum claim term.
     * @param termMax The requested maximum claim term.
     * @param expiration The allocation expiration epoch.
     */
    function _ensureValidAllocationTerms(int64 termMin, int64 termMax, int64 expiration) internal view {
        if (int256(termMax) < int256(termMin) + int256(uint256(MIN_CLAIM_WINDOW_EPOCHS))) {
            revert InvalidClaimWindow(termMin, termMax);
        }
        if (expiration < int64(uint64(block.number))) {
            revert InvalidAllocationRequest();
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
     * @notice Copies up to `batchSize` allocation ids from the front of a deal's allocation list
     * @param allocationIds The deal's stored allocation ids
     * @param batchSize The maximum number of ids to copy
     * @return batch A memory array with the leading ids
     */
    function _loadAllocationBatch(CommonTypes.FilActorId[] storage allocationIds, uint256 batchSize)
        internal
        view
        returns (CommonTypes.FilActorId[] memory batch)
    {
        uint256 batchCount = batchSize > allocationIds.length ? allocationIds.length : batchSize;
        batch = new CommonTypes.FilActorId[](batchCount);
        for (uint256 i = 0; i < batchCount; ++i) {
            batch[i] = allocationIds[i];
        }
    }

    /**
     * @notice getter to retrieve allocation ids for a deal with pagination
     * @param dealId the id of the deal
     * @param offset index to start from
     * @param limit max number of ids to return
     * @return ids allocation ids for the deal
     * @return sumOfAllocations total number of allocation ids for the deal
     */
    function getAllocationIdsPerDeal(uint256 dealId, uint256 offset, uint256 limit)
        external
        view
        returns (CommonTypes.FilActorId[] memory ids, uint256 sumOfAllocations)
    {
        if (limit == 0) revert InvalidLimit();
        if (dealId == 0) revert InvalidDealId();
        CommonTypes.FilActorId[] storage allocationIds = s()._deals[dealId].allocationIds;
        sumOfAllocations = allocationIds.length;

        // solhint-disable-next-line gas-strict-inequalities
        if (offset >= sumOfAllocations) {
            return (new CommonTypes.FilActorId[](0), sumOfAllocations);
        }

        uint256 remaining = sumOfAllocations - offset;
        uint256 count = limit > remaining ? remaining : limit;
        ids = new CommonTypes.FilActorId[](count);

        for (uint256 i = 0; i < count; i++) {
            ids[i] = allocationIds[offset + i];
        }
    }

    /**
     * @notice getter to retrieve claim ids for a deal with pagination
     * @param dealId the id of the deal
     * @param offset pagination offset for the claim ids
     * @param limit pagination limit for the claim ids
     * @return ids list of claim ids for the given deal
     * @return sumOfClaims total number of claims for the given deal
     */
    function getClaimIds(uint256 dealId, uint256 offset, uint256 limit)
        external
        view
        returns (CommonTypes.FilActorId[] memory ids, uint256 sumOfClaims)
    {
        if (limit == 0) revert InvalidLimit();
        if (dealId == 0) revert InvalidDealId();
        CommonTypes.FilActorId[] storage claimIds = s()._deals[dealId].claimIds;
        sumOfClaims = claimIds.length;

        // solhint-disable-next-line gas-strict-inequalities
        if (offset >= sumOfClaims) {
            return (new CommonTypes.FilActorId[](0), sumOfClaims);
        }

        uint256 remaining = sumOfClaims - offset;
        uint256 count = limit > remaining ? remaining : limit;
        ids = new CommonTypes.FilActorId[](count);

        for (uint256 i = 0; i < count; ++i) {
            ids[i] = claimIds[offset + i];
        }
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
     * @notice custom getter to retrieve allocated size in deal
     * @param dealId The id of the deal
     * @return sizeOfAllocations size of allocations for the selected deal
     */
    function getSizeOfAllocations(uint256 dealId) external view returns (uint256) {
        return s()._deals[dealId].sizeOfAllocations;
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
        DataCapEvidenceAdapterStorage storage $ = s();

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
        DataCapEvidenceAdapterStorage storage $ = s();
        for (uint256 i = 0; i < claims.length; ++i) {
            $._terminatedClaims[claims[i]] = true;
        }
    }

    /**
     * @notice Getter for the PoRepMarket contract address
     * @return Address of the PoRepMarket contract
     */
    function getPoRepMarketAddress() external view returns (address) {
        return address(s()._poRepMarketContract);
    }

    /**
     * @notice Ensures the caller is the PoRepMarket contract
     */
    function _onlyPoRepMarket() internal view {
        address poRepMarketAddress = address(s()._poRepMarketContract);
        if (msg.sender != poRepMarketAddress) revert CallerIsNotPoRepMarket();
    }

    /**
     * @notice Getter for the evidence type
     * @return The evidence type as uint8
     */
    function evidenceType() external pure returns (uint8) {
        return EvidenceTypes.VERIF_REG_CLAIMS;
    }

    /**
     * @notice Permanently marks the adapter as no longer operational. Reverts if the adapter is already non-operational
     * @dev Only callable by the admin
     */
    function disableAdapter() external onlyRole(DEFAULT_ADMIN_ROLE) {
        DataCapEvidenceAdapterStorage storage $ = s();
        if ($._operational == false) {
            revert AdapterAlreadyNonOperational();
        }
        $._operational = false;
        emit AdapterNonOperational(msg.sender, block.number);
    }
}

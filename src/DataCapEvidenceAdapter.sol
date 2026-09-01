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
import {IStorageEvidenceAdapter} from "./interfaces/IStorageEvidenceAdapter.sol";
import {DealState} from "./types/DealState.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMetaAllocator} from "./interfaces/IMetaAllocator.sol";
import {EvidenceTypes} from "./types/EvidenceTypes.sol";
import {SharedTypes} from "./types/SharedTypes.sol";
import {EvidenceResult} from "./types/EvidenceResult.sol";
import {DataCapAllocationStatus} from "./types/DataCapAllocationStatus.sol";

/**
 * @title DataCapEvidenceAdapter
 * @notice Handles DataCap posting and VerifReg claim checks for deals using the current Filecoin Plus path
 * @dev Keeps DataCap-specific state and actor calls outside PoRepMarket so new
 * deals can move to a replacement adapter when DataCap is removed.
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
        mapping(uint256 dealId => DataCapDealEvidence dealEvidence) _deals;
        mapping(uint64 claim => bool isTerminated) _terminatedClaims;
        mapping(uint256 dealId => uint8 status) _allocationStatusPerDeal;
        mapping(uint256 dealId => RefreshStatus refreshStatus) _refreshStatus;
        IPoRepMarket _poRepMarketContract;
        IMetaAllocator _metaAllocatorContract;
        bool _operational;
        mapping(uint256 dealId => CommonTypes.ChainEpoch expiration) _maxAllocationExpirationPerDeal;
        mapping(uint64 claimId => uint256 dealId) _claimDealIds;
        mapping(uint256 dealId => uint256 revision) _terminationRevisions;
        mapping(uint64 allocationOrClaimId => uint256 dealId) _dealByAllocationOrClaimId;
    }

    /**
     * @notice Struct to track the progress of refreshing evidence status
     * @dev This struct is used to store the number of checked claims and the number of checked bytes
     */
    struct RefreshStatus {
        uint256 checkedClaims;
        uint256 activeClaimedBytes;
        CommonTypes.ChainEpoch lastEvidenceRefreshEpoch;
        CommonTypes.ChainEpoch partialEvidenceRefreshEpoch;
        CommonTypes.FilActorId[] failedClaimIds;
        uint8 result;
        uint256 pendingActiveClaimedBytes;
        uint256 terminationRevision;
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
     * @notice The role to set terminated claims.
     */
    bytes32 public constant TERMINATION_ORACLE = keccak256("TERMINATION_ORACLE");

    /**
     * @notice Size of 32GiB sector in bytes
     * @dev 32 GiB = 32 * 1024 * 1024 * 1024 bytes
     */
    uint256 private constant SECTOR_SIZE = 32 * 1024 * 1024 * 1024;

    /**
     * @notice Denominator for basis points calculations
     */
    uint256 private constant BPS_DENOMINATOR = 10_000;

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
     * @notice Emitted when the adapter is permanently non-operational
     * @param account The account that set the adapter non-operational
     * @param setAtBlock The block number at which the adapter was set non-operational
     */
    event AdapterNonOperational(address indexed account, uint256 setAtBlock);

    /**
     * @notice Emitted when deal evidence is ready
     * @param dealId The deal id
     * @param evidenceAdapter The address of the evidence adapter
     */
    event DealEvidenceReady(uint256 indexed dealId, address indexed evidenceAdapter);

    /**
     * @notice Emitted when DataCap posting has been finished for a deal
     * @param dealId The id of the deal
     * @param allocatedBytes The total amount of DataCap allocated
     */
    event DataCapPostingFinished(uint256 indexed dealId, uint256 allocatedBytes);

    /**
     * @notice Emitted when a batch of DataCap allocations has been submitted for a deal
     * @param dealId The id of the deal
     * @param allocatedBytes The total amount of DataCap allocated
     */
    event DataCapBatchSubmitted(uint256 indexed dealId, uint256 allocatedBytes);

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

    /**
     * @notice Error thrown when the transfer destination is not the VerifReg actor
     * @dev 0x4c93c0b7
     */
    error InvalidTransferDestination();

    /**
     * @notice Error thrown when DataCap posting has already been finished for the deal
     * @dev 0xd12572b1
     */
    error PostingAlreadyFinished();

    /**
     * @notice Error thrown when DataCap posting has not been finished for the deal
     * @dev 0xaa6d8a1c
     */
    error PostingNotFinished();

    /**
     * @notice Error thrown when the allocated bytes do not cover the deal's requested size
     * @dev 0xfc4988b6
     */
    error InvalidAllocatedBytes();

    /**
     * @notice Error thrown when the allocation state is invalid
     * @dev 0x3f791d94
     */
    error InvalidAllocationState();

    /**
     * @notice Error thrown when an allocation or claim ID is assigned to another deal
     * @dev 0xfaf9d8cd
     */
    error AllocationOrClaimIdAssignedToAnotherDeal();

    /**
     * @notice Error thrown when the allocated bytes exceed the requested size
     * @dev 0x0d8466b6
     */
    error AllocatedBytesExceededRequestedSize();

    struct DataCapDealEvidence {
        bool postingFinished;
        address client;
        address validator;
        CommonTypes.FilActorId provider;
        uint256 dealId;
        uint256 railId;
        uint256 allocatedBytes;
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
    /// @custom:oz-upgrades-unsafe-allow constructor
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

        DataCapEvidenceAdapterStorage storage $ = s();
        $._poRepMarketContract = IPoRepMarket(_poRepMarketContract);
        $._metaAllocatorContract = IMetaAllocator(_metaAllocatorContract);
        $._operational = true;
    }

    // solhint-disable function-max-lines
    /**
     * @notice This function transfers DataCap tokens from the client to the storage provider
     * @dev This function can only be called by the client
     * @param params The parameters for the transfer
     * @param dealId The id of the deal
     */
    function submitDataCapBatch(DataCapTypes.TransferParams calldata params, uint256 dealId) external nonReentrant {
        DataCapEvidenceAdapterStorage storage $ = s();
        PoRepTypes.Deal memory dealSnapshot = $._poRepMarketContract.getDeal(dealId);

        if (!$._operational) {
            revert AdapterNotOperational();
        }

        if (
            keccak256(params.to.data)
                != keccak256(FilAddresses.fromActorID(CommonTypes.FilActorId.unwrap(VerifRegTypes.ActorID)).data)
        ) {
            revert InvalidTransferDestination();
        }

        if (dealSnapshot.state != DealState.ACCEPTED) {
            revert InvalidDealStateForTransfer();
        }

        if (msg.sender != dealSnapshot.client) {
            revert InvalidClient();
        }

        if (_getStorageDeal(dealId).postingFinished) {
            revert PostingAlreadyFinished();
        }

        if ($._deals[dealId].dealId == 0) {
            _registerDeal(dealSnapshot);
        }

        uint256 allocationCount;
        uint256 datacapSpendBytes;
        uint256 newEvidenceBytes;
        {
            (ProviderAllocation[] memory allocations, ProviderClaim[] memory claimExtensions) =
                _deserializeVerifregOperatorData(params.operator_data);
            allocationCount = allocations.length;

            uint256 allocatedBytes = _verifyAndRegisterAllocations(dealId, allocations);
            (uint256 claimBytes, uint256 newClaimEvidenceBytes) =
                _verifyAndRegisterClaimExtensions(dealId, claimExtensions);
            datacapSpendBytes = allocatedBytes + claimBytes;
            newEvidenceBytes = allocatedBytes + newClaimEvidenceBytes;
        }

        $._metaAllocatorContract.addVerifiedClient(FilAddresses.fromEthAddress(address(this)).data, datacapSpendBytes);

        PoRepTypes.DealTerms memory dealTerms = $._poRepMarketContract.getDealTerms(dealId);
        uint256 activationToleranceBps = $._poRepMarketContract.getDealActivationPadding();
        uint256 maxAllocatedBytes =
            _applyActivationToleranceCeiling(dealTerms.requestedSizeBytes, activationToleranceBps);
        if (_getStorageDeal(dealId).allocatedBytes + newEvidenceBytes > maxAllocatedBytes) {
            revert AllocatedBytesExceededRequestedSize();
        }

        emit DatacapSpent(msg.sender, datacapSpendBytes);
        /// @custom:oz-upgrades-unsafe-allow-reachable delegatecall
        (int256 exitCode, DataCapTypes.TransferReturn memory transferReturn) = DataCapAPI.transfer(params);
        if (exitCode != 0) {
            revert TransferFailed(exitCode);
        }
        _recordBatchEvidence(dealId, allocationCount, transferReturn, newEvidenceBytes);
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

        DataCapDealEvidence storage deal = _getStorageDeal(context.dealId);

        if (!deal.postingFinished) {
            revert PostingNotFinished();
        }

        CommonTypes.FilActorId[] memory allocationsBatch = _loadAllocationBatch(deal.allocationIds, batchSize);

        VerifRegTypes.GetClaimsParams memory getClaimsParams =
            VerifRegTypes.GetClaimsParams({provider: deal.provider, claim_ids: allocationsBatch});
        (int256 exitCode, VerifRegTypes.GetClaimsReturn memory result) = VerifRegAPI.getClaims(getClaimsParams);
        if (exitCode != 0) revert GetClaimsCallFailed();

        uint256 coveredBytes = 0;
        uint256 failPointer = result.batch_info.fail_codes.length;
        uint256 claimPointer = result.claims.length;

        for (uint256 i = allocationsBatch.length; i > 0; i--) {
            uint256 idx = i - 1;
            if (failPointer > 0 && result.batch_info.fail_codes[failPointer - 1].idx == idx) {
                failPointer--;
                continue;
            }
            claimPointer--;
            deal.claimIds.push(allocationsBatch[idx]);
            s()._claimDealIds[CommonTypes.FilActorId.unwrap(allocationsBatch[idx])] = context.dealId;
            coveredBytes += result.claims[claimPointer].size;
            _deleteIdByIndex(deal.allocationIds, idx);
        }

        deal.claimedBytes += coveredBytes;

        if (deal.allocationIds.length == 0) {
            s()._allocationStatusPerDeal[context.dealId] = DataCapAllocationStatus.CLAIMED;
        }

        uint8 evidenceResult;
        if (result.claims.length == 0) {
            evidenceResult = EvidenceResult.NONE;
        } else if (result.batch_info.fail_codes.length == 0) {
            evidenceResult = EvidenceResult.ACCEPTED;
        } else {
            evidenceResult = EvidenceResult.PARTIAL;
        }
        // TODO: add custom reasonCode
        return SharedTypes.ActivationDecision({coveredBytes: coveredBytes, reasonCode: 0, result: evidenceResult});
    }

    //solhint-enable function-max-lines

    // solhint-disable no-unused-vars
    /**
     * @notice Return the adapter's activation decision after submitted evidence
     * covers enough bytes for the frozen deal
     * @dev Only callable by the PoRepMarket contract
     * @dev This function does not set payment terms; PoRepMarket consumes the
     * returned covered bytes and derives committed bytes, billed units, service
     * start/end, rail ceiling, and deal state
     * @param context Activation context for the deal and market state
     * @param evidenceData Adapter-specific evidence payload
     * @return decision Activation decision for the provided evidence
     */
    function activateEvidence(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        onlyPoRepMarket
        returns (SharedTypes.ActivationDecision memory decision)
    {
        /// NOTE: compiler's warning silenced for unused variable; evidenceData gonna be used potentially in the future
        evidenceData;

        DataCapDealEvidence storage deal = _getStorageDeal(context.dealId);

        uint256 threshold = _applyActivationToleranceFloor(context.requestedSizeBytes, context.activationToleranceBps);

        if (deal.allocationIds.length != 0 || deal.claimedBytes < threshold) {
            // TODO: add custom reasonCode
            return SharedTypes.ActivationDecision({
                coveredBytes: deal.claimedBytes, reasonCode: 0, result: EvidenceResult.REJECTED
            });
        }

        emit DealEvidenceReady(context.dealId, address(this));

        // TODO: add custom reasonCode
        return SharedTypes.ActivationDecision({
            coveredBytes: deal.claimedBytes, reasonCode: 0, result: EvidenceResult.ACCEPTED
        });
    }

    // solhint-enable no-unused-vars

    // solhint-disable function-max-lines
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
        nonReentrant
        onlyPoRepMarket
        returns (SharedTypes.EvidenceStatus memory status)
    {
        uint256 batchSize = abi.decode(evidenceData, (uint256));
        if (batchSize == 0) revert InvalidBatchSize();

        DataCapEvidenceAdapterStorage storage $ = s();
        if ($._allocationStatusPerDeal[context.dealId] != DataCapAllocationStatus.CLAIMED) {
            revert InvalidAllocationState();
        }

        DataCapDealEvidence storage deal = _getStorageDeal(context.dealId);
        int64 currentEpoch = int64(uint64(block.number));
        RefreshStatus storage refreshStatus = $._refreshStatus[context.dealId];
        uint256 partialRefreshEpoch =
            uint256(uint64(CommonTypes.ChainEpoch.unwrap(refreshStatus.partialEvidenceRefreshEpoch)));
        if (
            refreshStatus.checkedClaims == deal.claimIds.length || refreshStatus.checkedClaims != 0
                && (
                    // forge-lint: disable-next-line(unsafe-typecast)
                    uint256(uint64(currentEpoch)) > partialRefreshEpoch + SharedTypes.EPOCHS_IN_MONTH
                    || refreshStatus.terminationRevision != $._terminationRevisions[context.dealId]
                )
        ) {
            refreshStatus.checkedClaims = 0;
            refreshStatus.pendingActiveClaimedBytes = 0;
            delete refreshStatus.failedClaimIds;
        }
        if (refreshStatus.checkedClaims == 0) {
            refreshStatus.terminationRevision = $._terminationRevisions[context.dealId];
            refreshStatus.partialEvidenceRefreshEpoch = CommonTypes.ChainEpoch.wrap(currentEpoch);
        }

        uint256 offset = refreshStatus.checkedClaims;

        (CommonTypes.FilActorId[] memory claimsBatch, uint256 totalClaims) =
            _getClaimIds(context.dealId, offset, batchSize, deal.claimIds);
        {
            (int256 getClaimsExitCode, VerifRegTypes.GetClaimsReturn memory getClaimsResult) =
                VerifRegAPI.getClaims(VerifRegTypes.GetClaimsParams({provider: deal.provider, claim_ids: claimsBatch}));
            if (getClaimsExitCode != 0) revert GetClaimsCallFailed();

            uint256 failIterator = 0;
            for (uint256 i = 0; i < claimsBatch.length; ++i) {
                if (
                    getClaimsResult.batch_info.fail_codes.length > 0
                        && getClaimsResult.batch_info.fail_codes.length > failIterator
                        && i == getClaimsResult.batch_info.fail_codes[failIterator].idx
                ) {
                    refreshStatus.failedClaimIds.push(claimsBatch[i]);
                    ++failIterator;
                    continue;
                }
                VerifRegTypes.Claim memory claim = getClaimsResult.claims[i - failIterator];

                if ($._terminatedClaims[CommonTypes.FilActorId.unwrap(claimsBatch[i])]) {
                    continue;
                }

                refreshStatus.pendingActiveClaimedBytes += claim.size;
            }
        }

        refreshStatus.checkedClaims = offset + claimsBatch.length;

        uint8 evidenceResult;

        if (refreshStatus.checkedClaims == totalClaims) {
            refreshStatus.activeClaimedBytes = refreshStatus.pendingActiveClaimedBytes;
            if (refreshStatus.activeClaimedBytes != deal.claimedBytes) {
                evidenceResult = EvidenceResult.COVERED_BYTES_MISMATCH;
            } else {
                refreshStatus.lastEvidenceRefreshEpoch = CommonTypes.ChainEpoch.wrap(currentEpoch);
                evidenceResult = EvidenceResult.ACTIVE;
            }
            refreshStatus.result = evidenceResult;
        } else {
            evidenceResult = EvidenceResult.PARTIAL;
        }
        // TODO: add custom reasonCode
        return SharedTypes.EvidenceStatus({
            activeCoveredBytes: evidenceResult == EvidenceResult.PARTIAL
                ? refreshStatus.pendingActiveClaimedBytes
                : refreshStatus.activeClaimedBytes,
            lastEvidenceRefreshEpoch: refreshStatus.lastEvidenceRefreshEpoch,
            reasonCode: 0,
            result: evidenceResult,
            checkedClaims: refreshStatus.checkedClaims,
            totalClaims: totalClaims
        });
    }

    // solhint-enable function-max-lines

    /**
     * @notice Read current evidence status from adapter storage only
     * @dev Must not call Filecoin actors or refresh live state
     * @param context Activation context for the deal and market state
     * @return status Current adapter-local evidence status
     */
    function currentEvidenceStatus(SharedTypes.ActivationContext calldata context)
        external
        onlyPoRepMarket
        returns (SharedTypes.EvidenceStatus memory status)
    {
        DataCapEvidenceAdapterStorage storage $ = s();
        RefreshStatus storage refreshStatus = $._refreshStatus[context.dealId];

        uint256 lastRefresh = uint256(uint64(CommonTypes.ChainEpoch.unwrap(refreshStatus.lastEvidenceRefreshEpoch)));

        if (block.number > lastRefresh + SharedTypes.EPOCHS_IN_MONTH) {
            refreshStatus.activeClaimedBytes = 0;
            refreshStatus.result = EvidenceResult.INACTIVE;
        }
        // TODO: add custom reasonCode
        return SharedTypes.EvidenceStatus({
            activeCoveredBytes: refreshStatus.activeClaimedBytes,
            lastEvidenceRefreshEpoch: refreshStatus.lastEvidenceRefreshEpoch,
            reasonCode: 0,
            result: refreshStatus.result,
            checkedClaims: refreshStatus.checkedClaims,
            totalClaims: _getStorageDeal(context.dealId).claimIds.length
        });
    }

    /**
     * @notice Closes DataCap posting for a deal in a separate transaction
     * @dev Only callable by the deal client while the deal is Accepted and posting is open
     * @param dealId The id of the deal
     */
    function finishDataCapPosting(uint256 dealId) external {
        DataCapEvidenceAdapterStorage storage $ = s();
        PoRepTypes.Deal memory dealSnapshot = $._poRepMarketContract.getDeal(dealId);

        if (dealSnapshot.state != DealState.ACCEPTED) {
            revert InvalidDealStateForTransfer();
        }

        if (msg.sender != dealSnapshot.client) {
            revert InvalidClient();
        }

        DataCapDealEvidence storage deal = _getStorageDeal(dealId);
        if (deal.postingFinished) {
            revert PostingAlreadyFinished();
        }

        PoRepTypes.DealTerms memory dealTerms = $._poRepMarketContract.getDealTerms(dealId);
        _ensureAllocationCoverage(deal.allocatedBytes, dealTerms.requestedSizeBytes);

        deal.postingFinished = true;
        $._allocationStatusPerDeal[dealId] = DataCapAllocationStatus.ALLOCATED;

        emit DataCapPostingFinished(dealId, deal.allocatedBytes);
    }

    function _ensureAllocationCoverage(uint256 allocatedBytes, uint256 requestedSizeBytes) internal view virtual {
        uint256 activationToleranceBps = s()._poRepMarketContract.getDealActivationPadding();
        if (allocatedBytes < _applyActivationToleranceFloor(requestedSizeBytes, activationToleranceBps)) {
            revert InvalidAllocatedBytes();
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

    /// @inheritdoc IDataCapEvidenceAdapter
    function disableAdapter() external onlyRole(DEFAULT_ADMIN_ROLE) {
        DataCapEvidenceAdapterStorage storage $ = s();
        if (!$._operational) {
            revert AdapterAlreadyNonOperational();
        }
        $._operational = false;
        emit AdapterNonOperational(msg.sender, block.number);
    }

    /**
     * @notice Marks the given claims as terminated early.
     * @dev Only callable by TERMINATION_ORACLE role.
     * @param claims An array of claim IDs to mark as terminated.
     */
    function claimsTerminatedEarly(uint64[] calldata claims) external onlyRole(TERMINATION_ORACLE) {
        DataCapEvidenceAdapterStorage storage $ = s();
        for (uint256 i = 0; i < claims.length; ++i) {
            uint64 claimId = claims[i];
            if ($._terminatedClaims[claimId]) continue;
            $._terminatedClaims[claimId] = true;
            uint256 dealId = $._claimDealIds[claimId];
            if (dealId != 0) ++$._terminationRevisions[dealId];
        }
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function isOperational() external view returns (bool) {
        return s()._operational;
    }

    /**
     * @notice Returns whether DataCap posting has been finished for a deal
     * @param dealId The id of the deal
     * @return True if posting is finished, false otherwise
     */
    function isDataCapPostingFinished(uint256 dealId) external view returns (bool) {
        return _getStorageDeal(dealId).postingFinished;
    }

    /**
     * @notice custom getter to check if claim is terminated
     * @param claimId the id of the claim
     * @return True whether the claim is terminated, false otherwise
     */
    function isClaimTerminated(uint64 claimId) external view returns (bool) {
        return s()._terminatedClaims[claimId];
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
        CommonTypes.FilActorId[] storage allocationIds = _getStorageDeal(dealId).allocationIds;
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
        (ids, sumOfClaims) = _getClaimIds(dealId, offset, limit, _getStorageDeal(dealId).claimIds);
    }

    /**
     * @notice getter to retrieve failed claim ids for a deal
     * @param dealId the id of the deal
     * @return failedClaimIds list of failed claim ids for the given deal
     */
    function getFailedClaimIds(uint256 dealId) external view returns (CommonTypes.FilActorId[] memory failedClaimIds) {
        return s()._refreshStatus[dealId].failedClaimIds;
    }

    /**
     * @notice custom getter to retrieve allocated bytes in deal
     * @param dealId The id of the deal
     * @return allocatedBytes allocated bytes for the selected deal
     */
    function getAllocatedBytes(uint256 dealId) external view returns (uint256) {
        return _getStorageDeal(dealId).allocatedBytes;
    }

    /**
     * @notice Getter to retrieve the lifecycle status of a deal's DataCap allocations
     * @param dealId The id of the deal
     * @return status The allocation status as defined in DataCapAllocationStatus
     */
    function getDealAllocationStatus(uint256 dealId) external view returns (uint8 status) {
        return s()._allocationStatusPerDeal[dealId];
    }

    /**
     * @notice Retrieves the latest expiration epoch among a deal's allocations
     * @param dealId The id of the deal
     * @return expiration The latest allocation expiration epoch
     */
    function getExpiration(uint256 dealId) external view returns (CommonTypes.ChainEpoch expiration) {
        return s()._maxAllocationExpirationPerDeal[dealId];
    }

    /**
     * @notice Getter for the PoRepMarket contract address
     * @return Address of the PoRepMarket contract
     */
    function getPoRepMarketAddress() external view returns (address) {
        return address(s()._poRepMarketContract);
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function getEvidenceType() external pure returns (uint8) {
        return EvidenceTypes.VERIF_REG_CLAIMS;
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

        DataCapDealEvidence storage dealEvidence = $._deals[dealSnapshot.dealId];
        dealEvidence.client = dealSnapshot.client;
        dealEvidence.provider = dealSnapshot.provider;
        dealEvidence.dealId = dealSnapshot.dealId;
        dealEvidence.validator = dealSnapshot.validator;
        dealEvidence.railId = dealSnapshot.railId;
    }

    /**
     * @notice Verifies and registers allocations.
     * @param dealId The deal id.
     * @param allocations The array of provider allocations.
     * @return allocatedBytes The total size of allocations
     */
    function _verifyAndRegisterAllocations(uint256 dealId, ProviderAllocation[] memory allocations)
        internal
        returns (uint256 allocatedBytes)
    {
        DataCapDealEvidence storage dealEvidence = _getStorageDeal(dealId);
        int64 savedExpiration = CommonTypes.ChainEpoch.unwrap(s()._maxAllocationExpirationPerDeal[dealId]);
        int64 maximumExpiration = savedExpiration;

        for (uint256 i = 0; i < allocations.length; i++) {
            ProviderAllocation memory alloc = allocations[i];
            if (CommonTypes.FilActorId.unwrap(alloc.provider) != CommonTypes.FilActorId.unwrap(dealEvidence.provider)) {
                revert InvalidProvider();
            }

            _ensureValidAllocationTerms(alloc.termMin, alloc.termMax, alloc.expiration);
            if (alloc.size == 0) {
                revert InvalidAllocationRequest();
            }

            if (alloc.size > SECTOR_SIZE) {
                revert InvalidAllocationSize();
            }

            if (alloc.expiration > maximumExpiration) {
                maximumExpiration = alloc.expiration;
            }
            allocatedBytes += alloc.size;
        }

        if (maximumExpiration != savedExpiration) {
            s()._maxAllocationExpirationPerDeal[dealId] = CommonTypes.ChainEpoch.wrap(maximumExpiration);
        }
    }

    function _recordBatchEvidence(
        uint256 dealId,
        uint256 allocationCount,
        DataCapTypes.TransferReturn memory transferReturn,
        uint256 newEvidenceBytes
    ) internal {
        DataCapDealEvidence storage dealEvidence = _getStorageDeal(dealId);
        if (allocationCount != 0) {
            CommonTypes.FilActorId[] memory allocationIds = transferReturn.decodeAllocationResponse();
            for (uint256 i = 0; i < allocationIds.length; i++) {
                CommonTypes.FilActorId allocId = allocationIds[i];
                _registerAllocationOrClaimId(dealId, allocId);
                dealEvidence.allocationIds.push(allocId);
            }
        }
        emit DataCapBatchSubmitted(dealId, newEvidenceBytes);
        dealEvidence.allocatedBytes += newEvidenceBytes;
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

    /**
     * @notice Verifies and registers claim extensions.
     * @param dealId The id of the deal.
     * @param claimExtensions The array of provider claims.
     * @return claimBytes The total size of claims
     * @return newEvidenceBytes The size of claims first assigned to the deal
     */
    function _verifyAndRegisterClaimExtensions(uint256 dealId, ProviderClaim[] memory claimExtensions)
        internal
        returns (uint256 claimBytes, uint256 newEvidenceBytes)
    {
        DataCapDealEvidence storage dealEvidence = _getStorageDeal(dealId);
        CommonTypes.FilActorId[] memory claimIds = new CommonTypes.FilActorId[](claimExtensions.length);
        CommonTypes.FilActorId dealProvider = dealEvidence.provider;

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
                claimBytes += claim.size;
                if (_registerAllocationOrClaimId(dealId, claimIds[i])) {
                    dealEvidence.allocationIds.push(claimIds[i]);
                    newEvidenceBytes += claim.size;
                }
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
     * @notice Internal getter to retrieve claim ids for a deal with pagination
     * @param dealId the id of the deal
     * @param offset pagination offset for the claim ids
     * @param limit pagination limit for the claim ids
     * @param claimIds storage array of claim ids for the deal
     * @return ids list of claim ids for the given deal
     * @return sumOfClaims total number of claims for the given deal
     */
    function _getClaimIds(uint256 dealId, uint256 offset, uint256 limit, CommonTypes.FilActorId[] storage claimIds)
        internal
        view
        returns (CommonTypes.FilActorId[] memory ids, uint256 sumOfClaims)
    {
        if (limit == 0) revert InvalidLimit();
        if (dealId == 0) revert InvalidDealId();
        sumOfClaims = claimIds.length;

        // solhint-disable-next-line gas-strict-inequalities
        if (offset >= sumOfClaims) {
            return (new CommonTypes.FilActorId[](0), sumOfClaims);
        }

        uint256 remaining = sumOfClaims - offset;
        uint256 count = limit > remaining ? remaining : limit;
        ids = new CommonTypes.FilActorId[](count);

        for (uint256 i = 0; i < count; i++) {
            ids[i] = claimIds[offset + i];
        }
    }

    /**
     * @notice Internal function used to retrieve a storage deal
     * @param dealId The id of the deal
     * @return deal The storage deal
     */
    function _getStorageDeal(uint256 dealId) internal view returns (DataCapDealEvidence storage) {
        return s()._deals[dealId];
    }

    /**
     * @notice Applies an activation tolerance to a requested size, returning the lower bound
     * @dev Used where a deal must be allowed to fall slightly short of the requested size
     * @param sizeBytes The requested size in bytes
     * @param toleranceBps The activation tolerance in basis points
     * @return The minimum number of bytes required after applying the tolerance
     */
    function _applyActivationToleranceFloor(uint256 sizeBytes, uint256 toleranceBps) internal pure returns (uint256) {
        return sizeBytes * (BPS_DENOMINATOR - toleranceBps) / BPS_DENOMINATOR;
    }

    /**
     * @notice Applies an activation tolerance to a requested size, returning the upper bound
     * @dev Used where allocations may exceed the requested size, as allocation sizes are padded piece sizes
     * @param sizeBytes The requested size in bytes
     * @param toleranceBps The activation tolerance in basis points
     * @return The maximum number of bytes allowed after applying the tolerance
     */
    function _applyActivationToleranceCeiling(uint256 sizeBytes, uint256 toleranceBps) internal pure returns (uint256) {
        return sizeBytes * (BPS_DENOMINATOR + toleranceBps) / BPS_DENOMINATOR;
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Internal function used to implement new logic and check if upgrade is authorized
     * @dev Will revert (reject upgrade) if upgrade isn't called by UPGRADER_ROLE
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // solhint-enable no-empty-blocks

    /**
     * @notice Internal function to delete an id from a storage array by its index
     * @param ids The list of ids to remove from
     * @param index The index of the id to delete
     */
    function _deleteIdByIndex(CommonTypes.FilActorId[] storage ids, uint256 index) internal {
        uint256 last = ids.length - 1;
        if (index != last) ids[index] = ids[last];
        ids.pop();
    }

    // solhint-disable-next-line use-natspec
    function _registerAllocationOrClaimId(uint256 dealId, CommonTypes.FilActorId allocationOrClaimId)
        internal
        returns (bool)
    {
        DataCapEvidenceAdapterStorage storage $ = s();
        uint64 allocationOrClaimIdValue = CommonTypes.FilActorId.unwrap(allocationOrClaimId);
        uint256 assignedDealId = $._dealByAllocationOrClaimId[allocationOrClaimIdValue];
        if (assignedDealId == 0) {
            $._dealByAllocationOrClaimId[allocationOrClaimIdValue] = dealId;
            return true;
        }
        if (assignedDealId != dealId) revert AllocationOrClaimIdAssignedToAnotherDeal();
        return false;
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
     * @notice Ensures the caller is the PoRepMarket contract
     */
    function _onlyPoRepMarket() internal view {
        address poRepMarketAddress = address(s()._poRepMarketContract);
        if (msg.sender != poRepMarketAddress) revert CallerIsNotPoRepMarket();
    }
}

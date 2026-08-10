// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {CalldataSlice, CalldataUtils} from "fvm-solidity/CalldataUtils.sol";
import {CBOR_CODEC} from "fvm-solidity/FVMCodec.sol";
import {FVMAddress} from "fvm-solidity/FVMAddress.sol";
import {SECTOR_CONTENT_CHANGED} from "fvm-solidity/FVMMethod.sol";
import {FVMMiner} from "fvm-solidity/FVMMiner.sol";
import {FVMSector, SectorStatus} from "fvm-solidity/FVMSector.sol";
import {
    FVMSectorContentChanged,
    PieceChangeIter,
    SectorChangesHeader,
    SectorContentChangedReturn,
    SectorReturn
} from "fvm-solidity/FVMSectorContentChanged.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {IStorageEvidenceAdapter} from "./interfaces/IStorageEvidenceAdapter.sol";
import {EvidenceResult} from "./types/EvidenceResult.sol";
import {EvidenceTypes} from "./types/EvidenceTypes.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {SharedTypes} from "./types/SharedTypes.sol";

/**
 * @title Experimental sector evidence adapter
 * @notice Accepts and refreshes authenticated sector placements for PoRep Market deals.
 * @dev This experiment supports grouped FIP-0109 placements and bounded FIP-0112 status checks.
 */
contract SectorEvidenceAdapter is IStorageEvidenceAdapter, Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using CalldataUtils for CalldataSlice;
    using FVMAddress for address;
    using FVMMiner for uint64;

    uint104 private constant CANONICAL_COMMP_CID_PREFIX = 0x83d82a5828000181e203922020;

    struct PlacementInput {
        bytes32 pieceDigest;
        uint64 providerActorId;
        uint64 paddedSize;
        uint64 sectorNumber;
        int64 minimumCommitmentEpoch;
    }

    /**
     * @dev Provider and size are retained so activation and refresh reject stale receipts if a future market upgrade
     *      makes either deal field mutable. The remaining fields preserve authenticated placement history for upgrades.
     */
    struct PlacementReceipt {
        bytes32 pieceCidDigest;
        uint64 providerActorId;
        uint64 paddedSize;
        uint64 sectorNumber;
        int64 minimumCommitmentEpoch;
        CommonTypes.ChainEpoch receiptEpoch;
        bool accepted;
        bool activated;
    }

    struct RefreshState {
        CommonTypes.ChainEpoch lastEvidenceRefreshEpoch;
        CommonTypes.ChainEpoch expiration;
        uint8 result;
    }

    // @custom:storage-location erc7201:porepmarket.storage.SectorEvidenceAdapterStorage
    struct SectorEvidenceAdapterStorage {
        IPoRepMarket _poRepMarket;
        mapping(uint256 dealId => PlacementReceipt receipt) _receipts;
        mapping(bytes32 placementKey => uint256 dealId) _placementDeals;
        mapping(uint256 dealId => RefreshState state) _refreshStates;
    }

    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.SectorEvidenceAdapterStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SECTOR_EVIDENCE_ADAPTER_STORAGE_LOCATION =
        0x57516ab2e793592bec7ab2e2851e8a91b20d6fd6aebf72f1617eb8ab0e7a2000;

    // solhint-disable-next-line use-natspec
    function _getSectorEvidenceAdapterStorage() private pure returns (SectorEvidenceAdapterStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := SECTOR_EVIDENCE_ADAPTER_STORAGE_LOCATION
        }
    }

    // solhint-disable-next-line use-natspec
    function s() internal pure returns (SectorEvidenceAdapterStorage storage) {
        return _getSectorEvidenceAdapterStorage();
    }

    /**
     * @notice Role allowed to upgrade the adapter implementation.
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // FIP-0109 fixes this entry-point name.
    // solhint-disable func-name-mixedcase

    /**
     * @notice Records an authenticated sector placement.
     * @param dealId PoRep Market deal ID.
     * @param providerActorId Authenticated miner actor ID.
     * @param sectorNumber Sector containing the piece.
     * @param pieceCidDigest PieceCID digest reported by the miner.
     * @param paddedSize Padded piece size reported by the miner.
     * @param minimumCommitmentEpoch Minimum sector commitment epoch.
     * @param pieceSetCommitment Deal manifest commitment reconstructed from the piece.
     * @param receiptEpoch Epoch when the callback was accepted.
     */
    event PlacementAccepted(
        uint256 indexed dealId,
        uint64 indexed providerActorId,
        uint64 indexed sectorNumber,
        bytes32 pieceCidDigest,
        uint64 paddedSize,
        int64 minimumCommitmentEpoch,
        bytes32 pieceSetCommitment,
        CommonTypes.ChainEpoch receiptEpoch
    );
    /**
     * @notice Records one-time consumption of an accepted placement.
     * @param dealId Activated PoRep Market deal ID.
     * @param sectorNumber Sector used for activation.
     * @param coveredBytes Exact padded bytes credited to the deal.
     */
    event PlacementActivated(uint256 indexed dealId, uint64 indexed sectorNumber, uint64 indexed coveredBytes);

    /**
     * @dev 0xa31f4508
     */
    error OnlyPoRepMarket();
    /**
     * @dev 0x14d4a4e8
     */
    error OnlySelf();
    /**
     * @dev 0x05bb467c
     */
    error InvalidAdminAddress();
    /**
     * @dev 0xc9cc4a06
     */
    error InvalidPoRepMarketAddress();
    /**
     * @dev 0x9e2d0208
     */
    error UnexpectedMethod(uint64 method);
    /**
     * @dev 0x1144e121
     */
    error UnexpectedCodec(uint64 codec);
    /**
     * @dev 0x6fc84408
     */
    error CallerIsNotMiner(uint64 actorId);
    /**
     * @dev 0xf61df232
     */
    error InvalidPayloadLength(uint256 length);
    /**
     * @dev 0x5d4cdcc4
     */
    error UnexpectedEvidenceAdapter(uint256 dealId, address actual);
    /**
     * @dev 0xf0b3e77e
     */
    error UnexpectedProvider(uint64 expected, uint64 actual);
    /**
     * @dev 0xb759283d
     */
    error UnexpectedPieceSetCommitment();
    /**
     * @dev 0x75bda749
     */
    error UnexpectedPaddedSize(uint256 expected, uint64 actual);
    /**
     * @dev 0xecb06d2e
     */
    error UnexpectedPieceCidHeader();
    /**
     * @dev 0xe0870ca8
     */
    error InvalidRefreshDataLength(uint256 length);
    /**
     * @dev 0xaf605f93
     */
    error InvalidSectorExpiration(uint64 expiration);
    /**
     * @dev 0x8599d34e
     */
    error InsufficientCommitmentEpoch(int64 required, int64 actual);
    /**
     * @dev 0x8fe7522b
     */
    error ConflictingPlacement(uint256 dealId);
    /**
     * @dev 0xba5f3d6f
     */
    error PlacementAlreadyAssigned(uint256 existingDealId, uint256 requestedDealId);

    modifier onlyPoRepMarket() {
        if (msg.sender != address(s()._poRepMarket)) revert OnlyPoRepMarket();
        _;
    }

    /**
     * @notice Disables initialization of the implementation contract.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy state.
     * @param admin Account granted the default admin and upgrader roles.
     * @param poRepMarketAddress PoRep Market allowed to consume adapter lifecycle results.
     */
    function initialize(address admin, address poRepMarketAddress) public initializer {
        if (admin == address(0)) revert InvalidAdminAddress();
        if (poRepMarketAddress == address(0)) revert InvalidPoRepMarketAddress();

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        s()._poRepMarket = IPoRepMarket(poRepMarketAddress);
    }

    /**
     * @notice Receives a grouped FIP-0109 SectorContentChanged callback.
     * @dev The calldata decoder reads the final `bytes` argument directly from message calldata.
     * @param method Filecoin method number.
     * @param codec Filecoin parameter codec.
     * @return exitCode Filecoin exit code.
     * @return returnCodec Codec for the returned acceptance bitmap.
     * @return returnData CBOR-encoded acceptance bitmap.
     */
    // solhint-disable-next-line use-natspec
    function handle_filecoin_method(uint64 method, uint64 codec, bytes calldata)
        external
        returns (uint32 exitCode, uint64 returnCodec, bytes memory returnData)
    {
        if (method != SECTOR_CONTENT_CHANGED) revert UnexpectedMethod(method);
        if (codec != CBOR_CODEC) revert UnexpectedCodec(codec);

        uint64 providerActorId = msg.sender.safeActorId();
        if (!providerActorId.isMiner()) revert CallerIsNotMiner(providerActorId);

        (uint256 sectorCount, uint256 offset) = FVMSectorContentChanged.readParamsHeader();
        SectorContentChangedReturn memory result;
        result.sectors = new SectorReturn[](sectorCount);
        SectorChangesHeader memory sector;
        PieceChangeIter memory piece;
        for (uint256 sectorIndex = 0; sectorIndex < sectorCount; sectorIndex++) {
            offset = FVMSectorContentChanged.readSectorHeader(offset, sector);
            FVMSectorContentChanged.initSectorReturn(result.sectors[sectorIndex], sector.numPieces);

            for (uint256 pieceIndex = 0; pieceIndex < sector.numPieces; pieceIndex++) {
                bool canonicalPieceCid = _hasCanonicalPieceCidHeader(offset);
                offset = FVMSectorContentChanged.readPiece(offset, piece);
                bytes memory payloadBytes = piece.payload.load();
                bool accepted;
                try this.processPieceNotification(
                    payloadBytes,
                    canonicalPieceCid,
                    providerActorId,
                    piece.digest,
                    piece.paddedSize,
                    sector.sector,
                    sector.minimumCommitmentEpoch
                ) {
                    accepted = true;
                } catch {
                    accepted = false;
                }
                if (accepted) FVMSectorContentChanged.accept(result.sectors[sectorIndex], pieceIndex);
            }
        }
        return (0, CBOR_CODEC, FVMSectorContentChanged.encodeReturn(result));
    }

    /**
     * @notice Validates and records one piece while isolating its rejection from the rest of a grouped callback.
     * @dev Callable only through an external self-call from `handle_filecoin_method` so a revert rejects one piece.
     * @param payloadBytes ABI-encoded receiver payload.
     * @param canonicalPieceCid Whether the piece CID uses the canonical CommP prefix.
     * @param providerActorId Authenticated miner actor ID.
     * @param pieceDigest CommP digest.
     * @param paddedSize Padded piece size.
     * @param sectorNumber Sector containing the piece.
     * @param minimumCommitmentEpoch Minimum sector commitment epoch.
     */
    function processPieceNotification(
        bytes calldata payloadBytes,
        bool canonicalPieceCid,
        uint64 providerActorId,
        bytes32 pieceDigest,
        uint64 paddedSize,
        uint64 sectorNumber,
        int64 minimumCommitmentEpoch
    ) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (!canonicalPieceCid) revert UnexpectedPieceCidHeader();
        if (payloadBytes.length != 32) revert InvalidPayloadLength(payloadBytes.length);
        uint256 dealId = abi.decode(payloadBytes, (uint256));
        PlacementInput memory placement = PlacementInput({
            providerActorId: providerActorId,
            pieceDigest: pieceDigest,
            paddedSize: paddedSize,
            sectorNumber: sectorNumber,
            minimumCommitmentEpoch: minimumCommitmentEpoch
        });

        _validateDealAndPiece(dealId, placement);
        _acceptPlacement(dealId, placement);
    }

    // solhint-enable func-name-mixedcase

    /// @inheritdoc IStorageEvidenceAdapter
    function submitEvidenceBatch(SharedTypes.ActivationContext calldata, bytes calldata)
        external
        view
        onlyPoRepMarket
        returns (SharedTypes.ActivationDecision memory decision)
    {
        return _rejectedActivation();
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function activateEvidence(SharedTypes.ActivationContext calldata context, bytes calldata)
        external
        onlyPoRepMarket
        returns (SharedTypes.ActivationDecision memory decision)
    {
        PlacementReceipt storage receipt = s()._receipts[context.dealId];
        if (
            !receipt.accepted || receipt.activated
                || receipt.providerActorId != CommonTypes.FilActorId.unwrap(context.provider)
                || receipt.paddedSize != context.requestedSizeBytes
        ) {
            return _rejectedActivation();
        }

        receipt.activated = true;
        emit PlacementActivated(context.dealId, receipt.sectorNumber, receipt.paddedSize);
        return SharedTypes.ActivationDecision({
            coveredBytes: receipt.paddedSize, reasonCode: 0, result: EvidenceResult.ACCEPTED
        });
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function refreshEvidenceStatus(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        onlyPoRepMarket
        returns (SharedTypes.EvidenceStatus memory status)
    {
        if (evidenceData.length != 64) revert InvalidRefreshDataLength(evidenceData.length);
        (int64 deadline, int64 partition) = abi.decode(evidenceData, (int64, int64));

        SectorEvidenceAdapterStorage storage $ = s();
        PlacementReceipt memory receipt = $._receipts[context.dealId];
        bool receiptMatches = receipt.accepted && receipt.activated
            && receipt.providerActorId == CommonTypes.FilActorId.unwrap(context.provider)
            && receipt.paddedSize == context.requestedSizeBytes;
        bool active;
        uint64 expiration;
        if (receiptMatches) {
            active = FVMSector.validateSectorStatus(
                receipt.providerActorId, receipt.sectorNumber, SectorStatus.Active, deadline, partition
            );
            if (active) {
                expiration = FVMSector.getNominalSectorExpiration(receipt.providerActorId, receipt.sectorNumber);
                if (expiration >> 63 != 0) revert InvalidSectorExpiration(expiration);
            }
        }

        return _storeRefreshState(context.dealId, active, expiration, receipt.paddedSize);
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function currentEvidenceStatus(SharedTypes.ActivationContext calldata context)
        external
        view
        onlyPoRepMarket
        returns (SharedTypes.EvidenceStatus memory status)
    {
        SectorEvidenceAdapterStorage storage $ = s();
        RefreshState memory refreshState = $._refreshStates[context.dealId];
        if (refreshState.result == EvidenceResult.NONE) return _inactiveStatus();
        return _evidenceStatus(refreshState, $._receipts[context.dealId].paddedSize);
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function getExpiration(uint256 dealId) external view returns (CommonTypes.ChainEpoch expiration) {
        return s()._refreshStates[dealId].expiration;
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function isOperational() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function getEvidenceType() external pure returns (uint8) {
        return EvidenceTypes.SECTOR_PLACEMENT;
    }

    // solhint-disable func-name-mixedcase
    /**
     * @notice Returns the PoRep Market allowed to consume adapter lifecycle results.
     * @return market PoRep Market contract.
     */
    function POREP_MARKET() external view returns (IPoRepMarket market) {
        return s()._poRepMarket;
    }

    // solhint-enable func-name-mixedcase

    /**
     * @notice Returns the PoRep Market contract address.
     * @return marketAddress PoRep Market address.
     */
    function getPoRepMarketAddress() external view returns (address marketAddress) {
        return address(s()._poRepMarket);
    }

    /**
     * @notice Returns the accepted placement and activation-consumption state for one deal.
     * @param dealId PoRep Market deal ID.
     * @return receipt Stored placement receipt.
     */
    function getReceipt(uint256 dealId) external view returns (PlacementReceipt memory receipt) {
        return s()._receipts[dealId];
    }

    function _validateDealAndPiece(uint256 dealId, PlacementInput memory placement) private view {
        SectorEvidenceAdapterStorage storage $ = s();
        PoRepTypes.Deal memory deal = $._poRepMarket.getDeal(dealId);
        if (deal.evidenceAdapter != address(this)) {
            revert UnexpectedEvidenceAdapter(dealId, deal.evidenceAdapter);
        }

        uint64 expectedProvider = CommonTypes.FilActorId.unwrap(deal.provider);
        if (placement.providerActorId != expectedProvider) {
            revert UnexpectedProvider(expectedProvider, placement.providerActorId);
        }

        bytes32 reconstructedCommitment = keccak256(abi.encode(placement.pieceDigest, placement.paddedSize));
        SharedTypes.DealData memory dealData = $._poRepMarket.getDealData(dealId);
        if (dealData.manifestHash != reconstructedCommitment) {
            revert UnexpectedPieceSetCommitment();
        }

        PoRepTypes.DealTerms memory terms = $._poRepMarket.getDealTerms(dealId);
        if (placement.paddedSize != terms.requestedSizeBytes) {
            revert UnexpectedPaddedSize(terms.requestedSizeBytes, placement.paddedSize);
        }

        int64 requiredCommitmentEpoch =
            CommonTypes.ChainEpoch.unwrap(deal.proposedAtEpoch) + int64(uint64(terms.durationEpochs));
        if (placement.minimumCommitmentEpoch < requiredCommitmentEpoch) {
            revert InsufficientCommitmentEpoch(requiredCommitmentEpoch, placement.minimumCommitmentEpoch);
        }
    }

    function _hasCanonicalPieceCidHeader(uint256 offset) private pure returns (bool) {
        uint104 prefix;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            prefix := shr(152, calldataload(offset))
        }
        return prefix == CANONICAL_COMMP_CID_PREFIX;
    }

    // solhint-disable-next-line function-max-lines
    function _acceptPlacement(uint256 dealId, PlacementInput memory placement) private {
        PlacementReceipt storage existing = s()._receipts[dealId];
        bytes32 pieceSetCommitment = keccak256(abi.encode(placement.pieceDigest, placement.paddedSize));
        if (existing.accepted) {
            // Re-Snap support must replace this conflict rule with an authenticated receipt update policy.
            if (
                existing.sectorNumber != placement.sectorNumber
                    || existing.minimumCommitmentEpoch != placement.minimumCommitmentEpoch
            ) {
                revert ConflictingPlacement(dealId);
            }
            return;
        }

        bytes32 placementKey = keccak256(
            abi.encode(placement.providerActorId, placement.sectorNumber, placement.pieceDigest, placement.paddedSize)
        );
        uint256 existingDealId = s()._placementDeals[placementKey];
        if (existingDealId != 0) revert PlacementAlreadyAssigned(existingDealId, dealId);

        CommonTypes.ChainEpoch receiptEpoch = CommonTypes.ChainEpoch.wrap(int64(uint64(block.number)));
        s()._receipts[dealId] = PlacementReceipt({
            providerActorId: placement.providerActorId,
            pieceCidDigest: placement.pieceDigest,
            paddedSize: placement.paddedSize,
            sectorNumber: placement.sectorNumber,
            minimumCommitmentEpoch: placement.minimumCommitmentEpoch,
            receiptEpoch: receiptEpoch,
            accepted: true,
            activated: false
        });
        s()._placementDeals[placementKey] = dealId;

        emit PlacementAccepted(
            dealId,
            placement.providerActorId,
            placement.sectorNumber,
            placement.pieceDigest,
            placement.paddedSize,
            placement.minimumCommitmentEpoch,
            pieceSetCommitment,
            receiptEpoch
        );
    }

    function _evidenceStatus(RefreshState memory refreshState, uint64 paddedSize)
        private
        pure
        returns (SharedTypes.EvidenceStatus memory status)
    {
        bool active = refreshState.result == EvidenceResult.ACTIVE;
        return SharedTypes.EvidenceStatus({
            activeCoveredBytes: active ? paddedSize : 0,
            lastEvidenceRefreshEpoch: refreshState.lastEvidenceRefreshEpoch,
            reasonCode: 0,
            result: refreshState.result,
            checkedClaims: 1,
            totalClaims: 1
        });
    }

    function _storeRefreshState(uint256 dealId, bool active, uint64 expiration, uint64 paddedSize)
        private
        returns (SharedTypes.EvidenceStatus memory status)
    {
        // An active sector expiration is bounded before this conversion.
        // forge-lint: disable-next-line(unsafe-typecast)
        CommonTypes.ChainEpoch storedExpiration = CommonTypes.ChainEpoch.wrap(active ? int64(expiration) : int64(0));
        RefreshState memory refreshState = RefreshState({
            lastEvidenceRefreshEpoch: CommonTypes.ChainEpoch.wrap(int64(uint64(block.number))),
            expiration: storedExpiration,
            result: active ? EvidenceResult.ACTIVE : EvidenceResult.INACTIVE
        });
        s()._refreshStates[dealId] = refreshState;
        return _evidenceStatus(refreshState, paddedSize);
    }

    function _rejectedActivation() private pure returns (SharedTypes.ActivationDecision memory decision) {
        return SharedTypes.ActivationDecision({coveredBytes: 0, reasonCode: 0, result: EvidenceResult.REJECTED});
    }

    function _inactiveStatus() private pure returns (SharedTypes.EvidenceStatus memory status) {
        return SharedTypes.EvidenceStatus({
            activeCoveredBytes: 0,
            lastEvidenceRefreshEpoch: CommonTypes.ChainEpoch.wrap(0),
            reasonCode: 0,
            result: EvidenceResult.INACTIVE,
            checkedClaims: 0,
            totalClaims: 0
        });
    }

    // solhint-disable no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    // solhint-enable no-empty-blocks
}

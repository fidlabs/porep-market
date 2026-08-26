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
import {
    FVMSectorContentChanged,
    PieceChangeIter,
    SectorChangesHeader,
    SectorContentChangedReturn,
    SectorReturn
} from "fvm-solidity/FVMSectorContentChanged.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {IStorageEvidenceAdapter} from "./interfaces/IStorageEvidenceAdapter.sol";
import {PieceSetCommitment} from "./lib/PieceSetCommitment.sol";
import {EvidenceResult} from "./types/EvidenceResult.sol";
import {EvidenceTypes} from "./types/EvidenceTypes.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {SharedTypes} from "./types/SharedTypes.sol";

/**
 * @title Experimental sector evidence adapter
 * @notice Accepts authenticated placements for every piece in a committed PoRep Market piece set.
 * @dev This initial-placement experiment intentionally reports current evidence as inactive.
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
        uint32 pieceIndex;
        uint32 pieceCount;
    }

    /**
     * @notice Authenticated placement of one committed piece.
     * @param pieceCidDigest CommP multihash digest.
     * @param sectorNumber Sector reported by the miner callback.
     * @param paddedSize Padded piece size in bytes.
     * @param minimumCommitmentEpoch Minimum sector commitment epoch.
     * @param accepted Whether this piece index has been accepted.
     */
    struct PiecePlacement {
        bytes32 pieceCidDigest;
        uint64 sectorNumber;
        uint64 paddedSize;
        int64 minimumCommitmentEpoch;
        bool accepted;
    }

    /**
     * @notice Compact per-deal progress for the committed piece set.
     * @param providerActorId Provider authenticated by the first accepted callback.
     * @param pieceCount Number of committed pieces.
     * @param acceptedPieceCount Number of unique accepted piece indexes.
     * @param activated Whether PoRep Market consumed the completed receipt.
     * @param minimumCommitmentEpoch Lowest commitment epoch across accepted pieces.
     * @param acceptedBytes Sum of padded sizes for unique accepted indexes.
     */
    struct ManifestReceipt {
        uint64 providerActorId;
        uint32 pieceCount;
        uint32 acceptedPieceCount;
        bool activated;
        int64 minimumCommitmentEpoch;
        uint256 acceptedBytes;
    }

    // @custom:storage-location erc7201:porepmarket.storage.SectorEvidenceAdapterStorage
    struct SectorEvidenceAdapterStorage {
        IPoRepMarket _poRepMarket;
        mapping(uint256 dealId => ManifestReceipt receipt) _manifestReceipts;
        mapping(uint256 dealId => mapping(uint32 pieceIndex => PiecePlacement placement)) _piecePlacements;
        mapping(uint256 dealId => uint64[] sectorNumbers) _sectorNumbers;
        mapping(uint256 dealId => mapping(uint64 sectorNumber => uint64 coveredBytes)) _sectorCoveredBytes;
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
     * @notice Records one newly accepted committed piece placement.
     * @param dealId PoRep Market deal ID.
     * @param pieceIndex Zero-based canonical piece index.
     * @param providerActorId Authenticated miner actor ID.
     * @param sectorNumber Sector reported by the miner callback.
     * @param pieceCidDigest CommP multihash digest.
     * @param paddedSize Padded piece size in bytes.
     * @param minimumCommitmentEpoch Minimum sector commitment epoch.
     * @param receiptEpoch Chain epoch when the callback was accepted.
     */
    event PiecePlacementAccepted(
        uint256 indexed dealId,
        uint32 indexed pieceIndex,
        uint64 indexed providerActorId,
        uint64 sectorNumber,
        bytes32 pieceCidDigest,
        uint64 paddedSize,
        int64 minimumCommitmentEpoch,
        CommonTypes.ChainEpoch receiptEpoch
    );

    /**
     * @notice Records exact receipt of every committed piece and byte.
     * @param dealId PoRep Market deal ID.
     * @param pieceCount Number of accepted unique indexes.
     * @param acceptedBytes Sum of accepted padded sizes.
     */
    event PieceSetCompleted(uint256 indexed dealId, uint32 indexed pieceCount, uint256 indexed acceptedBytes);

    /**
     * @notice Records one-time consumption of a complete piece-set receipt.
     * @param dealId PoRep Market deal ID.
     * @param pieceCount Number of activated pieces.
     * @param coveredBytes Exact activated byte total.
     */
    event PlacementActivated(uint256 indexed dealId, uint32 indexed pieceCount, uint256 indexed coveredBytes);

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
     * @dev 0x8599d34e
     */
    error InsufficientCommitmentEpoch(int64 required, int64 actual);
    /**
     * @dev 0xecb06d2e
     */
    error UnexpectedPieceCidHeader();
    /**
     * @dev 0x6888df45
     */
    error UnexpectedReceiptProvider(uint64 expected, uint64 actual);
    /**
     * @dev 0x5b47989c
     */
    error UnexpectedReceiptPieceCount(uint32 expected, uint32 actual);
    /**
     * @dev 0xd8b4f967
     */
    error InvalidPaddedSize();
    /**
     * @dev 0xd61193d3
     */
    error ConflictingPiecePlacement(uint256 dealId, uint32 pieceIndex);

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
     * @param payloadBytes ABI encoding of deal ID, piece index, piece count, and proof.
     * @param canonicalPieceCid Whether the callback used the canonical CommP CID prefix.
     * @param providerActorId Authenticated miner actor ID.
     * @param pieceDigest CommP multihash digest.
     * @param paddedSize Padded piece size in bytes.
     * @param sectorNumber Sector reported by the miner callback.
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
        if (paddedSize == 0) revert InvalidPaddedSize();
        if (payloadBytes.length < 160) revert InvalidPayloadLength(payloadBytes.length);

        (uint256 dealId, uint32 pieceIndex, uint32 pieceCount, bytes32[] memory proof) =
            abi.decode(payloadBytes, (uint256, uint32, uint32, bytes32[]));
        if (payloadBytes.length != 160 + proof.length * 32) revert InvalidPayloadLength(payloadBytes.length);

        PlacementInput memory placement = PlacementInput({
            pieceDigest: pieceDigest,
            providerActorId: providerActorId,
            paddedSize: paddedSize,
            sectorNumber: sectorNumber,
            minimumCommitmentEpoch: minimumCommitmentEpoch,
            pieceIndex: pieceIndex,
            pieceCount: pieceCount
        });
        uint256 requestedSizeBytes = _validateDealAndPiece(dealId, placement, proof);
        _acceptPlacement(dealId, placement, requestedSizeBytes);
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
        SectorEvidenceAdapterStorage storage $ = s();
        ManifestReceipt storage receipt = $._manifestReceipts[context.dealId];
        if (
            receipt.activated || receipt.pieceCount == 0 || receipt.acceptedPieceCount != receipt.pieceCount
                || receipt.acceptedBytes != context.requestedSizeBytes
                || receipt.providerActorId != CommonTypes.FilActorId.unwrap(context.provider)
                || receipt.minimumCommitmentEpoch < 1
                || uint256(uint64(receipt.minimumCommitmentEpoch)) < block.number + context.durationEpochs
        ) {
            return _rejectedActivation();
        }

        receipt.activated = true;
        emit PlacementActivated(context.dealId, receipt.pieceCount, receipt.acceptedBytes);
        return SharedTypes.ActivationDecision({
            coveredBytes: receipt.acceptedBytes, reasonCode: 0, result: EvidenceResult.ACCEPTED
        });
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function refreshEvidenceStatus(SharedTypes.ActivationContext calldata, bytes calldata)
        external
        view
        onlyPoRepMarket
        returns (SharedTypes.EvidenceStatus memory status)
    {
        return _inactiveStatus();
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function currentEvidenceStatus(SharedTypes.ActivationContext calldata)
        external
        view
        onlyPoRepMarket
        returns (SharedTypes.EvidenceStatus memory status)
    {
        return _inactiveStatus();
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function getExpiration(uint256) external pure returns (CommonTypes.ChainEpoch expiration) {
        return CommonTypes.ChainEpoch.wrap(0);
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
     * @notice Returns compact piece-set progress for one deal.
     * @param dealId PoRep Market deal ID.
     * @return receipt Stored progress receipt.
     */
    function getManifestReceipt(uint256 dealId) external view returns (ManifestReceipt memory receipt) {
        return s()._manifestReceipts[dealId];
    }

    /**
     * @notice Returns one authenticated piece placement.
     * @param dealId PoRep Market deal ID.
     * @param pieceIndex Zero-based piece index.
     * @return placement Stored placement, or an empty placement when the index has not been accepted.
     */
    function getPiecePlacement(uint256 dealId, uint32 pieceIndex)
        external
        view
        returns (PiecePlacement memory placement)
    {
        return s()._piecePlacements[dealId][pieceIndex];
    }

    /**
     * @notice Returns whether one piece index has already been accepted for a deal.
     * @param dealId PoRep Market deal ID.
     * @param pieceIndex Zero-based piece index.
     * @return accepted Whether a placement is stored for this index.
     */
    function isPieceAccepted(uint256 dealId, uint32 pieceIndex) public view returns (bool accepted) {
        return s()._piecePlacements[dealId][pieceIndex].accepted;
    }

    /**
     * @notice Returns the number of unique sectors recorded for a deal.
     * @param dealId PoRep Market deal ID.
     * @return count Number of stored sector numbers.
     */
    function getSectorCount(uint256 dealId) external view returns (uint256 count) {
        return s()._sectorNumbers[dealId].length;
    }

    /**
     * @notice Returns one stored sector number by insertion index.
     * @param dealId PoRep Market deal ID.
     * @param sectorIndex Zero-based sector-list index.
     * @return sectorNumber Stored sector number.
     */
    function getSectorNumber(uint256 dealId, uint256 sectorIndex) external view returns (uint64 sectorNumber) {
        return s()._sectorNumbers[dealId][sectorIndex];
    }

    /**
     * @notice Returns the deal bytes placed in one sector.
     * @param dealId PoRep Market deal ID.
     * @param sectorNumber Sector number to query.
     * @return coveredBytes Sum of accepted padded piece sizes in the sector.
     */
    function getSectorCoveredBytes(uint256 dealId, uint64 sectorNumber) external view returns (uint64 coveredBytes) {
        return s()._sectorCoveredBytes[dealId][sectorNumber];
    }

    function _validateDealAndPiece(uint256 dealId, PlacementInput memory placement, bytes32[] memory proof)
        private
        view
        returns (uint256 requestedSizeBytes)
    {
        SectorEvidenceAdapterStorage storage $ = s();
        PoRepTypes.Deal memory deal = $._poRepMarket.getDeal(dealId);
        if (deal.evidenceAdapter != address(this)) {
            revert UnexpectedEvidenceAdapter(dealId, deal.evidenceAdapter);
        }

        uint64 expectedProvider = CommonTypes.FilActorId.unwrap(deal.provider);
        if (placement.providerActorId != expectedProvider) {
            revert UnexpectedProvider(expectedProvider, placement.providerActorId);
        }

        PoRepTypes.DealTerms memory terms = $._poRepMarket.getDealTerms(dealId);
        bytes32 merkleRoot = PieceSetCommitment.root(
            placement.pieceIndex, placement.pieceCount, placement.pieceDigest, placement.paddedSize, proof
        );
        bytes32 reconstructedCommitment =
            PieceSetCommitment.commitment(placement.pieceCount, terms.requestedSizeBytes, merkleRoot);
        SharedTypes.DealData memory dealData = $._poRepMarket.getDealData(dealId);
        if (dealData.manifestHash != reconstructedCommitment) revert UnexpectedPieceSetCommitment();

        int64 requiredCommitmentEpoch =
            CommonTypes.ChainEpoch.unwrap(deal.proposedAtEpoch) + int64(uint64(terms.durationEpochs));
        if (placement.minimumCommitmentEpoch < requiredCommitmentEpoch) {
            revert InsufficientCommitmentEpoch(requiredCommitmentEpoch, placement.minimumCommitmentEpoch);
        }
        return terms.requestedSizeBytes;
    }

    function _acceptPlacement(uint256 dealId, PlacementInput memory placement, uint256 requestedSizeBytes) private {
        SectorEvidenceAdapterStorage storage $ = s();
        ManifestReceipt storage receipt = $._manifestReceipts[dealId];
        if (receipt.pieceCount == 0) {
            receipt.providerActorId = placement.providerActorId;
            receipt.pieceCount = placement.pieceCount;
        } else {
            if (receipt.providerActorId != placement.providerActorId) {
                revert UnexpectedReceiptProvider(receipt.providerActorId, placement.providerActorId);
            }
            if (receipt.pieceCount != placement.pieceCount) {
                revert UnexpectedReceiptPieceCount(receipt.pieceCount, placement.pieceCount);
            }
        }

        PiecePlacement storage stored = $._piecePlacements[dealId][placement.pieceIndex];
        if (stored.accepted) {
            if (
                stored.pieceCidDigest != placement.pieceDigest || stored.sectorNumber != placement.sectorNumber
                    || stored.paddedSize != placement.paddedSize
                    || stored.minimumCommitmentEpoch != placement.minimumCommitmentEpoch
            ) {
                revert ConflictingPiecePlacement(dealId, placement.pieceIndex);
            }
            return;
        }

        stored.pieceCidDigest = placement.pieceDigest;
        stored.sectorNumber = placement.sectorNumber;
        stored.paddedSize = placement.paddedSize;
        stored.minimumCommitmentEpoch = placement.minimumCommitmentEpoch;
        stored.accepted = true;

        uint64 sectorCoveredBytes = $._sectorCoveredBytes[dealId][placement.sectorNumber];
        if (sectorCoveredBytes == 0) $._sectorNumbers[dealId].push(placement.sectorNumber);
        $._sectorCoveredBytes[dealId][placement.sectorNumber] = sectorCoveredBytes + placement.paddedSize;

        if (receipt.acceptedPieceCount == 0) {
            receipt.minimumCommitmentEpoch = placement.minimumCommitmentEpoch;
        } else if (
            receipt.minimumCommitmentEpoch != 0 && placement.minimumCommitmentEpoch < receipt.minimumCommitmentEpoch
        ) {
            receipt.minimumCommitmentEpoch = placement.minimumCommitmentEpoch;
        }
        receipt.acceptedPieceCount += 1;
        receipt.acceptedBytes += placement.paddedSize;

        CommonTypes.ChainEpoch receiptEpoch = CommonTypes.ChainEpoch.wrap(int64(uint64(block.number)));
        emit PiecePlacementAccepted(
            dealId,
            placement.pieceIndex,
            placement.providerActorId,
            placement.sectorNumber,
            placement.pieceDigest,
            placement.paddedSize,
            placement.minimumCommitmentEpoch,
            receiptEpoch
        );
        if (receipt.acceptedPieceCount == receipt.pieceCount && receipt.acceptedBytes == requestedSizeBytes) {
            emit PieceSetCompleted(dealId, receipt.pieceCount, receipt.acceptedBytes);
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

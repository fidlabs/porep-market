// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

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
 * @notice Accepts and refreshes one authenticated sector placement for one PoRep Market deal.
 * @dev This experiment supports one FIP-0109 placement and one bounded FIP-0112 status check.
 */
contract SectorEvidenceAdapter is IStorageEvidenceAdapter {
    using CalldataUtils for CalldataSlice;
    using FVMAddress for address;
    using FVMMiner for uint64;

    /**
     * @notice Version of the canonical ABI-encoded notification payload.
     */
    uint8 public constant PAYLOAD_VERSION = 1;

    uint104 private constant CANONICAL_COMMP_CID_PREFIX = 0x83d82a5828000181e203922020;

    struct NotificationPayload {
        uint8 version;
        uint64 chainId;
        address adapter;
        uint256 dealId;
        bytes32 pieceSetCommitment;
        uint64 placementNonce;
    }

    struct ExpectedPlacement {
        uint64 placementNonce;
        bool registered;
    }

    // solhint-disable-next-line gas-struct-packing
    struct PlacementReceipt {
        uint256 dealId;
        bytes32 pieceCidDigest;
        bytes32 pieceSetCommitment;
        uint64 providerActorId;
        uint64 paddedSize;
        uint64 sectorNumber;
        uint64 placementNonce;
        int64 minimumCommitmentEpoch;
        CommonTypes.ChainEpoch receiptEpoch;
        bool accepted;
        bool activated;
    }

    // FIP-0109 fixes this entry-point name.
    // solhint-disable func-name-mixedcase
    /**
     * @notice PoRep Market allowed to consume adapter lifecycle results.
     */
    IPoRepMarket public immutable POREP_MARKET;

    mapping(uint256 dealId => PlacementReceipt receipt) private _receipts;
    mapping(uint256 dealId => ExpectedPlacement placement) private _expectedPlacements;
    mapping(uint64 placementNonce => uint256 dealId) private _placementNonces;
    mapping(bytes32 placementKey => uint256 dealId) private _placementDeals;
    mapping(uint256 dealId => SharedTypes.EvidenceStatus status) private _evidenceStatuses;
    mapping(uint256 dealId => CommonTypes.ChainEpoch expiration) private _expirations;

    /**
     * @notice Records the per-deal value that the notification payload must contain.
     * @param dealId PoRep Market deal ID.
     * @param placementNonce Non-zero value selected before sealing.
     */
    event PlacementRegistered(uint256 indexed dealId, uint64 indexed placementNonce);

    /**
     * @notice Records an authenticated sector placement.
     * @param dealId PoRep Market deal ID.
     * @param providerActorId Authenticated miner actor ID.
     * @param sectorNumber Sector containing the piece.
     * @param pieceCidDigest PieceCID digest reported by the miner.
     * @param paddedSize Padded piece size reported by the miner.
     * @param minimumCommitmentEpoch Minimum sector commitment epoch.
     * @param pieceSetCommitment Deal manifest commitment reconstructed from the piece.
     * @param placementNonce Placement nonce from the payload.
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
        uint64 placementNonce,
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
     * @dev 0xdb8ae859
     */
    error UnexpectedSectorCount(uint256 count);
    /**
     * @dev 0x10d120e5
     */
    error UnexpectedPieceCount(uint256 count);
    /**
     * @dev 0xf61df232
     */
    error InvalidPayloadLength(uint256 length);
    /**
     * @dev 0x3180c7dd
     */
    error UnexpectedPayloadVersion(uint8 version);
    /**
     * @dev 0x799638a8
     */
    error UnexpectedChainId(uint256 expected, uint256 actual);
    /**
     * @dev 0x14057de2
     */
    error UnexpectedAdapter(address expected, address actual);
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
     * @dev 0x3d015b9e
     */
    error UnexpectedPlacementNonce(uint64 expected, uint64 actual);
    /**
     * @dev 0xc91367c7
     */
    error PlacementNotRegistered(uint256 dealId);
    /**
     * @dev 0xb6c4f360
     */
    error ConflictingPlacementRegistration(uint256 dealId, uint64 expected, uint64 actual);
    /**
     * @dev 0x7834ea65
     */
    error PlacementNonceAlreadyAssigned(uint64 nonce, uint256 existingDealId, uint256 requestedDealId);
    /**
     * @dev 0x048fdc35
     */
    error InvalidPlacementNonce();
    /**
     * @dev 0x1ece0326
     */
    error InvalidRegistrationLength(uint256 length);
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
        if (msg.sender != address(POREP_MARKET)) revert OnlyPoRepMarket();
        _;
    }

    constructor(address poRepMarketAddress) {
        if (poRepMarketAddress == address(0)) revert InvalidPoRepMarketAddress();
        POREP_MARKET = IPoRepMarket(poRepMarketAddress);
    }

    /**
     * @notice Receives one FIP-0109 SectorContentChanged callback.
     * @dev The calldata decoder reads the final `bytes` argument directly from message calldata.
     * @param method Filecoin method number.
     * @param codec Filecoin parameter codec.
     * @param params CBOR-encoded SectorContentChanged parameters.
     * @return exitCode Filecoin exit code.
     * @return returnCodec Codec for the returned acceptance bitmap.
     * @return returnData CBOR-encoded acceptance bitmap.
     */
    function handle_filecoin_method(uint64 method, uint64 codec, bytes calldata params)
        external
        returns (uint32 exitCode, uint64 returnCodec, bytes memory returnData)
    {
        params;
        if (method != SECTOR_CONTENT_CHANGED) revert UnexpectedMethod(method);
        if (codec != CBOR_CODEC) revert UnexpectedCodec(codec);

        uint64 providerActorId = msg.sender.safeActorId();
        if (!providerActorId.isMiner()) revert CallerIsNotMiner(providerActorId);

        (uint256 sectorCount, uint256 offset) = FVMSectorContentChanged.readParamsHeader();
        if (sectorCount != 1) revert UnexpectedSectorCount(sectorCount);

        SectorChangesHeader memory sector;
        offset = FVMSectorContentChanged.readSectorHeader(offset, sector);
        if (sector.numPieces != 1) revert UnexpectedPieceCount(sector.numPieces);

        _validatePieceCidHeader(offset);
        PieceChangeIter memory piece;
        FVMSectorContentChanged.readPiece(offset, piece);
        bytes memory payloadBytes = piece.payload.load();
        if (payloadBytes.length != 192) revert InvalidPayloadLength(payloadBytes.length);
        NotificationPayload memory payload = abi.decode(payloadBytes, (NotificationPayload));

        _validatePayload(payload);
        _validateDealAndPiece(payload, providerActorId, piece, sector.minimumCommitmentEpoch);
        _acceptPlacement(payload, providerActorId, piece, sector);

        SectorContentChangedReturn memory result;
        result.sectors = new SectorReturn[](1);
        FVMSectorContentChanged.initSectorReturn(result.sectors[0], 1);
        FVMSectorContentChanged.accept(result.sectors[0], 0);
        return (0, CBOR_CODEC, FVMSectorContentChanged.encodeReturn(result));
    }

    // solhint-enable func-name-mixedcase

    /// @inheritdoc IStorageEvidenceAdapter
    function submitEvidenceBatch(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        onlyPoRepMarket
        returns (SharedTypes.ActivationDecision memory decision)
    {
        if (evidenceData.length == 0) return _rejectedActivation();
        if (evidenceData.length != 32) revert InvalidRegistrationLength(evidenceData.length);

        uint64 placementNonce = abi.decode(evidenceData, (uint64));
        if (placementNonce == 0) revert InvalidPlacementNonce();
        _validateRegistrationContext(context);

        ExpectedPlacement storage expected = _expectedPlacements[context.dealId];
        if (expected.registered) {
            if (expected.placementNonce != placementNonce) {
                revert ConflictingPlacementRegistration(context.dealId, expected.placementNonce, placementNonce);
            }
            return _rejectedActivation();
        }

        uint256 assignedDealId = _placementNonces[placementNonce];
        if (assignedDealId != 0) {
            revert PlacementNonceAlreadyAssigned(placementNonce, assignedDealId, context.dealId);
        }

        expected.placementNonce = placementNonce;
        expected.registered = true;
        _placementNonces[placementNonce] = context.dealId;
        emit PlacementRegistered(context.dealId, placementNonce);
        return _rejectedActivation();
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function activateEvidence(SharedTypes.ActivationContext calldata context, bytes calldata)
        external
        onlyPoRepMarket
        returns (SharedTypes.ActivationDecision memory decision)
    {
        PlacementReceipt storage receipt = _receipts[context.dealId];
        if (
            !receipt.accepted || receipt.activated || receipt.dealId != context.dealId
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

        PlacementReceipt memory receipt = _receipts[context.dealId];
        bool receiptMatches = receipt.accepted && receipt.activated && receipt.dealId == context.dealId
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

        CommonTypes.ChainEpoch refreshEpoch = CommonTypes.ChainEpoch.wrap(int64(uint64(block.number)));
        status = SharedTypes.EvidenceStatus({
            activeCoveredBytes: active ? receipt.paddedSize : 0,
            lastEvidenceRefreshEpoch: refreshEpoch,
            reasonCode: 0,
            result: active ? EvidenceResult.ACTIVE : EvidenceResult.INACTIVE,
            checkedClaims: 1,
            totalClaims: 1
        });
        _evidenceStatuses[context.dealId] = status;
        // The bound above makes the Filecoin ChainEpoch conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        _expirations[context.dealId] = CommonTypes.ChainEpoch.wrap(active ? int64(expiration) : int64(0));
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function currentEvidenceStatus(SharedTypes.ActivationContext calldata context)
        external
        view
        onlyPoRepMarket
        returns (SharedTypes.EvidenceStatus memory status)
    {
        status = _evidenceStatuses[context.dealId];
        if (status.result == EvidenceResult.NONE) return _inactiveStatus();
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function getExpiration(uint256 dealId) external view returns (CommonTypes.ChainEpoch expiration) {
        return _expirations[dealId];
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function isOperational() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IStorageEvidenceAdapter
    function getEvidenceType() external pure returns (uint8) {
        return EvidenceTypes.SECTOR_PLACEMENT;
    }

    /**
     * @notice Returns the accepted placement and activation-consumption state for one deal.
     * @param dealId PoRep Market deal ID.
     * @return receipt Stored placement receipt.
     */
    function getReceipt(uint256 dealId) external view returns (PlacementReceipt memory receipt) {
        return _receipts[dealId];
    }

    function _validatePayload(NotificationPayload memory payload) private view {
        if (payload.version != PAYLOAD_VERSION) revert UnexpectedPayloadVersion(payload.version);
        if (payload.chainId != block.chainid) revert UnexpectedChainId(block.chainid, payload.chainId);
        if (payload.adapter != address(this)) revert UnexpectedAdapter(address(this), payload.adapter);
    }

    function _validateDealAndPiece(
        NotificationPayload memory payload,
        uint64 providerActorId,
        PieceChangeIter memory piece,
        int64 minimumCommitmentEpoch
    ) private view {
        PoRepTypes.Deal memory deal = POREP_MARKET.getDeal(payload.dealId);
        if (deal.evidenceAdapter != address(this)) {
            revert UnexpectedEvidenceAdapter(payload.dealId, deal.evidenceAdapter);
        }

        uint64 expectedProvider = CommonTypes.FilActorId.unwrap(deal.provider);
        if (providerActorId != expectedProvider) revert UnexpectedProvider(expectedProvider, providerActorId);

        bytes32 reconstructedCommitment = keccak256(abi.encode(piece.digest, piece.paddedSize));
        SharedTypes.DealData memory dealData = POREP_MARKET.getDealData(payload.dealId);
        if (payload.pieceSetCommitment != reconstructedCommitment || dealData.manifestHash != reconstructedCommitment) {
            revert UnexpectedPieceSetCommitment();
        }

        PoRepTypes.DealTerms memory terms = POREP_MARKET.getDealTerms(payload.dealId);
        if (piece.paddedSize != terms.requestedSizeBytes) {
            revert UnexpectedPaddedSize(terms.requestedSizeBytes, piece.paddedSize);
        }

        int64 requiredCommitmentEpoch =
            CommonTypes.ChainEpoch.unwrap(deal.proposedAtEpoch) + int64(uint64(terms.durationEpochs));
        if (minimumCommitmentEpoch < requiredCommitmentEpoch) {
            revert InsufficientCommitmentEpoch(requiredCommitmentEpoch, minimumCommitmentEpoch);
        }

        ExpectedPlacement memory expected = _expectedPlacements[payload.dealId];
        if (!expected.registered) revert PlacementNotRegistered(payload.dealId);
        if (payload.placementNonce != expected.placementNonce) {
            revert UnexpectedPlacementNonce(expected.placementNonce, payload.placementNonce);
        }
    }

    function _validateRegistrationContext(SharedTypes.ActivationContext calldata context) private view {
        PoRepTypes.Deal memory deal = POREP_MARKET.getDeal(context.dealId);
        if (deal.evidenceAdapter != address(this)) {
            revert UnexpectedEvidenceAdapter(context.dealId, deal.evidenceAdapter);
        }

        uint64 expectedProvider = CommonTypes.FilActorId.unwrap(deal.provider);
        uint64 actualProvider = CommonTypes.FilActorId.unwrap(context.provider);
        if (actualProvider != expectedProvider) revert UnexpectedProvider(expectedProvider, actualProvider);

        uint256 expectedSize = POREP_MARKET.getDealTerms(context.dealId).requestedSizeBytes;
        if (context.requestedSizeBytes != expectedSize) {
            revert UnexpectedPaddedSize(expectedSize, uint64(context.requestedSizeBytes));
        }
    }

    function _validatePieceCidHeader(uint256 offset) private pure {
        uint104 prefix;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            prefix := shr(152, calldataload(offset))
        }
        if (prefix != CANONICAL_COMMP_CID_PREFIX) revert UnexpectedPieceCidHeader();
    }

    function _acceptPlacement(
        NotificationPayload memory payload,
        uint64 providerActorId,
        PieceChangeIter memory piece,
        SectorChangesHeader memory sector
    ) private {
        PlacementReceipt storage existing = _receipts[payload.dealId];
        if (existing.accepted) {
            if (
                existing.providerActorId != providerActorId || existing.pieceCidDigest != piece.digest
                    || existing.paddedSize != piece.paddedSize || existing.sectorNumber != sector.sector
                    || existing.minimumCommitmentEpoch != sector.minimumCommitmentEpoch
                    || existing.pieceSetCommitment != payload.pieceSetCommitment
                    || existing.placementNonce != payload.placementNonce
            ) {
                revert ConflictingPlacement(payload.dealId);
            }
            return;
        }

        bytes32 placementKey = keccak256(abi.encode(providerActorId, sector.sector, piece.digest, piece.paddedSize));
        uint256 existingDealId = _placementDeals[placementKey];
        if (existingDealId != 0) revert PlacementAlreadyAssigned(existingDealId, payload.dealId);

        CommonTypes.ChainEpoch receiptEpoch = CommonTypes.ChainEpoch.wrap(int64(uint64(block.number)));
        _receipts[payload.dealId] = PlacementReceipt({
            dealId: payload.dealId,
            providerActorId: providerActorId,
            pieceCidDigest: piece.digest,
            paddedSize: piece.paddedSize,
            sectorNumber: sector.sector,
            minimumCommitmentEpoch: sector.minimumCommitmentEpoch,
            pieceSetCommitment: payload.pieceSetCommitment,
            placementNonce: payload.placementNonce,
            receiptEpoch: receiptEpoch,
            accepted: true,
            activated: false
        });
        _placementDeals[placementKey] = payload.dealId;

        emit PlacementAccepted(
            payload.dealId,
            providerActorId,
            sector.sector,
            piece.digest,
            piece.paddedSize,
            sector.minimumCommitmentEpoch,
            payload.pieceSetCommitment,
            payload.placementNonce,
            receiptEpoch
        );
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
}

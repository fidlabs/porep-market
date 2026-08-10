// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {CBOR_CODEC} from "fvm-solidity/FVMCodec.sol";
import {FVMAddress} from "fvm-solidity/FVMAddress.sol";
import {USR_NOT_FOUND} from "fvm-solidity/FVMErrors.sol";
import {SECTOR_CONTENT_CHANGED} from "fvm-solidity/FVMMethod.sol";
import {FVMSector, SectorStatus} from "fvm-solidity/FVMSector.sol";
import {FVMMinerActor} from "fvm-solidity/mocks/FVMMinerActor.sol";
import {MockFVMTest} from "fvm-solidity/mocks/MockFVMTest.sol";
import {
    FVMSectorContentChanged,
    PieceChange,
    SectorChanges,
    SectorContentChangedParams,
    SectorContentChangedReturn
} from "fvm-solidity/FVMSectorContentChanged.sol";
import {SectorEvidenceAdapter} from "../src/SectorEvidenceAdapter.sol";
import {EvidenceResult} from "../src/types/EvidenceResult.sol";
import {EvidenceTypes} from "../src/types/EvidenceTypes.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";

contract SectorEvidenceMarketMock {
    mapping(uint256 dealId => PoRepTypes.Deal deal) private _deals;
    mapping(uint256 dealId => SharedTypes.DealData data) private _dealData;
    mapping(uint256 dealId => PoRepTypes.DealTerms terms) private _dealTerms;
    mapping(uint64 providerActorId => uint256 committedBytes) private _committedBytes;

    function setDeal(
        uint256 dealId,
        uint64 provider,
        address evidenceAdapter,
        bytes32 manifestHash,
        uint256 requestedSizeBytes,
        uint64 durationEpochs,
        int64 proposedAtEpoch
    ) external {
        _deals[dealId] = PoRepTypes.Deal({
            dealId: dealId,
            client: address(0xC1E17),
            provider: CommonTypes.FilActorId.wrap(provider),
            offerId: 1,
            state: 20,
            evidenceAdapter: evidenceAdapter,
            dealType: 1,
            validator: address(0),
            railId: 0,
            proposedAtEpoch: CommonTypes.ChainEpoch.wrap(proposedAtEpoch)
        });
        _dealData[dealId] = SharedTypes.DealData({manifestHash: manifestHash, manifestLocation: "test"});
        _dealTerms[dealId] =
            PoRepTypes.DealTerms({requestedSizeBytes: requestedSizeBytes, durationEpochs: durationEpochs});
    }

    function getDeal(uint256 dealId) external view returns (PoRepTypes.Deal memory) {
        return _deals[dealId];
    }

    function getDealData(uint256 dealId) external view returns (SharedTypes.DealData memory) {
        return _dealData[dealId];
    }

    function getDealTerms(uint256 dealId) external view returns (PoRepTypes.DealTerms memory) {
        return _dealTerms[dealId];
    }

    function activate(SectorEvidenceAdapter adapter, SharedTypes.ActivationContext calldata context)
        external
        returns (SharedTypes.ActivationDecision memory)
    {
        SharedTypes.ActivationDecision memory decision = adapter.activateEvidence(context, "");
        if (decision.result == EvidenceResult.ACCEPTED) {
            _deals[context.dealId].state = 30;
            _committedBytes[CommonTypes.FilActorId.unwrap(context.provider)] += decision.coveredBytes;
        }
        return decision;
    }

    function committedBytes(uint64 providerActorId) external view returns (uint256) {
        return _committedBytes[providerActorId];
    }

    function submit(
        SectorEvidenceAdapter adapter,
        SharedTypes.ActivationContext calldata context,
        bytes calldata evidenceData
    ) external returns (SharedTypes.ActivationDecision memory) {
        return adapter.submitEvidenceBatch(context, evidenceData);
    }

    function refresh(
        SectorEvidenceAdapter adapter,
        SharedTypes.ActivationContext calldata context,
        bytes calldata evidenceData
    ) external returns (SharedTypes.EvidenceStatus memory) {
        return adapter.refreshEvidenceStatus(context, evidenceData);
    }

    function current(SectorEvidenceAdapter adapter, SharedTypes.ActivationContext calldata context)
        external
        view
        returns (SharedTypes.EvidenceStatus memory)
    {
        return adapter.currentEvidenceStatus(context);
    }
}

contract SectorEvidenceAdapterTest is MockFVMTest {
    using FVMAddress for uint64;

    uint8 internal constant PAYLOAD_VERSION = 1;
    uint64 internal constant PROVIDER = 1004;
    uint64 internal constant OTHER_PROVIDER = 1005;
    uint64 internal constant SECTOR = 2;
    uint64 internal constant PADDED_SIZE = 2_097_152;
    uint64 internal constant DURATION = 518_400;
    int64 internal constant PROPOSED_AT = 100;
    int64 internal constant MINIMUM_COMMITMENT_EPOCH = PROPOSED_AT + int64(uint64(DURATION));
    uint256 internal constant DEAL_ID = 1;
    uint256 internal constant OTHER_DEAL_ID = 2;
    uint64 internal constant PLACEMENT_NONCE = 11;

    bytes internal constant PIECE_CID =
        hex"0181e203922020c47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b";
    bytes internal constant MALFORMED_PIECE_CID =
        hex"0281e203922020c47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b";
    bytes internal constant OTHER_PIECE_CID =
        hex"0181e203922020cdf33e1783f2ff8261e66f95858ff85f976bbc0bf05ce8476d3e360832165cd0";
    bytes32 internal constant PIECE_DIGEST = 0xc47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b;

    SectorEvidenceMarketMock internal market;
    SectorEvidenceAdapter internal adapter;
    FVMMinerActor internal miner;
    bytes32 internal pieceSetCommitment;

    function setUp() public override {
        super.setUp();
        market = new SectorEvidenceMarketMock();
        adapter = new SectorEvidenceAdapter(address(market));
        miner = mockMiner(PROVIDER);
        pieceSetCommitment = keccak256(abi.encode(PIECE_DIGEST, PADDED_SIZE));
        market.setDeal(DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT);
        _registerPlacement(DEAL_ID, PLACEMENT_NONCE);
    }

    function testPayloadEncodingFixedVector() public pure {
        bytes memory encoded = abi.encode(
            PAYLOAD_VERSION,
            uint64(31_415_926),
            address(0x1111111111111111111111111111111111111111),
            uint256(7),
            bytes32(0x2222222222222222222222222222222222222222222222222222222222222222),
            uint64(0)
        );

        assertEq(
            encoded,
            hex"0000000000000000000000000000000000000000000000000000000000000001"
            hex"0000000000000000000000000000000000000000000000000000000001df5e76"
            hex"0000000000000000000000001111111111111111111111111111111111111111"
            hex"0000000000000000000000000000000000000000000000000000000000000007"
            hex"2222222222222222222222222222222222222222222222222222222222222222"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
        );
    }

    function testValidReceiptActivatesExactBytesOnce() public {
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );

        SharedTypes.ActivationDecision memory first = market.activate(adapter, _context(DEAL_ID, PROVIDER));
        SharedTypes.ActivationDecision memory second = market.activate(adapter, _context(DEAL_ID, PROVIDER));
        SectorEvidenceAdapter.PlacementReceipt memory receipt = adapter.getReceipt(DEAL_ID);

        assertEq(first.coveredBytes, PADDED_SIZE);
        assertEq(first.result, EvidenceResult.ACCEPTED);
        assertEq(second.coveredBytes, 0);
        assertEq(second.result, EvidenceResult.REJECTED);
        assertEq(market.getDeal(DEAL_ID).state, 30);
        assertEq(market.committedBytes(PROVIDER), PADDED_SIZE);
        assertTrue(receipt.activated);
    }

    function testWrongProviderIsRejectedWithoutReceipt() public {
        market.setDeal(
            DEAL_ID, OTHER_PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT
        );

        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedProvider.selector, OTHER_PROVIDER, PROVIDER)
        );
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testWrongDealIsRejectedWithoutReceipt() public {
        market.setDeal(OTHER_DEAL_ID, PROVIDER, address(0xBAD), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT);

        vm.expectRevert(
            abi.encodeWithSelector(
                SectorEvidenceAdapter.UnexpectedEvidenceAdapter.selector, OTHER_DEAL_ID, address(0xBAD)
            )
        );
        _notify(
            OTHER_DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        assertFalse(adapter.getReceipt(OTHER_DEAL_ID).accepted);
    }

    function testIdenticalDealsRequireExactPreSealingBinding() public {
        market.setDeal(
            OTHER_DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT
        );
        _registerPlacement(DEAL_ID, PLACEMENT_NONCE);
        _registerPlacement(OTHER_DEAL_ID, 22);

        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedPlacementNonce.selector, uint64(22), PLACEMENT_NONCE)
        );
        _notify(
            OTHER_DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );

        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
        assertFalse(adapter.getReceipt(OTHER_DEAL_ID).accepted);
        assertEq(market.getDeal(DEAL_ID).state, 20);
        assertEq(market.getDeal(OTHER_DEAL_ID).state, 20);
        assertEq(market.committedBytes(PROVIDER), 0);
    }

    function testMalformedPieceCidHeaderIsRejected() public {
        vm.expectRevert(SectorEvidenceAdapter.UnexpectedPieceCidHeader.selector);
        _notifyWithPiece(
            MALFORMED_PIECE_CID,
            PADDED_SIZE,
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );

        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testWrongPieceIsRejectedWithoutReceipt() public {
        vm.expectRevert(SectorEvidenceAdapter.UnexpectedPieceSetCommitment.selector);
        _notifyWithPiece(
            OTHER_PIECE_CID,
            PADDED_SIZE,
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testWrongSizeIsRejectedWithoutReceipt() public {
        vm.expectRevert(SectorEvidenceAdapter.UnexpectedPieceSetCommitment.selector);
        _notifyWithPiece(
            PIECE_CID,
            PADDED_SIZE * 2,
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testPieceSizeDifferentFromDealTermsIsRejectedWithoutReceipt() public {
        market.setDeal(DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE * 2, DURATION, PROPOSED_AT);

        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedPaddedSize.selector, PADDED_SIZE * 2, PADDED_SIZE)
        );
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testIdenticalDuplicateIsIdempotent() public {
        vm.roll(700);
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        SectorEvidenceAdapter.PlacementReceipt memory beforeReceipt = adapter.getReceipt(DEAL_ID);

        vm.roll(701);
        SectorContentChangedReturn memory duplicate = _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        SectorEvidenceAdapter.PlacementReceipt memory afterReceipt = adapter.getReceipt(DEAL_ID);

        assertTrue((duplicate.sectors[0].accepted[0] & 1) != 0);
        assertEq(
            CommonTypes.ChainEpoch.unwrap(afterReceipt.receiptEpoch),
            CommonTypes.ChainEpoch.unwrap(beforeReceipt.receiptEpoch)
        );
        assertEq(afterReceipt.sectorNumber, beforeReceipt.sectorNumber);
        assertEq(afterReceipt.minimumCommitmentEpoch, beforeReceipt.minimumCommitmentEpoch);
        assertFalse(afterReceipt.activated);
    }

    function testConflictingDuplicateRevertsWithoutChangingReceipt() public {
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        SectorEvidenceAdapter.PlacementReceipt memory beforeReceipt = adapter.getReceipt(DEAL_ID);

        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.ConflictingPlacement.selector, DEAL_ID));
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR + 1,
            MINIMUM_COMMITMENT_EPOCH
        );
        SectorEvidenceAdapter.PlacementReceipt memory afterReceipt = adapter.getReceipt(DEAL_ID);

        assertEq(afterReceipt.sectorNumber, beforeReceipt.sectorNumber);
        assertEq(
            CommonTypes.ChainEpoch.unwrap(afterReceipt.receiptEpoch),
            CommonTypes.ChainEpoch.unwrap(beforeReceipt.receiptEpoch)
        );
        assertEq(afterReceipt.pieceSetCommitment, beforeReceipt.pieceSetCommitment);
        assertFalse(afterReceipt.activated);
    }

    function testCrossDealEvidenceCannotActivate() public {
        market.setDeal(
            OTHER_DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT
        );
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );

        SharedTypes.ActivationDecision memory decision = market.activate(adapter, _context(OTHER_DEAL_ID, PROVIDER));

        assertEq(decision.coveredBytes, 0);
        assertEq(decision.result, EvidenceResult.REJECTED);
        assertEq(market.getDeal(DEAL_ID).state, 20);
        assertEq(market.getDeal(OTHER_DEAL_ID).state, 20);
        assertEq(market.committedBytes(PROVIDER), 0);
        assertFalse(adapter.getReceipt(DEAL_ID).activated);
        assertFalse(adapter.getReceipt(OTHER_DEAL_ID).accepted);
    }

    function testSamePlacementCannotBeCreditedToAnotherDeal() public {
        market.setDeal(
            OTHER_DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT
        );
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );

        _registerPlacement(OTHER_DEAL_ID, 22);
        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.PlacementAlreadyAssigned.selector, DEAL_ID, OTHER_DEAL_ID)
        );
        _notify(
            OTHER_DEAL_ID, address(adapter), block.chainid, pieceSetCommitment, 22, SECTOR, MINIMUM_COMMITMENT_EPOCH
        );
        assertFalse(adapter.getReceipt(OTHER_DEAL_ID).accepted);
    }

    function testWrongSectorLocationDoesNotOverwriteActiveEvidence() public {
        int64 deadline = 4;
        int64 partition = 7;
        uint64 expiration = 600_000;
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        market.activate(adapter, _context(DEAL_ID, PROVIDER));
        miner.mockSector(SECTOR, SectorStatus.Active, deadline, partition, expiration);

        vm.roll(900);
        SharedTypes.EvidenceStatus memory first =
            market.refresh(adapter, _context(DEAL_ID, PROVIDER), abi.encode(deadline, partition));

        assertEq(first.result, EvidenceResult.ACTIVE);
        assertEq(first.activeCoveredBytes, PADDED_SIZE);
        assertEq(CommonTypes.ChainEpoch.unwrap(first.lastEvidenceRefreshEpoch), 900);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), int64(uint64(expiration)));

        vm.roll(901);
        vm.expectRevert(
            abi.encodeWithSelector(FVMSector.ValidateSectorStatusFailed.selector, int256(uint256(USR_NOT_FOUND)))
        );
        market.refresh(adapter, _context(DEAL_ID, PROVIDER), abi.encode(deadline + 1, partition));

        SharedTypes.EvidenceStatus memory current = market.current(adapter, _context(DEAL_ID, PROVIDER));
        assertEq(current.result, EvidenceResult.ACTIVE);
        assertEq(current.activeCoveredBytes, PADDED_SIZE);
        assertEq(CommonTypes.ChainEpoch.unwrap(current.lastEvidenceRefreshEpoch), 900);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), int64(uint64(expiration)));
    }

    function testConfirmedNonActiveSectorOverwritesActiveEvidence() public {
        int64 deadline = 4;
        int64 partition = 7;
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        market.activate(adapter, _context(DEAL_ID, PROVIDER));
        miner.mockSector(SECTOR, SectorStatus.Active, deadline, partition, 600_000);
        market.refresh(adapter, _context(DEAL_ID, PROVIDER), abi.encode(deadline, partition));

        miner.mockSectorStatus(SECTOR, SectorStatus.Faulty);
        SharedTypes.EvidenceStatus memory refreshed =
            market.refresh(adapter, _context(DEAL_ID, PROVIDER), abi.encode(deadline, partition));

        assertEq(refreshed.result, EvidenceResult.INACTIVE);
        assertEq(refreshed.activeCoveredBytes, 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), 0);
    }

    function testExpirationLookupFailureDoesNotStoreActiveEvidence() public {
        int64 deadline = 4;
        int64 partition = 7;
        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        market.activate(adapter, _context(DEAL_ID, PROVIDER));
        miner.mockSectorStatus(SECTOR, SectorStatus.Active);
        miner.mockSectorLocation(SECTOR, deadline, partition);

        vm.expectRevert(
            abi.encodeWithSelector(FVMSector.GetNominalSectorExpirationFailed.selector, int256(uint256(USR_NOT_FOUND)))
        );
        market.refresh(adapter, _context(DEAL_ID, PROVIDER), abi.encode(deadline, partition));

        SharedTypes.EvidenceStatus memory current = market.current(adapter, _context(DEAL_ID, PROVIDER));
        assertEq(current.result, EvidenceResult.INACTIVE);
        assertEq(current.activeCoveredBytes, 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(current.lastEvidenceRefreshEpoch), 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), 0);
    }

    function testPayloadFromAnotherChainIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedChainId.selector, block.chainid, block.chainid + 1)
        );
        _notify(DEAL_ID, address(adapter), block.chainid + 1, pieceSetCommitment, 0, SECTOR, MINIMUM_COMMITMENT_EPOCH);
    }

    function testPayloadForAnotherAdapterIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedAdapter.selector, address(adapter), address(0xBAD))
        );
        _notify(DEAL_ID, address(0xBAD), block.chainid, pieceSetCommitment, 0, SECTOR, MINIMUM_COMMITMENT_EPOCH);
    }

    function testPayloadWithWrongPieceSetCommitmentIsRejected() public {
        vm.expectRevert(SectorEvidenceAdapter.UnexpectedPieceSetCommitment.selector);
        _notify(DEAL_ID, address(adapter), block.chainid, bytes32(uint256(1)), 0, SECTOR, MINIMUM_COMMITMENT_EPOCH);
    }

    function testPayloadWithWrongRegisteredNonceIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedPlacementNonce.selector, PLACEMENT_NONCE, uint64(1))
        );
        _notify(DEAL_ID, address(adapter), block.chainid, pieceSetCommitment, 1, SECTOR, MINIMUM_COMMITMENT_EPOCH);
    }

    function testInsufficientCommitmentEpochIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SectorEvidenceAdapter.InsufficientCommitmentEpoch.selector,
                MINIMUM_COMMITMENT_EPOCH,
                MINIMUM_COMMITMENT_EPOCH - 1
            )
        );
        _notify(DEAL_ID, address(adapter), block.chainid, pieceSetCommitment, 0, SECTOR, MINIMUM_COMMITMENT_EPOCH - 1);
    }

    function testUnregisteredMinerActorIsRejected() public {
        uint64 unregisteredMiner = 9999;
        bytes memory params = FVMSectorContentChanged.encodeParams(
            _params(
                PIECE_CID,
                PADDED_SIZE,
                _payload(DEAL_ID, address(adapter), block.chainid, pieceSetCommitment, 0),
                SECTOR,
                MINIMUM_COMMITMENT_EPOCH
            )
        );

        vm.prank(unregisteredMiner.maskedAddress());
        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.CallerIsNotMiner.selector, unregisteredMiner));
        adapter.handle_filecoin_method(SECTOR_CONTENT_CHANGED, CBOR_CODEC, params);
    }

    function testCallbackRejectsMoreThanOneSector() public {
        SectorContentChangedParams memory params = _params(
            PIECE_CID,
            PADDED_SIZE,
            _payload(DEAL_ID, address(adapter), block.chainid, pieceSetCommitment, 0),
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        SectorChanges[] memory sectors = new SectorChanges[](2);
        sectors[0] = params.sectors[0];
        sectors[1] = params.sectors[0];
        params.sectors = sectors;

        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedSectorCount.selector, uint256(2)));
        miner.callSectorContentChanged(address(adapter), params);
    }

    function testCallbackRejectsMoreThanOnePiece() public {
        SectorContentChangedParams memory params = _params(
            PIECE_CID,
            PADDED_SIZE,
            _payload(DEAL_ID, address(adapter), block.chainid, pieceSetCommitment, 0),
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        PieceChange[] memory pieces = new PieceChange[](2);
        pieces[0] = params.sectors[0].added[0];
        pieces[1] = params.sectors[0].added[0];
        params.sectors[0].added = pieces;

        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedPieceCount.selector, uint256(2)));
        miner.callSectorContentChanged(address(adapter), params);
    }

    function testOnlyPoRepMarketCanCallLifecycleEntryPoints() public {
        SharedTypes.ActivationContext memory context = _context(DEAL_ID, PROVIDER);
        vm.expectRevert(SectorEvidenceAdapter.OnlyPoRepMarket.selector);
        adapter.submitEvidenceBatch(context, "");
        vm.expectRevert(SectorEvidenceAdapter.OnlyPoRepMarket.selector);
        adapter.activateEvidence(context, "");
        vm.expectRevert(SectorEvidenceAdapter.OnlyPoRepMarket.selector);
        adapter.refreshEvidenceStatus(context, "");
        vm.expectRevert(SectorEvidenceAdapter.OnlyPoRepMarket.selector);
        adapter.currentEvidenceStatus(context);
    }

    function testEmptySubmissionAndUnrefreshedStatusReportNoHealthyEvidenceOrExpiration() public {
        SharedTypes.ActivationDecision memory submitted = market.submit(adapter, _context(DEAL_ID, PROVIDER), "");
        SharedTypes.EvidenceStatus memory current = market.current(adapter, _context(DEAL_ID, PROVIDER));

        assertEq(submitted.coveredBytes, 0);
        assertEq(submitted.result, EvidenceResult.REJECTED);
        assertEq(current.activeCoveredBytes, 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(current.lastEvidenceRefreshEpoch), 0);
        assertEq(current.result, EvidenceResult.INACTIVE);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), 0);
        assertTrue(adapter.isOperational());
        assertEq(adapter.getEvidenceType(), EvidenceTypes.SECTOR_PLACEMENT);
    }

    function testRefreshRejectsMalformedLocationData() public {
        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.InvalidRefreshDataLength.selector, uint256(0)));
        market.refresh(adapter, _context(DEAL_ID, PROVIDER), "");
    }

    function testPlacementRegistrationRejectsZeroConflictAndCrossDealReuse() public {
        vm.expectRevert(SectorEvidenceAdapter.InvalidPlacementNonce.selector);
        market.submit(adapter, _context(DEAL_ID, PROVIDER), abi.encode(uint64(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                SectorEvidenceAdapter.ConflictingPlacementRegistration.selector, DEAL_ID, PLACEMENT_NONCE, uint64(12)
            )
        );
        _registerPlacement(DEAL_ID, 12);

        market.setDeal(
            OTHER_DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                SectorEvidenceAdapter.PlacementNonceAlreadyAssigned.selector, PLACEMENT_NONCE, DEAL_ID, OTHER_DEAL_ID
            )
        );
        _registerPlacement(OTHER_DEAL_ID, PLACEMENT_NONCE);

        _notify(
            DEAL_ID,
            address(adapter),
            block.chainid,
            pieceSetCommitment,
            PLACEMENT_NONCE,
            SECTOR,
            MINIMUM_COMMITMENT_EPOCH
        );
        assertTrue(adapter.getReceipt(DEAL_ID).accepted);
        assertFalse(adapter.getReceipt(OTHER_DEAL_ID).accepted);
    }

    function testPlacementRegistrationRejectsWrongDealContext() public {
        market.setDeal(DEAL_ID, PROVIDER, address(0xBAD), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT);
        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedEvidenceAdapter.selector, DEAL_ID, address(0xBAD))
        );
        _registerPlacement(DEAL_ID, PLACEMENT_NONCE);

        market.setDeal(
            DEAL_ID, OTHER_PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT
        );
        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedProvider.selector, OTHER_PROVIDER, PROVIDER)
        );
        _registerPlacement(DEAL_ID, PLACEMENT_NONCE);

        market.setDeal(DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE * 2, DURATION, PROPOSED_AT);
        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedPaddedSize.selector, PADDED_SIZE * 2, PADDED_SIZE)
        );
        _registerPlacement(DEAL_ID, PLACEMENT_NONCE);
    }

    function testUnregisteredPlacementIsRejected() public {
        SectorEvidenceAdapter unregisteredAdapter = new SectorEvidenceAdapter(address(market));
        adapter = unregisteredAdapter;
        market.setDeal(DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT);

        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.PlacementNotRegistered.selector, DEAL_ID));
        _notify(DEAL_ID, address(adapter), block.chainid, pieceSetCommitment, 9, SECTOR, MINIMUM_COMMITMENT_EPOCH);
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function _notify(
        uint256 dealId,
        address payloadAdapter,
        uint256 chainId,
        bytes32 commitment,
        uint64 nonce,
        uint64 sector,
        int64 minimumCommitmentEpoch
    ) internal returns (SectorContentChangedReturn memory) {
        return _notifyWithPiece(
            PIECE_CID, PADDED_SIZE, dealId, payloadAdapter, chainId, commitment, nonce, sector, minimumCommitmentEpoch
        );
    }

    function _registerPlacement(uint256 dealId, uint64 placementNonce) internal {
        market.submit(adapter, _context(dealId, PROVIDER), abi.encode(placementNonce));
    }

    function _notifyWithPiece(
        bytes memory pieceCid,
        uint64 paddedSize,
        uint256 dealId,
        address payloadAdapter,
        uint256 chainId,
        bytes32 commitment,
        uint64 nonce,
        uint64 sector,
        int64 minimumCommitmentEpoch
    ) internal returns (SectorContentChangedReturn memory) {
        return miner.callSectorContentChanged(
            address(adapter),
            _params(
                pieceCid,
                paddedSize,
                _payload(dealId, payloadAdapter, chainId, commitment, nonce),
                sector,
                minimumCommitmentEpoch
            )
        );
    }

    function _params(
        bytes memory pieceCid,
        uint64 paddedSize,
        bytes memory payload,
        uint64 sector,
        int64 minimumCommitmentEpoch
    ) internal pure returns (SectorContentChangedParams memory params) {
        PieceChange[] memory pieces = new PieceChange[](1);
        pieces[0] = PieceChange({data: pieceCid, size: paddedSize, payload: payload});
        SectorChanges[] memory sectors = new SectorChanges[](1);
        sectors[0] = SectorChanges({sector: sector, minimumCommitmentEpoch: minimumCommitmentEpoch, added: pieces});
        params = SectorContentChangedParams({sectors: sectors});
    }

    function _payload(uint256 dealId, address payloadAdapter, uint256 chainId, bytes32 commitment, uint64 nonce)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(PAYLOAD_VERSION, uint64(chainId), payloadAdapter, dealId, commitment, nonce);
    }

    function _context(uint256 dealId, uint64 provider) internal pure returns (SharedTypes.ActivationContext memory) {
        return SharedTypes.ActivationContext({
            dealId: dealId,
            requestedSizeBytes: PADDED_SIZE,
            client: address(0xC1E17),
            durationEpochs: DURATION,
            activationToleranceBps: 0,
            provider: CommonTypes.FilActorId.wrap(provider)
        });
    }
}

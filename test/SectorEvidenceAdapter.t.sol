// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {CBOR_CODEC} from "fvm-solidity/FVMCodec.sol";
import {FVMAddress} from "fvm-solidity/FVMAddress.sol";
import {SECTOR_CONTENT_CHANGED} from "fvm-solidity/FVMMethod.sol";
import {SectorStatus} from "fvm-solidity/FVMSector.sol";
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

contract SectorEvidenceAdapterV2 is SectorEvidenceAdapter {
    function version() external pure returns (uint256) {
        return 2;
    }

    function clearMinimumCommitmentEpochForTest(uint256 dealId) external {
        s()._manifestReceipts[dealId].minimumCommitmentEpoch = 0;
    }
}

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
    ) external view returns (SharedTypes.ActivationDecision memory) {
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
    event PieceSetCompleted(uint256 indexed dealId, uint32 indexed pieceCount, uint256 indexed acceptedBytes);
    event PlacementActivated(uint256 indexed dealId, uint32 indexed pieceCount, uint256 indexed coveredBytes);

    bytes32 internal constant LEAF_DOMAIN = 0xde24299ea19a4e461e31a0be02e5c601b2f66c1f3786214aa46f553fde6f7179;
    bytes32 internal constant NODE_DOMAIN = 0xaedbcc7b5d2c40692870fd30607e9e30315a8153c6b3a368ef838aec7de83b5d;
    bytes32 internal constant EMPTY_LEAF = 0x784f6484cd3db69cd3d40f6148c228e3ef179ced49d461ca765d98c6ac8fc45e;
    bytes32 internal constant COMMITMENT_DOMAIN = 0x30999723613fc3c0c783e4cfe2d089b89c98f5f609e29f18d0c8eefcc99be0b6;

    uint64 internal constant PROVIDER = 1004;
    uint64 internal constant OTHER_PROVIDER = 1005;
    uint64 internal constant SECTOR = 2;
    uint64 internal constant PADDED_SIZE = 2_097_152;
    uint64 internal constant DURATION = 518_400;
    int64 internal constant PROPOSED_AT = 100;
    int64 internal constant MINIMUM_COMMITMENT_EPOCH = PROPOSED_AT + 518_400;
    uint256 internal constant DEAL_ID = 1;
    uint256 internal constant OTHER_DEAL_ID = 2;
    uint32 internal constant PIECE_COUNT = 3;
    uint256 internal constant REQUESTED_SIZE = uint256(PADDED_SIZE) * PIECE_COUNT;

    bytes internal constant PIECE_CID_0 =
        hex"0181e203922020c47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b";
    bytes internal constant PIECE_CID_1 =
        hex"0181e203922020cdf33e1783f2ff8261e66f95858ff85f976bbc0bf05ce8476d3e360832165cd0";
    bytes internal constant PIECE_CID_2 =
        hex"0181e203922020eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    bytes internal constant MALFORMED_PIECE_CID =
        hex"0281e203922020c47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b";
    bytes32 internal constant DIGEST_0 = 0xc47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b;
    bytes32 internal constant DIGEST_1 = 0xcdf33e1783f2ff8261e66f95858ff85f976bbc0bf05ce8476d3e360832165cd0;
    bytes32 internal constant DIGEST_2 = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;
    bytes32 internal constant LEAF_0 = 0xeb6311dd854dcbf53bf60471a663aee4d6905ef84b4a963584aa5c3feb50c098;
    bytes32 internal constant LEAF_1 = 0xe8a90c7c511c5ac9e11e2121af757e41c655dcf7176d021180a6aac5f99fe92d;
    bytes32 internal constant LEAF_2 = 0x429544948f210e7abf035026efcddef889de92fc18142d871cc69cb46ebe9261;
    bytes32 internal constant NODE_01 = 0xb5c36553242a676b6dfe94f326a682566fbd19caa14a0b4fe3e2bc2b34f84dae;
    bytes32 internal constant NODE_2_EMPTY = 0x1e64bb94d1b44089cf5aa6898815b244c732cf5c8abe8592ca4691d9e53bdbb6;
    bytes32 internal constant TREE_ROOT = 0xe456a8ad3e9967927c2808f552359bf284baf7214dcd2cd2a40762eb4ef6b5cd;
    bytes32 internal constant PIECE_SET_COMMITMENT = 0x08adb274b38dd7323986b69cfec7cc66099d79912a700cfc02dae6c137be04f7;

    SectorEvidenceMarketMock internal market;
    SectorEvidenceAdapter internal adapter;
    FVMMinerActor internal miner;

    function setUp() public override {
        super.setUp();
        market = new SectorEvidenceMarketMock();
        adapter = _deployAdapter(address(this), address(market));
        miner = mockMiner(PROVIDER);
        market.setDeal(DEAL_ID, PROVIDER, address(adapter), PIECE_SET_COMMITMENT, REQUESTED_SIZE, DURATION, PROPOSED_AT);
    }

    function testImplementationCannotBeInitialized() public {
        SectorEvidenceAdapter implementation = new SectorEvidenceAdapter();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(this), address(market));
    }

    function testInitializationRejectsZeroAdminAndMarket() public {
        SectorEvidenceAdapter implementation = new SectorEvidenceAdapter();
        SectorEvidenceAdapter zeroAdmin = SectorEvidenceAdapter(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(SectorEvidenceAdapter.InvalidAdminAddress.selector);
        zeroAdmin.initialize(address(0), address(market));

        SectorEvidenceAdapter zeroMarket = SectorEvidenceAdapter(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(SectorEvidenceAdapter.InvalidPoRepMarketAddress.selector);
        zeroMarket.initialize(address(this), address(0));
    }

    function testProxyInitializationSetsMarketAndUpgradeRoles() public view {
        assertEq(address(adapter.POREP_MARKET()), address(market));
        assertEq(adapter.getPoRepMarketAddress(), address(market));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(adapter.hasRole(adapter.UPGRADER_ROLE(), address(this)));
    }

    function testProxyCannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.initialize(address(this), address(market));
    }

    function testUpgradePreservesManifestReceiptAndPlacementInventory() public {
        _notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR);
        SectorEvidenceAdapter.ManifestReceipt memory beforeReceipt = adapter.getManifestReceipt(DEAL_ID);

        SectorEvidenceAdapterV2 nextImplementation = new SectorEvidenceAdapterV2();
        adapter.upgradeToAndCall(address(nextImplementation), "");
        SectorEvidenceAdapterV2 upgraded = SectorEvidenceAdapterV2(address(adapter));
        SectorEvidenceAdapter.ManifestReceipt memory afterReceipt = upgraded.getManifestReceipt(DEAL_ID);

        assertEq(upgraded.version(), 2);
        assertEq(afterReceipt.providerActorId, beforeReceipt.providerActorId);
        assertEq(afterReceipt.pieceCount, beforeReceipt.pieceCount);
        assertEq(afterReceipt.acceptedPieceCount, beforeReceipt.acceptedPieceCount);
        assertEq(afterReceipt.acceptedBytes, beforeReceipt.acceptedBytes);
        assertEq(afterReceipt.minimumCommitmentEpoch, beforeReceipt.minimumCommitmentEpoch);
        assertFalse(afterReceipt.activated);
        assertTrue(upgraded.isPieceAccepted(DEAL_ID, 1));
        assertEq(upgraded.getPiecePlacement(DEAL_ID, 1).sectorNumber, SECTOR);
        assertEq(upgraded.getSectorCount(DEAL_ID), 1);
        assertEq(upgraded.getSectorCoveredBytes(DEAL_ID, SECTOR), PADDED_SIZE);
        assertEq(address(upgraded.POREP_MARKET()), address(market));

        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR + 1);
        _notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 2);
        SharedTypes.ActivationDecision memory decision =
            market.activate(upgraded, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));
        assertEq(decision.result, EvidenceResult.ACCEPTED);
        assertEq(decision.coveredBytes, REQUESTED_SIZE);
    }

    function testUpgradeLeavesReceiptWithoutCommitmentEpochFailClosed() public {
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);

        SectorEvidenceAdapterV2 nextImplementation = new SectorEvidenceAdapterV2();
        adapter.upgradeToAndCall(address(nextImplementation), "");
        SectorEvidenceAdapterV2 upgraded = SectorEvidenceAdapterV2(address(adapter));
        upgraded.clearMinimumCommitmentEpochForTest(DEAL_ID);

        _notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR + 1);
        _notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 2);

        SectorEvidenceAdapter.ManifestReceipt memory receipt = upgraded.getManifestReceipt(DEAL_ID);
        assertEq(receipt.acceptedPieceCount, PIECE_COUNT);
        assertEq(receipt.acceptedBytes, REQUESTED_SIZE);
        assertRejectedActivation(DEAL_ID, PROVIDER, REQUESTED_SIZE);
        assertFalse(upgraded.getManifestReceipt(DEAL_ID).activated);
    }

    function testOnlyUpgraderCanUpgrade() public {
        SectorEvidenceAdapterV2 nextImplementation = new SectorEvidenceAdapterV2();

        vm.prank(address(0xBAD));
        vm.expectRevert();
        adapter.upgradeToAndCall(address(nextImplementation), "");
    }

    function testOnlyAdapterCanProcessOnePiece() public {
        vm.expectRevert(SectorEvidenceAdapter.OnlySelf.selector);
        adapter.processPieceNotification("", false, PROVIDER, DIGEST_0, PADDED_SIZE, SECTOR, MINIMUM_COMMITMENT_EPOCH);
    }

    function testThreePiecesArriveOutOfOrderAndActivateExactBytesOnce() public {
        assertRejectedActivation(DEAL_ID, PROVIDER, REQUESTED_SIZE);

        _assertAccepted(_notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 2));
        assertRejectedActivation(DEAL_ID, PROVIDER, REQUESTED_SIZE);
        _assertAccepted(_notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR));
        assertRejectedActivation(DEAL_ID, PROVIDER, REQUESTED_SIZE);
        _assertAccepted(_notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR + 1));

        SectorEvidenceAdapter.ManifestReceipt memory receipt = adapter.getManifestReceipt(DEAL_ID);
        assertEq(receipt.providerActorId, PROVIDER);
        assertEq(receipt.pieceCount, PIECE_COUNT);
        assertEq(receipt.acceptedPieceCount, PIECE_COUNT);
        assertEq(receipt.acceptedBytes, REQUESTED_SIZE);
        assertTrue(adapter.isPieceAccepted(DEAL_ID, 0));
        assertTrue(adapter.isPieceAccepted(DEAL_ID, 1));
        assertTrue(adapter.isPieceAccepted(DEAL_ID, 2));

        SharedTypes.ActivationDecision memory first =
            market.activate(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));
        SharedTypes.ActivationDecision memory second =
            market.activate(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));
        assertEq(first.result, EvidenceResult.ACCEPTED);
        assertEq(first.coveredBytes, REQUESTED_SIZE);
        assertEq(second.result, EvidenceResult.REJECTED);
        assertEq(second.coveredBytes, 0);
        assertEq(market.committedBytes(PROVIDER), REQUESTED_SIZE);
        assertTrue(adapter.getManifestReceipt(DEAL_ID).activated);
    }

    function testStoresPiecePlacementsAndUniqueSectorCoverage() public {
        _assertAccepted(_notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR));
        _assertAccepted(_notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR));
        _assertAccepted(_notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 1));

        SectorEvidenceAdapter.PiecePlacement memory first = adapter.getPiecePlacement(DEAL_ID, 0);
        SectorEvidenceAdapter.PiecePlacement memory second = adapter.getPiecePlacement(DEAL_ID, 1);
        SectorEvidenceAdapter.PiecePlacement memory third = adapter.getPiecePlacement(DEAL_ID, 2);

        assertEq(first.pieceCidDigest, DIGEST_0);
        assertEq(first.sectorNumber, SECTOR);
        assertEq(first.paddedSize, PADDED_SIZE);
        assertEq(first.minimumCommitmentEpoch, MINIMUM_COMMITMENT_EPOCH);
        assertTrue(first.accepted);
        assertEq(second.pieceCidDigest, DIGEST_1);
        assertEq(second.sectorNumber, SECTOR);
        assertEq(third.pieceCidDigest, DIGEST_2);
        assertEq(third.sectorNumber, SECTOR + 1);

        assertEq(adapter.getSectorCount(DEAL_ID), 2);
        assertEq(adapter.getSectorNumber(DEAL_ID, 0), SECTOR);
        assertEq(adapter.getSectorNumber(DEAL_ID, 1), SECTOR + 1);
        assertEq(adapter.getSectorCoveredBytes(DEAL_ID, SECTOR), uint256(PADDED_SIZE) * 2);
        assertEq(adapter.getSectorCoveredBytes(DEAL_ID, SECTOR + 1), PADDED_SIZE);
    }

    function testPlacementCompletionAndActivationEvents() public {
        CommonTypes.ChainEpoch receiptEpoch = CommonTypes.ChainEpoch.wrap(int64(uint64(block.number)));
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PiecePlacementAccepted(
            DEAL_ID, 0, PROVIDER, SECTOR, DIGEST_0, PADDED_SIZE, MINIMUM_COMMITMENT_EPOCH, receiptEpoch
        );
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        _notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR + 1);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit PiecePlacementAccepted(
            DEAL_ID, 2, PROVIDER, SECTOR + 2, DIGEST_2, PADDED_SIZE, MINIMUM_COMMITMENT_EPOCH, receiptEpoch
        );
        vm.expectEmit(true, true, true, false, address(adapter));
        emit PieceSetCompleted(DEAL_ID, PIECE_COUNT, REQUESTED_SIZE);
        _notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 2);

        vm.expectEmit(true, true, true, false, address(adapter));
        emit PlacementActivated(DEAL_ID, PIECE_COUNT, REQUESTED_SIZE);
        market.activate(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));
    }

    function testExactReplayIsNoOpAndConflictingReplayIsRejected() public {
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        SectorEvidenceAdapter.ManifestReceipt memory beforeReceipt = adapter.getManifestReceipt(DEAL_ID);

        vm.recordLogs();
        SectorContentChangedReturn memory replay = _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        SectorContentChangedReturn memory conflict = _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR + 99);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        SectorEvidenceAdapter.ManifestReceipt memory afterReceipt = adapter.getManifestReceipt(DEAL_ID);

        _assertAccepted(replay);
        _assertRejected(conflict);
        assertEq(logs.length, 0);
        assertEq(afterReceipt.acceptedPieceCount, beforeReceipt.acceptedPieceCount);
        assertEq(afterReceipt.acceptedBytes, beforeReceipt.acceptedBytes);
        assertEq(adapter.getSectorCount(DEAL_ID), 1);
        assertEq(adapter.getSectorNumber(DEAL_ID, 0), SECTOR);
        assertEq(adapter.getSectorCoveredBytes(DEAL_ID, SECTOR), PADDED_SIZE);
        assertEq(adapter.getSectorCoveredBytes(DEAL_ID, SECTOR + 99), 0);
    }

    function testEarliestUniquePieceCommitmentControlsActivation() public {
        int64 activationEpoch = PROPOSED_AT + 10;
        int64 exactBoundary = activationEpoch + int64(uint64(DURATION));
        _assertAccepted(_notifyAtEpoch(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR, exactBoundary + 100));
        _assertAccepted(_notifyAtEpoch(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR + 1, exactBoundary - 1));
        _assertAccepted(_notifyAtEpoch(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 2, exactBoundary + 200));

        vm.roll(uint256(uint64(activationEpoch)));
        assertRejectedActivation(DEAL_ID, PROVIDER, REQUESTED_SIZE);
    }

    function testInvalidProofDoesNotRejectValidSiblingInGroupedCallback() public {
        PieceChange[] memory pieces = new PieceChange[](2);
        bytes32[] memory invalidProof = _proof(0);
        invalidProof[0] = bytes32(uint256(123));
        pieces[0] = PieceChange({
            data: PIECE_CID_0, size: PADDED_SIZE, payload: _payload(DEAL_ID, 0, PIECE_COUNT, invalidProof)
        });
        pieces[1] =
            PieceChange({data: PIECE_CID_1, size: PADDED_SIZE, payload: _payload(DEAL_ID, 1, PIECE_COUNT, _proof(1))});

        SectorContentChangedReturn memory result = _notifyPieces(pieces, SECTOR);

        assertEq(result.sectors[0].accepted[0], 2);
        assertFalse(adapter.isPieceAccepted(DEAL_ID, 0));
        assertTrue(adapter.isPieceAccepted(DEAL_ID, 1));
        assertEq(adapter.getManifestReceipt(DEAL_ID).acceptedPieceCount, 1);
    }

    function testMultipleDealsAcrossSeveralSectorsAreIsolated() public {
        market.setDeal(
            OTHER_DEAL_ID, PROVIDER, address(adapter), PIECE_SET_COMMITMENT, REQUESTED_SIZE, DURATION, PROPOSED_AT
        );
        SectorChanges[] memory sectors = new SectorChanges[](2);
        sectors[0] = _params(PIECE_CID_0, PADDED_SIZE, _payload(DEAL_ID, 0, PIECE_COUNT, _proof(0)), SECTOR).sectors[0];
        sectors[1] = _params(PIECE_CID_1, PADDED_SIZE, _payload(OTHER_DEAL_ID, 1, PIECE_COUNT, _proof(1)), SECTOR + 1)
        .sectors[0];

        SectorContentChangedReturn memory result =
            miner.callSectorContentChanged(address(adapter), SectorContentChangedParams({sectors: sectors}));

        assertEq(result.sectors[0].accepted[0], 1);
        assertEq(result.sectors[1].accepted[0], 1);
        assertTrue(adapter.isPieceAccepted(DEAL_ID, 0));
        assertTrue(adapter.isPieceAccepted(OTHER_DEAL_ID, 1));
    }

    function testWrongAdapterProviderCidSizeAndCommitmentEpochAreRejected() public {
        market.setDeal(
            OTHER_DEAL_ID, PROVIDER, address(0xBAD), PIECE_SET_COMMITMENT, REQUESTED_SIZE, DURATION, PROPOSED_AT
        );
        _assertRejected(_notifyForDeal(OTHER_DEAL_ID, 0, PIECE_COUNT, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR));

        market.setDeal(
            OTHER_DEAL_ID, OTHER_PROVIDER, address(adapter), PIECE_SET_COMMITMENT, REQUESTED_SIZE, DURATION, PROPOSED_AT
        );
        _assertRejected(_notifyForDeal(OTHER_DEAL_ID, 0, PIECE_COUNT, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR));

        _assertRejected(_notify(0, _proof(0), PIECE_CID_1, PADDED_SIZE, SECTOR));
        _assertRejected(_notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE * 2, SECTOR));
        _assertRejected(_notifyAtEpoch(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR, MINIMUM_COMMITMENT_EPOCH - 1));
        _assertEmptyReceipt(DEAL_ID);
    }

    function testInvalidIndexCountAndProofLengthsLeaveStateUnchanged() public {
        _assertRejected(_notifyForDeal(DEAL_ID, 3, PIECE_COUNT, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR));
        _assertRejected(_notifyForDeal(DEAL_ID, 0, 0, new bytes32[](0), PIECE_CID_0, PADDED_SIZE, SECTOR));
        _assertRejected(_notifyForDeal(DEAL_ID, 0, 4, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR));
        _assertRejected(_notifyForDeal(DEAL_ID, 0, PIECE_COUNT, new bytes32[](1), PIECE_CID_0, PADDED_SIZE, SECTOR));
        _assertRejected(_notifyForDeal(DEAL_ID, 0, PIECE_COUNT, new bytes32[](3), PIECE_CID_0, PADDED_SIZE, SECTOR));
        bytes32[] memory reversed = _proof(0);
        (reversed[0], reversed[1]) = (reversed[1], reversed[0]);
        _assertRejected(_notifyForDeal(DEAL_ID, 0, PIECE_COUNT, reversed, PIECE_CID_0, PADDED_SIZE, SECTOR));
        _assertEmptyReceipt(DEAL_ID);
    }

    function testMalformedCidAndPayloadAreRejectedWithoutState() public {
        _assertRejected(_notify(0, _proof(0), MALFORMED_PIECE_CID, PADDED_SIZE, SECTOR));

        SectorContentChangedReturn memory shortPayload = _notifyRaw(PIECE_CID_0, PADDED_SIZE, hex"01", SECTOR);
        _assertRejected(shortPayload);
        bytes memory trailingPayload = abi.encodePacked(_payload(DEAL_ID, 0, PIECE_COUNT, _proof(0)), hex"00");
        _assertRejected(_notifyRaw(PIECE_CID_0, PADDED_SIZE, trailingPayload, SECTOR));
        _assertEmptyReceipt(DEAL_ID);
    }

    function testReceiptRejectsProviderChange() public {
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        market.setDeal(
            DEAL_ID, OTHER_PROVIDER, address(adapter), PIECE_SET_COMMITMENT, REQUESTED_SIZE, DURATION, PROPOSED_AT
        );
        FVMMinerActor otherMiner = mockMiner(OTHER_PROVIDER);

        SectorContentChangedReturn memory changedProvider = otherMiner.callSectorContentChanged(
            address(adapter),
            _params(PIECE_CID_1, PADDED_SIZE, _payload(DEAL_ID, 1, PIECE_COUNT, _proof(1)), SECTOR + 1)
        );

        _assertRejected(changedProvider);
        SectorEvidenceAdapter.ManifestReceipt memory receipt = adapter.getManifestReceipt(DEAL_ID);
        assertEq(receipt.providerActorId, PROVIDER);
        assertEq(receipt.acceptedPieceCount, 1);
    }

    function testReceiptRejectsPieceCountChange() public {
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        market.setDeal(
            DEAL_ID, PROVIDER, address(adapter), _wrap(1, PADDED_SIZE, LEAF_0), PADDED_SIZE, DURATION, PROPOSED_AT
        );

        _assertRejected(_notifyForDeal(DEAL_ID, 0, 1, new bytes32[](0), PIECE_CID_0, PADDED_SIZE, SECTOR + 1));
        SectorEvidenceAdapter.ManifestReceipt memory receipt = adapter.getManifestReceipt(DEAL_ID);
        assertEq(receipt.pieceCount, PIECE_COUNT);
        assertEq(receipt.acceptedPieceCount, 1);
    }

    function testWrongRequestedBytesWrapperCannotVerify() public {
        market.setDeal(
            DEAL_ID, PROVIDER, address(adapter), PIECE_SET_COMMITMENT, REQUESTED_SIZE + 1, DURATION, PROPOSED_AT
        );

        _assertRejected(_notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR));
        _assertEmptyReceipt(DEAL_ID);
    }

    function testExactCountWithWrongAccumulatedBytesCannotActivate() public {
        uint256 mismatchedRequested = REQUESTED_SIZE + 1;
        bytes32 mismatchedWrapper = _wrap(PIECE_COUNT, mismatchedRequested, TREE_ROOT);
        market.setDeal(
            DEAL_ID, PROVIDER, address(adapter), mismatchedWrapper, mismatchedRequested, DURATION, PROPOSED_AT
        );
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        _notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR + 1);
        _notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 2);

        SectorEvidenceAdapter.ManifestReceipt memory receipt = adapter.getManifestReceipt(DEAL_ID);
        assertEq(receipt.acceptedPieceCount, PIECE_COUNT);
        assertEq(receipt.acceptedBytes, REQUESTED_SIZE);
        assertRejectedActivation(DEAL_ID, PROVIDER, mismatchedRequested);
    }

    function testPlacementIndexes255And256AndLastIndex1392() public {
        uint32 count = 1393;
        uint64 size = 128;
        uint256 requestedSize = uint256(count) * size;
        (bytes32 digest255, bytes32[] memory proof255, bytes32 commitment) = _scaleVector(count, 255, size);
        (bytes32 digest256, bytes32[] memory proof256,) = _scaleVector(count, 256, size);
        (bytes32 digest1392, bytes32[] memory proof1392,) = _scaleVector(count, 1392, size);
        market.setDeal(DEAL_ID, PROVIDER, address(adapter), commitment, requestedSize, DURATION, PROPOSED_AT);

        _assertAccepted(_notifyForDeal(DEAL_ID, 255, count, proof255, _pieceCid(digest255), size, SECTOR));
        _assertAccepted(_notifyForDeal(DEAL_ID, 256, count, proof256, _pieceCid(digest256), size, SECTOR + 1));
        _assertAccepted(_notifyForDeal(DEAL_ID, 1392, count, proof1392, _pieceCid(digest1392), size, SECTOR + 2));

        assertTrue(adapter.isPieceAccepted(DEAL_ID, 255));
        assertTrue(adapter.isPieceAccepted(DEAL_ID, 256));
        assertTrue(adapter.isPieceAccepted(DEAL_ID, 1392));
        assertFalse(adapter.isPieceAccepted(DEAL_ID, 254));
        assertFalse(adapter.isPieceAccepted(DEAL_ID, 257));
        assertEq(adapter.getManifestReceipt(DEAL_ID).acceptedPieceCount, 3);
    }

    function testUnrefreshedStatusIsInactiveAndEmptyRefreshIsRejected() public {
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        _notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR + 1);
        _notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 2);
        market.activate(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));

        SharedTypes.EvidenceStatus memory current = market.current(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));

        assertEq(current.result, EvidenceResult.INACTIVE);
        assertEq(current.activeCoveredBytes, 0);
        assertEq(current.checkedClaims, 0);
        assertEq(current.totalClaims, 3);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), 0);

        SectorEvidenceAdapter.SectorLocation[] memory locations = new SectorEvidenceAdapter.SectorLocation[](0);
        vm.expectRevert(
            abi.encodeWithSelector(SectorEvidenceAdapter.InvalidSectorLocationCount.selector, uint256(0), uint256(3))
        );
        market.refresh(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(locations));
    }

    function testFullActiveSectorSweepPublishesExactDealEvidence() public {
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        _notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR);
        _notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 1);
        market.activate(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));

        int64 deadline = 4;
        int64 partition = 7;
        uint64 firstExpiration = 600_000;
        uint64 secondExpiration = 500_000;
        miner.mockSector(SECTOR, SectorStatus.Active, deadline, partition, firstExpiration);
        miner.mockSector(SECTOR + 1, SectorStatus.Active, deadline, partition + 1, secondExpiration);
        SectorEvidenceAdapter.SectorLocation[] memory locations = new SectorEvidenceAdapter.SectorLocation[](2);
        locations[0] = SectorEvidenceAdapter.SectorLocation({deadline: deadline, partition: partition});
        locations[1] = SectorEvidenceAdapter.SectorLocation({deadline: deadline, partition: partition + 1});

        vm.roll(900);
        SharedTypes.EvidenceStatus memory refreshed =
            market.refresh(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(locations));
        SharedTypes.EvidenceStatus memory current = market.current(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));
        SectorEvidenceAdapter.DealRefreshState memory refreshState = adapter.getRefreshState(DEAL_ID);

        assertEq(refreshed.result, EvidenceResult.ACTIVE);
        assertEq(refreshed.activeCoveredBytes, REQUESTED_SIZE);
        assertEq(CommonTypes.ChainEpoch.unwrap(refreshed.lastEvidenceRefreshEpoch), 900);
        assertEq(refreshed.checkedClaims, 2);
        assertEq(refreshed.totalClaims, 2);
        assertEq(current.result, EvidenceResult.ACTIVE);
        assertEq(current.activeCoveredBytes, REQUESTED_SIZE);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), int64(uint64(secondExpiration)));
        assertEq(refreshState.nextSectorIndex, 0);
        assertEq(refreshState.pendingCoveredBytes, 0);
        assertEq(refreshState.completedResult, EvidenceResult.ACTIVE);
        assertEq(refreshState.completedExpiration, int64(uint64(secondExpiration)));
    }

    function testPartialSweepKeepsCompletedSnapshotUntilFinalBatch() public {
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        _notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR + 1);
        _notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 2);
        market.activate(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));

        int64 deadline = 4;
        int64 partition = 7;
        miner.mockSector(SECTOR, SectorStatus.Active, deadline, partition, 600_000);
        miner.mockSector(SECTOR + 1, SectorStatus.Active, deadline, partition + 1, 600_000);
        miner.mockSector(SECTOR + 2, SectorStatus.Active, deadline, partition + 2, 600_000);
        SectorEvidenceAdapter.SectorLocation[] memory initial = new SectorEvidenceAdapter.SectorLocation[](3);
        initial[0] = SectorEvidenceAdapter.SectorLocation({deadline: deadline, partition: partition});
        initial[1] = SectorEvidenceAdapter.SectorLocation({deadline: deadline, partition: partition + 1});
        initial[2] = SectorEvidenceAdapter.SectorLocation({deadline: deadline, partition: partition + 2});
        vm.roll(900);
        market.refresh(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(initial));

        miner.mockSectorExpiration(SECTOR, 500_000);
        SectorEvidenceAdapter.SectorLocation[] memory firstBatch = new SectorEvidenceAdapter.SectorLocation[](1);
        firstBatch[0] = initial[0];
        vm.roll(1_000);
        SharedTypes.EvidenceStatus memory partialStatus =
            market.refresh(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(firstBatch));
        SharedTypes.EvidenceStatus memory current = market.current(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));
        SectorEvidenceAdapter.DealRefreshState memory pending = adapter.getRefreshState(DEAL_ID);

        assertEq(partialStatus.result, EvidenceResult.PARTIAL);
        assertEq(partialStatus.activeCoveredBytes, PADDED_SIZE);
        assertEq(partialStatus.checkedClaims, 1);
        assertEq(partialStatus.totalClaims, 3);
        assertEq(current.result, EvidenceResult.ACTIVE);
        assertEq(current.activeCoveredBytes, REQUESTED_SIZE);
        assertEq(CommonTypes.ChainEpoch.unwrap(current.lastEvidenceRefreshEpoch), 900);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), 600_000);
        assertEq(pending.nextSectorIndex, 1);
        assertEq(pending.pendingCoveredBytes, PADDED_SIZE);
        assertEq(pending.sweepStartEpoch, 1_000);

        SectorEvidenceAdapter.SectorLocation[] memory secondBatch = new SectorEvidenceAdapter.SectorLocation[](2);
        secondBatch[0] = initial[1];
        secondBatch[1] = initial[2];
        vm.roll(1_001);
        SharedTypes.EvidenceStatus memory completed =
            market.refresh(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(secondBatch));

        assertEq(completed.result, EvidenceResult.ACTIVE);
        assertEq(completed.activeCoveredBytes, REQUESTED_SIZE);
        assertEq(CommonTypes.ChainEpoch.unwrap(completed.lastEvidenceRefreshEpoch), 1_000);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), 500_000);
        assertEq(adapter.getRefreshState(DEAL_ID).nextSectorIndex, 0);
    }

    function testInactiveRefreshBadWitnessAndLaterActiveRecovery() public {
        _notify(0, _proof(0), PIECE_CID_0, PADDED_SIZE, SECTOR);
        _notify(1, _proof(1), PIECE_CID_1, PADDED_SIZE, SECTOR);
        _notify(2, _proof(2), PIECE_CID_2, PADDED_SIZE, SECTOR + 1);
        market.activate(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));

        int64 deadline = 4;
        int64 partition = 7;
        miner.mockSector(SECTOR, SectorStatus.Active, deadline, partition, 600_000);
        miner.mockSector(SECTOR + 1, SectorStatus.Active, deadline, partition + 1, 500_000);
        SectorEvidenceAdapter.SectorLocation[] memory locations = new SectorEvidenceAdapter.SectorLocation[](2);
        locations[0] = SectorEvidenceAdapter.SectorLocation({deadline: deadline, partition: partition});
        locations[1] = SectorEvidenceAdapter.SectorLocation({deadline: deadline, partition: partition + 1});
        vm.roll(900);
        market.refresh(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(locations));

        miner.mockSectorStatus(SECTOR + 1, SectorStatus.Faulty);
        vm.roll(901);
        SharedTypes.EvidenceStatus memory inactive =
            market.refresh(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(locations));

        assertEq(inactive.result, EvidenceResult.INACTIVE);
        assertEq(inactive.activeCoveredBytes, 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(inactive.lastEvidenceRefreshEpoch), 901);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), 0);

        miner.mockSectorStatus(SECTOR + 1, SectorStatus.Active);
        SectorEvidenceAdapter.SectorLocation[] memory badLocations = new SectorEvidenceAdapter.SectorLocation[](2);
        badLocations[0] = SectorEvidenceAdapter.SectorLocation({deadline: deadline + 1, partition: partition});
        badLocations[1] = locations[1];
        vm.roll(902);
        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.SectorStatusUnavailable.selector, SECTOR));
        market.refresh(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(badLocations));

        SharedTypes.EvidenceStatus memory preserved =
            market.current(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE));
        assertEq(preserved.result, EvidenceResult.INACTIVE);
        assertEq(CommonTypes.ChainEpoch.unwrap(preserved.lastEvidenceRefreshEpoch), 901);

        vm.roll(903);
        SharedTypes.EvidenceStatus memory recovered =
            market.refresh(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(locations));

        assertEq(recovered.result, EvidenceResult.ACTIVE);
        assertEq(recovered.activeCoveredBytes, REQUESTED_SIZE);
        assertEq(CommonTypes.ChainEpoch.unwrap(recovered.lastEvidenceRefreshEpoch), 903);
        assertEq(CommonTypes.ChainEpoch.unwrap(adapter.getExpiration(DEAL_ID)), 500_000);
    }

    function testOnlyPoRepMarketCanCallLifecycleEntryPoints() public {
        SharedTypes.ActivationContext memory context = _context(DEAL_ID, PROVIDER, REQUESTED_SIZE);
        vm.expectRevert(SectorEvidenceAdapter.OnlyPoRepMarket.selector);
        adapter.submitEvidenceBatch(context, "");
        vm.expectRevert(SectorEvidenceAdapter.OnlyPoRepMarket.selector);
        adapter.activateEvidence(context, "");
        vm.expectRevert(SectorEvidenceAdapter.OnlyPoRepMarket.selector);
        adapter.refreshEvidenceStatus(context, "");
        vm.expectRevert(SectorEvidenceAdapter.OnlyPoRepMarket.selector);
        adapter.currentEvidenceStatus(context);
    }

    function testSubmissionOperationalAndEvidenceTypeContracts() public view {
        SharedTypes.ActivationDecision memory submitted =
            market.submit(adapter, _context(DEAL_ID, PROVIDER, REQUESTED_SIZE), abi.encode(uint256(123)));
        assertEq(submitted.result, EvidenceResult.REJECTED);
        assertEq(submitted.coveredBytes, 0);
        assertTrue(adapter.isOperational());
        assertEq(adapter.getEvidenceType(), EvidenceTypes.SECTOR_PLACEMENT);
    }

    function testUnexpectedMethodCodecAndUnregisteredMinerAreRejected() public {
        bytes memory params = FVMSectorContentChanged.encodeParams(
            _params(PIECE_CID_0, PADDED_SIZE, _payload(DEAL_ID, 0, PIECE_COUNT, _proof(0)), SECTOR)
        );
        vm.prank(PROVIDER.maskedAddress());
        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedMethod.selector, uint64(0)));
        adapter.handle_filecoin_method(0, CBOR_CODEC, params);
        vm.prank(PROVIDER.maskedAddress());
        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.UnexpectedCodec.selector, uint64(0)));
        adapter.handle_filecoin_method(SECTOR_CONTENT_CHANGED, 0, params);

        uint64 unregisteredMiner = 9999;
        vm.prank(unregisteredMiner.maskedAddress());
        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.CallerIsNotMiner.selector, unregisteredMiner));
        adapter.handle_filecoin_method(SECTOR_CONTENT_CHANGED, CBOR_CODEC, params);
    }

    function assertRejectedActivation(uint256 dealId, uint64 provider, uint256 requestedSize) internal {
        SharedTypes.ActivationDecision memory decision =
            market.activate(adapter, _context(dealId, provider, requestedSize));
        assertEq(decision.result, EvidenceResult.REJECTED);
        assertEq(decision.coveredBytes, 0);
    }

    function _assertEmptyReceipt(uint256 dealId) internal view {
        SectorEvidenceAdapter.ManifestReceipt memory receipt = adapter.getManifestReceipt(dealId);
        assertEq(receipt.providerActorId, 0);
        assertEq(receipt.pieceCount, 0);
        assertEq(receipt.acceptedPieceCount, 0);
        assertEq(receipt.acceptedBytes, 0);
        assertFalse(receipt.activated);
    }

    function _assertAccepted(SectorContentChangedReturn memory result) internal pure {
        assertEq(result.sectors[0].accepted[0], 1);
    }

    function _assertRejected(SectorContentChangedReturn memory result) internal pure {
        assertEq(result.sectors[0].accepted[0], 0);
    }

    function _notify(uint32 pieceIndex, bytes32[] memory proof, bytes memory pieceCid, uint64 paddedSize, uint64 sector)
        internal
        returns (SectorContentChangedReturn memory)
    {
        return _notifyForDeal(DEAL_ID, pieceIndex, PIECE_COUNT, proof, pieceCid, paddedSize, sector);
    }

    function _notifyAtEpoch(
        uint32 pieceIndex,
        bytes32[] memory proof,
        bytes memory pieceCid,
        uint64 paddedSize,
        uint64 sector,
        int64 minimumCommitmentEpoch
    ) internal returns (SectorContentChangedReturn memory) {
        return miner.callSectorContentChanged(
            address(adapter),
            _params(
                pieceCid, paddedSize, _payload(DEAL_ID, pieceIndex, PIECE_COUNT, proof), sector, minimumCommitmentEpoch
            )
        );
    }

    function _notifyForDeal(
        uint256 dealId,
        uint32 pieceIndex,
        uint32 pieceCount,
        bytes32[] memory proof,
        bytes memory pieceCid,
        uint64 paddedSize,
        uint64 sector
    ) internal returns (SectorContentChangedReturn memory) {
        return _notifyRaw(pieceCid, paddedSize, _payload(dealId, pieceIndex, pieceCount, proof), sector);
    }

    function _notifyRaw(bytes memory pieceCid, uint64 paddedSize, bytes memory payload, uint64 sector)
        internal
        returns (SectorContentChangedReturn memory)
    {
        return miner.callSectorContentChanged(address(adapter), _params(pieceCid, paddedSize, payload, sector));
    }

    function _notifyPieces(PieceChange[] memory pieces, uint64 sector)
        internal
        returns (SectorContentChangedReturn memory)
    {
        SectorChanges[] memory sectors = new SectorChanges[](1);
        sectors[0] = SectorChanges({sector: sector, minimumCommitmentEpoch: MINIMUM_COMMITMENT_EPOCH, added: pieces});
        return miner.callSectorContentChanged(address(adapter), SectorContentChangedParams({sectors: sectors}));
    }

    function _params(bytes memory pieceCid, uint64 paddedSize, bytes memory payload, uint64 sector)
        internal
        pure
        returns (SectorContentChangedParams memory params)
    {
        return _params(pieceCid, paddedSize, payload, sector, MINIMUM_COMMITMENT_EPOCH);
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

    function _payload(uint256 dealId, uint32 pieceIndex, uint32 pieceCount, bytes32[] memory proof)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(dealId, pieceIndex, pieceCount, proof);
    }

    function _proof(uint32 pieceIndex) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        if (pieceIndex == 0) {
            proof[0] = LEAF_1;
            proof[1] = NODE_2_EMPTY;
        } else if (pieceIndex == 1) {
            proof[0] = LEAF_0;
            proof[1] = NODE_2_EMPTY;
        } else {
            proof[0] = EMPTY_LEAF;
            proof[1] = NODE_01;
        }
    }

    function _context(uint256 dealId, uint64 provider, uint256 requestedSize)
        internal
        pure
        returns (SharedTypes.ActivationContext memory)
    {
        return SharedTypes.ActivationContext({
            dealId: dealId,
            requestedSizeBytes: requestedSize,
            client: address(0xC1E17),
            durationEpochs: DURATION,
            activationToleranceBps: 0,
            provider: CommonTypes.FilActorId.wrap(provider)
        });
    }

    function _deployAdapter(address admin, address poRepMarket) internal returns (SectorEvidenceAdapter deployed) {
        SectorEvidenceAdapter implementation = new SectorEvidenceAdapter();
        bytes memory initData = abi.encodeCall(SectorEvidenceAdapter.initialize, (admin, poRepMarket));
        deployed = SectorEvidenceAdapter(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _wrap(uint32 pieceCount, uint256 requestedSize, bytes32 root) internal pure returns (bytes32) {
        return keccak256(abi.encode(COMMITMENT_DOMAIN, uint8(1), pieceCount, requestedSize, root));
    }

    function _pieceCid(bytes32 digest) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"0181e203922020", digest);
    }

    function _scaleVector(uint32 pieceCount, uint32 targetIndex, uint64 paddedSize)
        internal
        pure
        returns (bytes32 targetDigest, bytes32[] memory proof, bytes32 commitment)
    {
        uint256 width = 1;
        uint256 depth;
        while (width < pieceCount) {
            width <<= 1;
            ++depth;
        }
        bytes32[] memory level = new bytes32[](width);
        for (uint256 i = 0; i < pieceCount; i++) {
            bytes32 digest = keccak256(abi.encode(i));
            // `i` is bounded by the uint32 `pieceCount`.
            // forge-lint: disable-next-line(unsafe-typecast)
            level[i] = keccak256(abi.encode(LEAF_DOMAIN, uint8(1), uint32(i), digest, paddedSize));
            if (i == targetIndex) targetDigest = digest;
        }
        for (uint256 i = pieceCount; i < width; i++) {
            level[i] = EMPTY_LEAF;
        }

        proof = new bytes32[](depth);
        uint256 target = targetIndex;
        uint256 activeWidth = width;
        for (uint256 height = 0; height < depth; height++) {
            proof[height] = level[target ^ 1];
            for (uint256 i = 0; i < activeWidth; i += 2) {
                level[i >> 1] = keccak256(abi.encode(NODE_DOMAIN, level[i], level[i + 1]));
            }
            target >>= 1;
            activeWidth >>= 1;
        }
        commitment = _wrap(pieceCount, uint256(pieceCount) * paddedSize, level[0]);
    }
}

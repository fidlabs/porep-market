// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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

contract SectorEvidenceAdapterV2 is SectorEvidenceAdapter {
    function version() external pure returns (uint256) {
        return 2;
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

    uint64 internal constant PROVIDER = 1004;
    uint64 internal constant OTHER_PROVIDER = 1005;
    uint64 internal constant SECTOR = 2;
    uint64 internal constant PADDED_SIZE = 2_097_152;
    uint64 internal constant DURATION = 518_400;
    int64 internal constant PROPOSED_AT = 100;
    int64 internal constant MINIMUM_COMMITMENT_EPOCH = PROPOSED_AT + int64(uint64(DURATION));
    uint256 internal constant DEAL_ID = 1;
    uint256 internal constant OTHER_DEAL_ID = 2;

    bytes internal constant PIECE_CID =
        hex"0181e203922020c47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b";
    bytes internal constant MALFORMED_PIECE_CID =
        hex"0281e203922020c47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b";
    bytes internal constant OTHER_PIECE_CID =
        hex"0181e203922020cdf33e1783f2ff8261e66f95858ff85f976bbc0bf05ce8476d3e360832165cd0";
    bytes32 internal constant PIECE_DIGEST = 0xc47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b;
    bytes32 internal constant OTHER_PIECE_DIGEST = 0xcdf33e1783f2ff8261e66f95858ff85f976bbc0bf05ce8476d3e360832165cd0;

    SectorEvidenceMarketMock internal market;
    SectorEvidenceAdapter internal adapter;
    FVMMinerActor internal miner;
    bytes32 internal pieceSetCommitment;

    function setUp() public override {
        super.setUp();
        market = new SectorEvidenceMarketMock();
        adapter = _deployAdapter(address(this), address(market));
        miner = mockMiner(PROVIDER);
        pieceSetCommitment = keccak256(abi.encode(PIECE_DIGEST, PADDED_SIZE));
        market.setDeal(DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT);
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

    function testProxyCannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.initialize(address(this), address(market));
    }

    function testProxyInitializationSetsMarketAndUpgradeRoles() public view {
        assertEq(address(adapter.POREP_MARKET()), address(market));
        assertEq(adapter.getPoRepMarketAddress(), address(market));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(adapter.hasRole(adapter.UPGRADER_ROLE(), address(this)));
    }

    function testUpgradePreservesPlacementReceipt() public {
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);

        SectorEvidenceAdapterV2 nextImplementation = new SectorEvidenceAdapterV2();
        adapter.upgradeToAndCall(address(nextImplementation), "");
        SectorEvidenceAdapterV2 upgraded = SectorEvidenceAdapterV2(address(adapter));

        assertEq(upgraded.version(), 2);
        assertTrue(upgraded.getReceipt(DEAL_ID).accepted);
        assertEq(address(upgraded.POREP_MARKET()), address(market));
    }

    function testOnlyUpgraderCanUpgrade() public {
        SectorEvidenceAdapterV2 nextImplementation = new SectorEvidenceAdapterV2();

        vm.prank(address(0xBAD));
        vm.expectRevert();
        adapter.upgradeToAndCall(address(nextImplementation), "");
    }

    function testOnlyAdapterCanProcessOnePiece() public {
        vm.expectRevert(SectorEvidenceAdapter.OnlySelf.selector);
        adapter.processPieceNotification(
            "", false, PROVIDER, PIECE_DIGEST, PADDED_SIZE, SECTOR, MINIMUM_COMMITMENT_EPOCH
        );
    }

    function testPayloadEncodingFixedVector() public pure {
        bytes memory encoded = abi.encode(uint256(7));

        assertEq(encoded, hex"0000000000000000000000000000000000000000000000000000000000000007");
    }

    function testValidReceiptActivatesExactBytesOnce() public {
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);

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

        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testWrongDealIsRejectedWithoutReceipt() public {
        market.setDeal(OTHER_DEAL_ID, PROVIDER, address(0xBAD), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT);

        _notify(OTHER_DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
        assertFalse(adapter.getReceipt(OTHER_DEAL_ID).accepted);
    }

    function testIdenticalDealsAreSelectedByPayloadDealId() public {
        market.setDeal(
            OTHER_DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE, DURATION, PROPOSED_AT
        );
        _notify(OTHER_DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);

        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
        assertTrue(adapter.getReceipt(OTHER_DEAL_ID).accepted);
        assertEq(market.getDeal(DEAL_ID).state, 20);
        assertEq(market.getDeal(OTHER_DEAL_ID).state, 20);
        assertEq(market.committedBytes(PROVIDER), 0);
    }

    function testMalformedPieceCidHeaderIsRejected() public {
        _notifyWithPiece(MALFORMED_PIECE_CID, PADDED_SIZE, DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);

        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testWrongPieceIsRejectedWithoutReceipt() public {
        _notifyWithPiece(OTHER_PIECE_CID, PADDED_SIZE, DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testWrongSizeIsRejectedWithoutReceipt() public {
        _notifyWithPiece(PIECE_CID, PADDED_SIZE * 2, DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testPieceSizeDifferentFromDealTermsIsRejectedWithoutReceipt() public {
        market.setDeal(DEAL_ID, PROVIDER, address(adapter), pieceSetCommitment, PADDED_SIZE * 2, DURATION, PROPOSED_AT);

        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testIdenticalDuplicateIsIdempotent() public {
        vm.roll(700);
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
        SectorEvidenceAdapter.PlacementReceipt memory beforeReceipt = adapter.getReceipt(DEAL_ID);

        vm.roll(701);
        SectorContentChangedReturn memory duplicate = _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
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

    function testConflictingDuplicateIsRejectedWithoutChangingReceipt() public {
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
        SectorEvidenceAdapter.PlacementReceipt memory beforeReceipt = adapter.getReceipt(DEAL_ID);

        SectorContentChangedReturn memory duplicate = _notify(DEAL_ID, SECTOR + 1, MINIMUM_COMMITMENT_EPOCH);
        SectorEvidenceAdapter.PlacementReceipt memory afterReceipt = adapter.getReceipt(DEAL_ID);

        assertEq(duplicate.sectors[0].accepted[0], 0);
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
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);

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
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);

        _notify(OTHER_DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
        assertFalse(adapter.getReceipt(OTHER_DEAL_ID).accepted);
    }

    function testWrongSectorLocationDoesNotOverwriteActiveEvidence() public {
        int64 deadline = 4;
        int64 partition = 7;
        uint64 expiration = 600_000;
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
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
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
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
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);
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

    function testInsufficientCommitmentEpochIsRejected() public {
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH - 1);
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
    }

    function testUnregisteredMinerActorIsRejected() public {
        uint64 unregisteredMiner = 9999;
        bytes memory params = FVMSectorContentChanged.encodeParams(
            _params(PIECE_CID, PADDED_SIZE, _payload(DEAL_ID), SECTOR, MINIMUM_COMMITMENT_EPOCH)
        );

        vm.prank(unregisteredMiner.maskedAddress());
        vm.expectRevert(abi.encodeWithSelector(SectorEvidenceAdapter.CallerIsNotMiner.selector, unregisteredMiner));
        adapter.handle_filecoin_method(SECTOR_CONTENT_CHANGED, CBOR_CODEC, params);
    }

    function testCallbackAcceptsMultipleSectors() public {
        bytes32 otherCommitment = keccak256(abi.encode(OTHER_PIECE_DIGEST, PADDED_SIZE));
        _setOtherDeal(otherCommitment);

        SectorChanges[] memory sectors = new SectorChanges[](2);
        sectors[0] = _params(PIECE_CID, PADDED_SIZE, _payload(DEAL_ID), SECTOR, MINIMUM_COMMITMENT_EPOCH).sectors[0];
        sectors[1] = _params(
            OTHER_PIECE_CID, PADDED_SIZE, _payload(OTHER_DEAL_ID), SECTOR + 1, MINIMUM_COMMITMENT_EPOCH
        )
        .sectors[0];

        SectorContentChangedReturn memory result =
            miner.callSectorContentChanged(address(adapter), SectorContentChangedParams({sectors: sectors}));

        assertEq(result.sectors.length, 2);
        assertEq(result.sectors[0].numPieces, 1);
        assertEq(result.sectors[0].accepted[0], 1);
        assertEq(result.sectors[1].numPieces, 1);
        assertEq(result.sectors[1].accepted[0], 1);
        assertTrue(adapter.getReceipt(DEAL_ID).accepted);
        assertTrue(adapter.getReceipt(OTHER_DEAL_ID).accepted);
    }

    function testCallbackAcceptsMultiplePiecesInOneSector() public {
        bytes32 otherCommitment = keccak256(abi.encode(OTHER_PIECE_DIGEST, PADDED_SIZE));
        _setOtherDeal(otherCommitment);

        SectorContentChangedParams memory params =
            _params(PIECE_CID, PADDED_SIZE, _payload(DEAL_ID), SECTOR, MINIMUM_COMMITMENT_EPOCH);
        PieceChange[] memory pieces = new PieceChange[](2);
        pieces[0] = params.sectors[0].added[0];
        pieces[1] = PieceChange({data: OTHER_PIECE_CID, size: PADDED_SIZE, payload: _payload(OTHER_DEAL_ID)});
        params.sectors[0].added = pieces;

        SectorContentChangedReturn memory result = miner.callSectorContentChanged(address(adapter), params);

        assertEq(result.sectors.length, 1);
        assertEq(result.sectors[0].numPieces, 2);
        assertEq(result.sectors[0].accepted[0], 3);
        assertTrue(adapter.getReceipt(DEAL_ID).accepted);
        assertTrue(adapter.getReceipt(OTHER_DEAL_ID).accepted);
    }

    function testCallbackRejectsOneInvalidPieceWithoutRollingBackValidPiece() public {
        bytes32 otherCommitment = keccak256(abi.encode(OTHER_PIECE_DIGEST, PADDED_SIZE));
        _setOtherDeal(otherCommitment);

        SectorContentChangedParams memory params =
            _params(PIECE_CID, PADDED_SIZE, _payload(DEAL_ID), SECTOR, MINIMUM_COMMITMENT_EPOCH);
        PieceChange[] memory pieces = new PieceChange[](2);
        pieces[0] = params.sectors[0].added[0];
        pieces[1] = PieceChange({data: OTHER_PIECE_CID, size: PADDED_SIZE, payload: _payload(OTHER_DEAL_ID + 1)});
        params.sectors[0].added = pieces;

        SectorContentChangedReturn memory result = miner.callSectorContentChanged(address(adapter), params);

        assertEq(result.sectors[0].accepted[0], 1);
        assertTrue(adapter.getReceipt(DEAL_ID).accepted);
        assertFalse(adapter.getReceipt(OTHER_DEAL_ID).accepted);
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

    function testNotificationDoesNotRequireBatchSubmission() public {
        SharedTypes.ActivationDecision memory submitted =
            market.submit(adapter, _context(DEAL_ID, PROVIDER), abi.encode(uint256(123)));
        _notify(DEAL_ID, SECTOR, MINIMUM_COMMITMENT_EPOCH);

        assertEq(submitted.result, EvidenceResult.REJECTED);
        assertTrue(adapter.getReceipt(DEAL_ID).accepted);
    }

    function _notify(uint256 dealId, uint64 sector, int64 minimumCommitmentEpoch)
        internal
        returns (SectorContentChangedReturn memory)
    {
        return _notifyWithPiece(PIECE_CID, PADDED_SIZE, dealId, sector, minimumCommitmentEpoch);
    }

    function _setOtherDeal(bytes32 commitment) internal {
        market.setDeal(OTHER_DEAL_ID, PROVIDER, address(adapter), commitment, PADDED_SIZE, DURATION, PROPOSED_AT);
    }

    function _deployAdapter(address admin, address poRepMarket) internal returns (SectorEvidenceAdapter deployed) {
        SectorEvidenceAdapter implementation = new SectorEvidenceAdapter();
        bytes memory initData = abi.encodeCall(SectorEvidenceAdapter.initialize, (admin, poRepMarket));
        deployed = SectorEvidenceAdapter(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _notifyWithPiece(
        bytes memory pieceCid,
        uint64 paddedSize,
        uint256 dealId,
        uint64 sector,
        int64 minimumCommitmentEpoch
    ) internal returns (SectorContentChangedReturn memory) {
        return miner.callSectorContentChanged(
            address(adapter), _params(pieceCid, paddedSize, _payload(dealId), sector, minimumCommitmentEpoch)
        );
    }

    function testMalformedPayloadIsRejectedWithoutReceipt() public {
        SectorContentChangedParams memory params =
            _params(PIECE_CID, PADDED_SIZE, hex"01", SECTOR, MINIMUM_COMMITMENT_EPOCH);

        SectorContentChangedReturn memory result = miner.callSectorContentChanged(address(adapter), params);

        assertEq(result.sectors[0].accepted[0], 0);
        assertFalse(adapter.getReceipt(DEAL_ID).accepted);
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

    function _payload(uint256 dealId) internal pure returns (bytes memory) {
        return abi.encode(dealId);
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

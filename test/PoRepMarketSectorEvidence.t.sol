// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, function-max-lines, gas-small-strings
pragma solidity =0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {FVMMinerActor} from "fvm-solidity/mocks/FVMMinerActor.sol";
import {MockFVMTest} from "fvm-solidity/mocks/MockFVMTest.sol";
import {
    PieceChange,
    SectorChanges,
    SectorContentChangedParams,
    SectorContentChangedReturn
} from "fvm-solidity/FVMSectorContentChanged.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SectorEvidenceAdapter} from "../src/SectorEvidenceAdapter.sol";
import {DealState} from "../src/types/DealState.sol";
import {DealType} from "../src/types/DealType.sol";
import {EvidenceResult} from "../src/types/EvidenceResult.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {RailStatus} from "../src/types/RailStatus.sol";
import {SettlementReason} from "../src/types/SettlementReason.sol";
import {SettlementResult} from "../src/types/SettlementResult.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {DataCapEvidenceAdapterMock} from "./contracts/DataCapEvidenceAdapterMock.sol";
import {PoRepMarketContractMock} from "./contracts/PoRepMarketContractMock.sol";
import {SLIScorerMock} from "./contracts/SLIScorerMock.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorFactoryMock} from "./contracts/ValidatorFactoryMock.sol";
import {ValidatorMock} from "./contracts/ValidatorMock.sol";

contract PoRepMarketSectorEvidenceTest is MockFVMTest {
    uint64 private constant PROVIDER = 1004;
    uint64 private constant SECTOR = 2;
    uint64 private constant PADDED_SIZE = 2_097_152;
    uint32 private constant DURATION_DAYS = 180;
    int64 private constant DURATION_EPOCHS = 518_400;
    uint256 private constant REQUESTED_SIZE = uint256(PADDED_SIZE) * 2;
    uint256 private constant DEAL_ID = 1;

    bytes private constant PIECE_CID_0 =
        hex"0181e203922020c47f5ea5e33d1ae11afb476c0cc63dba09241fcb2fb0775c33ec522e87044b2b";
    bytes private constant PIECE_CID_1 =
        hex"0181e203922020cdf33e1783f2ff8261e66f95858ff85f976bbc0bf05ce8476d3e360832165cd0";
    bytes32 private constant LEAF_0 = 0xeb6311dd854dcbf53bf60471a663aee4d6905ef84b4a963584aa5c3feb50c098;
    bytes32 private constant LEAF_1 = 0xe8a90c7c511c5ac9e11e2121af757e41c655dcf7176d021180a6aac5f99fe92d;
    bytes32 private constant PIECE_SET_COMMITMENT = 0xb8f59f326ce64b1216c67afe5809b0e21263532d505c04c42f136bf9b9542092;

    address private admin = vm.addr(0xA11);
    address private client = vm.addr(0xC11);
    address private validatorAddress;
    address private paymentToken = vm.addr(0x777);
    address private payee = vm.addr(0x778);

    PoRepMarketContractMock private market;
    SectorEvidenceAdapter private adapter;
    SPRegistryMock private registry;
    ValidatorFactoryMock private validatorFactory;
    ValidatorMock private validator;
    SLIScorerMock private sliScorer;
    FVMMinerActor private miner;

    function setUp() public override {
        super.setUp();

        registry = new SPRegistryMock();
        validatorFactory = new ValidatorFactoryMock();
        validator = new ValidatorMock();
        validatorAddress = address(validator);
        sliScorer = new SLIScorerMock();
        DataCapEvidenceAdapterMock initialAdapter = new DataCapEvidenceAdapterMock();

        PoRepMarketContractMock implementation = new PoRepMarketContractMock();
        bytes memory marketInit = abi.encodeCall(
            PoRepMarket.initialize,
            (admin, address(validatorFactory), address(registry), address(initialAdapter), address(sliScorer))
        );
        market = PoRepMarketContractMock(address(new ERC1967Proxy(address(implementation), marketInit)));

        SectorEvidenceAdapter adapterImplementation = new SectorEvidenceAdapter();
        bytes memory adapterInit = abi.encodeCall(SectorEvidenceAdapter.initialize, (admin, address(market)));
        adapter = SectorEvidenceAdapter(address(new ERC1967Proxy(address(adapterImplementation), adapterInit)));

        vm.prank(admin);
        market.setGlobalEvidenceAdapter(address(adapter));

        registry.setNextSelection(
            SharedTypes.ProviderDealSelection({
                provider: CommonTypes.FilActorId.wrap(PROVIDER),
                offerId: 42,
                paymentToken: paymentToken,
                payee: payee,
                pricePer32GiBPerMonth: 86_400,
                promisedSLIs: _slis(),
                reservedBytes: REQUESTED_SIZE
            })
        );
        validatorFactory.setValidator(validatorAddress, true);
        miner = mockMiner(PROVIDER);
    }

    function testRealMarketActivatesOnlyAfterEveryCommittedPieceArrives() public {
        vm.prank(client);
        market.proposeDeal(_request());

        PoRepTypes.Deal memory proposedDeal = market.getDeal(DEAL_ID);
        assertEq(proposedDeal.state, DealState.ACCEPTED);
        assertEq(proposedDeal.evidenceAdapter, address(adapter));
        assertEq(market.getDealData(DEAL_ID).manifestHash, PIECE_SET_COMMITMENT);

        vm.startPrank(validatorAddress);
        market.updateValidator(DEAL_ID);
        market.updateRailId(DEAL_ID, 1);
        vm.stopPrank();
        validator.setRailStatus(RailStatus.PREPARED);

        SharedTypes.ActivationDecision memory empty = market.activateEvidence(DEAL_ID, "");
        assertEq(empty.result, EvidenceResult.REJECTED);
        assertEq(market.getDealCapacity(DEAL_ID).committedBytes, 0);

        int64 minimumCommitmentEpoch = CommonTypes.ChainEpoch.unwrap(proposedDeal.proposedAtEpoch) + DURATION_EPOCHS;
        SectorContentChangedReturn memory first =
            _notify(PIECE_CID_0, 0, _proof(LEAF_1), SECTOR, minimumCommitmentEpoch);
        assertEq(first.sectors[0].accepted[0], 1);

        SectorEvidenceAdapter.ManifestReceipt memory partialReceipt = adapter.getManifestReceipt(DEAL_ID);
        assertEq(partialReceipt.pieceCount, 2);
        assertEq(partialReceipt.acceptedPieceCount, 1);
        assertEq(partialReceipt.acceptedBytes, PADDED_SIZE);
        assertFalse(partialReceipt.activated);
        assertTrue(adapter.isPieceAccepted(DEAL_ID, 0));
        assertFalse(adapter.isPieceAccepted(DEAL_ID, 1));

        SharedTypes.ActivationDecision memory incomplete = market.activateEvidence(DEAL_ID, "");
        assertEq(incomplete.result, EvidenceResult.REJECTED);
        assertEq(market.getDeal(DEAL_ID).state, DealState.ACCEPTED);
        assertEq(market.getDealCapacity(DEAL_ID).committedBytes, 0);

        SectorContentChangedReturn memory second =
            _notify(PIECE_CID_1, 1, _proof(LEAF_0), SECTOR + 1, minimumCommitmentEpoch);
        assertEq(second.sectors[0].accepted[0], 1);

        SectorEvidenceAdapter.ManifestReceipt memory complete = adapter.getManifestReceipt(DEAL_ID);
        assertEq(complete.acceptedPieceCount, 2);
        assertEq(complete.acceptedBytes, REQUESTED_SIZE);

        SharedTypes.ActivationDecision memory activated = market.activateEvidence(DEAL_ID, "");
        assertEq(activated.result, EvidenceResult.ACCEPTED);
        assertEq(activated.coveredBytes, REQUESTED_SIZE);
        assertEq(market.getDeal(DEAL_ID).state, DealState.ACTIVE);
        assertEq(market.getDealCapacity(DEAL_ID).committedBytes, REQUESTED_SIZE);
        assertEq(registry.lastCommittedActualBytes(), REQUESTED_SIZE);
        assertEq(validator.getRailStatus(), RailStatus.ACTIVE);
        assertTrue(adapter.getManifestReceipt(DEAL_ID).activated);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, DEAL_ID, DealState.ACTIVE, DealState.ACCEPTED
            )
        );
        market.activateEvidence(DEAL_ID, "");

        SharedTypes.EvidenceStatus memory evidenceStatus = market.currentEvidenceStatus(DEAL_ID);
        assertEq(evidenceStatus.result, EvidenceResult.INACTIVE);
        assertEq(evidenceStatus.activeCoveredBytes, 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(evidenceStatus.lastEvidenceRefreshEpoch), 0);

        sliScorer.setScore(DEAL_ID, 100);
        PoRepTypes.DealService memory service = market.getDealService(DEAL_ID);
        uint256 settlementStartEpoch = uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch)));
        uint256 settlementEndEpoch = settlementStartEpoch + market.EPOCHS_IN_MONTH();
        vm.roll(settlementEndEpoch);

        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory settlement =
            market.validateDealSettlement(DEAL_ID, settlementStartEpoch, settlementEndEpoch);
        assertEq(settlement.result, SettlementResult.REJECTED);
        assertEq(settlement.reasonCode, SettlementReason.EVIDENCE_TOO_STALE);
        assertEq(settlement.settlementAmount, 0);
        assertEq(settlement.settleUpto, settlementStartEpoch);
    }

    function testDelayedActivationRejectsProposalBoundCommitmentWithoutStartingService() public {
        vm.prank(client);
        market.proposeDeal(_request());

        PoRepTypes.Deal memory proposedDeal = market.getDeal(DEAL_ID);
        vm.startPrank(validatorAddress);
        market.updateValidator(DEAL_ID);
        market.updateRailId(DEAL_ID, 1);
        vm.stopPrank();
        validator.setRailStatus(RailStatus.PREPARED);

        int64 proposedAtEpoch = CommonTypes.ChainEpoch.unwrap(proposedDeal.proposedAtEpoch);
        int64 minimumCommitmentEpoch = proposedAtEpoch + DURATION_EPOCHS;
        assertEq(_notify(PIECE_CID_0, 0, _proof(LEAF_1), SECTOR, minimumCommitmentEpoch).sectors[0].accepted[0], 1);
        assertEq(_notify(PIECE_CID_1, 1, _proof(LEAF_0), SECTOR + 1, minimumCommitmentEpoch).sectors[0].accepted[0], 1);

        vm.roll(uint256(uint64(proposedAtEpoch + 1)));
        SharedTypes.ActivationDecision memory decision = market.activateEvidence(DEAL_ID, "");

        assertEq(decision.result, EvidenceResult.REJECTED);
        assertEq(decision.coveredBytes, 0);
        assertEq(market.getDeal(DEAL_ID).state, DealState.ACCEPTED);
        assertEq(market.getDealCapacity(DEAL_ID).committedBytes, 0);
        assertEq(registry.lastCommittedActualBytes(), 0);
        assertEq(validator.getRailStatus(), RailStatus.PREPARED);
        assertEq(validator.modifyRailPaymentCallCount(), 0);
        PoRepTypes.DealService memory service = market.getDealService(DEAL_ID);
        assertEq(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch), 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch), 0);
        assertFalse(adapter.getManifestReceipt(DEAL_ID).activated);
    }

    function testActivationAcceptsExactBoundaryAndDuplicateReplayDoesNotLowerCommitment() public {
        vm.prank(client);
        market.proposeDeal(_request());

        PoRepTypes.Deal memory proposedDeal = market.getDeal(DEAL_ID);
        vm.startPrank(validatorAddress);
        market.updateValidator(DEAL_ID);
        market.updateRailId(DEAL_ID, 1);
        vm.stopPrank();
        validator.setRailStatus(RailStatus.PREPARED);

        int64 proposedAtEpoch = CommonTypes.ChainEpoch.unwrap(proposedDeal.proposedAtEpoch);
        int64 activationEpoch = proposedAtEpoch + 10;
        int64 activationBoundary = activationEpoch + DURATION_EPOCHS;
        assertEq(_notify(PIECE_CID_0, 0, _proof(LEAF_1), SECTOR, activationBoundary).sectors[0].accepted[0], 1);
        assertEq(
            _notify(PIECE_CID_1, 1, _proof(LEAF_0), SECTOR + 1, activationBoundary + 100).sectors[0].accepted[0], 1
        );

        SectorEvidenceAdapter.ManifestReceipt memory beforeReplay = adapter.getManifestReceipt(DEAL_ID);
        assertEq(
            _notify(PIECE_CID_1, 1, _proof(LEAF_0), SECTOR + 99, proposedAtEpoch + DURATION_EPOCHS)
            .sectors[0].accepted[0],
            1
        );
        SectorEvidenceAdapter.ManifestReceipt memory afterReplay = adapter.getManifestReceipt(DEAL_ID);
        assertEq(afterReplay.acceptedPieceCount, beforeReplay.acceptedPieceCount);
        assertEq(afterReplay.acceptedBytes, beforeReplay.acceptedBytes);

        vm.roll(uint256(uint64(activationEpoch)));
        SharedTypes.ActivationDecision memory decision = market.activateEvidence(DEAL_ID, "");

        assertEq(decision.result, EvidenceResult.ACCEPTED);
        assertEq(decision.coveredBytes, REQUESTED_SIZE);
        assertEq(market.getDeal(DEAL_ID).state, DealState.ACTIVE);
        assertEq(market.getDealCapacity(DEAL_ID).committedBytes, REQUESTED_SIZE);
        assertEq(registry.lastCommittedActualBytes(), REQUESTED_SIZE);
        assertEq(validator.getRailStatus(), RailStatus.ACTIVE);
        assertEq(validator.modifyRailPaymentCallCount(), 1);
        PoRepTypes.DealService memory service = market.getDealService(DEAL_ID);
        assertEq(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch), activationEpoch);
        assertEq(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch), activationBoundary);
        assertTrue(adapter.getManifestReceipt(DEAL_ID).activated);
    }

    function _request() private view returns (SharedTypes.DealRequest memory) {
        return SharedTypes.DealRequest({
            manifestHash: PIECE_SET_COMMITMENT,
            requestedSizeBytes: REQUESTED_SIZE,
            maxPricePer32GiBPerMonth: 86_400,
            manifestLocation: "https://example.com/two-piece-manifest.json",
            paymentToken: paymentToken,
            durationDays: DURATION_DAYS,
            dealType: DealType.PUBLIC,
            requiredSLIs: _slis()
        });
    }

    function _slis() private pure returns (SharedTypes.SLIThresholds memory) {
        return
            SharedTypes.SLIThresholds({retrievabilityBps: 0, bandwidthBytesPerSecond: 0, latencyMs: 0, indexingPct: 0});
    }

    function _notify(
        bytes memory pieceCid,
        uint32 pieceIndex,
        bytes32[] memory proof,
        uint64 sector,
        int64 minimumCommitmentEpoch
    ) private returns (SectorContentChangedReturn memory) {
        PieceChange[] memory pieces = new PieceChange[](1);
        pieces[0] = PieceChange({
            data: pieceCid, size: PADDED_SIZE, payload: abi.encode(DEAL_ID, pieceIndex, uint32(2), proof)
        });
        SectorChanges[] memory sectors = new SectorChanges[](1);
        sectors[0] = SectorChanges({sector: sector, minimumCommitmentEpoch: minimumCommitmentEpoch, added: pieces});
        return miner.callSectorContentChanged(address(adapter), SectorContentChangedParams({sectors: sectors}));
    }

    function _proof(bytes32 sibling) private pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }
}

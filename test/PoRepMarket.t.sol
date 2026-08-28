// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Test} from "lib/forge-std/src/Test.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorFactoryMock} from "./contracts/ValidatorFactoryMock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {ISPRegistry} from "../src/interfaces/ISPRegistry.sol";
import {IPoRepMarket} from "../src/interfaces/IPoRepMarket.sol";
import {IStorageEvidenceAdapter} from "../src/interfaces/IStorageEvidenceAdapter.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {DealState} from "../src/types/DealState.sol";
import {DealType} from "../src/types/DealType.sol";
import {RailStatus} from "../src/types/RailStatus.sol";
import {EvidenceResult} from "../src/types/EvidenceResult.sol";
import {SettlementReason} from "../src/types/SettlementReason.sol";
import {SettlementResult} from "../src/types/SettlementResult.sol";
import {PoRepMarketContractMock} from "./contracts/PoRepMarketContractMock.sol";
import {ValidatorMock} from "./contracts/ValidatorMock.sol";
import {TestUtils} from "./utils/TestUtils.sol";
import {DataCapEvidenceAdapter} from "../src/DataCapEvidenceAdapter.sol";
import {DataCapEvidenceAdapterMock} from "./contracts/DataCapEvidenceAdapterMock.sol";
import {SLIScorerMock} from "./contracts/SLIScorerMock.sol";

// solhint-disable-next-line max-states-count
contract PoRepMarketTest is Test {
    struct RequestTerms {
        uint256 dealSizeBytes;
        uint256 pricePerSectorPerMonth;
        uint32 durationDays;
    }

    PoRepMarket public poRepMarket;
    SPRegistryMock public spRegistry;
    ValidatorFactoryMock public validatorFactory;
    address public validatorAddress;
    DataCapEvidenceAdapterMock public dataCapEvidenceAdapterAddress;
    SLIScorerMock public sliScorer;
    address public clientAddress;
    address public providerOwnerAddress;
    address public operatorAddress;
    address public adminAddress;
    uint256 public railId;
    uint256 public dealId;
    uint256 public totalDealSize;
    SharedTypes.SLIThresholds internal defaultRequirements;
    RequestTerms internal defaultTerms;

    uint256 public constant MIN_PRICE_PER_SECTOR_PER_MONTH = 86_400;
    uint256 public constant EPOCHS_IN_TWO_DAYS = 5_760;
    uint256 public constant EVIDENCE_REFRESH_GRACE_EPOCHS = 23_040;

    CommonTypes.FilActorId public providerFilActorId;
    address public paymentToken;
    address public paymentPayee;
    uint256 public selectedOfferId;
    bytes32 public defaultManifestHash;
    string public expectedManifestLocation = "https://example.com/manifest";

    // solhint-disable-next-line function-max-lines
    function setUp() public {
        PoRepMarketContractMock impl = new PoRepMarketContractMock();
        spRegistry = new SPRegistryMock();
        validatorFactory = new ValidatorFactoryMock();
        validatorAddress = vm.addr(0x001);
        dataCapEvidenceAdapterAddress = new DataCapEvidenceAdapterMock();
        sliScorer = new SLIScorerMock();
        clientAddress = vm.addr(0x003);
        providerOwnerAddress = vm.addr(0x004);
        operatorAddress = vm.addr(0x005);
        adminAddress = vm.addr(0x006);
        dealId = 1;
        railId = 1;
        totalDealSize = 103_079_215_104; // 96 GiB

        providerFilActorId = CommonTypes.FilActorId.wrap(1000);
        paymentToken = vm.addr(0x777);
        paymentPayee = vm.addr(0x778);
        selectedOfferId = 42;
        defaultManifestHash = keccak256("default-manifest");

        defaultRequirements = SharedTypes.SLIThresholds({
            retrievabilityBps: 80, bandwidthBytesPerSecond: 500, latencyMs: 200, indexingPct: 90
        });
        defaultTerms = RequestTerms({
            dealSizeBytes: totalDealSize, pricePerSectorPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH, durationDays: 360
        });

        bytes memory initData = abi.encodeCall(
            PoRepMarket.initialize,
            (
                adminAddress,
                address(validatorFactory),
                address(spRegistry),
                address(dataCapEvidenceAdapterAddress),
                address(sliScorer)
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        poRepMarket = PoRepMarketContractMock(address(proxy));

        spRegistry.setNextProvider(providerFilActorId);
        spRegistry.setNextSelection(
            SharedTypes.ProviderDealSelection({
                provider: providerFilActorId,
                offerId: selectedOfferId,
                paymentToken: paymentToken,
                payee: paymentPayee,
                pricePer32GiBPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH + 10,
                promisedSLIs: defaultRequirements,
                reservedBytes: totalDealSize
            })
        );
        spRegistry.setIsOwner(providerOwnerAddress, providerFilActorId, true);
        spRegistry.setIsOwner(operatorAddress, providerFilActorId, true);
        validatorFactory.setValidator(validatorAddress, true);
    }

    function createDeal(uint256 proposalDealId, uint8 state) public view returns (PoRepTypes.Deal memory) {
        return PoRepTypes.Deal({
            dealId: proposalDealId,
            client: clientAddress,
            provider: providerFilActorId,
            offerId: 0,
            state: state,
            evidenceAdapter: address(dataCapEvidenceAdapterAddress),
            validator: validatorAddress,
            railId: railId,
            proposedAtEpoch: CommonTypes.ChainEpoch.wrap(0),
            dealType: DealType.PUBLIC
        });
    }

    function dealRequest(
        SharedTypes.SLIThresholds memory requirements,
        RequestTerms memory terms,
        string memory manifestLocation
    ) public view returns (SharedTypes.DealRequest memory) {
        return SharedTypes.DealRequest({
            manifestHash: defaultManifestHash,
            requestedSizeBytes: terms.dealSizeBytes,
            maxPricePer32GiBPerMonth: terms.pricePerSectorPerMonth,
            manifestLocation: manifestLocation,
            paymentToken: paymentToken,
            durationDays: terms.durationDays,
            requiredSLIs: requirements,
            dealType: DealType.PUBLIC
        });
    }

    function createClientDealWithAllocationSize(uint256 _dealId, uint256 _allocationSize)
        public
        view
        returns (DataCapEvidenceAdapter.DataCapDealEvidence memory)
    {
        return DataCapEvidenceAdapter.DataCapDealEvidence({
            postingFinished: false,
            client: clientAddress,
            validator: validatorAddress,
            provider: providerFilActorId,
            dealId: _dealId,
            railId: railId,
            allocatedBytes: _allocationSize,
            allocationIds: new CommonTypes.FilActorId[](0),
            claimIds: new CommonTypes.FilActorId[](0),
            claimedBytes: 0
        });
    }

    function expectedRailRate(uint256 _dealId) internal view returns (uint256) {
        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(_dealId);
        return (payment.pricePer32GiBPerMonth * payment.billed32GiBUnits + poRepMarket.EPOCHS_IN_MONTH() - 1)
            / poRepMarket.EPOCHS_IN_MONTH();
    }

    function chainEpochFromBlock(uint256 epoch) internal pure returns (CommonTypes.ChainEpoch) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return CommonTypes.ChainEpoch.wrap(int64(uint64(epoch)));
    }

    function proposeDefaultDeal() internal {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
    }

    function testPreviewProviderForDealReturnsRegistrySelection() public {
        SharedTypes.DealRequest memory request =
            dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation);

        vm.expectCall(address(spRegistry), abi.encodeCall(ISPRegistry.previewProviderForDeal, (request)));
        SharedTypes.ProviderDealSelection memory selection = poRepMarket.previewProviderForDeal(request);

        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(selection.offerId, selectedOfferId);
        assertEq(selection.paymentToken, paymentToken);
        assertEq(selection.payee, paymentPayee);
        assertEq(selection.pricePer32GiBPerMonth, MIN_PRICE_PER_SECTOR_PER_MONTH + 10);
        assertEq(selection.reservedBytes, totalDealSize);
        assertEq(selection.promisedSLIs.retrievabilityBps, defaultRequirements.retrievabilityBps);
        assertEq(selection.promisedSLIs.bandwidthBytesPerSecond, defaultRequirements.bandwidthBytesPerSecond);
        assertEq(selection.promisedSLIs.latencyMs, defaultRequirements.latencyMs);
        assertEq(selection.promisedSLIs.indexingPct, defaultRequirements.indexingPct);
    }

    function testPreviewProviderForDealRevertsWhenManifestHashIsZero() public {
        SharedTypes.DealRequest memory request =
            dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation);
        request.manifestHash = bytes32(0);

        vm.expectRevert(PoRepMarket.InvalidManifestHash.selector);
        poRepMarket.previewProviderForDeal(request);
    }

    function setDealActive(uint256 targetDealId) internal {
        PoRepMarketContractMock(address(poRepMarket)).setDealState(targetDealId, DealState.ACTIVE);
    }

    function setBilledUnits(uint256 targetDealId, uint256 billed32GiBUnits) internal {
        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(targetDealId);
        payment.billed32GiBUnits = billed32GiBUnits;
        PoRepMarketContractMock(address(poRepMarket)).setDealPayment(targetDealId, payment);
    }

    function createInitializedMarketMock() internal returns (PoRepMarketContractMock) {
        PoRepMarketContractMock impl = new PoRepMarketContractMock();
        bytes memory initData = abi.encodeCall(
            PoRepMarket.initialize,
            (
                adminAddress,
                address(validatorFactory),
                address(spRegistry),
                address(dataCapEvidenceAdapterAddress),
                address(sliScorer)
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return PoRepMarketContractMock(address(proxy));
    }

    function seedProposedDeal(PoRepMarketContractMock market) internal {
        market.setDeal(
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: providerFilActorId,
                offerId: selectedOfferId,
                state: DealState.PROPOSED,
                evidenceAdapter: address(dataCapEvidenceAdapterAddress),
                validator: address(0),
                railId: 0,
                proposedAtEpoch: CommonTypes.ChainEpoch.wrap(0),
                dealType: DealType.PUBLIC
            })
        );
        market.setDealCapacity(dealId, PoRepTypes.DealCapacity({reservedBytes: totalDealSize, committedBytes: 0}));
        market.setDealData(
            dealId,
            SharedTypes.DealData({manifestHash: defaultManifestHash, manifestLocation: expectedManifestLocation})
        );
    }

    function _epochToUint(CommonTypes.ChainEpoch epoch) internal pure returns (uint256) {
        return uint256(uint64(CommonTypes.ChainEpoch.unwrap(epoch)));
    }

    function testProposeDealEmitsEvent() public {
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCreated(
            dealId,
            clientAddress,
            providerFilActorId,
            defaultRequirements,
            defaultManifestHash,
            expectedManifestLocation,
            totalDealSize,
            block.number
        );

        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
    }

    function testProposeDealEmitsDealAcceptedEvent() public {
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCreated(
            dealId,
            clientAddress,
            providerFilActorId,
            defaultRequirements,
            defaultManifestHash,
            expectedManifestLocation,
            totalDealSize,
            block.number
        );
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(dealId, clientAddress, providerFilActorId);

        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
    }

    function testProposeDealWithValidDataCreatesDeal() public {
        vm.roll(100);
        proposeDefaultDeal();

        PoRepTypes.Deal memory p = poRepMarket.getDeal(1);
        assertEq(p.dealId, 1);
        assertEq(p.client, clientAddress);
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(p.offerId, selectedOfferId);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertTrue(p.state == DealState.ACCEPTED);
        assertEq(p.evidenceAdapter, address(dataCapEvidenceAdapterAddress));
    }

    function testProposeDealStoresDealType() public {
        SharedTypes.DealRequest memory request =
            dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation);
        request.dealType = DealType.PUBLIC;

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(request);

        assertEq(poRepMarket.getDeal(dealId).dealType, DealType.PUBLIC);
    }

    function testProposeDealStoresPrivateDealType() public {
        SharedTypes.DealRequest memory request =
            dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation);
        request.dealType = DealType.PRIVATE;

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(request);

        assertEq(poRepMarket.getDeal(dealId).dealType, DealType.PRIVATE);
    }

    function testProposeDealRevertsWhenDealTypeIsNone() public {
        SharedTypes.DealRequest memory request =
            dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation);
        request.dealType = DealType.NONE;

        vm.prank(clientAddress);
        vm.expectRevert(PoRepMarket.InvalidDealType.selector);
        poRepMarket.proposeDeal(request);
    }

    function testProposeDealStoresCustomDealType() public {
        SharedTypes.DealRequest memory request =
            dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation);
        uint8 customDealType = 30;
        request.dealType = customDealType;

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(request);

        assertEq(poRepMarket.getDeal(dealId).dealType, customDealType);
    }

    function testGetDealReturnsValidDeal() public {
        proposeDefaultDeal();

        PoRepTypes.Deal memory p = poRepMarket.getDeal(1);
        assertEq(p.dealId, 1);
        assertEq(p.client, clientAddress);
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(p.offerId, selectedOfferId);
        assertTrue(p.state == DealState.ACCEPTED);
        assertEq(p.evidenceAdapter, address(dataCapEvidenceAdapterAddress));
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
    }

    function testReadPaginationInterfaceSelectorsAreAvailable() public pure {
        assertEq(IPoRepMarket.getDealCount.selector, bytes4(keccak256("getDealCount()")));
        assertEq(IPoRepMarket.getDealIds.selector, bytes4(keccak256("getDealIds(uint256,uint256)")));
        assertEq(
            IPoRepMarket.getDealIdsByState.selector,
            bytes4(keccak256(abi.encodePacked("getDealIdsByState(", "uint8,uint256,uint256)")))
        );
    }

    function testGetDealCountReturnsZeroWhenEmpty() public view {
        assertEq(poRepMarket.getDealCount(), 0);
    }

    function testGetDealIdsReturnsEmptyWhenLimitIsZero() public view {
        (uint256[] memory ids, uint256 total) = poRepMarket.getDealIds(0, 0);
        assertEq(total, 0);
        assertEq(ids.length, 0);
    }

    function testGetDealIdsReturnsEmptyWhenLimitIsZeroAfterDealsExist() public {
        proposeDefaultDeal();

        (uint256[] memory ids, uint256 total) = poRepMarket.getDealIds(0, 0);

        assertEq(total, 1);
        assertEq(ids.length, 0);
    }

    function testGetDealCountReturnsCreatedDealCount() public {
        proposeDefaultDeal();
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, "https://e.com/m2.json"));

        assertEq(poRepMarket.getDealCount(), 2);
    }

    function testGetDealIdsReturnsCreationOrderPage() public {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(clientAddress);
            poRepMarket.proposeDeal(
                dealRequest(
                    defaultRequirements,
                    defaultTerms,
                    string.concat("https://example.com/manifest-", vm.toString(i), ".json")
                )
            );
        }

        (uint256[] memory ids, uint256 total) = poRepMarket.getDealIds(1, 2);

        assertEq(total, 3);
        assertEq(ids.length, 2);
        assertEq(ids[0], 2);
        assertEq(ids[1], 3);
    }

    function testGetDealIdsReturnsLastPartialPage() public {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(clientAddress);
            poRepMarket.proposeDeal(
                dealRequest(
                    defaultRequirements,
                    defaultTerms,
                    string.concat("https://example.com/partial-", vm.toString(i), ".json")
                )
            );
        }

        (uint256[] memory ids, uint256 total) = poRepMarket.getDealIds(2, 10);

        assertEq(total, 3);
        assertEq(ids.length, 1);
        assertEq(ids[0], 3);
    }

    function testGetDealIdsReturnsEmptyWhenOffsetPastTotal() public {
        proposeDefaultDeal();

        (uint256[] memory ids, uint256 total) = poRepMarket.getDealIds(1, 10);

        assertEq(total, 1);
        assertEq(ids.length, 0);
    }

    function testGetDealIdsByStateTracksAcceptedDealAfterProposal() public {
        proposeDefaultDeal();

        (uint256[] memory proposedIds, uint256 proposedTotal) = poRepMarket.getDealIdsByState(DealState.PROPOSED, 0, 10);
        (uint256[] memory acceptedIds, uint256 acceptedTotal) = poRepMarket.getDealIdsByState(DealState.ACCEPTED, 0, 10);

        assertEq(proposedTotal, 0);
        assertEq(proposedIds.length, 0);
        assertEq(acceptedTotal, 1);
        assertEq(acceptedIds.length, 1);
        assertEq(acceptedIds[0], dealId);
    }

    function testGetDealIdsByStateReturnsEmptyWhenOffsetPastAcceptedTotal() public {
        proposeDefaultDeal();

        (uint256[] memory ids, uint256 total) = poRepMarket.getDealIdsByState(DealState.ACCEPTED, 1, 10);

        assertEq(total, 1);
        assertEq(ids.length, 0);
    }

    function testGetDealDataReturnsValidData() public {
        proposeDefaultDeal();

        SharedTypes.DealData memory data = poRepMarket.getDealData(1);
        assertEq(data.manifestHash, defaultManifestHash);
        assertEq(data.manifestLocation, expectedManifestLocation);
    }

    function testGetDealTermsReturnsValidTerms() public {
        proposeDefaultDeal();

        PoRepTypes.DealTerms memory terms = poRepMarket.getDealTerms(1);
        assertEq(terms.requestedSizeBytes, defaultTerms.dealSizeBytes);
        assertEq(terms.durationEpochs, uint64(uint256(defaultTerms.durationDays) * 2_880));
    }

    function testGetDealProposedAtEpochReturnsValidTiming() public {
        vm.roll(100);
        proposeDefaultDeal();

        PoRepTypes.Deal memory deal = poRepMarket.getDeal(1);
        assertEq(CommonTypes.ChainEpoch.unwrap(deal.proposedAtEpoch), 100);
    }

    function testGetDealServiceReturnsValidService() public {
        proposeDefaultDeal();

        PoRepTypes.DealService memory service = poRepMarket.getDealService(1);
        assertEq(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch), 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch), 0);
        assertEq(service.minTimeBetweenSettlementsInEpochs, poRepMarket.EPOCHS_IN_MONTH());
        assertEq(CommonTypes.ChainEpoch.unwrap(service.lastSettledEpoch), 0);
    }

    function testGetDealCapacityReturnsValidCapacity() public {
        proposeDefaultDeal();

        PoRepTypes.DealCapacity memory capacity = poRepMarket.getDealCapacity(1);
        assertEq(capacity.reservedBytes, totalDealSize);
        assertEq(capacity.committedBytes, 0);
    }

    function testGetDealPaymentReturnsValidPayment() public {
        proposeDefaultDeal();

        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(1);
        assertEq(payment.paymentToken, paymentToken);
        assertEq(payment.payee, paymentPayee);
        assertEq(payment.pricePer32GiBPerMonth, MIN_PRICE_PER_SECTOR_PER_MONTH + 10);
        assertEq(payment.billed32GiBUnits, 0);
        assertEq(payment.railMaxRatePerEpoch, 0);
    }

    function testGetDealSLIsReturnsValidThresholds() public {
        proposeDefaultDeal();

        SharedTypes.SLIThresholds memory slis = poRepMarket.getDealSLIs(1);
        assertEq(slis.retrievabilityBps, defaultRequirements.retrievabilityBps);
        assertEq(slis.bandwidthBytesPerSecond, defaultRequirements.bandwidthBytesPerSecond);
        assertEq(slis.latencyMs, defaultRequirements.latencyMs);
        assertEq(slis.indexingPct, defaultRequirements.indexingPct);
    }

    function testProposeDealSnapshotsGlobalEvidenceAdapter() public {
        DataCapEvidenceAdapterMock newEvidenceAdapter = new DataCapEvidenceAdapterMock();

        vm.prank(adminAddress);
        poRepMarket.setGlobalEvidenceAdapter(address(newEvidenceAdapter));

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        assertEq(poRepMarket.getDealEvidenceAdapter(dealId), address(newEvidenceAdapter));

        vm.prank(adminAddress);
        poRepMarket.setGlobalEvidenceAdapter(address(dataCapEvidenceAdapterAddress));

        assertEq(poRepMarket.getDealEvidenceAdapter(dealId), address(newEvidenceAdapter));
    }

    function testProposeDealStoresV2SelectionSnapshot() public {
        uint256 reservedBytes = totalDealSize - 32;
        spRegistry.setNextSelection(
            SharedTypes.ProviderDealSelection({
                provider: providerFilActorId,
                offerId: selectedOfferId,
                paymentToken: paymentToken,
                payee: paymentPayee,
                pricePer32GiBPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH + 10,
                promisedSLIs: defaultRequirements,
                reservedBytes: reservedBytes
            })
        );

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        PoRepTypes.Deal memory deal = poRepMarket.getDeal(dealId);
        assertEq(CommonTypes.FilActorId.unwrap(deal.provider), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(deal.offerId, selectedOfferId);

        PoRepTypes.DealCapacity memory capacity = poRepMarket.getDealCapacity(dealId);
        assertEq(capacity.reservedBytes, reservedBytes);
        assertEq(capacity.committedBytes, 0);

        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);
        assertEq(payment.paymentToken, paymentToken);
        assertEq(payment.payee, paymentPayee);
        assertEq(payment.pricePer32GiBPerMonth, MIN_PRICE_PER_SECTOR_PER_MONTH + 10);

        SharedTypes.SLIThresholds memory slis = poRepMarket.getDealSLIs(dealId);
        assertEq(slis.retrievabilityBps, defaultRequirements.retrievabilityBps);
        assertEq(slis.bandwidthBytesPerSecond, defaultRequirements.bandwidthBytesPerSecond);
        assertEq(slis.latencyMs, defaultRequirements.latencyMs);
        assertEq(slis.indexingPct, defaultRequirements.indexingPct);
    }

    function testProposeDealWithSpecificOfferCallsReserveOfferForDealWithRequest() public {
        SharedTypes.DealRequest memory request =
            dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation);

        vm.prank(adminAddress);
        vm.expectCall(address(spRegistry), abi.encodeCall(ISPRegistry.reserveOfferForDeal, (selectedOfferId, request)));
        poRepMarket.proposeDealWithSpecificOffer(selectedOfferId, request);

        assertEq(spRegistry.lastReserveOfferId(), selectedOfferId);
        SharedTypes.DealRequest memory lastRequest = spRegistry.getLastReserveRequest();
        assertEq(lastRequest.manifestHash, defaultManifestHash);
        assertEq(lastRequest.requestedSizeBytes, totalDealSize);
        assertEq(lastRequest.maxPricePer32GiBPerMonth, MIN_PRICE_PER_SECTOR_PER_MONTH);
        assertEq(lastRequest.paymentToken, paymentToken);
        assertEq(lastRequest.durationDays, defaultTerms.durationDays);
    }

    function testProposeDealWithSpecificOfferCreatesDealForSelectedProviderOffer() public {
        CommonTypes.FilActorId selectedProvider = CommonTypes.FilActorId.wrap(2000);
        address selectedPayee = vm.addr(0x779);
        uint256 specificOfferId = 77;
        uint256 reservedBytes = totalDealSize - 64;
        spRegistry.setProviderState(
            selectedProvider,
            SPRegistryMock.MockProviderState({
                organization: providerOwnerAddress, payee: selectedPayee, paused: false, blocked: false
            })
        );
        spRegistry.setNextSelection(
            SharedTypes.ProviderDealSelection({
                provider: selectedProvider,
                offerId: specificOfferId,
                paymentToken: paymentToken,
                payee: selectedPayee,
                pricePer32GiBPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH + 20,
                promisedSLIs: defaultRequirements,
                reservedBytes: reservedBytes
            })
        );

        vm.prank(adminAddress);
        poRepMarket.proposeDealWithSpecificOffer(
            specificOfferId, dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation)
        );

        PoRepTypes.Deal memory deal = poRepMarket.getDeal(dealId);
        assertEq(CommonTypes.FilActorId.unwrap(deal.provider), CommonTypes.FilActorId.unwrap(selectedProvider));
        assertEq(deal.offerId, specificOfferId);
        assertEq(deal.client, adminAddress);
        assertEq(deal.state, DealState.ACCEPTED);

        PoRepTypes.DealCapacity memory capacity = poRepMarket.getDealCapacity(dealId);
        assertEq(capacity.reservedBytes, reservedBytes);

        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);
        assertEq(payment.payee, selectedPayee);
        assertEq(payment.pricePer32GiBPerMonth, MIN_PRICE_PER_SECTOR_PER_MONTH + 20);
    }

    function testProposeDealWithSpecificOfferRevertsWhenCallerIsNotAdmin() public {
        SharedTypes.DealRequest memory request =
            dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                clientAddress,
                poRepMarket.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(clientAddress);
        poRepMarket.proposeDealWithSpecificOffer(selectedOfferId, request);
    }

    function testProposeDealCallsReserveProviderForDealWithRequest() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        SharedTypes.DealRequest memory request = spRegistry.getLastReserveRequest();
        assertEq(request.manifestHash, defaultManifestHash);
        assertEq(request.requestedSizeBytes, totalDealSize);
        assertEq(request.maxPricePer32GiBPerMonth, MIN_PRICE_PER_SECTOR_PER_MONTH);
        assertEq(request.paymentToken, paymentToken);
        assertEq(request.durationDays, defaultTerms.durationDays);
    }

    function testProposeDealRevertsWhenManifestHashIsZero() public {
        SharedTypes.DealRequest memory request =
            dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation);
        request.manifestHash = bytes32(0);

        vm.prank(clientAddress);
        vm.expectRevert(PoRepMarket.InvalidManifestHash.selector);
        poRepMarket.proposeDeal(request);
    }

    function testShouldIncrementDealIdCounter() public {
        uint8 proposalsCount = 3;
        uint8 startingId = 1;
        PoRepTypes.Deal memory p;

        // solhint-disable-next-line gas-strict-inequalities
        for (uint8 i = startingId; i <= proposalsCount; i++) {
            vm.prank(vm.addr(i));
            poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

            p = poRepMarket.getDeal(i);
            assertEq(p.dealId, i);
            assertEq(p.client, vm.addr(i));
        }

        p = poRepMarket.getDeal(proposalsCount + 1);
        assertEq(p.dealId, 0);
        assertEq(p.client, address(0));
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), 0);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertEq(uint8(p.state), 0);
    }

    function testProposeDealRevertsWhenNoOfferMatched() public {
        spRegistry.setNextProvider(CommonTypes.FilActorId.wrap(0));

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(ISPRegistry.NoOfferMatched.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
    }

    function testUpdateValidatorEmitsValidatorUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ValidatorUpdated(dealId, validatorAddress);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateValidatorRevertsIfValidatorIsAlreadySet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.ValidatorAlreadySet.selector, dealId));
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateValidatorRevertsIfNotTheRegisteredValidator() public {
        address notTheValidator = vm.addr(0x999);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheRegisteredValidator.selector, dealId, notTheValidator));
        vm.prank(notTheValidator);
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateRailIdEmitsRailIdUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.RailIdUpdated(dealId, railId);

        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, railId);
    }

    function testUpdateRailIdRevertsIfSenderIsNotTheDealValidator() public {
        address notTheValidator = vm.addr(0x999);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheDealValidator.selector, dealId, notTheValidator));
        vm.prank(notTheValidator);
        poRepMarket.updateRailId(dealId, railId);
    }

    function testUpdateRailIdRevertsWhenDealIsInIncorrectState() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACTIVE, DealState.ACCEPTED
            )
        );
        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, railId);
    }

    function testUpdateRailIdRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, railId);
    }

    function testUpdateRailIdRevertsWhenRailIdIsAlreadySet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, railId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.RailIdAlreadySet.selector));
        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, railId);
    }

    function testUpdateRailIdRevertsWhenRailIdIsInvalid() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidRailId.selector));
        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, 0);
    }

    function testAcceptDealEmitsDealAcceptedEvent() public {
        PoRepMarketContractMock market = createInitializedMarketMock();
        seedProposedDeal(market);

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(dealId, providerOwnerAddress, providerFilActorId);

        market.acceptDeal(dealId);
    }

    function testAcceptDealAllowsOperatorAuthorisedForProvider() public {
        PoRepMarketContractMock market = createInitializedMarketMock();
        seedProposedDeal(market);

        vm.prank(operatorAddress);
        market.acceptDeal(dealId);

        PoRepTypes.Deal memory p = market.getDeal(dealId);
        assertTrue(p.state == DealState.ACCEPTED);
    }

    function testAcceptDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenNotTheControllingAddress() public {
        address notOwnerAddress = vm.addr(3);
        PoRepMarketContractMock market = createInitializedMarketMock();
        seedProposedDeal(market);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.NotTheControllingAddress.selector, dealId, notOwnerAddress, providerFilActorId
            )
        );
        vm.prank(notOwnerAddress);
        market.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenDealNotInExpectedState() public {
        PoRepMarketContractMock market = createInitializedMarketMock();
        seedProposedDeal(market);
        market.setDealState(dealId, DealState.REJECTED);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.REJECTED, DealState.PROPOSED
            )
        );
        vm.prank(providerOwnerAddress);
        market.acceptDeal(dealId);
    }

    function testFinalizeDealEmitsDealFinalizedEvent() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);
        vm.prank(adminAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealFinalized(dealId, address(validator));

        poRepMarket.finalizeDeal(dealId);
    }

    function testActivatePaymentInitializesPaymentAndServiceWindow() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        setDealActive(dealId);
        setBilledUnits(dealId, defaultTerms.dealSizeBytes / poRepMarket.SECTOR_SIZE());
        validator.setRailStatus(RailStatus.PREPARED);

        uint256 serviceStartEpoch = block.number;
        uint256 expectedBilledUnits = defaultTerms.dealSizeBytes / poRepMarket.SECTOR_SIZE();

        vm.prank(adminAddress);
        poRepMarket.activatePayment(dealId);

        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);
        PoRepTypes.DealService memory service = poRepMarket.getDealService(dealId);

        assertEq(payment.billed32GiBUnits, expectedBilledUnits);
        assertEq(payment.railMaxRatePerEpoch, expectedRailRate(dealId));
        assertEq(uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch))), serviceStartEpoch);
        assertEq(
            uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch))),
            serviceStartEpoch + poRepMarket.getDealTerms(dealId).durationEpochs
        );
        assertEq(validator.modifyRailPaymentCallCount(), 1);
        assertEq(validator.lastNewRate(), expectedRailRate(dealId));
        assertEq(validator.getRailStatus(), RailStatus.ACTIVE);
    }

    function testActivateEvidenceCommitsCapacitySetsDealActiveAndStartsPreparedRail() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, totalDealSize));
        validator.setRailStatus(RailStatus.PREPARED);

        uint256 serviceStartEpoch = block.number;
        bytes memory evidenceData = abi.encode("activate");

        vm.prank(adminAddress);
        SharedTypes.ActivationDecision memory decision = poRepMarket.activateEvidence(dealId, evidenceData);

        PoRepTypes.Deal memory deal = poRepMarket.getDeal(dealId);
        PoRepTypes.DealCapacity memory capacity = poRepMarket.getDealCapacity(dealId);
        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);
        PoRepTypes.DealService memory service = poRepMarket.getDealService(dealId);

        assertEq(decision.result, EvidenceResult.ACCEPTED);
        assertEq(decision.coveredBytes, totalDealSize);
        assertEq(dataCapEvidenceAdapterAddress.activatedEvidence(dealId), evidenceData);
        assertEq(deal.state, DealState.ACTIVE);
        assertEq(capacity.reservedBytes, totalDealSize);
        assertEq(capacity.committedBytes, totalDealSize);
        assertEq(payment.billed32GiBUnits, totalDealSize / poRepMarket.SECTOR_SIZE());
        assertEq(payment.railMaxRatePerEpoch, expectedRailRate(dealId));
        assertEq(uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch))), serviceStartEpoch);
        assertEq(
            uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch))),
            serviceStartEpoch + poRepMarket.getDealTerms(dealId).durationEpochs
        );
        assertEq(spRegistry.lastCommittedProvider(), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(spRegistry.lastCommittedEstimatedBytes(), totalDealSize);
        assertEq(spRegistry.lastCommittedActualBytes(), totalDealSize);
        assertEq(validator.modifyRailPaymentCallCount(), 1);
        assertEq(validator.lastNewRate(), expectedRailRate(dealId));
        assertEq(validator.getRailStatus(), RailStatus.ACTIVE);
    }

    function testActivateEvidenceDoesNotMutateMarketWhenAdapterRejects() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, totalDealSize));
        dataCapEvidenceAdapterAddress.setActivationResult(dealId, EvidenceResult.REJECTED);
        validator.setRailStatus(RailStatus.PREPARED);

        vm.prank(adminAddress);
        SharedTypes.ActivationDecision memory decision = poRepMarket.activateEvidence(dealId, abi.encode("activate"));

        PoRepTypes.Deal memory deal = poRepMarket.getDeal(dealId);
        PoRepTypes.DealCapacity memory capacity = poRepMarket.getDealCapacity(dealId);
        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);
        PoRepTypes.DealService memory service = poRepMarket.getDealService(dealId);

        assertEq(decision.result, EvidenceResult.REJECTED);
        assertEq(deal.state, DealState.ACCEPTED);
        assertEq(capacity.committedBytes, 0);
        assertEq(payment.billed32GiBUnits, 0);
        assertEq(payment.railMaxRatePerEpoch, 0);
        assertEq(uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch))), 0);
        assertEq(spRegistry.lastCommittedActualBytes(), 0);
        assertEq(validator.modifyRailPaymentCallCount(), 0);
        assertEq(validator.getRailStatus(), RailStatus.PREPARED);
    }

    function testActivateEvidenceUsesCoveredBytesForCapacityAndBilling() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);
        uint256 overCoveredBytes = totalDealSize + poRepMarket.SECTOR_SIZE();

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, overCoveredBytes));
        validator.setRailStatus(RailStatus.PREPARED);

        vm.prank(adminAddress);
        SharedTypes.ActivationDecision memory decision = poRepMarket.activateEvidence(dealId, abi.encode("activate"));

        PoRepTypes.DealCapacity memory capacity = poRepMarket.getDealCapacity(dealId);
        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);

        assertEq(decision.coveredBytes, overCoveredBytes);
        assertEq(capacity.committedBytes, overCoveredBytes);
        assertEq(payment.billed32GiBUnits, overCoveredBytes / poRepMarket.SECTOR_SIZE());
        assertEq(spRegistry.lastCommittedActualBytes(), overCoveredBytes);
    }

    function testActivateEvidenceRoundsBilledUnitsUpForPartialSector() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);
        uint256 partialSectorSize = poRepMarket.SECTOR_SIZE() + 1;
        RequestTerms memory terms = RequestTerms({
            dealSizeBytes: partialSectorSize, pricePerSectorPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH, durationDays: 360
        });
        spRegistry.setNextSelection(
            SharedTypes.ProviderDealSelection({
                provider: providerFilActorId,
                offerId: selectedOfferId,
                paymentToken: paymentToken,
                payee: paymentPayee,
                pricePer32GiBPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH + 10,
                promisedSLIs: defaultRequirements,
                reservedBytes: partialSectorSize
            })
        );

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, terms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, partialSectorSize));
        validator.setRailStatus(RailStatus.PREPARED);

        vm.prank(adminAddress);
        poRepMarket.activateEvidence(dealId, abi.encode("activate"));

        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);
        assertEq(payment.billed32GiBUnits, 2);
        assertEq(payment.railMaxRatePerEpoch, expectedRailRate(dealId));
        assertEq(spRegistry.lastCommittedActualBytes(), partialSectorSize);
    }

    function testActivateEvidenceRevertsAfterDealIsAlreadyActive() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, totalDealSize));
        validator.setRailStatus(RailStatus.PREPARED);

        vm.prank(adminAddress);
        poRepMarket.activateEvidence(dealId, abi.encode("activate"));

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACTIVE, DealState.ACCEPTED
            )
        );
        vm.prank(adminAddress);
        poRepMarket.activateEvidence(dealId, abi.encode("activate-again"));

        assertEq(spRegistry.lastCommittedActualBytes(), totalDealSize);
        assertEq(validator.modifyRailPaymentCallCount(), 1);
    }

    function testActivateEvidenceRollsBackMarketWritesWhenPaymentActivationReverts() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, totalDealSize));
        validator.setRailStatus(RailStatus.PREPARED);

        vm.expectRevert(PoRepMarket.InvalidRailId.selector);
        vm.prank(adminAddress);
        poRepMarket.activateEvidence(dealId, abi.encode("activate"));

        PoRepTypes.Deal memory deal = poRepMarket.getDeal(dealId);
        PoRepTypes.DealCapacity memory capacity = poRepMarket.getDealCapacity(dealId);
        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);
        PoRepTypes.DealService memory service = poRepMarket.getDealService(dealId);

        assertEq(deal.state, DealState.ACCEPTED);
        assertEq(capacity.committedBytes, 0);
        assertEq(payment.billed32GiBUnits, 0);
        assertEq(payment.railMaxRatePerEpoch, 0);
        assertEq(uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch))), 0);
        assertEq(spRegistry.lastCommittedActualBytes(), 0);
        assertEq(validator.modifyRailPaymentCallCount(), 0);
    }

    function testActivatePaymentEmitsPaymentActivatedEvent() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        setDealActive(dealId);
        setBilledUnits(dealId, defaultTerms.dealSizeBytes / poRepMarket.SECTOR_SIZE());
        validator.setRailStatus(RailStatus.PREPARED);

        CommonTypes.ChainEpoch expectedServiceStartEpoch = CommonTypes.ChainEpoch.wrap(int64(uint64(block.number)));
        uint256 expectedRate = expectedRailRate(dealId);
        CommonTypes.ChainEpoch expectedServiceEndEpoch = CommonTypes.ChainEpoch
            .wrap(
                CommonTypes.ChainEpoch.unwrap(expectedServiceStartEpoch)
                    + int64(uint64(poRepMarket.getDealTerms(dealId).durationEpochs))
            );

        vm.expectEmit(true, true, true, true, address(poRepMarket));
        emit PoRepMarket.PaymentActivated(dealId, expectedRate, expectedServiceStartEpoch, expectedServiceEndEpoch);

        vm.prank(adminAddress);
        poRepMarket.activatePayment(dealId);
    }

    function testActivatePaymentRevertsWhenRailStateIsInvalid() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        setDealActive(dealId);

        validator.setRailStatus(RailStatus.ACTIVE);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidRailState.selector, RailStatus.ACTIVE));
        vm.prank(adminAddress);
        poRepMarket.activatePayment(dealId);

        assertEq(validator.modifyRailPaymentCallCount(), 0);
    }

    function testActivatePaymentRevertsWhenRailIdIsInvalid() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);

        setDealActive(dealId);

        vm.expectRevert(PoRepMarket.InvalidRailId.selector);
        vm.prank(adminAddress);
        poRepMarket.activatePayment(dealId);
    }

    function testActivatePaymentRevertsWhenBilledUnitsAreZero() public {
        PoRepMarketContractMock impl = new PoRepMarketContractMock();
        bytes memory initData = abi.encodeCall(
            PoRepMarket.initialize,
            (
                adminAddress,
                address(validatorFactory),
                address(spRegistry),
                address(dataCapEvidenceAdapterAddress),
                address(sliScorer)
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        PoRepMarketContractMock market = PoRepMarketContractMock(address(proxy));
        ValidatorMock validator = new ValidatorMock();
        validator.setRailStatus(RailStatus.PREPARED);

        market.setDeal(
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: providerFilActorId,
                offerId: 0,
                state: DealState.ACTIVE,
                evidenceAdapter: address(dataCapEvidenceAdapterAddress),
                validator: address(validator),
                railId: railId,
                proposedAtEpoch: CommonTypes.ChainEpoch.wrap(0),
                dealType: DealType.PUBLIC
            })
        );

        vm.expectRevert(PoRepMarket.InvalidBilled32GiBUnits.selector);
        vm.prank(adminAddress);
        market.activatePayment(dealId);
    }

    function testActivatePaymentRoundsUpRate() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);
        RequestTerms memory terms = RequestTerms({
            dealSizeBytes: poRepMarket.SECTOR_SIZE() * 2, pricePerSectorPerMonth: 43_200, durationDays: 360
        });
        spRegistry.setNextSelection(
            SharedTypes.ProviderDealSelection({
                provider: providerFilActorId,
                offerId: selectedOfferId,
                paymentToken: paymentToken,
                payee: paymentPayee,
                pricePer32GiBPerMonth: terms.pricePerSectorPerMonth,
                promisedSLIs: defaultRequirements,
                reservedBytes: terms.dealSizeBytes
            })
        );

        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(50);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, terms, expectedManifestLocation));
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        setDealActive(dealId);
        setBilledUnits(dealId, 1);
        validator.setRailStatus(RailStatus.PREPARED);

        vm.prank(adminAddress);
        poRepMarket.activatePayment(dealId);

        assertEq(poRepMarket.getDealPayment(dealId).railMaxRatePerEpoch, 1);
        assertEq(validator.lastNewRate(), 1);
    }

    function testActivatePaymentRevertsWhenCalculatedRateIsZero() public {
        PoRepMarketContractMock impl = new PoRepMarketContractMock();
        bytes memory initData = abi.encodeCall(
            PoRepMarket.initialize,
            (
                adminAddress,
                address(validatorFactory),
                address(spRegistry),
                address(dataCapEvidenceAdapterAddress),
                address(sliScorer)
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        PoRepMarketContractMock market = PoRepMarketContractMock(address(proxy));
        ValidatorMock validator = new ValidatorMock();
        validator.setRailStatus(RailStatus.PREPARED);

        market.setDeal(
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: providerFilActorId,
                offerId: 0,
                state: DealState.ACTIVE,
                evidenceAdapter: address(dataCapEvidenceAdapterAddress),
                validator: address(validator),
                railId: railId,
                proposedAtEpoch: CommonTypes.ChainEpoch.wrap(0),
                dealType: DealType.PUBLIC
            })
        );
        market.setDealPayment(
            dealId,
            PoRepTypes.DealPayment({
                paymentToken: address(0),
                payee: address(0),
                pricePer32GiBPerMonth: 0,
                billed32GiBUnits: 1,
                railMaxRatePerEpoch: 0
            })
        );

        vm.expectRevert(PoRepMarket.InvalidZeroAmount.selector);
        vm.prank(adminAddress);
        market.activatePayment(dealId);
    }

    function testFinalizeDealEmitsDealFinalizedEventWhenDealIsActiveWithCustomActivationPadding() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(50);

        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);
        vm.prank(adminAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealFinalized(dealId, address(validator));

        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealEmitsDealFinalizedEventWhenDealIsActiveAfterActivationPaddingUpdate() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(50);

        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);
        vm.prank(adminAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealFinalized(dealId, address(validator));

        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithZeroAllocationAtMaxActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(2_000);

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithAllocationUnderCustomActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(50);

        uint256 dealAllocationSizeAtTheBottomLimit =
            defaultTerms.dealSizeBytes - (defaultTerms.dealSizeBytes * 50) / 10_000 - 1;

        dataCapEvidenceAdapterAddress.setDeal(
            createClientDealWithAllocationSize(dealId, dealAllocationSizeAtTheBottomLimit)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithAllocationOverCustomActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(50);

        uint256 dealAllocationSizeAtTheUpperLimit =
            defaultTerms.dealSizeBytes + (defaultTerms.dealSizeBytes * 50) / 10_000 + 1;

        dataCapEvidenceAdapterAddress.setDeal(
            createClientDealWithAllocationSize(dealId, dealAllocationSizeAtTheUpperLimit)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealDoesNotAddDealIdToReadyForPaymentSet() public {
        PoRepMarketContractMock impl = new PoRepMarketContractMock();
        // solhint-disable-next-line gas-small-strings
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address)",
            adminAddress,
            address(validatorFactory),
            address(spRegistry),
            address(dataCapEvidenceAdapterAddress),
            address(sliScorer)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        PoRepMarketContractMock porepMarekMock = PoRepMarketContractMock(address(proxy));
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        porepMarekMock.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(address(validator));
        porepMarekMock.updateValidator(dealId);
        porepMarekMock.setDealState(dealId, DealState.ACTIVE);
        vm.prank(adminAddress);
        porepMarekMock.finalizeDeal(dealId);

        uint256[] memory activeDealIdsReadyForPayment = porepMarekMock.getActiveDealIdsReadyForPayment();
        assertEq(activeDealIdsReadyForPayment.length, 0);
    }

    function testFinalizeDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithAllocationUnderDefaultActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        dataCapEvidenceAdapterAddress.setDeal(
            createClientDealWithAllocationSize(
                dealId, defaultTerms.dealSizeBytes - (defaultTerms.dealSizeBytes * 1_000) / 10_000 - 1
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithAllocationOverDefaultActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        dataCapEvidenceAdapterAddress.setDeal(
            createClientDealWithAllocationSize(
                dealId, defaultTerms.dealSizeBytes + (defaultTerms.dealSizeBytes * 1_000) / 10_000 + 1
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsWhenCallerIsNotPoRepServiceOrAdmin() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);

        address notTheClientAddress = vm.addr(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                notTheClientAddress,
                poRepMarket.POREP_SERVICE_ROLE()
            )
        );
        vm.prank(notTheClientAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsWhenValidatorNotSet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        setDealActive(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.ValidatorNotSet.selector, dealId));
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsBeforeServiceEnds() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);
        int64 serviceEndEpoch = int64(uint64(block.number + 1));
        PoRepTypes.DealService memory service = poRepMarket.getDealService(dealId);
        service.serviceEndEpoch = CommonTypes.ChainEpoch.wrap(serviceEndEpoch);
        PoRepMarketContractMock(address(poRepMarket)).setDealService(dealId, service);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.ServiceNotEnded.selector, serviceEndEpoch, block.number));
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsWhenDealIsNotActive() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsWhenDealAlreadyFinalized() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.FINALIZED, DealState.ACTIVE
            )
        );
        vm.prank(adminAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testAuthorizeUpgradeRevert() public {
        address unauthorized = vm.addr(0x999);
        address newImpl = address(new PoRepMarket());
        bytes32 upgraderRole = poRepMarket.UPGRADER_ROLE();
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, upgraderRole)
        );
        poRepMarket.upgradeToAndCall(newImpl, "");
    }

    function testProposeDealRevertsWhenRetrievabilityBpsExceeds10000() public {
        SharedTypes.SLIThresholds memory badRequirements = SharedTypes.SLIThresholds({
            retrievabilityBps: 10001, bandwidthBytesPerSecond: 500, latencyMs: 200, indexingPct: 90
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidRetrievabilityBps.selector, uint16(10001)));
        poRepMarket.proposeDeal(dealRequest(badRequirements, defaultTerms, expectedManifestLocation));
    }

    function testProposeDealRevertsWhenIndexingPctExceeds100() public {
        SharedTypes.SLIThresholds memory badRequirements = SharedTypes.SLIThresholds({
            retrievabilityBps: 80, bandwidthBytesPerSecond: 500, latencyMs: 200, indexingPct: 101
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidIndexingPct.selector, uint8(101)));
        poRepMarket.proposeDeal(dealRequest(badRequirements, defaultTerms, expectedManifestLocation));
    }

    function testProposeDealCreatesAcceptedDeal() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        PoRepTypes.Deal memory p = poRepMarket.getDeal(dealId);
        assertTrue(p.state == DealState.ACCEPTED);
    }

    function testProposeDealEmitsDealCreatedAndAcceptedEvents() public {
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCreated(
            dealId,
            clientAddress,
            providerFilActorId,
            defaultRequirements,
            defaultManifestHash,
            expectedManifestLocation,
            totalDealSize,
            block.number
        );
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(dealId, clientAddress, providerFilActorId);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
    }

    function testProposeDealRevertsEmptyManifestLocation() public {
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.EmptyManifestLocation.selector, ""));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, ""));
    }

    function testUpdateManifestLocationRevertsEmptyManifestLocation() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.EmptyManifestLocation.selector, ""));
        poRepMarket.updateManifestLocation(dealId, "");
    }

    function testProposeDealRevertsWhenDealDurationIsBelowMinimum() public {
        RequestTerms memory badTerms = RequestTerms({
            durationDays: poRepMarket.MIN_DEAL_DURATION_DAYS() - 1, dealSizeBytes: 1024, pricePerSectorPerMonth: 100
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealDuration.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testProposeDealRevertsWhenDealDurationIsNotMultipleOf30() public {
        RequestTerms memory badTerms = RequestTerms({
            durationDays: poRepMarket.MIN_DEAL_DURATION_DAYS() + 1, dealSizeBytes: 1024, pricePerSectorPerMonth: 100
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealDuration.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testProposeDealRevertsWhenDealDurationExceedsMaximum() public {
        RequestTerms memory badTerms = RequestTerms({
            durationDays: poRepMarket.MAX_DEAL_DURATION_DAYS() + 12, dealSizeBytes: 1024, pricePerSectorPerMonth: 100
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealDuration.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testManifestLocationIsSetCorrectly() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        SharedTypes.DealData memory data = poRepMarket.getDealData(dealId);
        assertEq(data.manifestLocation, expectedManifestLocation);
    }

    function testManifestLocationIsUpdatedCorrectly() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        SharedTypes.DealData memory data = poRepMarket.getDealData(dealId);
        assertEq(data.manifestLocation, expectedManifestLocation);
        string memory updatedManifestLocation = "updatedManifestLocation";
        vm.prank(adminAddress);
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
        data = poRepMarket.getDealData(dealId);
        assertEq(data.manifestLocation, updatedManifestLocation);
    }

    function testManifestLocationUpdateEmitsEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        string memory updatedManifestLocation = "updatedManifestLocation";
        vm.prank(adminAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ManifestLocationUpdated(dealId, expectedManifestLocation, updatedManifestLocation);
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
    }

    function testManifestLocationUpdateRevertsTooLongManifestLocation() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        string memory updatedManifestLocation = TestUtils.generateLongString(2049);
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.TooLongManifestLocation.selector, updatedManifestLocation));
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
    }

    function testProposeDealRevertsTooLongManifestLocation() public {
        string memory tooLongManifestLocation = TestUtils.generateLongString(2049);
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.TooLongManifestLocation.selector, tooLongManifestLocation));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, tooLongManifestLocation));
    }

    function testInitializeRevertsWhenGlobalEvidenceAdapterIsZero() public {
        PoRepMarket impl = new PoRepMarket();
        bytes memory initData = abi.encodeCall(
            PoRepMarket.initialize,
            (adminAddress, address(validatorFactory), address(spRegistry), address(0), address(sliScorer))
        );

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidEvidenceAdapterAddress.selector));
        new ERC1967Proxy(address(impl), initData);
    }

    function testInitializeRevertsWhenSLIScorerIsZero() public {
        PoRepMarket impl = new PoRepMarket();
        bytes memory initData = abi.encodeCall(
            PoRepMarket.initialize,
            (
                adminAddress,
                address(validatorFactory),
                address(spRegistry),
                address(dataCapEvidenceAdapterAddress),
                address(0)
            )
        );

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidSLIScorerAddress.selector));
        new ERC1967Proxy(address(impl), initData);
    }

    function testProposeDealRevertsWhenGlobalEvidenceAdapterIsZero() public {
        PoRepMarketContractMock market = createInitializedMarketMock();
        market.setGlobalEvidenceAdapterForTest(address(0));

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidEvidenceAdapterAddress.selector));
        vm.prank(clientAddress);
        market.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
    }

    function testSetGlobalEvidenceAdapterRevertsWhenAddressIsZero() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidEvidenceAdapterAddress.selector));
        poRepMarket.setGlobalEvidenceAdapter(address(0));
    }

    function testSetGlobalEvidenceAdapterUpdatesAdapter() public {
        DataCapEvidenceAdapterMock newEvidenceAdapter = new DataCapEvidenceAdapterMock();

        vm.prank(adminAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.GlobalEvidenceAdapterUpdated(address(newEvidenceAdapter));
        poRepMarket.setGlobalEvidenceAdapter(address(newEvidenceAdapter));

        assertEq(poRepMarket.getGlobalEvidenceAdapter(), address(newEvidenceAdapter));
    }

    function testSetGlobalEvidenceAdapterRevertsWhenCallerIsNotAdmin() public {
        DataCapEvidenceAdapterMock newEvidenceAdapter = new DataCapEvidenceAdapterMock();
        address caller = vm.addr(0x999);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, poRepMarket.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(caller);
        poRepMarket.setGlobalEvidenceAdapter(address(newEvidenceAdapter));
    }

    function testSubmitEvidenceBatchRevertsWhenCallerIsNotAdminOrPoRepService() public {
        address caller = vm.addr(0x999);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, poRepMarket.POREP_SERVICE_ROLE()
            )
        );
        vm.prank(caller);
        poRepMarket.submitEvidenceBatch(dealId, abi.encode("payload"));
    }

    function testSubmitEvidenceBatchCallsAssignedDealAdapter() public {
        bytes memory evidenceData = abi.encode("payload");

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        DataCapEvidenceAdapterMock newEvidenceAdapter = new DataCapEvidenceAdapterMock();
        vm.prank(adminAddress);
        poRepMarket.setGlobalEvidenceAdapter(address(newEvidenceAdapter));

        vm.prank(adminAddress);
        poRepMarket.submitEvidenceBatch(dealId, evidenceData);

        assertEq(dataCapEvidenceAdapterAddress.submittedEvidence(dealId), evidenceData);
        assertEq(dataCapEvidenceAdapterAddress.submitEvidenceCaller(dealId), address(poRepMarket));
        assertEq(newEvidenceAdapter.submittedEvidence(dealId).length, 0);
    }

    function testActivateEvidenceAllowsAnyCaller() public {
        bytes memory evidenceData = abi.encode("activate");

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        dataCapEvidenceAdapterAddress.setActivationResult(dealId, EvidenceResult.REJECTED);

        poRepMarket.activateEvidence(dealId, evidenceData);

        assertEq(dataCapEvidenceAdapterAddress.activatedEvidence(dealId), evidenceData);
    }

    function testRefreshEvidenceStatusAllowsAnyCaller() public {
        bytes memory evidenceData = abi.encode("refresh");
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        setDealActive(dealId);

        poRepMarket.refreshEvidenceStatus(dealId, evidenceData);

        assertEq(dataCapEvidenceAdapterAddress.refreshedEvidence(dealId), evidenceData);
    }

    function testCurrentEvidenceStatusIsReadableByAnyCaller() public {
        uint256 coveredBytes = defaultTerms.dealSizeBytes;
        address caller = vm.addr(0x999);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, coveredBytes));

        vm.prank(caller);
        SharedTypes.EvidenceStatus memory status = poRepMarket.currentEvidenceStatus(dealId);

        assertEq(status.activeCoveredBytes, coveredBytes);
    }

    function testValidateDealSettlementUsesCumulativePaymentMath() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);
        uint256 settlementEndEpoch = _epochToUint(service.serviceStartEpoch) + poRepMarket.EPOCHS_IN_MONTH();
        vm.roll(settlementEndEpoch);

        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory decision =
            poRepMarket.validateDealSettlement(dealId, _epochToUint(service.serviceStartEpoch), settlementEndEpoch);

        assertEq(decision.settlementAmount, 259_200);
        assertEq(decision.settleUpto, settlementEndEpoch);
        assertEq(decision.reasonCode, SettlementReason.OK);
        assertEq(decision.result, SettlementResult.ACCEPTED);
        assertEq(decision.note, "payment validated successfully");
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 settlementEndChainEpoch = int64(uint64(settlementEndEpoch));
        assertEq(
            CommonTypes.ChainEpoch.unwrap(poRepMarket.getDealService(dealId).lastSettledEpoch), settlementEndChainEpoch
        );
    }

    function testValidateDealSettlementUpdatesLastSettledEpochAcrossSettlements() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);
        uint256 settlementStartEpoch = _epochToUint(service.serviceStartEpoch);
        uint256 firstSettlementEndEpoch = settlementStartEpoch + poRepMarket.EPOCHS_IN_MONTH();
        uint256 secondSettlementEndEpoch = firstSettlementEndEpoch + poRepMarket.EPOCHS_IN_MONTH();

        dataCapEvidenceAdapterAddress.setLastRefreshEpoch(dealId, chainEpochFromBlock(firstSettlementEndEpoch));
        vm.prank(validatorAddress);
        poRepMarket.validateDealSettlement(dealId, settlementStartEpoch, firstSettlementEndEpoch);

        // forge-lint: disable-next-line(unsafe-typecast)
        int64 firstSettlementEndChainEpoch = int64(uint64(firstSettlementEndEpoch));
        assertEq(
            CommonTypes.ChainEpoch.unwrap(poRepMarket.getDealService(dealId).lastSettledEpoch),
            firstSettlementEndChainEpoch
        );

        dataCapEvidenceAdapterAddress.setLastRefreshEpoch(dealId, chainEpochFromBlock(secondSettlementEndEpoch));
        vm.prank(validatorAddress);
        poRepMarket.validateDealSettlement(dealId, firstSettlementEndEpoch, secondSettlementEndEpoch);

        // forge-lint: disable-next-line(unsafe-typecast)
        int64 secondSettlementEndChainEpoch = int64(uint64(secondSettlementEndEpoch));
        assertEq(
            CommonTypes.ChainEpoch.unwrap(poRepMarket.getDealService(dealId).lastSettledEpoch),
            secondSettlementEndChainEpoch
        );
    }

    function testValidateDealSettlementRevertsWhenCallerIsNotValidator() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        address caller = vm.addr(0x999);
        uint256 settlementEndEpoch = _epochToUint(service.serviceStartEpoch) + poRepMarket.EPOCHS_IN_MONTH();

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.CallerIsNotValidator.selector, dealId, caller));
        vm.prank(caller);
        poRepMarket.validateDealSettlement(dealId, _epochToUint(service.serviceStartEpoch), settlementEndEpoch);
    }

    function testValidateDealSettlementRevertsWhenServiceNotStarted() public {
        proposeDefaultDeal();
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        uint256 settlementEndEpoch = poRepMarket.EPOCHS_IN_MONTH();

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealServiceNotStarted.selector, dealId));
        vm.prank(validatorAddress);
        poRepMarket.validateDealSettlement(dealId, 0, settlementEndEpoch);
    }

    function testValidateDealSettlementRevertsTooEarlyBeforeMinimumSettlementWindow() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);
        uint256 settlementStartEpoch = _epochToUint(service.serviceStartEpoch);
        uint256 settlementEndEpoch = 200;
        uint256 earliestSettlementEpoch = settlementStartEpoch + service.minTimeBetweenSettlementsInEpochs;

        vm.expectRevert(
            abi.encodeWithSelector(PoRepMarket.SettlementTooEarly.selector, settlementEndEpoch, earliestSettlementEpoch)
        );
        vm.prank(validatorAddress);
        poRepMarket.validateDealSettlement(dealId, settlementStartEpoch, settlementEndEpoch);
    }

    function testValidateDealSettlementReturnsScoreFailureNote() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 99);
        uint256 settlementEndEpoch = _epochToUint(service.serviceStartEpoch) + poRepMarket.EPOCHS_IN_MONTH();

        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory decision =
            poRepMarket.validateDealSettlement(dealId, _epochToUint(service.serviceStartEpoch), settlementEndEpoch);

        assertEq(decision.settlementAmount, 0);
        assertEq(decision.settleUpto, settlementEndEpoch);
        assertEq(decision.reasonCode, SettlementReason.SCORE_BELOW_THRESHOLD);
        assertEq(decision.result, SettlementResult.REJECTED);
        assertEq(decision.note, "score below required threshold");
    }

    function testValidateDealSettlementReturnsEvidenceFailureNote() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);
        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, 0));
        uint256 settlementEndEpoch = _epochToUint(service.serviceStartEpoch) + poRepMarket.EPOCHS_IN_MONTH();
        vm.roll(settlementEndEpoch);

        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory decision =
            poRepMarket.validateDealSettlement(dealId, _epochToUint(service.serviceStartEpoch), settlementEndEpoch);

        assertEq(decision.settlementAmount, 0);
        assertEq(decision.settleUpto, settlementEndEpoch);
        assertEq(decision.reasonCode, SettlementReason.DATA_SIZE_MISMATCH);
        assertEq(decision.result, SettlementResult.REJECTED);
        // solhint-disable-next-line gas-small-strings
        assertEq(decision.note, "data size does not match the deal");
    }

    function testValidateDealSettlementRevertsWhenEvidenceRefreshTooOld() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);

        uint256 settlementStartEpoch = _epochToUint(service.serviceStartEpoch);
        uint256 settlementEndEpoch = settlementStartEpoch + poRepMarket.EPOCHS_IN_MONTH();
        uint256 lastRefreshEpoch = settlementEndEpoch - EVIDENCE_REFRESH_GRACE_EPOCHS - 1;

        dataCapEvidenceAdapterAddress.setLastRefreshEpoch(dealId, chainEpochFromBlock(lastRefreshEpoch));
        vm.roll(settlementEndEpoch);

        vm.expectRevert(PoRepMarket.EvidenceTooStale.selector);
        vm.prank(validatorAddress);
        poRepMarket.validateDealSettlement(dealId, settlementStartEpoch, settlementEndEpoch);
    }

    function testValidateDealSettlementRevertsWithInactiveEvidence() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);

        uint256 settlementStartEpoch = _epochToUint(service.serviceStartEpoch);
        uint256 settlementEndEpoch = settlementStartEpoch + poRepMarket.EPOCHS_IN_MONTH();
        uint256 lastRefreshEpoch = settlementEndEpoch - EVIDENCE_REFRESH_GRACE_EPOCHS;

        vm.roll(lastRefreshEpoch + poRepMarket.EPOCHS_IN_MONTH() + 1);
        vm.mockCall(
            address(dataCapEvidenceAdapterAddress),
            IStorageEvidenceAdapter.currentEvidenceStatus.selector,
            abi.encode(
                SharedTypes.EvidenceStatus({
                    activeCoveredBytes: 0,
                    lastEvidenceRefreshEpoch: chainEpochFromBlock(lastRefreshEpoch),
                    reasonCode: 0,
                    result: EvidenceResult.INACTIVE,
                    checkedClaims: 0,
                    totalClaims: 0
                })
            )
        );

        vm.expectRevert(PoRepMarket.EvidenceTooStale.selector);
        vm.prank(validatorAddress);
        poRepMarket.validateDealSettlement(dealId, settlementStartEpoch, settlementEndEpoch);
    }

    function testValidateDealSettlementAcceptsEvidenceAtRefreshMarginBoundary() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);

        uint256 settlementStartEpoch = _epochToUint(service.serviceStartEpoch);
        uint256 settlementEndEpoch = settlementStartEpoch + poRepMarket.EPOCHS_IN_MONTH();
        uint256 lastRefreshEpoch = settlementEndEpoch - EVIDENCE_REFRESH_GRACE_EPOCHS;

        dataCapEvidenceAdapterAddress.setLastRefreshEpoch(dealId, chainEpochFromBlock(lastRefreshEpoch));
        vm.roll(settlementEndEpoch);

        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory decision =
            poRepMarket.validateDealSettlement(dealId, settlementStartEpoch, settlementEndEpoch);

        assertEq(decision.settlementAmount, 259_200);
        assertEq(decision.settleUpto, settlementEndEpoch);
        assertEq(decision.reasonCode, SettlementReason.OK);
        assertEq(decision.result, SettlementResult.ACCEPTED);
    }

    function testValidateDealSettlementRejectsWhenSettlementStartsAfterServiceEnd() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        uint256 serviceEndEpoch = _epochToUint(service.serviceEndEpoch);
        uint256 fromEpoch = serviceEndEpoch + 1;
        uint256 toEpoch = serviceEndEpoch + 100;

        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory decision = poRepMarket.validateDealSettlement(dealId, fromEpoch, toEpoch);

        assertEq(decision.settlementAmount, 0);
        assertEq(decision.settleUpto, toEpoch);
        assertEq(decision.reasonCode, SettlementReason.DEAL_ENDED);
        assertEq(decision.result, SettlementResult.REJECTED);
        assertEq(decision.note, "deal ended");
    }

    function testValidateDealSettlementSkipsMinimumWindowAfterEarlyTermination() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);
        uint256 earlyTerminationEpoch = _epochToUint(service.serviceStartEpoch) + 100;
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 earlyTerminationChainEpoch = int64(uint64(earlyTerminationEpoch));
        PoRepMarketContractMock(address(poRepMarket))
            .setDealService(
                dealId,
                PoRepTypes.DealService({
                serviceStartEpoch: service.serviceStartEpoch,
                serviceEndEpoch: service.serviceEndEpoch,
                earlyTerminationEpoch: CommonTypes.ChainEpoch.wrap(earlyTerminationChainEpoch),
                minTimeBetweenSettlementsInEpochs: poRepMarket.EPOCHS_IN_MONTH(),
                lastSettledEpoch: service.lastSettledEpoch
            })
            );

        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory decision =
            poRepMarket.validateDealSettlement(dealId, _epochToUint(service.serviceStartEpoch), earlyTerminationEpoch);

        assertEq(decision.settlementAmount, 300);
        assertEq(decision.settleUpto, earlyTerminationEpoch);
        assertEq(decision.reasonCode, SettlementReason.OK);
        assertEq(decision.result, SettlementResult.ACCEPTED);
        assertEq(decision.note, "payment validated successfully");
    }

    function testValidateDealSettlementRejectsWhenSettlementStartsAfterEarlyTermination() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        uint256 earlyTerminationEpoch = _epochToUint(service.serviceStartEpoch) + 100;
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 earlyTerminationEpochValue = int64(uint64(earlyTerminationEpoch));
        CommonTypes.ChainEpoch earlyTerminationChainEpoch = CommonTypes.ChainEpoch.wrap(earlyTerminationEpochValue);
        PoRepMarketContractMock(address(poRepMarket))
            .setDealService(
                dealId,
                PoRepTypes.DealService({
                serviceStartEpoch: service.serviceStartEpoch,
                serviceEndEpoch: service.serviceEndEpoch,
                earlyTerminationEpoch: earlyTerminationChainEpoch,
                minTimeBetweenSettlementsInEpochs: poRepMarket.EPOCHS_IN_MONTH(),
                lastSettledEpoch: earlyTerminationChainEpoch
            })
            );

        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory decision =
            poRepMarket.validateDealSettlement(dealId, earlyTerminationEpoch, earlyTerminationEpoch + 100);

        assertEq(decision.settlementAmount, 0);
        assertEq(decision.settleUpto, earlyTerminationEpoch + 100);
        assertEq(decision.reasonCode, SettlementReason.DEAL_TERMINATED);
        assertEq(decision.result, SettlementResult.REJECTED);
        assertEq(decision.note, "deal terminated");
    }

    function testValidateDealSettlementReturnsModifiedResultWhenCappedToEarlyTermination() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);
        uint256 settlementStartEpoch = _epochToUint(service.serviceStartEpoch);
        uint256 earlyTerminationEpoch = settlementStartEpoch + 100;
        uint256 requestedEndEpoch = earlyTerminationEpoch + 100;
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 earlyTerminationChainEpoch = int64(uint64(earlyTerminationEpoch));
        PoRepMarketContractMock(address(poRepMarket))
            .setDealService(
                dealId,
                PoRepTypes.DealService({
                serviceStartEpoch: service.serviceStartEpoch,
                serviceEndEpoch: service.serviceEndEpoch,
                earlyTerminationEpoch: CommonTypes.ChainEpoch.wrap(earlyTerminationChainEpoch),
                minTimeBetweenSettlementsInEpochs: poRepMarket.EPOCHS_IN_MONTH(),
                lastSettledEpoch: service.lastSettledEpoch
            })
            );

        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory decision =
            poRepMarket.validateDealSettlement(dealId, settlementStartEpoch, requestedEndEpoch);

        assertEq(decision.settlementAmount, 300);
        assertEq(decision.settleUpto, requestedEndEpoch);
        assertEq(decision.reasonCode, SettlementReason.OK);
        assertEq(decision.result, SettlementResult.MODIFIED);
        // solhint-disable-next-line gas-small-strings
        assertEq(decision.note, "payment limited to deal termination epoch");
    }

    function testValidateDealSettlementReturnsModifiedResultWhenCappedToServiceEnd() public {
        PoRepTypes.DealService memory service = _completeDefaultDealForSettlement();
        sliScorer.setScore(dealId, 100);
        uint256 serviceEndEpoch = _epochToUint(service.serviceEndEpoch);
        uint256 settlementStartEpoch = serviceEndEpoch - poRepMarket.EPOCHS_IN_MONTH();
        uint256 requestedEndEpoch = serviceEndEpoch + 100;
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 settlementStartChainEpoch = int64(uint64(settlementStartEpoch));
        PoRepMarketContractMock(address(poRepMarket))
            .setDealService(
                dealId,
                PoRepTypes.DealService({
                serviceStartEpoch: service.serviceStartEpoch,
                serviceEndEpoch: service.serviceEndEpoch,
                earlyTerminationEpoch: service.earlyTerminationEpoch,
                minTimeBetweenSettlementsInEpochs: service.minTimeBetweenSettlementsInEpochs,
                lastSettledEpoch: CommonTypes.ChainEpoch.wrap(settlementStartChainEpoch)
            })
            );

        dataCapEvidenceAdapterAddress.setLastRefreshEpoch(dealId, chainEpochFromBlock(serviceEndEpoch));
        vm.prank(validatorAddress);
        SharedTypes.SettlementDecision memory decision =
            poRepMarket.validateDealSettlement(dealId, settlementStartEpoch, requestedEndEpoch);

        assertEq(decision.settlementAmount, poRepMarket.EPOCHS_IN_MONTH() * 3);
        assertEq(decision.settleUpto, requestedEndEpoch);
        assertEq(decision.reasonCode, SettlementReason.OK);
        assertEq(decision.result, SettlementResult.MODIFIED);
        assertEq(decision.note, "payment limited to deal endepoch");
    }

    function testSetMinEpochsBetweenSettlementsUpdatesDealService() public {
        proposeDefaultDeal();

        vm.expectEmit(true, false, false, true);
        emit PoRepMarket.MinEpochsBetweenSettlementsUpdated(dealId, 1000);
        vm.prank(adminAddress);
        poRepMarket.setMinEpochsBetweenSettlements(dealId, 1000);

        assertEq(poRepMarket.getDealService(dealId).minTimeBetweenSettlementsInEpochs, 1000);
    }

    function testSetMinEpochsBetweenSettlementsRevertsForZeroValue() public {
        proposeDefaultDeal();

        vm.expectRevert(PoRepMarket.InvalidMinEpochsBetweenSettlements.selector);
        vm.prank(adminAddress);
        poRepMarket.setMinEpochsBetweenSettlements(dealId, 0);
    }

    function testSetMinEpochsBetweenSettlementsRevertsAboveOneYear() public {
        proposeDefaultDeal();

        vm.expectRevert(PoRepMarket.MinEpochsBetweenSettlementsExceeded.selector);
        vm.prank(adminAddress);
        poRepMarket.setMinEpochsBetweenSettlements(dealId, 1_051_201);
    }

    function testSetMinEpochsBetweenSettlementsRevertsWhenCallerIsNotAdmin() public {
        proposeDefaultDeal();
        address caller = vm.addr(0x999);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, poRepMarket.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(caller);
        poRepMarket.setMinEpochsBetweenSettlements(dealId, 1000);
    }

    function _completeDefaultDealForSettlement() internal returns (PoRepTypes.DealService memory service) {
        vm.roll(100);
        proposeDefaultDeal();

        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        PoRepMarketContractMock market = PoRepMarketContractMock(address(poRepMarket));
        market.setDealState(dealId, DealState.ACTIVE);
        market.setDealCapacity(
            dealId,
            PoRepTypes.DealCapacity({
                reservedBytes: defaultTerms.dealSizeBytes, committedBytes: defaultTerms.dealSizeBytes
            })
        );
        market.setDealPayment(
            dealId,
            PoRepTypes.DealPayment({
                paymentToken: address(0),
                payee: address(0),
                pricePer32GiBPerMonth: defaultTerms.pricePerSectorPerMonth,
                billed32GiBUnits: 3,
                railMaxRatePerEpoch: 3
            })
        );
        market.setDealService(
            dealId,
            PoRepTypes.DealService({
                serviceStartEpoch: CommonTypes.ChainEpoch.wrap(int64(uint64(block.number))),
                serviceEndEpoch: CommonTypes.ChainEpoch
                    .wrap(
                        int64(uint64(block.number + defaultTerms.durationDays * (poRepMarket.EPOCHS_IN_MONTH() / 30)))
                    ),
                earlyTerminationEpoch: CommonTypes.ChainEpoch.wrap(0),
                minTimeBetweenSettlementsInEpochs: poRepMarket.EPOCHS_IN_MONTH(),
                lastSettledEpoch: CommonTypes.ChainEpoch.wrap(0)
            })
        );
        return poRepMarket.getDealService(dealId);
    }

    function testTerminateDealEmitsEventAndSetsState() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.startPrank(address(validator));
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        setDealActive(dealId);

        vm.expectEmit(true, true, true, true);
        int64 endEpoch = int64(uint64(block.number));
        emit PoRepMarket.DealTerminated(dealId, CommonTypes.ChainEpoch.wrap(endEpoch));
        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EARLY_TERMINATED);

        PoRepTypes.Deal memory p = poRepMarket.getDeal(dealId);
        assertTrue(p.state == DealState.EARLY_TERMINATED);
        assertEq(validator.earlyRailTerminationCallCount(), 1);
    }

    function testTerminateDealAtServiceEndEpoch() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);

        int64 serviceEndEpoch = int64(uint64(block.number + 1));
        PoRepTypes.DealService memory service = poRepMarket.getDealService(dealId);
        service.serviceEndEpoch = CommonTypes.ChainEpoch.wrap(serviceEndEpoch);
        PoRepMarketContractMock(address(poRepMarket)).setDealService(dealId, service);
        vm.roll(block.number + 1);

        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EARLY_TERMINATED);

        assertEq(poRepMarket.getDeal(dealId).state, DealState.EARLY_TERMINATED);
        assertEq(
            CommonTypes.ChainEpoch.unwrap(poRepMarket.getDealService(dealId).earlyTerminationEpoch), serviceEndEpoch
        );
        assertEq(validator.earlyRailTerminationCallCount(), 1);
    }

    function testTerminateDealRevertsAfterServiceEndEpoch() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);

        int64 serviceEndEpoch = int64(uint64(block.number + 1));
        PoRepTypes.DealService memory service = poRepMarket.getDealService(dealId);
        service.serviceEndEpoch = CommonTypes.ChainEpoch.wrap(serviceEndEpoch);
        PoRepMarketContractMock(address(poRepMarket)).setDealService(dealId, service);
        vm.roll(block.number + 2);
        int64 earlyTerminationEpoch = int64(uint64(block.number));

        vm.expectRevert(
            abi.encodeWithSelector(PoRepMarket.ServiceAlreadyEnded.selector, serviceEndEpoch, earlyTerminationEpoch)
        );
        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EARLY_TERMINATED);

        assertEq(poRepMarket.getDeal(dealId).state, DealState.ACTIVE);
        assertEq(validator.earlyRailTerminationCallCount(), 0);
    }

    function testTerminateDealReleasesCommittedCapacityWithManifestHash() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);
        uint256 allocatedSize = totalDealSize - 64;

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);

        PoRepMarketContractMock(address(poRepMarket))
            .setDealCapacity(
                dealId, PoRepTypes.DealCapacity({reservedBytes: totalDealSize, committedBytes: allocatedSize})
            );
        setDealActive(dealId);

        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EARLY_TERMINATED);

        assertEq(spRegistry.lastReleasedCapacityProvider(), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(spRegistry.lastReleasedCapacityBytes(), allocatedSize);
        assertEq(spRegistry.lastReleasedCapacityManifestHash(), defaultManifestHash);
        assertEq(validator.earlyRailTerminationCallCount(), 1);
    }

    function testTerminateAcceptedDealReleasesPendingCapacityWithManifestHash() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.startPrank(address(validator));
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();
        validator.setRailStatus(RailStatus.PREPARED);

        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EARLY_TERMINATED);

        assertEq(spRegistry.lastReleasedPendingProvider(), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(spRegistry.lastReleasedPendingBytes(), totalDealSize);
        assertEq(spRegistry.lastReleasedPendingManifestHash(), defaultManifestHash);
        assertEq(poRepMarket.getDeal(dealId).state, DealState.EARLY_TERMINATED);
        assertEq(validator.earlyRailTerminationCallCount(), 1);
    }

    function testTerminateDealExpiresAcceptedDealAfterEvidenceExpiration() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);
        proposeDefaultDeal();

        vm.startPrank(address(validator));
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();
        validator.setRailStatus(RailStatus.PREPARED);

        vm.roll(100);
        dataCapEvidenceAdapterAddress.setDealAllocationExpiration(dealId, chainEpochFromBlock(block.number - 1));

        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EXPIRED);

        assertEq(poRepMarket.getDeal(dealId).state, DealState.EXPIRED);
        assertEq(validator.earlyRailTerminationCallCount(), 1);
        assertEq(spRegistry.lastReleasedPendingProvider(), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(spRegistry.lastReleasedPendingBytes(), totalDealSize);
        assertEq(spRegistry.lastReleasedPendingManifestHash(), defaultManifestHash);
    }

    function testTerminateDealRevertsWhenEvidenceExpirationIsNotSet() public {
        proposeDefaultDeal();
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.EvidenceNotExpired.selector, dealId));
        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EXPIRED);
    }

    function testTerminateDealRevertsBeforeEvidenceExpiration() public {
        proposeDefaultDeal();
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        dataCapEvidenceAdapterAddress.setDealAllocationExpiration(dealId, chainEpochFromBlock(block.number + 1));

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.EvidenceNotExpired.selector, dealId));
        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EXPIRED);
    }

    function testTerminateDealRevertsForUnsupportedTerminalState() public {
        uint8 unsupportedState = DealState.FINALIZED;
        proposeDefaultDeal();
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidTerminationState.selector, unsupportedState));
        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, unsupportedState);
    }

    function testTerminateDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EARLY_TERMINATED);
    }

    function testTerminateDealRevertsWhenValidatorNotSetForDealThatIsNotActive() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.ValidatorNotSet.selector, dealId));
        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EARLY_TERMINATED);
    }

    function testTerminateDealRevertsWhenValidatorNotSet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        setDealActive(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.ValidatorNotSet.selector, dealId));
        vm.prank(adminAddress);
        poRepMarket.terminateDeal(dealId, DealState.EARLY_TERMINATED);
    }

    function testTerminateDealRevertsWhenCallerIsNotPoRepServiceOrAdmin() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        setDealActive(dealId);

        address caller = vm.addr(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, poRepMarket.POREP_SERVICE_ROLE()
            )
        );
        vm.prank(caller);
        poRepMarket.terminateDeal(dealId, DealState.EARLY_TERMINATED);
    }

    function testGetDealsForOrganizationByStateZeroAddressOfOrganizationReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidOrganizationAddress.selector, address(0)));
        poRepMarket.getDealsForOrganizationByState(address(0), DealState.PROPOSED);
    }

    function testGetDealsForOrganizationByStateAccepted() public {
        address organization1 = vm.addr(0x111);
        address organization2 = vm.addr(0x222);

        spRegistry.setProviderState(
            providerFilActorId,
            SPRegistryMock.MockProviderState({
                organization: organization1, payee: address(0), paused: false, blocked: false
            })
        );

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        PoRepTypes.Deal[] memory dealsOrg1 =
            poRepMarket.getDealsForOrganizationByState(organization1, DealState.ACCEPTED);
        assertEq(dealsOrg1.length, 1);
        assertEq(dealsOrg1[0].dealId, dealId);

        PoRepTypes.Deal[] memory proposedOrg1 =
            poRepMarket.getDealsForOrganizationByState(organization1, DealState.PROPOSED);
        assertEq(proposedOrg1.length, 0);

        PoRepTypes.Deal[] memory dealsOrg2 =
            poRepMarket.getDealsForOrganizationByState(organization2, DealState.ACCEPTED);
        assertEq(dealsOrg2.length, 0);
    }

    function testGetDealsReturnsEmptyArrayWhenNoDeals() public view {
        PoRepTypes.Deal[] memory deals = poRepMarket.getDeals();
        assertEq(deals.length, 0);
    }

    function testGetDealsReturnsAllDeals() public {
        uint256 count = 3;
        for (uint256 i = 1; i < count + 1; i++) {
            vm.prank(vm.addr(i));
            poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        }

        PoRepTypes.Deal[] memory deals = poRepMarket.getDeals();
        assertEq(deals.length, count);
        for (uint256 i = 0; i < count; i++) {
            assertEq(deals[i].dealId, i + 1);
            assertEq(deals[i].client, vm.addr(i + 1));
        }
    }

    function testProposeDealRevertsWhenDealSizeIsZero() public {
        RequestTerms memory badTerms =
            RequestTerms({durationDays: 360, dealSizeBytes: 0, pricePerSectorPerMonth: 100_000});

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealSize.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testProposeDealRevertsWhenPriceTimeSectorsIsBelowEpochsInMonth() public {
        RequestTerms memory badTerms = RequestTerms({
            durationDays: 360, dealSizeBytes: 1024, pricePerSectorPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH - 1
        });

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealPricePerSectorPerMonth.selector, 86_399, 86_400));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testProposeDealSucceedsWhenLowPriceButManySectors() public {
        uint256 oneTebibyteInBytes = 1024 * 1024 * 1024 * 1024;
        uint256 pricePerSector = 62_500;

        RequestTerms memory terms = RequestTerms({
            durationDays: 360, dealSizeBytes: oneTebibyteInBytes, pricePerSectorPerMonth: pricePerSector
        });

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, terms, expectedManifestLocation));
    }

    function testRejectAcceptedDealByAdmin() public {
        uint256 reservedBytes = totalDealSize - 96;
        spRegistry.setNextSelection(
            SharedTypes.ProviderDealSelection({
                provider: providerFilActorId,
                offerId: selectedOfferId,
                paymentToken: paymentToken,
                payee: paymentPayee,
                pricePer32GiBPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH + 10,
                promisedSLIs: defaultRequirements,
                reservedBytes: reservedBytes
            })
        );

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectEmit(true, false, false, false);
        emit PoRepMarket.DealRejected(dealId, adminAddress);
        vm.prank(adminAddress);
        poRepMarket.rejectAcceptedDeal(dealId);

        PoRepTypes.Deal memory deal = poRepMarket.getDeal(dealId);
        assertTrue(deal.state == DealState.REJECTED);
        assertEq(spRegistry.lastReleasedPendingProvider(), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(spRegistry.lastReleasedPendingBytes(), reservedBytes);
        assertEq(spRegistry.lastReleasedPendingManifestHash(), defaultManifestHash);
    }

    function testRejectAcceptedDealRevertsWhenRailIdIsSet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, 1);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealNotRejectable.selector, dealId));
        vm.prank(adminAddress);
        poRepMarket.rejectAcceptedDeal(dealId);
    }

    function testSetDealActivationPaddingEmitsEvent() public {
        uint256 newPadding = 15;

        vm.expectEmit(true, false, false, false);
        emit PoRepMarket.DealActivationPaddingUpdated(1_000, newPadding);
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(newPadding);
    }

    function testSetDealActivationPaddingRevertsWhenPaddingTooHigh() public {
        uint256 newPadding = 2_001;

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealActivationPaddingTooHigh.selector, newPadding, 2_000));
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(newPadding);
    }

    function testSetDealActivationPaddingRevertsWhenCallerIsNotAdmin() public {
        uint256 newPadding = 15;
        address notTheAdmin = vm.addr(0x999);
        bytes32 defaultAdminRole = poRepMarket.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notTheAdmin, defaultAdminRole
            )
        );
        vm.prank(notTheAdmin);
        poRepMarket.setDealActivationPadding(newPadding);
    }

    function testGetDealActivationPaddingReturnsUpdatedValue() public {
        assertEq(poRepMarket.getDealActivationPadding(), 1_000);

        uint256 newPadding = 15;
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(newPadding);
        assertEq(poRepMarket.getDealActivationPadding(), newPadding);
    }

    function testGetSPRegistryContract() public view {
        assertEq(poRepMarket.getSPRegistryContract(), address(spRegistry));
    }

    function testGetGlobalEvidenceAdapter() public view {
        assertEq(poRepMarket.getGlobalEvidenceAdapter(), address(dataCapEvidenceAdapterAddress));
    }

    function testGetValidatorFactoryContract() public view {
        assertEq(poRepMarket.getValidatorFactoryContract(), address(validatorFactory));
    }

    function testManifestLocationUpdateRevertsWhenCallerIsNotAdmin() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        string memory updatedManifestLocation = "updatedManifestLocation";
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                clientAddress,
                poRepMarket.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(clientAddress);
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
    }
}

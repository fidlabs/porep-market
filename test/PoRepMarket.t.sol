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
import {SLITypes} from "../src/types/SLITypes.sol";
import {ISPRegistry} from "../src/interfaces/ISPRegistry.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {DealState} from "../src/types/DealState.sol";
import {RailStatus} from "../src/types/RailStatus.sol";
import {PoRepMarketContractMock} from "./contracts/PoRepMarketContractMock.sol";
import {ValidatorMock} from "./contracts/ValidatorMock.sol";
import {TestUtils} from "./utils/TestUtils.sol";
import {DataCapEvidenceAdapterMock} from "./contracts/DataCapEvidenceAdapterMock.sol";
import {DataCapEvidenceAdapter} from "../src/DataCapEvidenceAdapter.sol";

// solhint-disable-next-line max-states-count
contract PoRepMarketTest is Test {
    PoRepMarket public poRepMarket;
    SPRegistryMock public spRegistry;
    ValidatorFactoryMock public validatorFactory;
    address public validatorAddress;
    DataCapEvidenceAdapterMock public dataCapEvidenceAdapterAddress;
    address public clientAddress;
    address public providerOwnerAddress;
    address public operatorAddress;
    address public adminAddress;
    uint256 public railId;
    uint256 public dealId;
    uint256 public totalDealSize;
    SharedTypes.SLIThresholds internal defaultRequirements;
    SLITypes.DealTerms internal defaultTerms;

    uint256 public constant MIN_PRICE_PER_SECTOR_PER_MONTH = 86_400;
    uint256 public constant EPOCHS_IN_TWO_DAYS = 5_760;

    CommonTypes.FilActorId public providerFilActorId;
    address public paymentToken;
    address public paymentPayee;
    uint256 public selectedOfferId;
    bytes32 public defaultManifestHash;
    string public expectedManifestLocation = "https://example.com/manifest";

    function setUp() public {
        PoRepMarketContractMock impl = new PoRepMarketContractMock();
        spRegistry = new SPRegistryMock();
        validatorFactory = new ValidatorFactoryMock();
        validatorAddress = vm.addr(0x001);
        dataCapEvidenceAdapterAddress = new DataCapEvidenceAdapterMock();
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
        defaultTerms = SLITypes.DealTerms({
            dealSizeBytes: totalDealSize, pricePerSectorPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH, durationDays: 360
        });

        bytes memory initData = abi.encodeCall(
            PoRepMarket.initialize,
            (adminAddress, address(validatorFactory), address(spRegistry), address(dataCapEvidenceAdapterAddress))
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
            railId: railId
        });
    }

    function dealRequest(
        SharedTypes.SLIThresholds memory requirements,
        SLITypes.DealTerms memory terms,
        string memory manifestLocation
    ) public view returns (SharedTypes.DealRequest memory) {
        return SharedTypes.DealRequest({
            manifestHash: defaultManifestHash,
            requestedSizeBytes: terms.dealSizeBytes,
            maxPricePer32GiBPerMonth: terms.pricePerSectorPerMonth,
            manifestLocation: manifestLocation,
            paymentToken: paymentToken,
            durationDays: terms.durationDays,
            requiredSLIs: requirements
        });
    }

    function createClientDealWithAllocationSize(uint256 _dealId, uint256 _allocationSize)
        public
        view
        returns (DataCapEvidenceAdapter.DataCapDealEvidence memory)
    {
        return DataCapEvidenceAdapter.DataCapDealEvidence({
            completed: false,
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

    function proposeDefaultDeal() internal {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
    }

    function setDealActive(uint256 targetDealId) internal {
        PoRepMarketContractMock(address(poRepMarket)).setDealState(targetDealId, DealState.ACTIVE);
    }

    function setBilledUnits(uint256 targetDealId, uint256 billed32GiBUnits) internal {
        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(targetDealId);
        payment.billed32GiBUnits = billed32GiBUnits;
        PoRepMarketContractMock(address(poRepMarket)).setDealPayment(targetDealId, payment);
    }

    function testProposeDealEmitsEvent() public {
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCreated(
            dealId,
            clientAddress,
            providerFilActorId,
            defaultRequirements,
            expectedManifestLocation,
            totalDealSize,
            block.number
        );

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

    function testGetDealTimingReturnsValidTiming() public {
        vm.roll(100);
        proposeDefaultDeal();

        PoRepTypes.DealTiming memory timing = poRepMarket.getDealTiming(1);
        assertEq(CommonTypes.ChainEpoch.unwrap(timing.proposedAtEpoch), 100);
        assertEq(CommonTypes.ChainEpoch.unwrap(timing.expiresAtEpoch), 5_860);
    }

    function testGetDealServiceReturnsValidService() public {
        proposeDefaultDeal();

        PoRepTypes.DealService memory service = poRepMarket.getDealService(1);
        assertEq(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch), 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch), 0);
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
        assertEq(p.dealId, 0);
        assertEq(p.client, address(0));
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), 0);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertEq(uint8(p.state), 0);
    }

    function testProposeDealRevertsWhenNoProviderFoundForDeal() public {
        spRegistry.setNextProvider(CommonTypes.FilActorId.wrap(0));

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NoProviderFoundForDeal.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
    }

    function testUpdateValidatorEmitsValidatorUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ValidatorUpdated(dealId, validatorAddress);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateValidatorRevertsIfValidatorIsAlreadySet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.ValidatorAlreadySet.selector, dealId));
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateValidatorRevertsIfNotTheRegisteredValidator() public {
        address notTheValidator = vm.addr(0x999);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheRegisteredValidator.selector, dealId, notTheValidator));
        vm.prank(notTheValidator);
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateRailIdEmitsRailIdUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
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
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheDealValidator.selector, dealId, notTheValidator));
        vm.prank(notTheValidator);
        poRepMarket.updateRailId(dealId, railId);
    }

    function testUpdateRailIdRevertsWhenDealIsInIncorrectState() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.PROPOSED, DealState.ACCEPTED
            )
        );
        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, railId);
    }

    function testUpdateRaildIdRevertsWhenDealDoesntExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, railId);
    }

    function testUpdateRailIdRevertsWhenRailIdIsAlreadySet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
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
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidRailId.selector));
        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, 0);
    }

    function testAcceptDealEmitsDealAcceptedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(dealId, providerOwnerAddress, providerFilActorId);

        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealAllowsOperatorAuthorisedForProvider() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(operatorAddress);
        poRepMarket.acceptDeal(dealId);

        PoRepTypes.Deal memory p = poRepMarket.getDeal(dealId);
        assertTrue(p.state == DealState.ACCEPTED);
    }

    function testAcceptDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenNotTheControllingAddress() public {
        address notOwnerAddress = vm.addr(3);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.NotTheControllingAddress.selector, dealId, notOwnerAddress, providerFilActorId
            )
        );
        vm.prank(notOwnerAddress);
        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenDealNotInExpectedState() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.rejectDeal(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.REJECTED, DealState.PROPOSED
            )
        );
        vm.prank(clientAddress);
        poRepMarket.acceptDeal(dealId);
    }

    function testFinalizeDealEmitsDealFinalizedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);
        vm.prank(validatorAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealFinalized(dealId, validatorAddress);

        poRepMarket.finalizeDeal(dealId);
    }

    function testActivatePaymentInitializesPaymentAndServiceWindow() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        setDealActive(dealId);
        setBilledUnits(dealId, defaultTerms.dealSizeBytes / poRepMarket.SECTOR_SIZE());
        validator.setRailStatus(RailStatus.PREPARED);

        uint256 serviceStartEpoch = block.number;
        uint256 expectedBilledUnits = defaultTerms.dealSizeBytes / poRepMarket.SECTOR_SIZE();
        uint256 expectedRate =
            (defaultTerms.pricePerSectorPerMonth * expectedBilledUnits) / poRepMarket.EPOCHS_IN_MONTH();

        vm.prank(adminAddress);
        poRepMarket.activatePayment(dealId);

        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);
        PoRepTypes.DealService memory service = poRepMarket.getDealService(dealId);

        assertEq(payment.billed32GiBUnits, expectedBilledUnits);
        assertEq(payment.railMaxRatePerEpoch, expectedRate);
        assertEq(uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch))), serviceStartEpoch);
        assertEq(
            uint256(uint64(CommonTypes.ChainEpoch.unwrap(service.serviceEndEpoch))),
            serviceStartEpoch + poRepMarket.getDealTerms(dealId).durationEpochs
        );
        assertEq(validator.modifyRailPaymentCallCount(), 1);
        assertEq(validator.lastNewRate(), expectedRate);
        assertEq(validator.getRailStatus(), RailStatus.ACTIVE);
    }

    function testActivatePaymentEmitsPaymentActivatedEvent() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(address(validator));
        poRepMarket.updateValidator(dealId);
        vm.prank(address(validator));
        poRepMarket.updateRailId(dealId, railId);

        setDealActive(dealId);
        setBilledUnits(dealId, defaultTerms.dealSizeBytes / poRepMarket.SECTOR_SIZE());
        validator.setRailStatus(RailStatus.PREPARED);

        CommonTypes.ChainEpoch expectedServiceStartEpoch = CommonTypes.ChainEpoch.wrap(int64(uint64(block.number)));
        uint256 expectedBilledUnits = defaultTerms.dealSizeBytes / poRepMarket.SECTOR_SIZE();
        uint256 expectedRate =
            (defaultTerms.pricePerSectorPerMonth * expectedBilledUnits) / poRepMarket.EPOCHS_IN_MONTH();
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
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
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
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
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
            (adminAddress, address(validatorFactory), address(spRegistry), address(dataCapEvidenceAdapterAddress))
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
                railId: railId
            })
        );

        vm.expectRevert(PoRepMarket.InvalidBilled32GiBUnits.selector);
        vm.prank(adminAddress);
        market.activatePayment(dealId);
    }

    function testActivatePaymentRoundsUpRate() public {
        ValidatorMock validator = new ValidatorMock();
        validatorFactory.setValidator(address(validator), true);
        SLITypes.DealTerms memory terms = SLITypes.DealTerms({
            dealSizeBytes: poRepMarket.SECTOR_SIZE() * 2, pricePerSectorPerMonth: 43_200, durationDays: 360
        });

        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(50);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, terms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
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
            (adminAddress, address(validatorFactory), address(spRegistry), address(dataCapEvidenceAdapterAddress))
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
                railId: railId
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
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(10);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);
        vm.prank(validatorAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealFinalized(dealId, validatorAddress);

        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealEmitsDealFinalizedEventWhenDealIsActiveAfterActivationPaddingUpdate() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(10);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);
        vm.prank(validatorAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealFinalized(dealId, validatorAddress);

        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithZeroAllocationAtMaxActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(100);

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, 0));
        vm.prank(clientAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithAllocationUnderCustomActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(10);

        uint256 dealAllocationSizeAtTheBottomLimit =
            defaultTerms.dealSizeBytes - (defaultTerms.dealSizeBytes * 10) / 100 - 1;

        dataCapEvidenceAdapterAddress.setDeal(
            createClientDealWithAllocationSize(dealId, dealAllocationSizeAtTheBottomLimit)
        );
        vm.prank(clientAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithAllocationOverCustomActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(10);

        uint256 dealAllocationSizeAtTheUpperLimit = (defaultTerms.dealSizeBytes * 110) / 100 + 1;

        dataCapEvidenceAdapterAddress.setDeal(
            createClientDealWithAllocationSize(dealId, dealAllocationSizeAtTheUpperLimit)
        );
        vm.prank(clientAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealDoesNotAddDealIdToReadyForPaymentSet() public {
        PoRepMarketContractMock impl = new PoRepMarketContractMock();
        // solhint-disable-next-line gas-small-strings
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            adminAddress,
            address(validatorFactory),
            address(spRegistry),
            address(dataCapEvidenceAdapterAddress)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        PoRepMarketContractMock porepMarekMock = PoRepMarketContractMock(address(proxy));
        vm.prank(clientAddress);
        porepMarekMock.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        porepMarekMock.acceptDeal(dealId);

        vm.prank(validatorAddress);
        porepMarekMock.updateValidator(dealId);
        porepMarekMock.setDealState(dealId, DealState.ACTIVE);
        vm.prank(validatorAddress);
        porepMarekMock.finalizeDeal(dealId);

        uint256[] memory activeDealIdsReadyForPayment = porepMarekMock.getActiveDealIdsReadyForPayment();
        assertEq(activeDealIdsReadyForPayment.length, 0);
    }

    function testFinalizeDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithAllocationUnderDefaultActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        dataCapEvidenceAdapterAddress.setDeal(
            createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes - 1)
        );
        vm.prank(clientAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsForAcceptedDealWithAllocationOverDefaultActivationPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        dataCapEvidenceAdapterAddress.setDeal(
            createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes + 1)
        );
        vm.prank(clientAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.ACTIVE
            )
        );
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsWhenCallerIsNotValidator() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);

        address notTheClientAddress = vm.addr(0x999);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.CallerIsNotValidator.selector, dealId, notTheClientAddress));
        vm.prank(notTheClientAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsWhenDealIsNotActive() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.PROPOSED, DealState.ACTIVE
            )
        );
        vm.prank(clientAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testFinalizeDealRevertsWhenDealAlreadyFinalized() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        setDealActive(dealId);
        vm.prank(validatorAddress);
        poRepMarket.finalizeDeal(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.FINALIZED, DealState.ACTIVE
            )
        );
        vm.prank(validatorAddress);
        poRepMarket.finalizeDeal(dealId);
    }

    function testRejectAsClientDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, clientAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectAsStorageProviderOwnerDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, providerOwnerAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectAsOperatorAuthorisedForProviderEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(operatorAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, operatorAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectDealRevertsWhenNotTheClientOrStorageProviderOwner() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        address notTheClientOrStorageProviderOwner = vm.addr(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.NotTheClientOrStorageProviderOrAdmin.selector, dealId, notTheClientOrStorageProviderOwner
            )
        );
        vm.prank(notTheClientOrStorageProviderOwner);
        poRepMarket.rejectDeal(dealId);
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
        SLITypes.DealTerms memory badTerms = SLITypes.DealTerms({
            durationDays: poRepMarket.MIN_DEAL_DURATION_DAYS() - 1, dealSizeBytes: 1024, pricePerSectorPerMonth: 100
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealDuration.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testProposeDealRevertsWhenDealDurationIsNotMultiplicatioveOf30() public {
        SLITypes.DealTerms memory badTerms = SLITypes.DealTerms({
            durationDays: poRepMarket.MIN_DEAL_DURATION_DAYS() + 1, dealSizeBytes: 1024, pricePerSectorPerMonth: 100
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealDuration.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testProposeDealRevertsWhenDealDurationExceedsMaximum() public {
        SLITypes.DealTerms memory badTerms = SLITypes.DealTerms({
            durationDays: poRepMarket.MAX_DEAL_DURATION_DAYS() + 12, dealSizeBytes: 1024, pricePerSectorPerMonth: 100
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealDuration.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testManifestLocationIsSetCorrectly() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        string memory manifestLocation = poRepMarket.getManifestLocation(dealId);
        assertEq(manifestLocation, expectedManifestLocation);
    }

    function testManifestLocationIsUpdateCorrectly() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
        string memory manifestLocation = poRepMarket.getManifestLocation(dealId);
        assertEq(manifestLocation, expectedManifestLocation);
        string memory updatedManifestLocation = "updatedManifestLocation";
        vm.prank(adminAddress);
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
        manifestLocation = poRepMarket.getManifestLocation(dealId);
        assertEq(manifestLocation, updatedManifestLocation);
    }

    function testManifestLocationUpdateEmitEvent() public {
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
            PoRepMarket.initialize, (adminAddress, address(validatorFactory), address(spRegistry), address(0))
        );

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidEvidenceAdapterAddress.selector));
        new ERC1967Proxy(address(impl), initData);
    }

    function testProposeDealRevertsWhenGlobalEvidenceAdapterIsZero() public {
        PoRepMarket uninitializedMarket = new PoRepMarket();

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidEvidenceAdapterAddress.selector));
        uninitializedMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));
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

    function testActivateEvidenceAllowsAdmin() public {
        bytes memory evidenceData = abi.encode("activate");

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(adminAddress);
        poRepMarket.activateEvidence(dealId, evidenceData);

        assertEq(dataCapEvidenceAdapterAddress.activatedEvidence(dealId), evidenceData);
    }

    function testActivateEvidenceAllowsPoRepServiceRole() public {
        bytes memory evidenceData = abi.encode("activate");
        address service = vm.addr(0x777);
        bytes32 serviceRole = poRepMarket.POREP_SERVICE_ROLE();

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(adminAddress);
        poRepMarket.grantRole(serviceRole, service);

        vm.prank(service);
        poRepMarket.activateEvidence(dealId, evidenceData);

        assertEq(dataCapEvidenceAdapterAddress.activatedEvidence(dealId), evidenceData);
    }

    function testActivateEvidenceRevertsWhenCallerIsNotServiceOrAdmin() public {
        address caller = vm.addr(0x999);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, poRepMarket.POREP_SERVICE_ROLE()
            )
        );
        vm.prank(caller);
        poRepMarket.activateEvidence(dealId, abi.encode("activate"));
    }

    function testRefreshEvidenceStatusAllowsAdmin() public {
        bytes memory evidenceData = abi.encode("refresh");

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(adminAddress);
        poRepMarket.refreshEvidenceStatus(dealId, evidenceData);

        assertEq(dataCapEvidenceAdapterAddress.refreshedEvidence(dealId), evidenceData);
    }

    function testRefreshEvidenceStatusAllowsPoRepServiceRole() public {
        bytes memory evidenceData = abi.encode("refresh");
        address service = vm.addr(0x777);
        bytes32 serviceRole = poRepMarket.POREP_SERVICE_ROLE();

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(adminAddress);
        poRepMarket.grantRole(serviceRole, service);

        vm.prank(service);
        poRepMarket.refreshEvidenceStatus(dealId, evidenceData);

        assertEq(dataCapEvidenceAdapterAddress.refreshedEvidence(dealId), evidenceData);
    }

    function testRefreshEvidenceStatusRevertsWhenCallerIsNotServiceOrAdmin() public {
        address caller = vm.addr(0x999);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, poRepMarket.POREP_SERVICE_ROLE()
            )
        );
        vm.prank(caller);
        poRepMarket.refreshEvidenceStatus(dealId, abi.encode("refresh"));
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

    function testTerminateDealEmitsEventAndSetsState() public {
        uint256 endEpoch = 12345;

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        setDealActive(dealId);

        vm.expectEmit(true, true, true, true);

        emit PoRepMarket.DealTerminated(dealId, endEpoch);
        vm.prank(validatorAddress);
        poRepMarket.terminateDeal(dealId, endEpoch);

        PoRepTypes.Deal memory p = poRepMarket.getDeal(dealId);
        assertTrue(p.state == DealState.TERMINATED);
    }

    function testTerminateDealReleasesCommittedCapacityWithManifestHash() public {
        uint256 allocatedSize = totalDealSize - 64;

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(adminAddress);
        poRepMarket.setDealCompletionPadding(1);

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        dataCapEvidenceAdapterAddress.setDeal(createClientDealWithAllocationSize(dealId, allocatedSize));
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.terminateDeal(dealId, validatorAddress, block.number);

        assertEq(spRegistry.lastReleasedCapacityProvider(), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(spRegistry.lastReleasedCapacityBytes(), allocatedSize);
        assertEq(spRegistry.lastReleasedCapacityManifestHash(), defaultManifestHash);
    }

    function testTerminateDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.terminateDeal(dealId, 1);
    }

    function testTerminateDealRevertsWhenDealIsNotActive() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.PROPOSED, DealState.ACTIVE
            )
        );
        vm.prank(validatorAddress);
        poRepMarket.terminateDeal(dealId, 2);
    }

    function testTerminateDealRevertsWhenValidatorNotSet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        setDealActive(dealId);

        address caller = vm.addr(0x999);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.CallerIsNotValidator.selector, dealId, caller));
        vm.prank(caller);
        poRepMarket.terminateDeal(dealId, 3);
    }

    function testTerminateDealRevertsWhenCallerIsNotValidator() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        setDealActive(dealId);

        address caller = vm.addr(0x999);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.CallerIsNotValidator.selector, dealId, caller));
        vm.prank(caller);
        poRepMarket.terminateDeal(dealId, 4);
    }

    function testGetDealsForOrganizationByStateZeroAddressOfOrganizationReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidOrganizationAddress.selector, address(0)));
        poRepMarket.getDealsForOrganizationByState(address(0), DealState.PROPOSED);
    }

    function testGetDealsForOrganizationByStateProposed() public {
        address organization1 = vm.addr(0x111);
        address organization2 = vm.addr(0x222);

        spRegistry.setProviderInfo(
            providerFilActorId,
            ISPRegistry.ProviderInfo({organization: organization1, payee: address(0), paused: false, blocked: false})
        );

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        PoRepTypes.Deal[] memory dealsOrg1 =
            poRepMarket.getDealsForOrganizationByState(organization1, DealState.PROPOSED);
        assertEq(dealsOrg1.length, 1);
        assertEq(dealsOrg1[0].dealId, dealId);

        PoRepTypes.Deal[] memory dealsOrg2 =
            poRepMarket.getDealsForOrganizationByState(organization2, DealState.PROPOSED);
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
        SLITypes.DealTerms memory badTerms =
            SLITypes.DealTerms({durationDays: 360, dealSizeBytes: 0, pricePerSectorPerMonth: 100_000});

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealSize.selector));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testProposeDealRevertsWhenPriceTimeSectorsIsBelowEpochsInMonth() public {
        SLITypes.DealTerms memory badTerms = SLITypes.DealTerms({
            durationDays: 360, dealSizeBytes: 1024, pricePerSectorPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH - 1
        });

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealPricePerSectorPerMonth.selector, 86_399, 86_400));
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, badTerms, expectedManifestLocation));
    }

    function testProposeDealSucceedsWhenLowPriceButManySectors() public {
        uint256 oneTebibyteInBytes = 1024 * 1024 * 1024 * 1024;
        uint256 pricePerSector = 62_500;

        SLITypes.DealTerms memory terms = SLITypes.DealTerms({
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

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

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

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateRailId(dealId, 1);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealNotRejectable.selector, dealId));
        vm.prank(adminAddress);
        poRepMarket.rejectAcceptedDeal(dealId);
    }

    function testSetNewDealExpirationRevertsWhenCalledByNonAdmin() public {
        address caller = vm.addr(0x999);
        bytes32 adminRole = poRepMarket.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, adminRole)
        );
        vm.prank(caller);
        poRepMarket.setNewDealExpiration(1000);
    }

    function testSetNewDealExpirationRevertsWhenZero() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealExpiration.selector));
        vm.prank(adminAddress);
        poRepMarket.setNewDealExpiration(0);
    }

    function testSetNewDealExpirationUpdatesExpiration() public {
        uint256 newExpiration = 1000;

        vm.prank(adminAddress);
        poRepMarket.setNewDealExpiration(newExpiration);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.roll(block.number + newExpiration + 1);

        vm.expectEmit(true, true, false, false);
        emit PoRepMarket.DealExpired(dealId, block.number);
        poRepMarket.rejectExpiredDeal(dealId);

        PoRepTypes.Deal memory p = poRepMarket.getDeal(dealId);
        assertTrue(p.state == DealState.EXPIRED);
    }

    function testRejectExpiredDealEmitsDealExpiredEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.roll(block.number + EPOCHS_IN_TWO_DAYS + 1);

        vm.expectEmit(true, true, false, false);
        emit PoRepMarket.DealExpired(dealId, block.number);
        poRepMarket.rejectExpiredDeal(dealId);
    }

    function testRejectExpiredDealSetsStateToExpired() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.roll(block.number + EPOCHS_IN_TWO_DAYS + 1);
        poRepMarket.rejectExpiredDeal(dealId);

        PoRepTypes.Deal memory p = poRepMarket.getDeal(dealId);
        assertTrue(p.state == DealState.EXPIRED);
    }

    function testRejectExpiredDealRevertsWhenDealNotExpiredYet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        uint256 expiresAt =
            uint256(uint64(CommonTypes.ChainEpoch.unwrap(poRepMarket.getDealTiming(dealId).expiresAtEpoch)));
        vm.roll(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealNotExpiredYet.selector, dealId, block.number, expiresAt));
        poRepMarket.rejectExpiredDeal(dealId);
    }

    function testRejectExpiredDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.rejectExpiredDeal(999);
    }

    function testRejectExpiredDealRevertsWhenDealNotProposed() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.roll(block.number + EPOCHS_IN_TWO_DAYS + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector, dealId, DealState.ACCEPTED, DealState.PROPOSED
            )
        );
        poRepMarket.rejectExpiredDeal(dealId);
    }

    function testRejectExpiredDealOnlyAffectsTargetDeal() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        vm.roll(block.number + EPOCHS_IN_TWO_DAYS + 1);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(dealRequest(defaultRequirements, defaultTerms, expectedManifestLocation));

        poRepMarket.rejectExpiredDeal(dealId);

        assertTrue(poRepMarket.getDeal(dealId).state == DealState.EXPIRED);
        assertTrue(poRepMarket.getDeal(dealId + 1).state == DealState.PROPOSED);
    }

    function testSetDealActivationPaddingEmitsEvent() public {
        uint256 newPadding = 15;

        vm.expectEmit(true, false, false, false);
        emit PoRepMarket.DealActivationPaddingUpdated(0, newPadding);
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(newPadding);
    }

    function testSetDealActivationPaddingRevertsWhenPaddingTooHigh() public {
        uint256 newPadding = 101;

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealActivationPaddingTooHigh.selector, newPadding, 100));
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
        assertEq(poRepMarket.getDealActivationPadding(), 0);

        uint256 newPadding = 15;
        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(newPadding);
        assertEq(poRepMarket.getDealActivationPadding(), newPadding);
    }

    function testEnsureAllocationSizeWithinToleranceRevertsWhenActualDealSizeIsZero() public {
        PoRepMarketContractMock market = PoRepMarketContractMock(address(poRepMarket));

        vm.expectRevert(PoRepMarket.InvalidAllocationSizeForDealActivation.selector);
        market.ensureAllocationSizeWithinTolerance(0, defaultTerms.dealSizeBytes);
    }

    function testEnsureAllocationSizeWithinToleranceAcceptsSizesInsideActivationPadding() public {
        PoRepMarketContractMock market = PoRepMarketContractMock(address(poRepMarket));
        uint256 expectedDealSize = defaultTerms.dealSizeBytes;
        uint256 padding = 10;

        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(padding);

        market.ensureAllocationSizeWithinTolerance(
            expectedDealSize - (expectedDealSize * padding) / 100, expectedDealSize
        );
        market.ensureAllocationSizeWithinTolerance(
            expectedDealSize + (expectedDealSize * padding) / 100, expectedDealSize
        );
    }

    function testEnsureAllocationSizeWithinToleranceRevertsWhenSizeIsOutsideActivationPadding() public {
        PoRepMarketContractMock market = PoRepMarketContractMock(address(poRepMarket));
        uint256 expectedDealSize = defaultTerms.dealSizeBytes;
        uint256 padding = 10;
        uint256 actualDealSize = expectedDealSize + (expectedDealSize * padding) / 100 + 1;

        vm.prank(adminAddress);
        poRepMarket.setDealActivationPadding(padding);

        vm.expectRevert(PoRepMarket.InvalidAllocationSizeForDealActivation.selector);
        market.ensureAllocationSizeWithinTolerance(actualDealSize, expectedDealSize);
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

    function testGetDealExpirationReturnsDefault() public view {
        assertEq(poRepMarket.getDealExpiration(), EPOCHS_IN_TWO_DAYS);
    }

    function testGetDealExpirationReturnsUpdatedValue() public {
        uint256 newDealExpiration = 1000;

        vm.prank(adminAddress);
        poRepMarket.setNewDealExpiration(newDealExpiration);

        assertEq(poRepMarket.getDealExpiration(), newDealExpiration);
    }

    function testSetNewDealExpirationEmitsEvent() public {
        uint256 newExpiration = 1000;

        vm.expectEmit(true, false, false, false);
        emit PoRepMarket.DealExpirationUpdated(newExpiration);

        vm.prank(adminAddress);
        poRepMarket.setNewDealExpiration(newExpiration);
    }
}

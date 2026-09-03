// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Test} from "lib/forge-std/src/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {DataCapEvidenceAdapter} from "../src/DataCapEvidenceAdapter.sol";
import {PoRepMarketViewHelper} from "../src/helpers/PoRepMarketViewHelper.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {PoRepMarketContractMock} from "./contracts/PoRepMarketContractMock.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorFactoryMock} from "./contracts/ValidatorFactoryMock.sol";
import {DataCapEvidenceAdapterMock} from "./contracts/DataCapEvidenceAdapterMock.sol";
import {SLIScorerMock} from "./contracts/SLIScorerMock.sol";
import {DealType} from "../src/types/DealType.sol";
import {DealState} from "../src/types/DealState.sol";
import {AccessManager} from "../src/AccessManager.sol";

// solhint-disable-next-line max-states-count
contract PoRepMarketViewHelperTest is Test {
    struct RequestTerms {
        uint256 dealSizeBytes;
        uint256 pricePerSectorPerMonth;
        uint32 durationDays;
    }

    PoRepMarketContractMock public poRepMarket;
    PoRepMarketViewHelper public poRepMarketViewHelper;
    SPRegistryMock public spRegistry;
    ValidatorFactoryMock public validatorFactory;
    DataCapEvidenceAdapterMock public dataCapEvidenceAdapter;
    SLIScorerMock public sliScorer;
    AccessManager public accessManager;

    address public clientAddress;
    address public providerOwnerAddress;
    address public validatorAddress;
    address public adminAddress;
    address public paymentToken;
    address public paymentPayee;
    CommonTypes.FilActorId public providerFilActorId;

    uint256 public constant MIN_PRICE_PER_SECTOR_PER_MONTH = 86_400;
    uint256 public dealId;
    uint256 public railId;
    uint256 public totalDealSize;
    uint256 public selectedOfferId;
    bytes32 public defaultManifestHash;
    string public expectedManifestLocation = "https://example.com/manifest";

    SharedTypes.SLIThresholds internal defaultRequirements;
    RequestTerms internal defaultTerms;

    // solhint-disable-next-line function-max-lines
    function setUp() public {
        PoRepMarketContractMock implementation = new PoRepMarketContractMock();
        spRegistry = new SPRegistryMock();
        validatorFactory = new ValidatorFactoryMock();
        dataCapEvidenceAdapter = new DataCapEvidenceAdapterMock();
        sliScorer = new SLIScorerMock();

        validatorAddress = vm.addr(0x001);
        clientAddress = vm.addr(0x003);
        providerOwnerAddress = vm.addr(0x004);
        adminAddress = vm.addr(0x006);
        accessManager = new AccessManager(adminAddress, adminAddress);
        paymentToken = vm.addr(0x777);
        paymentPayee = vm.addr(0x778);
        providerFilActorId = CommonTypes.FilActorId.wrap(1000);
        dealId = 1;
        railId = 1;
        totalDealSize = 103_079_215_104;
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
                address(accessManager),
                address(validatorFactory),
                address(spRegistry),
                address(dataCapEvidenceAdapter),
                address(sliScorer)
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        poRepMarket = PoRepMarketContractMock(address(proxy));
        poRepMarketViewHelper = new PoRepMarketViewHelper(address(poRepMarket));

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
        validatorFactory.setValidator(validatorAddress, true);
    }

    function testDealViewInterfaceSelectorsAreAvailable() public pure {
        assertEq(PoRepMarketViewHelper.getDealView.selector, bytes4(keccak256("getDealView(uint256)")));
        assertEq(PoRepMarketViewHelper.getDealViews.selector, bytes4(keccak256("getDealViews(uint256,uint256)")));
        assertEq(
            PoRepMarketViewHelper.getDealViewsForOrganizationByState.selector,
            // solhint-disable-next-line gas-small-strings
            bytes4(keccak256("getDealViewsForOrganizationByState(address,uint8,uint256,uint256)"))
        );
    }

    function testConstructorRevertsWhenPoRepMarketAddressIsZero() public {
        vm.expectRevert(PoRepMarketViewHelper.InvalidPoRepMarketAddress.selector);
        new PoRepMarketViewHelper(address(0));
    }

    function testGetDealViewMatchesPrimitiveGetters() public {
        spRegistry.setProviderState(
            providerFilActorId,
            SPRegistryMock.MockProviderState({
                organization: providerOwnerAddress, payee: address(0), paused: false, blocked: false
            })
        );
        _proposeDefaultDeal();

        PoRepTypes.DealView memory view_ = poRepMarketViewHelper.getDealView(dealId);
        PoRepTypes.Deal memory deal = poRepMarket.getDeal(dealId);
        SharedTypes.DealData memory data = poRepMarket.getDealData(dealId);
        SharedTypes.SLIThresholds memory slis = poRepMarket.getDealSLIs(dealId);
        PoRepTypes.DealTerms memory terms = poRepMarket.getDealTerms(dealId);
        PoRepTypes.DealService memory service = poRepMarket.getDealService(dealId);
        PoRepTypes.DealCapacity memory capacity = poRepMarket.getDealCapacity(dealId);
        PoRepTypes.DealPayment memory payment = poRepMarket.getDealPayment(dealId);

        assertEq(view_.deal.dealId, deal.dealId);
        assertEq(view_.deal.client, deal.client);
        assertEq(CommonTypes.FilActorId.unwrap(view_.deal.provider), CommonTypes.FilActorId.unwrap(deal.provider));
        assertEq(view_.deal.state, deal.state);
        assertEq(view_.data.manifestHash, data.manifestHash);
        assertEq(view_.data.manifestLocation, data.manifestLocation);
        assertEq(view_.requiredSLIs.retrievabilityBps, slis.retrievabilityBps);
        assertEq(view_.terms.requestedSizeBytes, terms.requestedSizeBytes);
        assertEq(
            CommonTypes.ChainEpoch.unwrap(view_.deal.proposedAtEpoch),
            CommonTypes.ChainEpoch.unwrap(deal.proposedAtEpoch)
        );
        assertEq(
            CommonTypes.ChainEpoch.unwrap(view_.service.serviceStartEpoch),
            CommonTypes.ChainEpoch.unwrap(service.serviceStartEpoch)
        );
        assertEq(view_.capacity.reservedBytes, capacity.reservedBytes);
        _assertDealViewPayment(view_.payment, payment);
        assertEq(view_.providerOrganization, providerOwnerAddress);
    }

    function testGetDealViewReturnsEvidenceStatus() public {
        uint256 coveredBytes = defaultTerms.dealSizeBytes;
        _proposeDefaultDeal();
        dataCapEvidenceAdapter.setDeal(_createClientDealWithAllocationSize(dealId, coveredBytes));

        PoRepTypes.DealView memory view_ = poRepMarketViewHelper.getDealView(dealId);

        assertEq(view_.evidenceStatus.activeCoveredBytes, coveredBytes);
    }

    function testGetDealViewUnknownDealReturnsZeroedView() public {
        PoRepTypes.DealView memory view_ = poRepMarketViewHelper.getDealView(999);

        assertEq(view_.deal.dealId, 0);
        assertEq(view_.deal.client, address(0));
        assertEq(view_.data.manifestHash, bytes32(0));
        assertEq(view_.data.manifestLocation, "");
        assertEq(view_.providerOrganization, address(0));
        assertEq(view_.evidenceStatus.activeCoveredBytes, 0);
    }

    function testGetDealViewsMatchesRepeatedGetDealView() public {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(clientAddress);
            poRepMarket.proposeDeal(_dealRequest(string.concat("https://example.com/view-", vm.toString(i), ".json")));
        }

        (PoRepTypes.DealView[] memory views, uint256 total) = poRepMarketViewHelper.getDealViews(1, 2);

        assertEq(total, 3);
        assertEq(views.length, 2);
        assertEq(views[0].deal.dealId, poRepMarketViewHelper.getDealView(2).deal.dealId);
        assertEq(views[1].deal.dealId, poRepMarketViewHelper.getDealView(3).deal.dealId);
        assertEq(views[0].data.manifestLocation, poRepMarketViewHelper.getDealView(2).data.manifestLocation);
        assertEq(views[1].data.manifestLocation, poRepMarketViewHelper.getDealView(3).data.manifestLocation);
    }

    function testGetDealViewsReturnsEmptyWhenOffsetPastTotal() public {
        _proposeDefaultDeal();

        (PoRepTypes.DealView[] memory views, uint256 total) = poRepMarketViewHelper.getDealViews(1, 10);

        assertEq(total, 1);
        assertEq(views.length, 0);
    }

    function testGetDealViewsForOrganizationByStateReturnsMiddleAndLastPartialPages() public {
        _proposeDealForOrganization(providerOwnerAddress);
        _proposeDealForOrganization(vm.addr(0x222));
        _proposeDealForOrganization(providerOwnerAddress);
        _proposeDealForOrganization(providerOwnerAddress);
        dataCapEvidenceAdapter.setDeal(_createClientDealWithAllocationSize(3, totalDealSize));

        (PoRepTypes.DealView[] memory views, uint256 total) =
            poRepMarketViewHelper.getDealViewsForOrganizationByState(providerOwnerAddress, DealState.ACCEPTED, 1, 1);

        assertEq(total, 3);
        assertEq(views.length, 1);
        assertEq(abi.encode(views[0]), abi.encode(poRepMarketViewHelper.getDealView(3)));
        assertEq(views[0].providerOrganization, providerOwnerAddress);
        assertEq(views[0].evidenceStatus.activeCoveredBytes, totalDealSize);

        (views, total) = poRepMarketViewHelper.getDealViewsForOrganizationByState(
            providerOwnerAddress, DealState.ACCEPTED, 2, type(uint256).max
        );

        assertEq(total, 3);
        assertEq(views.length, 1);
        assertEq(abi.encode(views[0]), abi.encode(poRepMarketViewHelper.getDealView(4)));
    }

    function testGetDealViewsForOrganizationByStateTracksStateChanges() public {
        address otherOrganization = vm.addr(0x222);
        _proposeDealForOrganization(providerOwnerAddress);
        _proposeDealForOrganization(otherOrganization);
        _proposeDealForOrganization(providerOwnerAddress);

        vm.prank(adminAddress);
        poRepMarket.rejectAcceptedDeal(1);

        (PoRepTypes.DealView[] memory views, uint256 total) = poRepMarketViewHelper.getDealViewsForOrganizationByState(
            providerOwnerAddress, DealState.ACCEPTED, 0, type(uint256).max
        );
        assertEq(total, 1);
        assertEq(views.length, 1);
        assertEq(views[0].deal.dealId, 3);
        assertEq(views[0].deal.state, DealState.ACCEPTED);

        (views, total) = poRepMarketViewHelper.getDealViewsForOrganizationByState(
            providerOwnerAddress, DealState.REJECTED, 0, type(uint256).max
        );
        assertEq(total, 1);
        assertEq(views.length, 1);
        assertEq(views[0].deal.dealId, 1);
        assertEq(views[0].deal.state, DealState.REJECTED);

        (views, total) = poRepMarketViewHelper.getDealViewsForOrganizationByState(
            otherOrganization, DealState.ACCEPTED, 0, type(uint256).max
        );
        assertEq(total, 1);
        assertEq(views.length, 1);
        assertEq(views[0].deal.dealId, 2);
        assertEq(views[0].providerOrganization, otherOrganization);
    }

    function testGetDealViewsForOrganizationByStateReturnsEmptyWhenNoMatchingDeals() public {
        (PoRepTypes.DealView[] memory views, uint256 total) =
            poRepMarketViewHelper.getDealViewsForOrganizationByState(providerOwnerAddress, DealState.ACCEPTED, 0, 10);
        assertEq(total, 0);
        assertEq(views.length, 0);

        _proposeDealForOrganization(providerOwnerAddress);

        (views, total) =
            poRepMarketViewHelper.getDealViewsForOrganizationByState(providerOwnerAddress, DealState.REJECTED, 0, 10);
        assertEq(total, 0);
        assertEq(views.length, 0);

        (views, total) =
            poRepMarketViewHelper.getDealViewsForOrganizationByState(vm.addr(0x222), DealState.ACCEPTED, 0, 10);
        assertEq(total, 0);
        assertEq(views.length, 0);
    }

    function testGetDealViewsForOrganizationByStateReturnsEmptyWhenLimitIsZero() public {
        _proposeDealForOrganization(providerOwnerAddress);

        (PoRepTypes.DealView[] memory views, uint256 total) =
            poRepMarketViewHelper.getDealViewsForOrganizationByState(providerOwnerAddress, DealState.ACCEPTED, 0, 0);

        assertEq(total, 1);
        assertEq(views.length, 0);
    }

    function testGetDealViewsForOrganizationByStateRevertsWhenOrganizationIsZero() public {
        vm.expectRevert(PoRepMarket.InvalidOrganizationAddress.selector);
        poRepMarketViewHelper.getDealViewsForOrganizationByState(address(0), DealState.ACCEPTED, 0, 10);
    }

    function _proposeDealForOrganization(address organization) internal {
        spRegistry.setProviderState(
            providerFilActorId,
            SPRegistryMock.MockProviderState({
                organization: organization, payee: address(0), paused: false, blocked: false
            })
        );
        _proposeDefaultDeal();
    }

    function _proposeDefaultDeal() internal {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(_dealRequest(expectedManifestLocation));
    }

    function _dealRequest(string memory manifestLocation) internal view returns (SharedTypes.DealRequest memory) {
        return SharedTypes.DealRequest({
            manifestHash: defaultManifestHash,
            requestedSizeBytes: defaultTerms.dealSizeBytes,
            maxPricePer32GiBPerMonth: defaultTerms.pricePerSectorPerMonth,
            manifestLocation: manifestLocation,
            paymentToken: paymentToken,
            durationDays: defaultTerms.durationDays,
            dealType: DealType.PUBLIC,
            requiredSLIs: defaultRequirements
        });
    }

    function _createClientDealWithAllocationSize(uint256 _dealId, uint256 allocationSize)
        internal
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
            allocatedBytes: allocationSize,
            allocationIds: new CommonTypes.FilActorId[](0),
            claimIds: new CommonTypes.FilActorId[](0),
            claimedBytes: 0
        });
    }

    function _assertDealViewPayment(PoRepTypes.DealPayment memory dealPayment, PoRepTypes.DealPayment memory payment)
        internal
        pure
    {
        assertEq(dealPayment.paymentToken, payment.paymentToken);
        assertEq(dealPayment.payee, payment.payee);
        assertEq(dealPayment.pricePer32GiBPerMonth, payment.pricePer32GiBPerMonth);
        assertEq(dealPayment.billed32GiBUnits, payment.billed32GiBUnits);
        assertEq(dealPayment.railMaxRatePerEpoch, payment.railMaxRatePerEpoch);
    }
}

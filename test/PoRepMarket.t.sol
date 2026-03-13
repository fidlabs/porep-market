// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.25;

import {Test} from "lib/forge-std/src/Test.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorFactoryMock} from "./contracts/ValidatorFactoryMock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SLITypes} from "../src/types/SLITypes.sol";
import {PoRepMarketContractMock} from "./contracts/PoRepMarketContractMock.sol";
import {TestUtils} from "./utils/TestUtils.sol";

// solhint-disable-next-line max-states-count
contract PoRepMarketTest is Test {
    PoRepMarket public poRepMarket;
    SPRegistryMock public spRegistry;
    ValidatorFactoryMock public validatorFactory;
    address public validatorAddress;
    address public clientSmartContractAddress;
    address public clientAddress;
    address public providerOwnerAddress;
    address public adminAddress;
    uint256 public railId;
    uint256 public dealId;

    CommonTypes.FilActorId public providerFilActorId;

    SLITypes.SLIThresholds internal defaultRequirements =
        SLITypes.SLIThresholds({retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});

    SLITypes.DealTerms internal defaultTerms =
        SLITypes.DealTerms({dealSizeBytes: 1000, pricePerSector: 100, durationDays: 365});

    string public expectedManifestLocation = "https://example.com/manifest";

    function setUp() public {
        PoRepMarket impl = new PoRepMarket();
        spRegistry = new SPRegistryMock();
        validatorFactory = new ValidatorFactoryMock();
        validatorAddress = vm.addr(0x001);
        clientSmartContractAddress = vm.addr(0x002);
        clientAddress = vm.addr(0x003);
        providerOwnerAddress = vm.addr(0x004);
        adminAddress = vm.addr(0x006);
        dealId = 1;
        railId = 1;

        providerFilActorId = CommonTypes.FilActorId.wrap(1000);

        bytes memory initData =
            abi.encodeCall(PoRepMarket.initialize, (adminAddress, address(validatorFactory), address(spRegistry)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        poRepMarket = PoRepMarket(address(proxy));
        vm.prank(adminAddress);
        poRepMarket.setClientSmartContract(clientSmartContractAddress);

        spRegistry.setNextProvider(providerFilActorId);
        spRegistry.setIsOwner(providerOwnerAddress, providerFilActorId, true);
        validatorFactory.setValidator(validatorAddress, true);
    }

    function createDealProposal(uint256 proposalDealId, PoRepMarket.DealState state)
        public
        view
        returns (PoRepMarket.DealProposal memory)
    {
        return PoRepMarket.DealProposal({
            dealId: proposalDealId,
            client: clientAddress,
            provider: providerFilActorId,
            requirements: defaultRequirements,
            terms: defaultTerms,
            validator: validatorAddress,
            state: state,
            railId: railId,
            manifestLocation: expectedManifestLocation
        });
    }

    function testProposeDealEmitsEvent() public {
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealProposalCreated(
            dealId, clientAddress, providerFilActorId, defaultRequirements, expectedManifestLocation
        );

        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
    }

    function testProposeDealSetsDealProposal() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        PoRepMarket.DealProposal memory p = poRepMarket.getDealProposal(1);
        assertEq(p.dealId, 1);
        assertEq(p.client, clientAddress);
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(p.requirements.retrievabilityBps, defaultRequirements.retrievabilityBps);
        assertEq(p.requirements.bandwidthMbps, defaultRequirements.bandwidthMbps);
        assertEq(p.requirements.latencyMs, defaultRequirements.latencyMs);
        assertEq(p.requirements.indexingPct, defaultRequirements.indexingPct);
        assertEq(p.manifestLocation, expectedManifestLocation);
        assertEq(p.terms.dealSizeBytes, defaultTerms.dealSizeBytes);
        assertEq(p.terms.pricePerSector, defaultTerms.pricePerSector);
        assertEq(p.terms.durationDays, defaultTerms.durationDays);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertTrue(p.state == PoRepMarket.DealState.Proposed);

        p = poRepMarket.getDealProposal(0);
        assertEq(p.dealId, 0);
        assertEq(p.client, address(0));
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), 0);
        assertEq(p.requirements.retrievabilityBps, 0);
        assertEq(p.requirements.bandwidthMbps, 0);
        assertEq(p.requirements.latencyMs, 0);
        assertEq(p.requirements.indexingPct, 0);
        assertEq(p.terms.dealSizeBytes, 0);
        assertEq(p.terms.pricePerSector, 0);
        assertEq(p.terms.durationDays, 0);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertEq(uint8(p.state), 0);
    }

    function testShouldIncrementDealIdCounter() public {
        uint8 proposalsCount = 3;
        uint8 startingId = 1;
        PoRepMarket.DealProposal memory p;

        // solhint-disable-next-line gas-strict-inequalities
        for (uint8 i = startingId; i <= proposalsCount; i++) {
            vm.prank(vm.addr(i));
            poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

            p = poRepMarket.getDealProposal(i);
            assertEq(p.dealId, i);
            assertEq(p.client, vm.addr(i));
        }

        p = poRepMarket.getDealProposal(proposalsCount + 1);
        assertEq(p.dealId, 0);
        assertEq(p.dealId, 0);
        assertEq(p.client, address(0));
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), 0);
        assertEq(p.requirements.retrievabilityBps, 0);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertEq(uint8(p.state), 0);
    }

    function testProposeDealRevertsWhenNoProviderFoundForDeal() public {
        spRegistry.setNextProvider(CommonTypes.FilActorId.wrap(0));

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NoProviderFoundForDeal.selector));
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
    }

    function testUpdateValidatorEmitsValidatorUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ValidatorUpdated(dealId, validatorAddress);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateValidatorRevertsIfValidatorIsAlreadySet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheRegisteredValidator.selector, dealId, notTheValidator));
        vm.prank(notTheValidator);
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateRailIdEmitsRailIdUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepMarket.DealState.Proposed,
                PoRepMarket.DealState.Accepted
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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(dealId, providerOwnerAddress, providerFilActorId);

        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenNotTheControllingAddress() public {
        address notOwnerAddress = vm.addr(3);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        vm.prank(providerOwnerAddress);
        poRepMarket.rejectDeal(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepMarket.DealState.Rejected,
                PoRepMarket.DealState.Proposed
            )
        );
        vm.prank(clientAddress);
        poRepMarket.acceptDeal(dealId);
    }

    function testCompleteDealEmitsDealCompletedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(clientSmartContractAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCompleted(dealId, clientSmartContractAddress, providerFilActorId);

        poRepMarket.completeDeal(dealId);
    }

    function testShouldAddDealIdToCompletedDealsIdsSet() public {
        PoRepMarketContractMock impl = new PoRepMarketContractMock();
        // solhint-disable-next-line gas-small-strings
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address)", adminAddress, address(validatorFactory), address(spRegistry)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        PoRepMarketContractMock porepMarekMock = PoRepMarketContractMock(address(proxy));
        vm.prank(adminAddress);
        porepMarekMock.setClientSmartContract(clientSmartContractAddress);
        vm.prank(clientAddress);
        porepMarekMock.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        vm.prank(providerOwnerAddress);
        porepMarekMock.acceptDeal(dealId);

        vm.prank(clientSmartContractAddress);
        porepMarekMock.completeDeal(dealId);

        uint256[] memory completedDealsIds = porepMarekMock.getCompletedDealsIds();
        assertEq(completedDealsIds.length, 1);
        assertEq(completedDealsIds[0], dealId);
    }

    function testCompleteDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenNotTheSPClient() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        address notTheClientSmartContract = vm.addr(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(PoRepMarket.NotTheClientSmartContract.selector, dealId, notTheClientSmartContract)
        );
        vm.prank(notTheClientSmartContract);
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenDealNotAcceptedByStorageProvider() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepMarket.DealState.Proposed,
                PoRepMarket.DealState.Accepted
            )
        );
        vm.prank(clientSmartContractAddress);
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenDealAlreadyCompleted() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(clientSmartContractAddress);
        poRepMarket.completeDeal(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepMarket.DealState.Completed,
                PoRepMarket.DealState.Accepted
            )
        );
        vm.prank(clientSmartContractAddress);
        poRepMarket.completeDeal(dealId);
    }

    function testRejectAsClientDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, clientAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectAsStorageProviderOwnerDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, providerOwnerAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectDealRevertsWhenNotTheClientOrStorageProviderOwner() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        address notTheClientOrStorageProviderOwner = vm.addr(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.NotTheClientOrStorageProvider.selector, dealId, notTheClientOrStorageProviderOwner
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
        SLITypes.SLIThresholds memory badRequirements =
            SLITypes.SLIThresholds({retrievabilityBps: 10001, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidRetrievabilityBps.selector, uint16(10001)));
        poRepMarket.proposeDeal(badRequirements, defaultTerms, expectedManifestLocation);
    }

    function testProposeDealRevertsWhenIndexingPctExceeds100() public {
        SLITypes.SLIThresholds memory badRequirements =
            SLITypes.SLIThresholds({retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 101});
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidIndexingPct.selector, uint8(101)));
        poRepMarket.proposeDeal(badRequirements, defaultTerms, expectedManifestLocation);
    }

    function testProposeDealAutoApproveSetsDealToAccepted() public {
        spRegistry.setNextAutoApprove(true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        PoRepMarket.DealProposal memory p = poRepMarket.getDealProposal(dealId);
        assertTrue(p.state == PoRepMarket.DealState.Accepted);
    }

    function testProposeDealAutoApproveEmitsBothEvents() public {
        spRegistry.setNextAutoApprove(true);

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealProposalCreated(
            dealId, clientAddress, providerFilActorId, defaultRequirements, expectedManifestLocation
        );
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(dealId, clientAddress, providerFilActorId);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
    }

    function testProposeDealNoAutoApproveKeepsProposed() public {
        spRegistry.setNextAutoApprove(false);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        PoRepMarket.DealProposal memory p = poRepMarket.getDealProposal(dealId);
        assertTrue(p.state == PoRepMarket.DealState.Proposed);
    }

    function testGetCompletedDeals() public {
        PoRepMarketContractMock porepMarekMock = new PoRepMarketContractMock();
        uint256[] memory ids = new uint256[](5);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        ids[3] = 4;
        ids[4] = 5;
        porepMarekMock.setDealProposal(createDealProposal(ids[0], PoRepMarket.DealState.Completed));
        porepMarekMock.setDealProposal(createDealProposal(ids[1], PoRepMarket.DealState.Accepted));
        porepMarekMock.setDealProposal(createDealProposal(ids[2], PoRepMarket.DealState.Proposed));
        porepMarekMock.setDealProposal(createDealProposal(ids[3], PoRepMarket.DealState.Completed));
        porepMarekMock.setDealProposal(createDealProposal(ids[4], PoRepMarket.DealState.Rejected));
        porepMarekMock.setDealIdsReadyForPayment(ids);

        PoRepMarket.DealProposal[] memory dealProposal = porepMarekMock.getCompletedDeals();
        assertEq(dealProposal.length, 2);
        assertEq(dealProposal[0].dealId, ids[0]);
        assertTrue(dealProposal[0].state == PoRepMarket.DealState.Completed);
        assertEq(dealProposal[1].dealId, ids[3]);
        assertTrue(dealProposal[1].state == PoRepMarket.DealState.Completed);
    }

    function testProposeDealRevertsEmptyManifestLocation() public {
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.EmptyManifestLocation.selector, ""));
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, "");
    }

    function testUpdateManifestLocationRevertsEmptyManifestLocation() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.EmptyManifestLocation.selector, ""));
        poRepMarket.updateManifestLocation(dealId, "");
    }

    function testUpdateManifestLocationRevertsUnauthorisedCaller() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        address unauthorisedCaller = vm.addr(0x007);
        vm.prank(unauthorisedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(PoRepMarket.UnauthorisedCaller.selector, dealId, unauthorisedCaller, clientAddress)
        );
        poRepMarket.updateManifestLocation(dealId, expectedManifestLocation);
    }

    function testManifestLocationIsSetCorrectly() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        string memory manifestLocation = poRepMarket.getManifestLocation(dealId);
        assertEq(manifestLocation, expectedManifestLocation);
    }

    function testManifestLocationIsUpdateCorrectly() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        string memory manifestLocation = poRepMarket.getManifestLocation(dealId);
        assertEq(manifestLocation, expectedManifestLocation);
        string memory updatedManifestLocation = "updatedManifestLocation";
        vm.prank(clientAddress);
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
        manifestLocation = poRepMarket.getManifestLocation(dealId);
        assertEq(manifestLocation, updatedManifestLocation);
    }

    function testManifestLocationUpdateEmitEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        string memory updatedManifestLocation = "updatedManifestLocation";
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ManifestLocationUpdated(dealId, expectedManifestLocation, updatedManifestLocation);
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
    }

    function testManifestLocationUpdateRevertsTooLongManifestLocation() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, expectedManifestLocation);
        string memory updatedManifestLocation = TestUtils.generateLongString(2049);
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.TooLongManifestLocation.selector, updatedManifestLocation));
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
    }

    function testProposeDealRevertsTooLongManifestLocation() public {
        string memory tooLongManifestLocation = TestUtils.generateLongString(2049);
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.TooLongManifestLocation.selector, tooLongManifestLocation));
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms, tooLongManifestLocation);
    }

    function testSetClientSmartContractRevertsWhenAddressIsZero() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidClientSmartContractAddress.selector));
        poRepMarket.setClientSmartContract(address(0));
    }
}

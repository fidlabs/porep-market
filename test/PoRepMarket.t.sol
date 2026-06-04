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
import {SLITypes} from "../src/types/SLITypes.sol";
import {ISPRegistry} from "../src/interfaces/ISPRegistry.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {PoRepMarketContractMock} from "./contracts/PoRepMarketContractMock.sol";
import {TestUtils} from "./utils/TestUtils.sol";
import {ClientSCMock} from "./contracts/ClientSCMock.sol";
import {ValidatorMock} from "./contracts/ValidatorMock.sol";
import {Client} from "../src/Client.sol";

// solhint-disable-next-line max-states-count
contract PoRepMarketTest is Test {
    PoRepMarket public poRepMarket;
    SPRegistryMock public spRegistry;
    ValidatorFactoryMock public validatorFactory;
    ValidatorMock public validatorMock;
    address public validatorAddress;
    ClientSCMock public clientSmartContractAddress;
    address public clientAddress;
    address public providerOwnerAddress;
    address public operatorAddress;
    address public adminAddress;
    uint256 public railId;
    uint256 public dealId;
    uint256 public totalDealSize;
    SLITypes.SLIThresholds internal defaultRequirements;
    SLITypes.DealTerms internal defaultTerms;

    uint256 public constant MIN_PRICE_PER_SECTOR_PER_MONTH = 86_400;
    uint256 public constant EPOCHS_IN_TWO_DAYS = 5_760;

    CommonTypes.FilActorId public providerFilActorId;
    string public expectedManifestLocation = "https://example.com/manifest";
    bytes32 public expectedManifestHash = keccak256("test-manifest");

    function setUp() public {
        PoRepMarket impl = new PoRepMarket();
        spRegistry = new SPRegistryMock();
        validatorFactory = new ValidatorFactoryMock();
        validatorMock = new ValidatorMock();
        validatorAddress = address(validatorMock);
        clientSmartContractAddress = new ClientSCMock();
        clientAddress = vm.addr(0x003);
        providerOwnerAddress = vm.addr(0x004);
        operatorAddress = vm.addr(0x005);
        adminAddress = vm.addr(0x006);
        dealId = 1;
        railId = 1;
        totalDealSize = 103_079_215_104; // 96 GiB

        providerFilActorId = CommonTypes.FilActorId.wrap(1000);

        defaultRequirements =
            SLITypes.SLIThresholds({retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});
        defaultTerms = SLITypes.DealTerms({
            dealSizeBytes: totalDealSize, pricePerSectorPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH, durationDays: 360
        });

        bytes memory initData =
            abi.encodeCall(PoRepMarket.initialize, (adminAddress, address(validatorFactory), address(spRegistry)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        poRepMarket = PoRepMarket(address(proxy));
        vm.prank(adminAddress);
        poRepMarket.setClientSmartContract(address(clientSmartContractAddress));

        spRegistry.setNextProvider(providerFilActorId);
        spRegistry.setIsOwner(providerOwnerAddress, providerFilActorId, true);
        spRegistry.setIsOwner(operatorAddress, providerFilActorId, true);
        validatorFactory.setValidator(validatorAddress, true);
    }

    function createDealProposal(uint256 proposalDealId, PoRepTypes.DealState state)
        public
        view
        returns (PoRepTypes.DealProposal memory)
    {
        return PoRepTypes.DealProposal({
            dealId: proposalDealId,
            client: clientAddress,
            provider: providerFilActorId,
            requirements: defaultRequirements,
            terms: defaultTerms,
            validator: validatorAddress,
            railId: railId,
            state: state,
            proposedAtBlock: block.number,
            manifestLocation: expectedManifestLocation,
            manifestHash: expectedManifestHash
        });
    }

    function createClientDealWithAllocationSize(uint256 _dealId, uint256 _allocationSize)
        public
        view
        returns (Client.Deal memory)
    {
        return Client.Deal({
            completed: false,
            client: clientAddress,
            validator: validatorAddress,
            provider: providerFilActorId,
            dealId: _dealId,
            railId: railId,
            sizeOfAllocations: _allocationSize,
            allocationIds: new CommonTypes.FilActorId[](0)
        });
    }

    function testProposeDealEmitsEvent() public {
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealProposalCreated(
            dealId,
            clientAddress,
            providerFilActorId,
            defaultRequirements,
            expectedManifestLocation,
            expectedManifestHash,
            totalDealSize,
            block.number
        );

        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testProposeDealSetsDealProposal() public {
        vm.roll(100);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        PoRepTypes.DealProposal memory p = poRepMarket.getDealProposal(1);
        assertEq(p.dealId, 1);
        assertEq(p.client, clientAddress);
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(p.requirements.retrievabilityBps, defaultRequirements.retrievabilityBps);
        assertEq(p.requirements.bandwidthMbps, defaultRequirements.bandwidthMbps);
        assertEq(p.requirements.latencyMs, defaultRequirements.latencyMs);
        assertEq(p.requirements.indexingPct, defaultRequirements.indexingPct);
        assertEq(p.manifestLocation, expectedManifestLocation);
        assertEq(p.terms.dealSizeBytes, defaultTerms.dealSizeBytes);
        assertEq(p.terms.pricePerSectorPerMonth, defaultTerms.pricePerSectorPerMonth);
        assertEq(p.terms.durationDays, defaultTerms.durationDays);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertEq(p.proposedAtBlock, 100);
        assertTrue(p.state == PoRepTypes.DealState.Proposed);

        p = poRepMarket.getDealProposal(0);
        assertEq(p.dealId, 0);
        assertEq(p.client, address(0));
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), 0);
        assertEq(p.requirements.retrievabilityBps, 0);
        assertEq(p.requirements.bandwidthMbps, 0);
        assertEq(p.requirements.latencyMs, 0);
        assertEq(p.requirements.indexingPct, 0);
        assertEq(p.terms.dealSizeBytes, 0);
        assertEq(p.terms.pricePerSectorPerMonth, 0);
        assertEq(p.terms.durationDays, 0);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertEq(p.proposedAtBlock, 0);
        assertEq(uint8(p.state), 0);
    }

    function testShouldIncrementDealIdCounter() public {
        uint8 proposalsCount = 3;
        uint8 startingId = 1;
        PoRepTypes.DealProposal memory p;

        // solhint-disable-next-line gas-strict-inequalities
        for (uint8 i = startingId; i <= proposalsCount; i++) {
            vm.prank(vm.addr(i));
            poRepMarket.proposeDeal(
                defaultRequirements,
                defaultTerms,
                PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
            );

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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testUpdateValidatorEmitsValidatorUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ValidatorUpdated(dealId, validatorAddress);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateValidatorRevertsIfValidatorIsAlreadySet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheRegisteredValidator.selector, dealId, notTheValidator));
        vm.prank(notTheValidator);
        poRepMarket.updateValidator(dealId);
    }

    function testUpdateRailIdEmitsRailIdUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepTypes.DealState.Proposed,
                PoRepTypes.DealState.Accepted
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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(dealId, providerOwnerAddress, providerFilActorId);

        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealAllowsOperatorAuthorisedForProvider() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.prank(operatorAddress);
        poRepMarket.acceptDeal(dealId);

        PoRepTypes.DealProposal memory p = poRepMarket.getDealProposal(dealId);
        assertTrue(p.state == PoRepTypes.DealState.Accepted);
    }

    function testAcceptDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenNotTheControllingAddress() public {
        address notOwnerAddress = vm.addr(3);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.rejectDeal(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepTypes.DealState.Rejected,
                PoRepTypes.DealState.Proposed
            )
        );
        vm.prank(clientAddress);
        poRepMarket.acceptDeal(dealId);
    }

    function testCompleteDealEmitsDealCompletedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCompleted(dealId, clientAddress, defaultTerms.dealSizeBytes, providerFilActorId);

        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealEmitsDealCompletedEventWhenAtBottomPaddingValue() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealCompletionPadding(10);
        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        uint256 dealAllocationSizeAtTheBottomLimit =
            defaultTerms.dealSizeBytes - (defaultTerms.dealSizeBytes * 10) / 100;

        clientSmartContractAddress.setDeal(
            createClientDealWithAllocationSize(dealId, dealAllocationSizeAtTheBottomLimit)
        );
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCompleted(dealId, clientAddress, dealAllocationSizeAtTheBottomLimit, providerFilActorId);

        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealEmitsDealCompletedEventWhenAtTopPaddingValue() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealCompletionPadding(10);
        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        uint256 dealAllocationSizeAtTheUpperLimit = (defaultTerms.dealSizeBytes * 110) / 100;

        clientSmartContractAddress.setDeal(
            createClientDealWithAllocationSize(dealId, dealAllocationSizeAtTheUpperLimit)
        );
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCompleted(dealId, clientAddress, dealAllocationSizeAtTheUpperLimit, providerFilActorId);

        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenAllocationIsZeroAtMaxPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealCompletionPadding(100);
        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, 0));
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidAllocationSizeForDealCompletion.selector));
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenAllocationIsUnderTheCustomPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealCompletionPadding(10);
        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        uint256 dealAllocationSizeAtTheBottomLimit =
            defaultTerms.dealSizeBytes - (defaultTerms.dealSizeBytes * 10) / 100 - 1;

        clientSmartContractAddress.setDeal(
            createClientDealWithAllocationSize(dealId, dealAllocationSizeAtTheBottomLimit)
        );
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidAllocationSizeForDealCompletion.selector));
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenAllocationIsOverTheCustomPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(adminAddress);
        poRepMarket.setDealCompletionPadding(10);
        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        uint256 dealAllocationSizeAtTheUpperLimit = (defaultTerms.dealSizeBytes * 110) / 100 + 1;

        clientSmartContractAddress.setDeal(
            createClientDealWithAllocationSize(dealId, dealAllocationSizeAtTheUpperLimit)
        );
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidAllocationSizeForDealCompletion.selector));
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
        porepMarekMock.setClientSmartContract(address(clientSmartContractAddress));
        vm.prank(clientAddress);
        porepMarekMock.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        porepMarekMock.acceptDeal(dealId);
        vm.startPrank(validatorAddress);
        porepMarekMock.updateValidator(dealId);
        porepMarekMock.updateRailId(dealId, railId);
        vm.stopPrank();

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        vm.prank(clientAddress);
        porepMarekMock.completeDeal(dealId);

        uint256[] memory completedDealsIds = porepMarekMock.getCompletedDealsIds();
        assertEq(completedDealsIds.length, 1);
        assertEq(completedDealsIds[0], dealId);
    }

    function testCompleteDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenAllocationIsUnderTheDefaultPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes - 1));
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidAllocationSizeForDealCompletion.selector));
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenAllocationIsOverTheDefaultPadding() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes + 1));
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidAllocationSizeForDealCompletion.selector));
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenNotTheSPClient() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        address notTheClientAddress = vm.addr(0x999);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheClientAddress.selector));
        vm.prank(notTheClientAddress);
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenValidatorNotSet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.ValidatorNotSet.selector));
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenRailIdIsNotSet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidRailId.selector));
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenClientHasInsufficientFunds() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        validatorMock.setInsufficientFunds(300, 100);

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        vm.expectRevert(abi.encodeWithSelector(ValidatorMock.InsufficientFundsForRail.selector, 300, 100));
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenDealNotAcceptedByStorageProvider() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepTypes.DealState.Proposed,
                PoRepTypes.DealState.Accepted
            )
        );
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenDealAlreadyCompleted() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepTypes.DealState.Completed,
                PoRepTypes.DealState.Accepted
            )
        );
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);
    }

    function testRejectAsClientDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, clientAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectAsStorageProviderOwnerDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, providerOwnerAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectAsOperatorAuthorisedForProviderEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

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
        SLITypes.SLIThresholds memory badRequirements =
            SLITypes.SLIThresholds({retrievabilityBps: 10001, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidRetrievabilityBps.selector, uint16(10001)));
        poRepMarket.proposeDeal(
            badRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testProposeDealRevertsWhenIndexingPctExceeds100() public {
        SLITypes.SLIThresholds memory badRequirements =
            SLITypes.SLIThresholds({retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 101});
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidIndexingPct.selector, uint8(101)));
        poRepMarket.proposeDeal(
            badRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testProposeDealAutoApproveSetsDealToAccepted() public {
        spRegistry.setNextAutoApprove(true);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        PoRepTypes.DealProposal memory p = poRepMarket.getDealProposal(dealId);
        assertTrue(p.state == PoRepTypes.DealState.Accepted);
    }

    function testProposeDealAutoApproveEmitsBothEvents() public {
        spRegistry.setNextAutoApprove(true);

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealProposalCreated(
            dealId,
            clientAddress,
            providerFilActorId,
            defaultRequirements,
            expectedManifestLocation,
            expectedManifestHash,
            totalDealSize,
            block.number
        );
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(dealId, clientAddress, providerFilActorId);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testProposeDealNoAutoApproveKeepsProposed() public {
        spRegistry.setNextAutoApprove(false);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        PoRepTypes.DealProposal memory p = poRepMarket.getDealProposal(dealId);
        assertTrue(p.state == PoRepTypes.DealState.Proposed);
    }

    function testGetCompletedDeals() public {
        PoRepMarketContractMock porepMarekMock = new PoRepMarketContractMock();
        uint256[] memory ids = new uint256[](5);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        ids[3] = 4;
        ids[4] = 5;
        porepMarekMock.setDealProposal(createDealProposal(ids[0], PoRepTypes.DealState.Completed));
        porepMarekMock.setDealProposal(createDealProposal(ids[1], PoRepTypes.DealState.Accepted));
        porepMarekMock.setDealProposal(createDealProposal(ids[2], PoRepTypes.DealState.Proposed));
        porepMarekMock.setDealProposal(createDealProposal(ids[3], PoRepTypes.DealState.Completed));
        porepMarekMock.setDealProposal(createDealProposal(ids[4], PoRepTypes.DealState.Rejected));
        porepMarekMock.setDealIdsReadyForPayment(ids);

        PoRepTypes.DealProposal[] memory dealProposal = porepMarekMock.getCompletedDeals();
        assertEq(dealProposal.length, 2);
        assertEq(dealProposal[0].dealId, ids[0]);
        assertTrue(dealProposal[0].state == PoRepTypes.DealState.Completed);
        assertEq(dealProposal[1].dealId, ids[3]);
        assertTrue(dealProposal[1].state == PoRepTypes.DealState.Completed);
    }

    function testProposeDealRevertsEmptyManifestLocation() public {
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.EmptyManifestLocation.selector, ""));
        poRepMarket.proposeDeal(
            defaultRequirements, defaultTerms, PoRepTypes.ManifestStruct({location: "", hash: expectedManifestHash})
        );
    }

    function testUpdateManifestLocationRevertsEmptyManifestLocation() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

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
        poRepMarket.proposeDeal(
            defaultRequirements,
            badTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testProposeDealRevertsWhenDealDurationIsNotMultiplicatioveOf30() public {
        SLITypes.DealTerms memory badTerms = SLITypes.DealTerms({
            durationDays: poRepMarket.MIN_DEAL_DURATION_DAYS() + 1, dealSizeBytes: 1024, pricePerSectorPerMonth: 100
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealDuration.selector));
        poRepMarket.proposeDeal(
            defaultRequirements,
            badTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testProposeDealRevertsWhenDealDurationExceedsMaximum() public {
        SLITypes.DealTerms memory badTerms = SLITypes.DealTerms({
            durationDays: poRepMarket.MAX_DEAL_DURATION_DAYS() + 12, dealSizeBytes: 1024, pricePerSectorPerMonth: 100
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealDuration.selector));
        poRepMarket.proposeDeal(
            defaultRequirements,
            badTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testManifestLocationIsSetCorrectly() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        string memory manifestLocation = poRepMarket.getManifestLocation(dealId);
        assertEq(manifestLocation, expectedManifestLocation);
    }

    function testManifestLocationIsUpdateCorrectly() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
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
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        string memory updatedManifestLocation = "updatedManifestLocation";
        vm.prank(adminAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ManifestLocationUpdated(dealId, expectedManifestLocation, updatedManifestLocation);
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
    }

    function testManifestLocationUpdateRevertsTooLongManifestLocation() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
        string memory updatedManifestLocation = TestUtils.generateLongString(2049);
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.TooLongManifestLocation.selector, updatedManifestLocation));
        poRepMarket.updateManifestLocation(dealId, updatedManifestLocation);
    }

    function testProposeDealRevertsTooLongManifestLocation() public {
        string memory tooLongManifestLocation = TestUtils.generateLongString(2049);
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.TooLongManifestLocation.selector, tooLongManifestLocation));
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: tooLongManifestLocation, hash: expectedManifestHash})
        );
    }

    function testSetClientSmartContractRevertsWhenAddressIsZero() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidClientSmartContractAddress.selector));
        poRepMarket.setClientSmartContract(address(0));
    }

    function testTerminateDealEmitsEventAndSetsState() public {
        address terminator = vm.addr(0x777);
        uint256 endEpoch = 12345;

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);

        vm.expectEmit(true, true, true, true);

        emit PoRepMarket.DealTerminated(dealId, terminator, endEpoch);
        vm.prank(validatorAddress);
        poRepMarket.terminateDeal(dealId, terminator, endEpoch);

        PoRepTypes.DealProposal memory p = poRepMarket.getDealProposal(dealId);
        assertTrue(p.state == PoRepTypes.DealState.Terminated);
    }

    function testTerminateDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.terminateDeal(dealId, vm.addr(0x1), 1);
    }

    function testTerminateDealRevertsWhenDealNotAccepted() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepTypes.DealState.Proposed,
                PoRepTypes.DealState.Completed
            )
        );
        vm.prank(validatorAddress);
        poRepMarket.terminateDeal(dealId, vm.addr(0x2), 2);
    }

    function testTerminateDealRevertsWhenValidatorNotSet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);

        address caller = vm.addr(0x999);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.CallerIsNotValidator.selector, dealId, caller));
        vm.prank(caller);
        poRepMarket.terminateDeal(dealId, vm.addr(0x3), 3);
    }

    function testTerminateDealRevertsWhenCallerIsNotValidator() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.startPrank(validatorAddress);
        poRepMarket.updateValidator(dealId);
        poRepMarket.updateRailId(dealId, railId);
        vm.stopPrank();

        clientSmartContractAddress.setDeal(createClientDealWithAllocationSize(dealId, defaultTerms.dealSizeBytes));
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);

        address caller = vm.addr(0x999);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.CallerIsNotValidator.selector, dealId, caller));
        vm.prank(caller);
        poRepMarket.terminateDeal(dealId, vm.addr(0x4), 4);
    }

    function testGetDealsForOrganizationByStateZeroAddressOfOrganizationReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidOrganizationAddress.selector, address(0)));
        poRepMarket.getDealsForOrganizationByState(address(0), PoRepTypes.DealState.Proposed);
    }

    function testGetDealsForOrganizationByStateProposed() public {
        address organization1 = vm.addr(0x111);
        address organization2 = vm.addr(0x222);

        spRegistry.setProviderInfo(
            providerFilActorId,
            ISPRegistry.ProviderInfo({
                organization: organization1,
                payee: address(0),
                paused: false,
                blocked: false,
                capabilities: defaultRequirements,
                availableBytes: 0,
                committedBytes: 0,
                pendingBytes: 0,
                pricePerSectorPerMonth: 0,
                minDealDurationDays: 0,
                maxDealDurationDays: 0
            })
        );

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        PoRepTypes.DealProposal[] memory dealsOrg1 =
            poRepMarket.getDealsForOrganizationByState(organization1, PoRepTypes.DealState.Proposed);
        assertEq(dealsOrg1.length, 1);
        assertEq(dealsOrg1[0].dealId, dealId);

        PoRepTypes.DealProposal[] memory dealsOrg2 =
            poRepMarket.getDealsForOrganizationByState(organization2, PoRepTypes.DealState.Proposed);
        assertEq(dealsOrg2.length, 0);
    }

    function testGetDealsReturnsEmptyArrayWhenNoDeals() public view {
        PoRepTypes.DealProposal[] memory deals = poRepMarket.getDeals();
        assertEq(deals.length, 0);
    }

    function testGetDealsReturnsAllDeals() public {
        uint256 count = 3;
        for (uint256 i = 1; i < count + 1; i++) {
            vm.prank(vm.addr(i));
            poRepMarket.proposeDeal(
                defaultRequirements,
                defaultTerms,
                PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
            );
        }

        PoRepTypes.DealProposal[] memory deals = poRepMarket.getDeals();
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
        poRepMarket.proposeDeal(
            defaultRequirements,
            badTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testProposeDealRevertsWhenPriceTimeSectorsIsBelowEpochsInMonth() public {
        SLITypes.DealTerms memory badTerms = SLITypes.DealTerms({
            durationDays: 360, dealSizeBytes: 1024, pricePerSectorPerMonth: MIN_PRICE_PER_SECTOR_PER_MONTH - 1
        });

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealPricePerSectorPerMonth.selector, 86_399, 86_400));
        poRepMarket.proposeDeal(
            defaultRequirements,
            badTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testProposeDealSucceedsWhenLowPriceButManySectors() public {
        uint256 oneTebibyteInBytes = 1024 * 1024 * 1024 * 1024;
        uint256 pricePerSector = 62_500;

        SLITypes.DealTerms memory terms = SLITypes.DealTerms({
            durationDays: 360, dealSizeBytes: oneTebibyteInBytes, pricePerSectorPerMonth: pricePerSector
        });

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            terms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
    }

    function testRejectAcceptedDealByAdmin() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidator(dealId);

        vm.expectEmit(true, false, false, false);
        emit PoRepMarket.DealRejected(dealId, adminAddress);
        vm.prank(adminAddress);
        poRepMarket.rejectAcceptedDeal(dealId);

        PoRepTypes.DealProposal memory dealProposal = poRepMarket.getDealProposal(dealId);
        assertTrue(dealProposal.state == PoRepTypes.DealState.Rejected);
    }

    function testRejectAcceptedDealRevertsWhenRailIdIsSet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

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

    function testSetNewDealProposalExpirationRevertsWhenCalledByNonAdmin() public {
        address caller = vm.addr(0x999);
        bytes32 adminRole = poRepMarket.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, adminRole)
        );
        vm.prank(caller);
        poRepMarket.setNewDealProposalExpiration(1000);
    }

    function testSetNewDealProposalExpirationRevertsWhenZero() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidDealProposalExpiration.selector));
        vm.prank(adminAddress);
        poRepMarket.setNewDealProposalExpiration(0);
    }

    function testSetNewDealProposalExpirationUpdatesExpiration() public {
        uint256 newExpiration = 1000;

        vm.prank(adminAddress);
        poRepMarket.setNewDealProposalExpiration(newExpiration);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.roll(block.number + newExpiration + 1);

        vm.expectEmit(true, true, false, false);
        emit PoRepMarket.DealProposalExpired(dealId, block.number);
        poRepMarket.rejectExpiredDeal(dealId);

        PoRepTypes.DealProposal memory p = poRepMarket.getDealProposal(dealId);
        assertTrue(p.state == PoRepTypes.DealState.Rejected);
    }

    function testRejectExpiredDealEmitsDealProposalExpiredEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.roll(block.number + EPOCHS_IN_TWO_DAYS + 1);

        vm.expectEmit(true, true, false, false);
        emit PoRepMarket.DealProposalExpired(dealId, block.number);
        poRepMarket.rejectExpiredDeal(dealId);
    }

    function testRejectExpiredDealSetsStateToRejected() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.roll(block.number + EPOCHS_IN_TWO_DAYS + 1);
        poRepMarket.rejectExpiredDeal(dealId);

        PoRepTypes.DealProposal memory p = poRepMarket.getDealProposal(dealId);
        assertTrue(p.state == PoRepTypes.DealState.Rejected);
    }

    function testRejectExpiredDealRevertsWhenDealNotExpiredYet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        uint256 proposedAt = block.number;
        vm.roll(block.number + EPOCHS_IN_TWO_DAYS);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotExpiredYet.selector, dealId, block.number, proposedAt + EPOCHS_IN_TWO_DAYS
            )
        );
        poRepMarket.rejectExpiredDeal(dealId);
    }

    function testRejectExpiredDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.rejectExpiredDeal(999);
    }

    function testRejectExpiredDealRevertsWhenDealNotProposed() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.roll(block.number + EPOCHS_IN_TWO_DAYS + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepTypes.DealState.Accepted,
                PoRepTypes.DealState.Proposed
            )
        );
        poRepMarket.rejectExpiredDeal(dealId);
    }

    function testRejectExpiredDealOnlyAffectsTargetDeal() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        vm.roll(block.number + EPOCHS_IN_TWO_DAYS + 1);

        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        poRepMarket.rejectExpiredDeal(dealId);

        assertTrue(poRepMarket.getDealProposal(dealId).state == PoRepTypes.DealState.Rejected);
        assertTrue(poRepMarket.getDealProposal(dealId + 1).state == PoRepTypes.DealState.Proposed);
    }

    function testSetPaddingShouldEmitEvent() public {
        uint256 newPadding = 15;

        vm.expectEmit(true, false, false, false);
        emit PoRepMarket.DealCompletionPaddingUpdated(0, newPadding);
        vm.prank(adminAddress);
        poRepMarket.setDealCompletionPadding(newPadding);
    }

    function testShouldRevertWhenNewPaddingValueIsTooLarge() public {
        uint256 newPadding = 101;

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealCompletionPaddingTooHigh.selector, newPadding, 100));
        vm.prank(adminAddress);
        poRepMarket.setDealCompletionPadding(newPadding);
    }

    function testShouldRevertWhenPaddingSetterIsNotTheAdmin() public {
        uint256 newPadding = 15;
        address notTheAdmin = vm.addr(0x999);
        bytes32 defaultAdminRole = poRepMarket.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notTheAdmin, defaultAdminRole
            )
        );
        vm.prank(notTheAdmin);
        poRepMarket.setDealCompletionPadding(newPadding);
    }

    function testShouldReturnDealCompletionPadding() public {
        assertEq(poRepMarket.getDealCompletionPadding(), 0);

        uint256 newPadding = 15;
        vm.prank(adminAddress);
        poRepMarket.setDealCompletionPadding(newPadding);
        assertEq(poRepMarket.getDealCompletionPadding(), newPadding);
    }

    function testGetSPRegistryContract() public view {
        assertEq(poRepMarket.getSPRegistryContract(), address(spRegistry));
    }

    function testGetClientSmartContract() public view {
        assertEq(poRepMarket.getClientSmartContract(), address(clientSmartContractAddress));
    }

    function testGetValidatorFactoryContract() public view {
        assertEq(poRepMarket.getValidatorFactoryContract(), address(validatorFactory));
    }

    function testManifestLocationUpdateRevertsWhenCallerIsNotAdmin() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );
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

    function testGetDealProposalExpirationReturnsDefault() public view {
        assertEq(poRepMarket.getDealProposalExpiration(), EPOCHS_IN_TWO_DAYS);
    }

    function testGetDealProposalExpirationReturnsUpdatedValue() public {
        uint256 newDealExpiration = 1000;

        vm.prank(adminAddress);
        poRepMarket.setNewDealProposalExpiration(newDealExpiration);

        assertEq(poRepMarket.getDealProposalExpiration(), newDealExpiration);
    }

    function testSetNewDealProposalExpirationEmitsEvent() public {
        uint256 newExpiration = 1000;

        vm.expectEmit(true, false, false, false);
        emit PoRepMarket.DealProposalExpirationUpdated(newExpiration);

        vm.prank(adminAddress);
        poRepMarket.setNewDealProposalExpiration(newExpiration);
    }

    function testProposeDealRevertsWhenManifestHashIsZero() public {
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.EmptyManifestHash.selector));
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: bytes32(0)})
        );
    }

    function testProposeDealStoresManifestHash() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        PoRepTypes.DealProposal memory dp = poRepMarket.getDealProposal(dealId);
        assertEq(dp.manifestHash, expectedManifestHash);
    }

    function testGetManifestHashReturnsStoredHash() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(
            defaultRequirements,
            defaultTerms,
            PoRepTypes.ManifestStruct({location: expectedManifestLocation, hash: expectedManifestHash})
        );

        assertEq(poRepMarket.getManifestHash(dealId), expectedManifestHash);
    }

    function testGetManifestHashRevertsForNonExistentDeal() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.getManifestHash(999);
    }
}

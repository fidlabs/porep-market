// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorFactoryMock} from "./contracts/ValidatorFactoryMock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SLIThresholds, DealTerms} from "../src/types/SLITypes.sol";

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

    SLIThresholds internal defaultRequirements =
        SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});

    DealTerms internal defaultTerms = DealTerms({dealSizeBytes: 1000, priceForDeal: 100, durationDays: 365});

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

        providerFilActorId = CommonTypes.FilActorId.wrap(1);

        // solhint-disable gas-small-strings
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)",
            adminAddress,
            address(validatorFactory),
            address(spRegistry),
            clientSmartContractAddress
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        poRepMarket = PoRepMarket(address(proxy));

        spRegistry.setNextProvider(providerFilActorId);
        spRegistry.setIsOwner(providerOwnerAddress, providerFilActorId, true);
        validatorFactory.setValidator(validatorAddress, true);
    }

    function testProposeDealEmitsEvent() public {
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealProposalCreated(dealId, clientAddress, providerFilActorId, defaultRequirements);

        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);
    }

    function testProposeDealSetsDealProposal() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);

        PoRepMarket.DealProposal memory p = poRepMarket.getDealProposal(1);
        assertEq(p.dealId, 1);
        assertEq(p.client, clientAddress);
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(p.requirements.retrievabilityPct, defaultRequirements.retrievabilityPct);
        assertEq(p.requirements.bandwidthMbps, defaultRequirements.bandwidthMbps);
        assertEq(p.requirements.latencyMs, defaultRequirements.latencyMs);
        assertEq(p.requirements.indexingPct, defaultRequirements.indexingPct);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertTrue(p.state == PoRepMarket.DealState.Proposed);

        p = poRepMarket.getDealProposal(0);
        assertEq(p.dealId, 0);
        assertEq(p.client, address(0));
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), 0);
        assertEq(p.requirements.retrievabilityPct, 0);
        assertEq(p.requirements.bandwidthMbps, 0);
        assertEq(p.requirements.latencyMs, 0);
        assertEq(p.requirements.indexingPct, 0);
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
            poRepMarket.proposeDeal(defaultRequirements, defaultTerms);

            p = poRepMarket.getDealProposal(i);
            assertEq(p.dealId, i);
            assertEq(p.client, vm.addr(i));
        }

        p = poRepMarket.getDealProposal(proposalsCount + 1);
        assertEq(p.dealId, 0);
        assertEq(p.dealId, 0);
        assertEq(p.client, address(0));
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), 0);
        assertEq(p.requirements.retrievabilityPct, 0);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertEq(uint8(p.state), 0);
    }

    function testProposeDealRevertsWhenNoProviderFoundForDeal() public {
        spRegistry.setNextProvider(CommonTypes.FilActorId.wrap(0));

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NoProviderFoundForDeal.selector));
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);
    }

    function testUpdateValidatorAndRailIdEmitsValidatorAndRailIdUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ValidatorAndRailIdUpdated(dealId, validatorAddress, railId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidatorAndRailId(dealId, railId);
    }

    function testUpdateValidatorAndRailIdRevertsIfValidatorIsAlreadySet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidatorAndRailId(dealId, railId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.ValidatorAlreadySet.selector, dealId));
        poRepMarket.updateValidatorAndRailId(dealId, railId);
    }

    function testUpdateValidatorAndRailIdRevertsIfNotTheRegisteredValidator() public {
        address notTheValidator = vm.addr(0x999);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheRegisteredValidator.selector, dealId, notTheValidator));
        vm.prank(notTheValidator);
        poRepMarket.updateValidatorAndRailId(dealId, railId);
    }

    function testAcceptDealEmitsDealAcceptedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(dealId, providerOwnerAddress, providerFilActorId);

        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenNotTheStorageProviderOwner() public {
        address notTheOwner = vm.addr(0x999);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.NotTheStorageProviderOwner.selector, dealId, notTheOwner, providerFilActorId
            )
        );
        vm.prank(notTheOwner);
        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenDealNotInExpectedState() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);
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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(clientSmartContractAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCompleted(dealId, clientSmartContractAddress, providerFilActorId);

        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector));
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenNotTheSPClient() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);
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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);

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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);
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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, clientAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectAsStorageProviderOwnerDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);

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
        poRepMarket.proposeDeal(defaultRequirements, defaultTerms);

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

    function testProposeDealRevertsWhenRetrievabilityPctExceeds100() public {
        SLIThresholds memory badRequirements =
            SLIThresholds({retrievabilityPct: 101, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidRetrievabilityPct.selector, uint8(101)));
        poRepMarket.proposeDeal(badRequirements, defaultTerms);
    }

    function testProposeDealRevertsWhenIndexingPctExceeds100() public {
        SLIThresholds memory badRequirements =
            SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 101});
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.InvalidIndexingPct.selector, uint8(101)));
        poRepMarket.proposeDeal(badRequirements, defaultTerms);
    }
}

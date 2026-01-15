// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorRegistryMock} from "./contracts/ValidatorRegistryMock.sol";
import {ClientMock} from "./contracts/ClientMock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract PoRepMarketTest is Test {
    PoRepMarket public poRepMarket;
    SPRegistryMock public spRegistry;
    ValidatorRegistryMock public validatorRegistry;
    ClientMock public client;
    address public validatorAddress;
    CommonTypes.FilActorId public providerFilActorId;
    address public clientAddress;
    address public providerOwnerAddress;
    address public slcAddress;
    uint256 public railId;
    uint256 public dealId;

    function setUp() public {
        PoRepMarket impl = new PoRepMarket();
        spRegistry = new SPRegistryMock();
        validatorRegistry = new ValidatorRegistryMock();
        client = new ClientMock();
        validatorAddress = address(0x000);
        providerFilActorId = CommonTypes.FilActorId.wrap(1);
        clientAddress = address(0x002);
        providerOwnerAddress = address(0x003);
        slcAddress = address(0x004);
        railId = 1;
        validatorAddress = address(0x005);
        dealId = 1;
        // solhint-disable gas-small-strings
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address)", address(validatorRegistry), address(spRegistry), address(client)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        poRepMarket = PoRepMarket(address(proxy));

        spRegistry.setProvider(slcAddress, providerFilActorId);
        client.setSPClient(providerFilActorId, clientAddress);
        spRegistry.setIsOwner(providerOwnerAddress, providerFilActorId, true);
        validatorRegistry.setValidator(validatorAddress, true);
    }

    function testProposeDealEmitsEvent() public {
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealProposalCreated(1, clientAddress, providerFilActorId, slcAddress);

        poRepMarket.proposeDeal(100, 100, slcAddress);
    }

    function testProposeDealSetsDealProposal() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);

        PoRepMarket.DealProposal memory p = poRepMarket.getDealProposal(1);
        assertEq(p.dealId, 1);
        assertEq(p.client, clientAddress);
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(p.SLC, slcAddress);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertTrue(p.state == PoRepMarket.DealState.Proposed);
    }

    function testShouldIncrementDealIdCounter() public {
        poRepMarket.proposeDeal(100, 100, slcAddress);
        assertEq(poRepMarket.dealIdCounter(), 1);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);
        assertEq(poRepMarket.dealIdCounter(), 2);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);
        assertEq(poRepMarket.dealIdCounter(), 3);
    }

    function testProposeDealRevertsWhenNoProviderFoundForDeal() public {
        vm.prank(clientAddress);
        address incorrectSLCAddress = vm.addr(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(PoRepMarket.NoProviderFoundForDeal.selector, 100, 100, incorrectSLCAddress)
        );
        poRepMarket.proposeDeal(100, 100, incorrectSLCAddress);
    }

    function testUpdateValidatorAndRailIdEmitsValidatorAndRailIdUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);

        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ValidatorAndRailIdUpdated(1, validatorAddress, railId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidatorAndRailId(1, railId);
    }

    function testUpdateValidatorAndRailIdRevertsIfNotTheRegisteredValidator() public {
        address notTheValidator = vm.addr(0x999);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheRegisteredValidator.selector, 1, notTheValidator));
        vm.prank(notTheValidator);
        poRepMarket.updateValidatorAndRailId(1, railId);
    }

    function testAcceptDealEmitsDealAcceptedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealAccepted(1, providerOwnerAddress, providerFilActorId);

        poRepMarket.acceptDeal(1);
    }

    function testAcceptDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector, 1));
        poRepMarket.acceptDeal(1);
    }

    function testAcceptDealRevertsWhenNotTheStorageProviderOwner() public {
        address notTheOwner = vm.addr(0x999);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);

        vm.expectRevert(
            abi.encodeWithSelector(PoRepMarket.NotTheStorageProviderOwner.selector, 1, notTheOwner, providerFilActorId)
        );
        vm.prank(notTheOwner);
        poRepMarket.acceptDeal(1);
    }

    function testAcceptDealRevertsWhenDealNotInExpectedState() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);
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
        poRepMarket.proposeDeal(100, 100, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealCompleted(dealId, clientAddress, providerFilActorId);

        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector, 1));
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenNotTheSPClient() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        address notTheClient = vm.addr(0x999);
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheSPClient.selector, 1, notTheClient));
        vm.prank(notTheClient);
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenDealNotAcceptedByStorageProvider() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepMarket.DealState.Proposed,
                PoRepMarket.DealState.Accepted
            )
        );
        poRepMarket.completeDeal(dealId);
    }

    function testCompleteDealRevertsWhenDealAlreadyCompleted() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(clientAddress);
        poRepMarket.completeDeal(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.DealNotInExpectedState.selector,
                dealId,
                PoRepMarket.DealState.Completed,
                PoRepMarket.DealState.Accepted
            )
        );
        poRepMarket.completeDeal(dealId);
    }

    function testRejectAsClientDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, clientAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectAsStorageProviderOwnerDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(providerOwnerAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, providerOwnerAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectDealRevertsWhenDealDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.DealDoesNotExist.selector, 1));
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectDealRevertsWhenNotTheClientOrStorageProviderOwner() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        address notTheClientOrStorageProviderOwner = vm.addr(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.NotTheClientOrStorageProvider.selector, dealId, notTheClientOrStorageProviderOwner
            )
        );
        vm.prank(notTheClientOrStorageProviderOwner);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectDealRevertsWhenDealAlreadyFinished() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(100, 100, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);
        vm.prank(clientAddress);
        poRepMarket.rejectDeal(dealId);

        vm.expectRevert(
            abi.encodeWithSelector(PoRepMarket.DealAlreadyFinished.selector, dealId, PoRepMarket.DealState.Rejected)
        );
        vm.prank(clientAddress);
        poRepMarket.rejectDeal(dealId);
    }
}

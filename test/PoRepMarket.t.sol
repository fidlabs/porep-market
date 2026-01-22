// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorRegistryMock} from "./contracts/ValidatorRegistryMock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract PoRepMarketTest is Test {
    PoRepMarket public poRepMarket;
    SPRegistryMock public spRegistry;
    ValidatorRegistryMock public validatorRegistry;
    address public validatorAddress;
    address public clientSmartContractAddress;
    address public clientAddress;
    address public providerOwnerAddress;
    address public slcAddress;
    uint256 public railId;
    uint256 public dealId;
    uint256 public expectedDealSize;
    uint256 public priceForDeal;

    CommonTypes.FilActorId public providerFilActorId;

    function setUp() public {
        PoRepMarket impl = new PoRepMarket();
        spRegistry = new SPRegistryMock();
        validatorRegistry = new ValidatorRegistryMock();
        validatorAddress = vm.addr(0x001);
        clientSmartContractAddress = vm.addr(0x002);
        clientAddress = vm.addr(0x003);
        providerOwnerAddress = vm.addr(0x004);
        slcAddress = vm.addr(0x005);
        dealId = 1;
        railId = 1;
        expectedDealSize = 100;
        priceForDeal = 150;

        providerFilActorId = CommonTypes.FilActorId.wrap(1);

        // solhint-disable gas-small-strings
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            address(validatorRegistry),
            address(spRegistry),
            clientSmartContractAddress
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        poRepMarket = PoRepMarket(address(proxy));

        spRegistry.setProvider(slcAddress, providerFilActorId);
        spRegistry.setIsOwner(providerOwnerAddress, providerFilActorId, true);
        validatorRegistry.setValidator(validatorAddress, true);
    }

    function testProposeDealEmitsEvent() public {
        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealProposalCreated(dealId, clientAddress, providerFilActorId, slcAddress);

        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
    }

    function testProposeDealSetsDealProposal() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);

        PoRepMarket.DealProposal memory p = poRepMarket.getDealProposal(1);
        assertEq(p.dealId, 1);
        assertEq(p.client, clientAddress);
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), CommonTypes.FilActorId.unwrap(providerFilActorId));
        assertEq(p.SLC, slcAddress);
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertTrue(p.state == PoRepMarket.DealState.Proposed);

        p = poRepMarket.getDealProposal(0);
        assertEq(p.dealId, 0);
        assertEq(p.client, address(0));
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), 0);
        assertEq(p.SLC, address(0));
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
            poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);

            p = poRepMarket.getDealProposal(i);
            assertEq(p.dealId, i);
            assertEq(p.client, vm.addr(i));
        }

        p = poRepMarket.getDealProposal(proposalsCount + 1);
        assertEq(p.dealId, 0);
        assertEq(p.dealId, 0);
        assertEq(p.client, address(0));
        assertEq(CommonTypes.FilActorId.unwrap(p.provider), 0);
        assertEq(p.SLC, address(0));
        assertEq(p.validator, address(0));
        assertEq(p.railId, 0);
        assertEq(uint8(p.state), 0);
    }

    function testProposeDealRevertsWhenNoProviderFoundForDeal() public {
        vm.prank(clientAddress);
        address incorrectSLCAddress = vm.addr(0x999);
        vm.expectRevert(
            abi.encodeWithSelector(
                PoRepMarket.NoProviderFoundForDeal.selector, expectedDealSize, priceForDeal, incorrectSLCAddress
            )
        );
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, incorrectSLCAddress);
    }

    function testUpdateValidatorAndRailIdEmitsValidatorAndRailIdUpdatedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.ValidatorAndRailIdUpdated(dealId, validatorAddress, railId);

        vm.prank(validatorAddress);
        poRepMarket.updateValidatorAndRailId(dealId, railId);
    }

    function testUpdateValidatorAndRailIdRevertsIfValidatorIsAlreadySet() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarket.NotTheRegisteredValidator.selector, dealId, notTheValidator));
        vm.prank(notTheValidator);
        poRepMarket.updateValidatorAndRailId(dealId, railId);
    }

    function testAcceptDealEmitsDealAcceptedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);

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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);

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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);

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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, clientAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectAsStorageProviderOwnerDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
        vm.prank(providerOwnerAddress);
        poRepMarket.acceptDeal(dealId);

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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
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
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);
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

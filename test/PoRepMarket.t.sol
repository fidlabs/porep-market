// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorFactoryMock} from "./contracts/ValidatorFactoryMock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ResolveAddressPrecompileMock} from "../test/contracts/ResolveAddressPrecompileMock.sol";
import {MockProxy} from "./contracts/MockProxy.sol";
import {ActorIdMock} from "./contracts/ActorIdMock.sol";
import {ActorIdFailingMock} from "./contracts/ActorIdFailingMock.sol";
import {ActorIdExitCodeErrorFailingMock} from "./contracts/ActorIdExitCodeErrorFailingMock.sol";
import {MinerUtils} from "../src/libs/MinerUtils.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PoRepMarketContractMock} from "./contracts/PoRepMarketContractMock.sol";

// solhint-disable-next-line max-states-count
contract PoRepMarketTest is Test {
    PoRepMarket public poRepMarket;
    SPRegistryMock public spRegistry;
    ResolveAddressPrecompileMock public resolveAddressPrecompileMock;
    ResolveAddressPrecompileMock public resolveAddress =
        ResolveAddressPrecompileMock(payable(0xFE00000000000000000000000000000000000001));
    ActorIdMock public actorIdMock;
    ActorIdFailingMock public actorIdFailingMock;
    ActorIdExitCodeErrorFailingMock public actorIdExitCodeErrorFailingMock;
    address public constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;
    ValidatorFactoryMock public validatorFactory;
    address public validatorAddress;
    address public clientSmartContractAddress;
    address public clientAddress;
    address public providerOwnerAddress;
    address public slcAddress;
    address public adminAddress;
    uint256 public railId;
    uint256 public dealId;
    uint256 public expectedDealSize;
    uint256 public priceForDeal;

    CommonTypes.FilActorId public providerFilActorId;

    function setUp() public {
        PoRepMarket impl = new PoRepMarket();
        spRegistry = new SPRegistryMock();
        actorIdMock = new ActorIdMock();
        actorIdFailingMock = new ActorIdFailingMock();
        actorIdExitCodeErrorFailingMock = new ActorIdExitCodeErrorFailingMock();
        address actorIdProxy = address(new MockProxy(address(5555)));

        resolveAddressPrecompileMock = new ResolveAddressPrecompileMock();
        vm.etch(address(resolveAddress), address(resolveAddressPrecompileMock).code);
        vm.etch(CALL_ACTOR_ID, address(actorIdMock).code);
        vm.etch(address(5555), address(actorIdProxy).code);
        validatorFactory = new ValidatorFactoryMock();
        validatorAddress = vm.addr(0x001);
        clientSmartContractAddress = vm.addr(0x002);
        clientAddress = vm.addr(0x003);
        providerOwnerAddress = vm.addr(0x004);
        slcAddress = vm.addr(0x005);
        adminAddress = vm.addr(0x006);
        dealId = 1;
        railId = 1;
        expectedDealSize = 100;
        priceForDeal = 150;

        providerFilActorId = CommonTypes.FilActorId.wrap(1000);

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

        spRegistry.setProvider(slcAddress, providerFilActorId);
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
            SLC: slcAddress,
            validator: validatorAddress,
            railId: railId,
            state: state
        });
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

    function testAcceptDealRevertsExitCodeError() public {
        vm.etch(CALL_ACTOR_ID, address(actorIdExitCodeErrorFailingMock).code);
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);

        vm.expectRevert(abi.encodeWithSelector(MinerUtils.ExitCodeError.selector));
        poRepMarket.acceptDeal(dealId);
    }

    function testAcceptDealRevertsWhenNotTheControllingAddress() public {
        vm.etch(CALL_ACTOR_ID, address(actorIdFailingMock).code);
        address notOwnerAddress = vm.addr(3);
        resolveAddress.setId(notOwnerAddress, uint64(20000));
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);

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

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit PoRepMarket.DealRejected(dealId, clientAddress);
        poRepMarket.rejectDeal(dealId);
    }

    function testRejectAsStorageProviderOwnerDealEmitsDealRejectedEvent() public {
        vm.prank(clientAddress);
        poRepMarket.proposeDeal(expectedDealSize, priceForDeal, slcAddress);

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

    function testGetCompletedDealsAndRemoveIdsFromSetWithIncorrectDealState() public {
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
        assertEq(porepMarekMock.getDealIdsReadyForPayment().length, 5);

        PoRepMarket.DealProposal[] memory dealProposal = porepMarekMock.getCompletedDeals();
        assertEq(dealProposal.length, 2);
        assertEq(dealProposal[0].dealId, ids[0]);
        assertTrue(dealProposal[0].state == PoRepMarket.DealState.Completed);
        assertEq(dealProposal[1].dealId, ids[3]);
        assertTrue(dealProposal[1].state == PoRepMarket.DealState.Completed);

        uint256[] memory readyForPaymentDeals = porepMarekMock.getDealIdsReadyForPayment();
        assertEq(readyForPaymentDeals.length, 2);
        assertEq(readyForPaymentDeals[0], ids[0]);
        assertEq(readyForPaymentDeals[1], ids[3]);
    }
}

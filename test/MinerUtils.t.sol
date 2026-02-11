// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {MinerUtilsHarness} from "./contracts/MinerUtilsHarness.sol";
import {ResolveAddressPrecompileMock} from "./contracts/ResolveAddressPrecompileMock.sol";
import {MockProxy} from "./contracts/MockProxy.sol";
import {ActorIdMock} from "./contracts/ActorIdMock.sol";
import {ActorIdFailingMock} from "./contracts/ActorIdFailingMock.sol";
import {ActorIdExitCodeErrorFailingMock} from "./contracts/ActorIdExitCodeErrorFailingMock.sol";
import {MinerUtils} from "../src/libs/MinerUtils.sol";

contract MinerUtilsTest is Test {
    MinerUtilsHarness public harness;
    ResolveAddressPrecompileMock public resolveAddressPrecompileMock;
    ResolveAddressPrecompileMock public resolveAddress =
        ResolveAddressPrecompileMock(payable(0xFE00000000000000000000000000000000000001));
    address public constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;
    address public testAddr;

    CommonTypes.FilActorId public minerID;

    function setUp() public {
        harness = new MinerUtilsHarness();
        testAddr = vm.addr(0x001);
        minerID = CommonTypes.FilActorId.wrap(10000);

        ActorIdMock actorIdMock = new ActorIdMock();
        address actorIdProxy = address(new MockProxy(address(5555)));

        resolveAddressPrecompileMock = new ResolveAddressPrecompileMock();
        vm.etch(address(resolveAddress), address(resolveAddressPrecompileMock).code);
        vm.etch(CALL_ACTOR_ID, address(actorIdMock).code);
        vm.etch(address(5555), address(actorIdProxy).code);

        resolveAddress.setId(testAddr, 10000);
    }

    function testIsControllingAddressReturnsTrue() public view {
        bool result = harness.isControllingAddress(minerID, testAddr);
        assertTrue(result);
    }

    function testIsControllingAddressReturnsFalse() public {
        ActorIdFailingMock failingMock = new ActorIdFailingMock();
        vm.etch(CALL_ACTOR_ID, address(failingMock).code);
        bool result = harness.isControllingAddress(minerID, testAddr);
        assertFalse(result);
    }

    function testIsControllingAddressRevertsOnExitCodeError() public {
        ActorIdExitCodeErrorFailingMock exitCodeMock = new ActorIdExitCodeErrorFailingMock();
        vm.etch(CALL_ACTOR_ID, address(exitCodeMock).code);
        vm.expectRevert(MinerUtils.ExitCodeError.selector);
        harness.isControllingAddress(minerID, testAddr);
    }
}

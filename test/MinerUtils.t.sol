// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {MinerUtilsHarness} from "./contracts/MinerUtilsHarness.sol";
import {ActorIdMock} from "./contracts/ActorIdMock.sol";
import {ActorIdFailingMock} from "./contracts/ActorIdFailingMock.sol";
import {ActorIdExitCodeErrorFailingMock} from "./contracts/ActorIdExitCodeErrorFailingMock.sol";
import {MinerUtils} from "../src/libs/MinerUtils.sol";

contract MinerUtilsTest is Test {
    MinerUtilsHarness public harness;
    address public testAddr;

    function setUp() public {
        harness = new MinerUtilsHarness();
        testAddr = vm.addr(0x001);
    }

    function testIsControllingAddressReturnsTrue() public {
        ActorIdMock mock = new ActorIdMock();
        CommonTypes.FilActorId minerID = CommonTypes.FilActorId.wrap(uint64(uint160(address(mock))));
        bool result = harness.isControllingAddress(minerID, testAddr);
        assertTrue(result);
    }

    function testIsControllingAddressReturnsFalse() public {
        ActorIdFailingMock mock = new ActorIdFailingMock();
        CommonTypes.FilActorId minerID = CommonTypes.FilActorId.wrap(uint64(uint160(address(mock))));
        bool result = harness.isControllingAddress(minerID, testAddr);
        assertFalse(result);
    }

    function testIsControllingAddressRevertsOnExitCodeError() public {
        ActorIdExitCodeErrorFailingMock mock = new ActorIdExitCodeErrorFailingMock();
        CommonTypes.FilActorId minerID = CommonTypes.FilActorId.wrap(uint64(uint160(address(mock))));
        vm.expectRevert(MinerUtils.ExitCodeError.selector);
        harness.isControllingAddress(minerID, testAddr);
    }
}

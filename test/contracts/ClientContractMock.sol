// solhint-disable use-natspec
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Client} from "../../src/Client.sol";

contract ClientContractMock is Client {
    function getDeal(uint256 dealId) public view returns (Client.Deal memory) {
        return s()._deals[dealId];
    }
}

// solhint-disable use-natspec
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Client} from "../../src/Client.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ClientContractMock is Client {
    function getDeal(uint256 dealId) public view returns (Client.Deal memory) {
        return s()._deals[dealId];
    }

    function addDealAllocationId(uint256 dealId, uint64 allocationId) external {
        s()._deals[dealId].allocationIds.push(CommonTypes.FilActorId.wrap(allocationId));
    }

    function deleteDealAllocationIdByValue(uint256 dealId, uint64 allocationId) external {
        Deal storage deal = s()._deals[dealId];
        _deleteDealAllocationIdByValue(dealId, deal, allocationId);
    }
}

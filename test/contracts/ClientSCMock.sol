// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {Client} from "../../src/Client.sol";

contract ClientSCMock {
    mapping(CommonTypes.FilActorId provider => bool ok) public valid;
    mapping(uint256 dealId => bool matches) public dataSizeMatches;
    mapping(uint256 dealId => Client.Deal deal) public deals;
    mapping(uint256 dealId => CommonTypes.FilActorId[] ids) internal allocationIds;

    function setValid(CommonTypes.FilActorId provider, bool ok) external {
        valid[provider] = ok;
    }

    function setDataSizeMatching(uint256 dealId, bool matches) external {
        dataSizeMatches[dealId] = matches;
    }

    function isDataSizeMatching(uint256 dealId) external view returns (bool) {
        return dataSizeMatches[dealId];
    }

    function getClientDealInfo(uint256 dealId) external view returns (Client.Deal memory) {
        return deals[dealId];
    }

    function setAllocationIds(uint256 dealId, CommonTypes.FilActorId[] calldata ids_) external {
        delete allocationIds[dealId];
        for (uint256 i = 0; i < ids_.length; i++) {
            allocationIds[dealId].push(ids_[i]);
        }
    }

    function getClientAllocationIdsPerDeal(uint256 dealId) external view returns (CommonTypes.FilActorId[] memory) {
        return allocationIds[dealId];
    }
}

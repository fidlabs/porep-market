// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {DataCapEvidenceAdapter} from "../../src/DataCapEvidenceAdapter.sol";

contract DataCapEvidenceAdapterMock {
    mapping(CommonTypes.FilActorId provider => bool ok) public valid;
    mapping(uint256 dealId => bool matches) public dataSizeMatches;
    mapping(uint256 dealId => DataCapEvidenceAdapter.Deal deal) public deals;
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

    function getDataCapEvidenceAdapterDealInfo(uint256 dealId)
        external
        view
        returns (DataCapEvidenceAdapter.Deal memory)
    {
        return deals[dealId];
    }

    function setAllocationIds(uint256 dealId, CommonTypes.FilActorId[] calldata ids_) external {
        delete allocationIds[dealId];
        for (uint256 i = 0; i < ids_.length; i++) {
            allocationIds[dealId].push(ids_[i]);
        }
    }

    function getAllAllocationIdsPerDeal(uint256 dealId) external view returns (CommonTypes.FilActorId[] memory) {
        return allocationIds[dealId];
    }

    function getAllocationIdsPerDeal(uint256 dealId, uint256 offset, uint256 limit)
        external
        view
        returns (CommonTypes.FilActorId[] memory ids, uint256 sumOfAllocations)
    {
        if (limit == 0) revert();
        sumOfAllocations = allocationIds[dealId].length;
        if (offset >= sumOfAllocations) {
            return (new CommonTypes.FilActorId[](0), sumOfAllocations);
        }

        uint256 end = offset + limit;
        if (end > sumOfAllocations) {
            end = sumOfAllocations;
        }

        ids = new CommonTypes.FilActorId[](end - offset);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = allocationIds[dealId][offset + i];
        }
    }

    function setDeal(DataCapEvidenceAdapter.Deal memory deal) external {
        deals[deal.dealId] = deal;
    }

    function getSizeOfAllocations(uint256 dealId) external view returns (uint256) {
        return deals[dealId].sizeOfAllocations;
    }
}

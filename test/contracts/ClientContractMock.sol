// solhint-disable use-natspec
// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {DataCapEvidenceAdapter} from "../../src/DataCapEvidenceAdapter.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ClientContractMock is DataCapEvidenceAdapter {
    function getDeal(uint256 dealId) public view returns (DataCapEvidenceAdapter.Deal memory) {
        return s()._deals[dealId];
    }

    function getClientAllocationIdsPerDeal(uint256 dealId) external view returns (CommonTypes.FilActorId[] memory) {
        return s()._deals[dealId].allocationIds;
    }

    function deleteDealAllocationIdByIndex(uint256 dealId, uint64 index) external {
        Deal storage deal = s()._deals[dealId];
        _deleteDealAllocationIdByIndex(deal, index);
    }
}

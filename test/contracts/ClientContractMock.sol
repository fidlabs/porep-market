// solhint-disable use-natspec
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Client} from "../../src/Client.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ClientContractMock is Client {
    function getDeal(uint256 dealId) public view returns (Client.Deal memory) {
        return s()._deals[dealId];
    }

    function addDealClaimId(uint256 dealId, uint64 claimId) external {
        s()._deals[dealId].claimIds.push(CommonTypes.FilActorId.wrap(claimId));
    }

    function deleteDealClaimIdByValue(uint256 dealId, uint64 claimId) external {
        Deal storage deal = s()._deals[dealId];
        _deleteDealClaimIdByValue(dealId, deal, claimId);
    }
}

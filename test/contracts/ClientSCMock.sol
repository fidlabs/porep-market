// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {Client} from "../../src/Client.sol";

contract ClientSCMock {
    mapping(CommonTypes.FilActorId provider => bool ok) public valid;
    mapping(uint256 dealId => bool matches) public dataSizeMatches;
    mapping(uint256 dealId => Client.Deal deal) public deals;

    function setValid(CommonTypes.FilActorId provider, bool ok) external {
        valid[provider] = ok;
    }

    function setDataSizeMatching(uint256 dealId, bool matches) external {
        dataSizeMatches[dealId] = matches;
    }

    function isDataSizeMatching(uint256 dealId) external view returns (bool) {
        return dataSizeMatches[dealId];
    }

    function setLongestDealTerm(uint256 dealId, int64 longestDealTerm) external {
        deals[dealId].longestDealTerm = CommonTypes.ChainEpoch.wrap(longestDealTerm);
    }

    function getClientDealInfo(uint256 dealId) external view returns (Client.Deal memory) {
        return deals[dealId];
    }
}

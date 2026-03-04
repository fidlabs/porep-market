// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ClientSCMock {
    mapping(CommonTypes.FilActorId provider => bool ok) public valid;
    mapping(uint256 dealId => bool matches) public dataSizeMatches;

    function setValid(CommonTypes.FilActorId provider, bool ok) external {
        valid[provider] = ok;
    }

    function setDataSizeMatching(uint256 dealId, bool matches) external {
        dataSizeMatches[dealId] = matches;
    }

    function isDataSizeMatching(uint256 dealId) external view returns (bool) {
        return dataSizeMatches[dealId];
    }
}

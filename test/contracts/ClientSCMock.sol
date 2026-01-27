// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ClientSCMock {
    mapping(CommonTypes.FilActorId provider => bool ok) public valid;

    function setValid(CommonTypes.FilActorId provider, bool ok) external {
        valid[provider] = ok;
    }

    function verifyAllocatedDataCapEqualsSealed(CommonTypes.FilActorId provider) external view returns (bool) {
        return valid[provider];
    }
}

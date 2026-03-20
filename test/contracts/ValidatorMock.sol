// SPDX-License-Identifier: MIT
// solhint-disable

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

pragma solidity =0.8.30;

contract ValidatorMock {
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external {
        // noop
    }

    function setDealEndEpoch(uint256 dealId, CommonTypes.ChainEpoch endEpoch) external {
        // noop
    }
}

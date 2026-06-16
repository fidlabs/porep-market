// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ValidatorMock {
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external {
        // noop
    }

    function setDealEndEpoch(uint256 dealId, CommonTypes.ChainEpoch endEpoch) external {
        // noop
    }
}

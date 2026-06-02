// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ValidatorMock {
    error InsufficientFundsForRail(uint256 required, uint256 actual);

    bool internal shouldRevertVerifyClientFunds;
    uint256 internal mockRequiredFunds;
    uint256 internal mockAvailableFunds;

    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external {
        // noop
    }

    function setDealEndEpoch(uint256 dealId, CommonTypes.ChainEpoch endEpoch) external {
        // noop
    }

    function setInsufficientFunds(uint256 required, uint256 available) external {
        shouldRevertVerifyClientFunds = true;
        mockRequiredFunds = required;
        mockAvailableFunds = available;
    }

    function verifyClientFunds(address, uint256) external view {
        if (shouldRevertVerifyClientFunds) {
            revert InsufficientFundsForRail(mockRequiredFunds, mockAvailableFunds);
        }
    }
}

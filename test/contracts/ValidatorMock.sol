// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOperator} from "../../src/interfaces/IOperator.sol";
import {RailStatus} from "../../src/types/RailStatus.sol";

contract ValidatorMock is IOperator {
    uint256 public modifyRailPaymentCallCount;
    uint256 public lastNewRate;
    uint8 public railStatus;

    function createRail(IERC20) external {}

    function updateLockupPeriod(uint256) external {}

    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external {
        // noop
    }

    function modifyRailPayment(uint256 newRate) external {
        modifyRailPaymentCallCount++;
        lastNewRate = newRate;
        railStatus = RailStatus.ACTIVE;
    }

    function setRailStatus(uint8 newRailStatus) external {
        railStatus = newRailStatus;
    }

    function getRailStatus() external view returns (uint8) {
        return railStatus;
    }

    function terminateRail() external {}
}

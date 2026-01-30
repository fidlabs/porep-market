// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {IValidator} from "../../src/interfaces/Validator.sol";

contract ValidatorMock is IValidator {
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external {
        // noop
    }
}

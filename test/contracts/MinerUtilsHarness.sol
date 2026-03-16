// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity =0.8.25;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {MinerUtils} from "../../src/lib/MinerUtils.sol";

contract MinerUtilsHarness {
    function isControllingAddress(CommonTypes.FilActorId minerID, address addr) external view returns (bool) {
        return MinerUtils.isControllingAddress(minerID, addr);
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {Validator} from "../../src/Validator.sol";

contract ValidatorContractMock is Validator {
    function _getStorage() private pure returns (Validator.ValidatorStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            $.slot := 0xf51cddbeb47ca42a561371db80eaffa401732269b8af46b255e3f43a7c044000
        }
    }

    function setDealEndEpochMock(CommonTypes.ChainEpoch endEpoch) external {
        _getStorage().dealEndEpoch = endEpoch;
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

library TestUtils {
    function generateLongString(uint256 len) public pure returns (string memory) {
        bytes memory result = new bytes(len);

        for (uint256 i = 0; i < len; i++) {
            result[i] = "a";
        }

        return string(result);
    }
}

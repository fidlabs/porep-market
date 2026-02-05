// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

contract ActorIdMock {
    error MethodNotFound();

    receive() external payable {}

    fallback(bytes calldata data) external payable returns (bytes memory) {
        (uint256 methodNum,,,,, uint64 target) = abi.decode(data, (uint64, uint256, uint64, uint64, bytes, uint64));

        if (methodNum == 3275365574 && target == 20000) {
            return abi.encode(0, 0x51, hex"824400C2A101f6");
        }

        revert MethodNotFound();
    }
}

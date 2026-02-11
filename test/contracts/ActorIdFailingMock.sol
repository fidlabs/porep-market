// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

contract ActorIdFailingMock {
    error MethodNotFound();
    receive() external payable {}

    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata data) external payable returns (bytes memory) {
        (uint256 methodNum,,,,,) = abi.decode(data, (uint64, uint256, uint64, uint64, bytes, uint64));

        if (methodNum == 348244887) {
            return abi.encode(0, 0x51, hex"F4");
        }
        revert MethodNotFound();
    }
}

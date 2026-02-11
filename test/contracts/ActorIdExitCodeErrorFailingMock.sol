// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

contract ActorIdExitCodeErrorFailingMock {
    error MethodNotFound();

    receive() external payable {}

    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata data) external payable returns (bytes memory) {
        (uint256 methodNum,,,,,) = abi.decode(data, (uint64, uint256, uint64, uint64, bytes, uint64));
        if (methodNum == 3916220144 || methodNum == 3275365574 || methodNum == 348244887) {
            // Exit Code Error
            return abi.encode(1, 0x00, "");
        }

        revert MethodNotFound();
    }
}

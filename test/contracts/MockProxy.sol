// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

contract MockProxy {
    error Err();

    address public immutable PROXY_ADDRESS;

    constructor(address _proxyAddress) {
        PROXY_ADDRESS = _proxyAddress;
    }

    receive() external payable {}

    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata data) external payable returns (bytes memory) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory retData) = PROXY_ADDRESS.call(data);
        if (!success) revert Err();
        return retData;
    }
}

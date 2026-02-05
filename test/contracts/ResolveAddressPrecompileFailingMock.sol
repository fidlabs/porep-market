// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

contract ResolveAddressPrecompileFailingMock {
    fallback(bytes calldata data) external payable returns (bytes memory) {
        return abi.encode(data);
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

contract ResolveAddressPrecompileFailingMock {
    fallback(bytes calldata data) external payable returns (bytes memory) {
        return abi.encode(data);
    }
}

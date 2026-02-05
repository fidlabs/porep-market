// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

contract ResolveAddressPrecompileMock {
    error ErrorExitCode();

    mapping(address client => uint64 id) public addressToId;
    mapping(bytes filAddressData => uint64 id) public filAddressToId;

    function setId(address addr, uint64 id) external {
        addressToId[addr] = id;
    }

    function setAddress(bytes calldata filAddressData, uint64 id) external {
        filAddressToId[filAddressData] = id;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        address clientAddress;
        assembly {
            let tmp := calldataload(add(data.offset, 2))
            clientAddress := shr(96, tmp)
        }
        uint64 id = addressToId[clientAddress];

        if (id == 0) {
            id = filAddressToId[data];
        }

        if (id == 0) {
            revert ErrorExitCode();
        }

        return abi.encode(id);
    }
}

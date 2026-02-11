// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

contract ResolveAddressPrecompileMock {
    error ErrorExitCode();

    mapping(address client => uint64 id) public addressToId;
    mapping(bytes filAddressData => uint64 id) public filAddressToId;

    function setId(address addr, uint64 id) external {
        addressToId[addr] = id;
    }

    function setIdFromFilAddress(bytes calldata filAddressData, uint64 id) external {
        filAddressToId[filAddressData] = id;
    }

    function setAddress(bytes calldata filAddressData, uint64 id) external {
        filAddressToId[filAddressData] = id;
    }

    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata data) external returns (bytes memory) {
        address clientAddress;
        // solhint-disable-next-line no-inline-assembly
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

// solhint-disable use-natspec
// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IMetaAllocator} from "../../src/interfaces/IMetaAllocator.sol";
import {VerifRegAPI} from "filecoin-solidity/v0.8/VerifRegAPI.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {FilAddresses} from "filecoin-solidity/v0.8/utils/FilAddresses.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

/**
 * @dev Mock contract for testing purposes with exact copy of addVerifiedClient from PoRepMarket contract
 */
contract MetaAllocatorMock is IMetaAllocator {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    EnumerableMap.AddressToUintMap private _allocators;

    function allowance(address allocator) public view returns (uint256 allowance_) {
        (, allowance_) = _allocators.tryGet(allocator);
    }

    function setAllowance(address allocator, uint256 amount) external {
        _allocators.set(allocator, amount);
    }

    function addVerifiedClient(bytes calldata clientAddress, uint256 amount) external {
        if (amount == 0) revert AmountEqualZero();
        uint256 allocatorBalance = allowance(msg.sender);
        if (allocatorBalance < amount) revert InsufficientAllowance();
        if (allocatorBalance - amount == 0) {
            _allocators.remove(msg.sender);
        } else {
            _allocators.set(msg.sender, allocatorBalance - amount);
        }
        emit DatacapAllocated(msg.sender, clientAddress, amount);
        VerifRegTypes.AddVerifiedClientParams memory params = VerifRegTypes.AddVerifiedClientParams({
            addr: FilAddresses.fromBytes(clientAddress), allowance: CommonTypes.BigInt(abi.encodePacked(amount), false)
        });
        VerifRegAPI.addVerifiedClient(params);
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable use-natspec

pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {Client} from "../../src/Client.sol";

contract ClientContractMock is Client {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    function deleteAllocationIdByValue(CommonTypes.FilActorId provider, address client, uint64 allocationId) external {
        _deleteAllocationIdByValue(provider, client, allocationId);
    }

    function addTerminatedClaims(uint64 claim) external {
        s()._terminatedClaims[claim] = true;
    }

    function getClientAllocationIds(CommonTypes.FilActorId provider, address client)
        external
        view
        returns (CommonTypes.FilActorId[] memory)
    {
        return s()._clientAllocationIdsPerProvider[provider][client];
    }

    function addClientAllocationIds(CommonTypes.FilActorId provider, address client, uint64 allocationId) external {
        s()._clientAllocationIdsPerProvider[provider][client].push(CommonTypes.FilActorId.wrap(allocationId));
    }

    function setSpClients(CommonTypes.FilActorId provider, address client, uint256 allocationSize) external {
        s()._spClients[provider].set(client, allocationSize);
    }
}

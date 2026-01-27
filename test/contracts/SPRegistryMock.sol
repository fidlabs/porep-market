// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {ISPRegistry} from "../../src/interfaces/SPRegistry.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract SPRegistryMock is ISPRegistry {
    mapping(address => CommonTypes.FilActorId) public providers;
    mapping(address => mapping(CommonTypes.FilActorId => bool)) public owners;

    function getProviderForDeal(address SLC, uint256, uint256) external view returns (CommonTypes.FilActorId) {
        return providers[SLC];
    }

    function setProvider(address SLC, CommonTypes.FilActorId provider) external {
        providers[SLC] = provider;
    }

    function setIsOwner(address client, CommonTypes.FilActorId provider, bool _isOwner) external {
        owners[client][provider] = _isOwner;
    }

    function isStorageProviderOwner(address client, CommonTypes.FilActorId provider) external view returns (bool) {
        return owners[client][provider];
    }
}

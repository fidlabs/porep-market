// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {ISPRegistry} from "../../src/interfaces/ISPRegistry.sol";
import {SLIThresholds, DealTerms} from "../../src/types/SLITypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract SPRegistryMock is ISPRegistry {
    CommonTypes.FilActorId public nextProvider;
    mapping(address => mapping(CommonTypes.FilActorId => bool)) public owners;

    // ============ Implemented Functions ============

    function getProviderForDeal(SLIThresholds calldata, DealTerms calldata)
        external
        view
        returns (CommonTypes.FilActorId)
    {
        return nextProvider;
    }

    function isStorageProviderOwner(address owner, CommonTypes.FilActorId provider) external view returns (bool) {
        return owners[owner][provider];
    }

    // ============ Test Helpers ============

    function setNextProvider(CommonTypes.FilActorId provider) external {
        nextProvider = provider;
    }

    function setIsOwner(address owner, CommonTypes.FilActorId provider, bool isOwner) external {
        owners[owner][provider] = isOwner;
    }

    // ============ Stub Functions ============

    function releaseCapacity(CommonTypes.FilActorId, uint256) external {}
    function addOwner(address) external {}
    function removeOwner(address) external {}
    function registerProvider(CommonTypes.FilActorId) external {}
    function pauseProvider(CommonTypes.FilActorId) external {}
    function unpauseProvider(CommonTypes.FilActorId) external {}
    function updateAvailableSpace(CommonTypes.FilActorId, uint256) external {}
    function setCapabilities(CommonTypes.FilActorId, SLIThresholds calldata) external {}
}

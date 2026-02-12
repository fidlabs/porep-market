// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {ISPRegistry} from "../../src/interfaces/ISPRegistry.sol";
import {SLIThresholds, DealTerms} from "../../src/types/SLITypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract SPRegistryMock is ISPRegistry {
    CommonTypes.FilActorId public nextProvider;
    mapping(address => mapping(CommonTypes.FilActorId => bool)) public owners;
    CommonTypes.FilActorId[] private _providers;
    CommonTypes.FilActorId[] private _committedProviders;
    mapping(uint64 => ProviderInfo) private _providerInfos;
    mapping(uint64 => bool) private _registered;

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

    function getProviders() external view returns (CommonTypes.FilActorId[] memory) {
        return _providers;
    }

    function getCommittedProviders() external view returns (CommonTypes.FilActorId[] memory) {
        return _committedProviders;
    }

    function getProviderInfo(CommonTypes.FilActorId provider) external view returns (ProviderInfo memory) {
        return _providerInfos[CommonTypes.FilActorId.unwrap(provider)];
    }

    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool) {
        return _registered[CommonTypes.FilActorId.unwrap(provider)];
    }

    // ============ Test Helpers ============

    function setNextProvider(CommonTypes.FilActorId provider) external {
        nextProvider = provider;
    }

    function setIsOwner(address owner, CommonTypes.FilActorId provider, bool isOwner) external {
        owners[owner][provider] = isOwner;
    }

    function addProviderToList(CommonTypes.FilActorId provider) external {
        _providers.push(provider);
        _registered[CommonTypes.FilActorId.unwrap(provider)] = true;
    }

    function addCommittedProvider(CommonTypes.FilActorId provider) external {
        _committedProviders.push(provider);
    }

    function setProviderInfo(CommonTypes.FilActorId provider, ProviderInfo calldata info) external {
        _providerInfos[CommonTypes.FilActorId.unwrap(provider)] = info;
    }

    // ============ Stub Functions ============

    function releaseCapacity(CommonTypes.FilActorId, uint256) external {}
    function commitCapacity(CommonTypes.FilActorId, uint256) external {}
    function addOwner(address) external {}
    function removeOwner(address) external {}
    function registerProvider(CommonTypes.FilActorId) external {}
    function pauseProvider(CommonTypes.FilActorId) external {}
    function unpauseProvider(CommonTypes.FilActorId) external {}
    function updateAvailableSpace(CommonTypes.FilActorId, uint256) external {}
    function setCapabilities(CommonTypes.FilActorId, SLIThresholds calldata) external {}
}

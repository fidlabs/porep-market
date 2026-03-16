// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.25;

import {ISPRegistry} from "../../src/interfaces/ISPRegistry.sol";
import {SLITypes} from "../../src/types/SLITypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract SPRegistryMock is ISPRegistry {
    CommonTypes.FilActorId public nextProvider;
    bool public nextAutoApprove;
    mapping(address => mapping(CommonTypes.FilActorId => bool)) public owners;
    CommonTypes.FilActorId[] private _providers;
    CommonTypes.FilActorId[] private _committedProviders;
    mapping(uint64 => ProviderInfo) private _providerInfos;
    mapping(uint64 => bool) private _registered;
    mapping(uint64 => address) private _payees;

    // ============ Implemented Functions ============

    function getProviderForDeal(SLITypes.SLIThresholds calldata, SLITypes.DealTerms calldata)
        external
        view
        returns (CommonTypes.FilActorId, bool)
    {
        return (nextProvider, nextAutoApprove);
    }

    function isAuthorizedForProvider(address owner, CommonTypes.FilActorId provider) external view returns (bool) {
        return owners[owner][provider];
    }

    function getProviders() external view returns (CommonTypes.FilActorId[] memory) {
        return _providers;
    }

    function getCommittedProviders() external view returns (CommonTypes.FilActorId[] memory) {
        return _committedProviders;
    }

    function getProvidersByOrganization(address) external pure returns (CommonTypes.FilActorId[] memory) {
        return new CommonTypes.FilActorId[](0);
    }

    function getProviderInfo(CommonTypes.FilActorId provider) external view returns (ProviderInfo memory) {
        return _providerInfos[CommonTypes.FilActorId.unwrap(provider)];
    }

    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool) {
        return _registered[CommonTypes.FilActorId.unwrap(provider)];
    }

    function setNextProvider(CommonTypes.FilActorId provider) external {
        nextProvider = provider;
    }

    function setNextAutoApprove(bool _autoApprove) external {
        nextAutoApprove = _autoApprove;
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

    function releaseCapacity(CommonTypes.FilActorId, uint256) external {}
    function releasePendingCapacity(CommonTypes.FilActorId, uint256) external {}
    function commitCapacity(CommonTypes.FilActorId, uint256, uint256) external {}
    function pauseProvider(CommonTypes.FilActorId) external {}
    function unpauseProvider(CommonTypes.FilActorId) external {}
    function blockProvider(CommonTypes.FilActorId) external {}
    function unblockProvider(CommonTypes.FilActorId) external {}
    function updateAvailableSpace(CommonTypes.FilActorId, uint256) external {}
    function setCapabilities(CommonTypes.FilActorId, SLITypes.SLIThresholds calldata) external {}
    function setPrice(CommonTypes.FilActorId, uint256) external {}

    function setPayee(CommonTypes.FilActorId provider, address payee) external {
        _payees[CommonTypes.FilActorId.unwrap(provider)] = payee;
    }

    function getPayee(CommonTypes.FilActorId provider) external view returns (address) {
        return _payees[CommonTypes.FilActorId.unwrap(provider)];
    }

    function setToleranceBps(uint256) external {}

    function getToleranceBps() external pure returns (uint256) {
        return 0;
    }

    function getPayAddressForProvider(CommonTypes.FilActorId provider) external view returns (address) {}
}

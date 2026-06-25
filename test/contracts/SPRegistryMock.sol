// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

// Real SPRegistry V2 disables that selector.

import {ISPRegistry} from "../../src/interfaces/ISPRegistry.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";
import {SLITypes} from "../../src/types/SLITypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract SPRegistryMock is ISPRegistry {
    SharedTypes.ProviderDealSelection public nextSelection;
    bool public nextAutoApprove;
    mapping(address => mapping(CommonTypes.FilActorId => bool)) public owners;
    CommonTypes.FilActorId[] private _providers;
    CommonTypes.FilActorId[] private _committedProviders;
    mapping(uint64 => ProviderInfo) private _providerInfos;
    mapping(uint64 => ProviderCapacityInfo) private _providerCapacity;
    mapping(uint64 => bool) private _registered;
    mapping(uint64 => address) private _payees;
    uint64 public lastReleasedPendingProvider;
    uint256 public lastReleasedPendingBytes;
    bytes32 public lastReleasedPendingManifestHash;
    uint64 public lastReleasedProvider;
    uint256 public lastReleasedBytes;
    bytes32 public lastReleasedManifestHash;

    function setNextSelection(SharedTypes.ProviderDealSelection calldata selection) external {
        nextSelection = selection;
    }

    function setNextProvider(CommonTypes.FilActorId provider) external {
        nextSelection.provider = provider;
    }

    function setNextAutoApprove(bool autoApprove) external {
        nextAutoApprove = autoApprove;
    }

    function isAuthorizedForProvider(address owner, CommonTypes.FilActorId provider) external view returns (bool) {
        return owners[owner][provider];
    }

    function setIsOwner(address owner, CommonTypes.FilActorId provider, bool isOwner) external {
        owners[owner][provider] = isOwner;
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

    function getProviderCapacity(CommonTypes.FilActorId provider) external view returns (ProviderCapacityInfo memory) {
        return _providerCapacity[CommonTypes.FilActorId.unwrap(provider)];
    }

    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool) {
        return _registered[CommonTypes.FilActorId.unwrap(provider)];
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

    function setProviderCapacity(CommonTypes.FilActorId provider, ProviderCapacityInfo calldata info) external {
        _providerCapacity[CommonTypes.FilActorId.unwrap(provider)] = info;
    }

    function setPayee(CommonTypes.FilActorId provider, address payee) external {
        _payees[CommonTypes.FilActorId.unwrap(provider)] = payee;
    }

    function getPayee(CommonTypes.FilActorId provider) external view returns (address) {
        return _payees[CommonTypes.FilActorId.unwrap(provider)];
    }

    function getProviderForDeal(SharedTypes.SLIThresholds calldata, SLITypes.DealTerms calldata)
        external
        view
        returns (CommonTypes.FilActorId provider, bool autoApprove, address organization)
    {
        provider = nextSelection.provider;
        autoApprove = nextAutoApprove;
        organization = _providerInfos[CommonTypes.FilActorId.unwrap(provider)].organization;
    }

    function previewProviderForDeal(SharedTypes.DealRequest calldata)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory)
    {
        return nextSelection;
    }

    function reserveProviderForDeal(SharedTypes.DealRequest calldata)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory)
    {
        return nextSelection;
    }

    function previewOfferForDeal(uint256, SharedTypes.DealRequest calldata)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory, uint16)
    {
        return (nextSelection, 0);
    }

    function reserveOfferForDeal(uint256, SharedTypes.DealRequest calldata)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory)
    {
        return nextSelection;
    }

    function setPaymentToken(address, bool, uint256) external {}

    function getPaymentTokens() external pure returns (address[] memory) {
        return new address[](0);
    }

    function getPaymentTokenConfig(address) external pure returns (TokenConfig memory) {
        return TokenConfig({allowed: false, minPricePer32GiBPerMonth: 0});
    }

    function createOffer(
        CommonTypes.FilActorId,
        string calldata,
        SharedTypes.OfferTerms calldata,
        SharedTypes.SLIThresholds calldata,
        SharedTypes.OfferPaymentInput[] calldata
    ) external pure returns (uint256) {
        return 0;
    }

    function setOfferActive(uint256, bool) external {}
    function setOfferName(uint256, string calldata) external {}
    function setOfferPayment(uint256, address, bool, uint256) external {}

    function getOffer(uint256) external pure returns (OfferInfo memory) {
        return OfferInfo({provider: CommonTypes.FilActorId.wrap(0), name: "", active: false});
    }

    function getOfferTerms(uint256) external pure returns (SharedTypes.OfferTerms memory) {
        return SharedTypes.OfferTerms({minSizeBytes: 0, maxSizeBytes: 0, minDurationEpochs: 0, maxDurationEpochs: 0});
    }

    function getOfferSLIs(uint256) external pure returns (SharedTypes.SLIThresholds memory) {
        return
            SharedTypes.SLIThresholds({retrievabilityBps: 0, bandwidthBytesPerSecond: 0, latencyMs: 0, indexingPct: 0});
    }

    function getOfferPayment(uint256, address) external pure returns (OfferPayment memory) {
        return OfferPayment({active: false, pricePer32GiBPerMonth: 0});
    }

    function getOffersByProvider(CommonTypes.FilActorId) external pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function getActiveOffersByProvider(CommonTypes.FilActorId) external pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function getActiveOffers() external pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function isManifestAssignedToProvider(bytes32, CommonTypes.FilActorId) external pure returns (bool) {
        return false;
    }

    function releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes) external {
        lastReleasedProvider = CommonTypes.FilActorId.unwrap(provider);
        lastReleasedBytes = sizeBytes;
    }

    function releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash) external {
        lastReleasedProvider = CommonTypes.FilActorId.unwrap(provider);
        lastReleasedBytes = sizeBytes;
        lastReleasedManifestHash = manifestHash;
    }

    function releasePendingCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes) external {
        lastReleasedPendingProvider = CommonTypes.FilActorId.unwrap(provider);
        lastReleasedPendingBytes = sizeBytes;
    }

    function releasePendingCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash)
        external
    {
        lastReleasedPendingProvider = CommonTypes.FilActorId.unwrap(provider);
        lastReleasedPendingBytes = sizeBytes;
        lastReleasedPendingManifestHash = manifestHash;
    }

    function commitCapacity(CommonTypes.FilActorId, uint256, uint256) external {}
    function pauseProvider(CommonTypes.FilActorId) external {}
    function unpauseProvider(CommonTypes.FilActorId) external {}
    function blockProvider(CommonTypes.FilActorId) external {}
    function unblockProvider(CommonTypes.FilActorId) external {}
    function updateAvailableSpace(CommonTypes.FilActorId, uint256) external {}
}

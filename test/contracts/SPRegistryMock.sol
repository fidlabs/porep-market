// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

// Real SPRegistry V2 disables that selector.

import {ISPRegistry} from "../../src/interfaces/ISPRegistry.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract SPRegistryMock is ISPRegistry {
    struct MockProviderState {
        address organization;
        address payee;
        bool paused;
        bool blocked;
    }

    struct MockCapacityState {
        uint256 availableBytes;
        uint256 committedBytes;
        uint256 pendingBytes;
    }

    SharedTypes.ProviderDealSelection public nextSelection;
    mapping(address => mapping(CommonTypes.FilActorId => bool)) public owners;
    address public defaultOwner = address(this);
    CommonTypes.FilActorId[] private _providers;
    mapping(uint64 => ProviderView) private _providerViews;
    mapping(uint64 => bool) private _registered;
    uint64 public lastReleasedPendingProvider;
    uint256 public lastReleasedPendingBytes;
    SharedTypes.DealRequest private _lastReserveRequest;
    uint64 public lastReleasedCapacityProvider;
    uint256 public lastReleasedCapacityBytes;
    bytes32 public lastReleasedCapacityManifestHash;
    bytes32 public lastReleasedPendingManifestHash;

    function setNextSelection(SharedTypes.ProviderDealSelection calldata selection) external {
        nextSelection = selection;
    }

    function getLastReserveRequest() external view returns (SharedTypes.DealRequest memory) {
        return _lastReserveRequest;
    }

    function registerProviderFor(
        CommonTypes.FilActorId provider,
        address organization,
        uint256 availableBytes,
        address payee
    ) external {
        address effectivePayee = payee == address(0) ? organization : payee;
        uint64 providerId = CommonTypes.FilActorId.unwrap(provider);
        _registered[providerId] = true;
        _providerViews[providerId] = ProviderView({
            provider: provider,
            organization: organization,
            payee: effectivePayee,
            paused: false,
            blocked: false,
            availableBytes: availableBytes,
            committedBytes: 0,
            pendingBytes: 0
        });
    }

    function setNextProvider(CommonTypes.FilActorId provider) external {
        nextSelection.provider = provider;
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

    function getProviderView(CommonTypes.FilActorId provider) external view returns (ProviderView memory) {
        uint64 providerId = CommonTypes.FilActorId.unwrap(provider);
        ProviderView memory view_ = _providerViews[providerId];
        if (CommonTypes.FilActorId.unwrap(view_.provider) == 0) {
            return ProviderView({
                provider: provider,
                organization: defaultOwner,
                payee: defaultOwner,
                paused: false,
                blocked: false,
                availableBytes: 0,
                committedBytes: 0,
                pendingBytes: 0
            });
        }
        return view_;
    }

    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool) {
        return _registered[CommonTypes.FilActorId.unwrap(provider)];
    }

    function addProviderToList(CommonTypes.FilActorId provider) external {
        _providers.push(provider);
        _registered[CommonTypes.FilActorId.unwrap(provider)] = true;
    }

    function setProviderState(CommonTypes.FilActorId provider, MockProviderState calldata info) external {
        uint64 providerId = CommonTypes.FilActorId.unwrap(provider);
        ProviderView storage view_ = _providerViews[providerId];
        view_.provider = provider;
        view_.organization = info.organization;
        view_.payee = info.payee;
        view_.paused = info.paused;
        view_.blocked = info.blocked;
    }

    function setCapacityState(CommonTypes.FilActorId provider, MockCapacityState calldata info) external {
        uint64 providerId = CommonTypes.FilActorId.unwrap(provider);
        ProviderView storage view_ = _providerViews[providerId];
        view_.provider = provider;
        view_.availableBytes = info.availableBytes;
        view_.committedBytes = info.committedBytes;
        view_.pendingBytes = info.pendingBytes;
    }

    function setPayee(CommonTypes.FilActorId provider, address payee) external {
        uint64 providerId = CommonTypes.FilActorId.unwrap(provider);
        _providerViews[providerId].provider = provider;
        _providerViews[providerId].payee = payee;
    }

    function previewProviderForDeal(SharedTypes.DealRequest calldata)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory)
    {
        return nextSelection;
    }

    function reserveProviderForDeal(SharedTypes.DealRequest calldata request)
        external
        returns (SharedTypes.ProviderDealSelection memory)
    {
        _lastReserveRequest = request;
        if (CommonTypes.FilActorId.unwrap(nextSelection.provider) == 0) revert ISPRegistry.NoOfferMatched();
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
        SharedTypes.OfferTerms calldata,
        SharedTypes.SLIThresholds calldata,
        SharedTypes.OfferPaymentInput[] calldata
    ) external pure returns (uint256) {
        return 0;
    }

    function setOfferActive(uint256, bool) external {}
    function setOfferPayment(uint256, address, bool, uint256) external {}

    function getOfferView(uint256 offerId, address paymentToken) external pure returns (OfferView memory) {
        return OfferView({
            offerId: offerId,
            provider: CommonTypes.FilActorId.wrap(0),
            active: false,
            terms: SharedTypes.OfferTerms({
                minSizeBytes: 0,
                maxSizeBytes: 0,
                minDurationEpochs: 0,
                maxDurationEpochs: 0
            }),
            slis: SharedTypes.SLIThresholds({
                retrievabilityBps: 0,
                bandwidthBytesPerSecond: 0,
                latencyMs: 0,
                indexingPct: 0
            }),
            paymentToken: paymentToken,
            paymentActive: false,
            pricePer32GiBPerMonth: 0
        });
    }

    function getOffersByProvider(CommonTypes.FilActorId) external pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function isManifestAssignedToProvider(bytes32, CommonTypes.FilActorId) external pure returns (bool) {
        return false;
    }

    function releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash) external {
        lastReleasedCapacityProvider = CommonTypes.FilActorId.unwrap(provider);
        lastReleasedCapacityBytes = sizeBytes;
        lastReleasedCapacityManifestHash = manifestHash;
    }

    function releasePendingCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash) external {
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

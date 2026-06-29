// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SharedTypes} from "../types/SharedTypes.sol";

/**
 * @title ISPRegistry
 * @notice Interface for storage provider registration, offers, matching, and capacity management
 */
interface ISPRegistry {
    /**
     * @notice Error thrown when no offer matches a deal request
     * @dev 0xde89fa00
     */
    error NoOfferMatched();

    /**
     * @notice Current provider registration and capacity data.
     * @param provider Provider actor ID.
     * @param organization Address that owns the provider registration.
     * @param payee Address receiving provider payments.
     * @param paused True when the provider is temporarily excluded from matching.
     * @param blocked True when the provider is administratively blocked.
     * @param availableBytes Total provider capacity available for deals.
     * @param committedBytes Capacity already committed to activated deals.
     * @param pendingBytes Capacity reserved by proposed deals.
     */
    struct ProviderView {
        CommonTypes.FilActorId provider;
        address organization;
        address payee;
        bool paused;
        bool blocked;
        uint256 availableBytes;
        uint256 committedBytes;
        uint256 pendingBytes;
    }

    /**
     * @notice Payment token policy.
     * @param allowed True when offers may use the token.
     * @param minPricePer32GiBPerMonth Minimum monthly price per 32 GiB in token smallest units.
     */
    struct TokenConfig {
        bool allowed;
        uint256 minPricePer32GiBPerMonth;
    }

    /**
     * @notice Current offer data plus the payment row for one token.
     * @param offerId Offer ID.
     * @param provider Provider actor ID that owns the offer.
     * @param active True when the offer participates in matching.
     * @param terms Offer size and duration bounds.
     * @param slis Promised offer SLIs.
     * @param paymentToken ERC20 token address used for the payment row.
     * @param paymentActive True when this token row can be selected.
     * @param pricePer32GiBPerMonth Monthly price per 32 GiB in token smallest units.
     */
    struct OfferView {
        uint256 offerId;
        CommonTypes.FilActorId provider;
        bool active;
        SharedTypes.OfferTerms terms;
        SharedTypes.SLIThresholds slis;
        address paymentToken;
        bool paymentActive;
        uint256 pricePer32GiBPerMonth;
    }

    /**
     * @notice Registers a provider on behalf of an organization (admin/operator only).
     * @param provider Miner actor ID to register.
     * @param organization Organization address that controls the provider.
     * @param availableBytes Initial available capacity in bytes.
     * @param payee Payout recipient; defaults to organization when zero.
     */
    function registerProviderFor(
        CommonTypes.FilActorId provider,
        address organization,
        uint256 availableBytes,
        address payee
    ) external;

    /**
     * @notice Returns all registered provider actor IDs.
     * @return Array of provider actor IDs.
     */
    function getProviders() external view returns (CommonTypes.FilActorId[] memory);

    /**
     * @notice Returns current provider registration and capacity data.
     * @param provider Provider actor ID.
     * @return view_ Current provider view.
     */
    function getProviderView(CommonTypes.FilActorId provider) external view returns (ProviderView memory view_);

    /**
     * @notice Checks whether a provider is registered.
     * @param provider Provider actor ID.
     * @return True when the provider is registered.
     */
    function isProviderRegistered(CommonTypes.FilActorId provider) external view returns (bool);

    /**
     * @notice Checks whether an address can manage or act for a provider.
     * @param caller Address to check.
     * @param provider Provider actor ID.
     * @return True when caller is admin, operator, or Filecoin controlling address.
     */
    function isAuthorizedForProvider(address caller, CommonTypes.FilActorId provider) external view returns (bool);

    /**
     * @notice Blocks a provider and excludes it from matching.
     * @param provider Provider actor ID.
     */
    function blockProvider(CommonTypes.FilActorId provider) external;

    /**
     * @notice Unblocks a provider.
     * @param provider Provider actor ID.
     */
    function unblockProvider(CommonTypes.FilActorId provider) external;

    /**
     * @notice Pauses a provider and excludes it from matching.
     * @param provider Provider actor ID.
     */
    function pauseProvider(CommonTypes.FilActorId provider) external;

    /**
     * @notice Unpauses a provider.
     * @param provider Provider actor ID.
     */
    function unpauseProvider(CommonTypes.FilActorId provider) external;

    /**
     * @notice Updates provider available capacity.
     * @param provider Provider actor ID.
     * @param availableBytes New available capacity in bytes.
     */
    function updateAvailableSpace(CommonTypes.FilActorId provider, uint256 availableBytes) external;

    /**
     * @notice Updates provider payment recipient.
     * @param provider Provider actor ID.
     * @param payee New payment recipient.
     */
    function setPayee(CommonTypes.FilActorId provider, address payee) external;

    /**
     * @notice Sets whether a payment token can be used by offers.
     * @param token ERC20 token address.
     * @param allowed True to allow the token, false to remove it from matching.
     * @param minPricePer32GiBPerMonth Minimum monthly price per 32 GiB in token smallest units.
     */
    function setPaymentToken(address token, bool allowed, uint256 minPricePer32GiBPerMonth) external;

    /**
     * @notice Returns allowed payment token addresses.
     * @return tokens Array of allowed token addresses.
     */
    function getPaymentTokens() external view returns (address[] memory tokens);

    /**
     * @notice Returns payment token policy.
     * @param token ERC20 token address.
     * @return config Token policy.
     */
    function getPaymentTokenConfig(address token) external view returns (TokenConfig memory config);

    /**
     * @notice Creates an active provider offer.
     * @param provider Provider actor ID.
     * @param terms Immutable offer size and duration bounds.
     * @param slis Immutable promised SLIs.
     * @param payments Initial payment rows.
     * @return offerId Created offer ID.
     */
    function createOffer(
        CommonTypes.FilActorId provider,
        SharedTypes.OfferTerms calldata terms,
        SharedTypes.SLIThresholds calldata slis,
        SharedTypes.OfferPaymentInput[] calldata payments
    ) external returns (uint256 offerId);

    /**
     * @notice Enables or disables an offer for matching.
     * @param offerId Offer ID.
     * @param active True to enable the offer, false to disable it.
     */
    function setOfferActive(uint256 offerId, bool active) external;

    /**
     * @notice Updates or adds a mutable offer payment row.
     * @param offerId Offer ID.
     * @param token ERC20 token address.
     * @param active True when the token row can be selected.
     * @param pricePer32GiBPerMonth Monthly price per 32 GiB in token smallest units.
     */
    function setOfferPayment(uint256 offerId, address token, bool active, uint256 pricePer32GiBPerMonth) external;

    /**
     * @notice Returns offer data plus the payment row for one token.
     * @param offerId Offer ID.
     * @param paymentToken ERC20 token address to read from the offer payment map.
     * @return view_ Current offer view for the requested payment token.
     */
    function getOfferView(uint256 offerId, address paymentToken) external view returns (OfferView memory view_);

    /**
     * @notice Returns all offer IDs created by a provider.
     * @param provider Provider actor ID.
     * @return offerIds Offer IDs for the provider.
     */
    function getOffersByProvider(CommonTypes.FilActorId provider) external view returns (uint256[] memory offerIds);

    /**
     * @notice Previews automatic offer matching without reserving capacity.
     * @param request Client deal request.
     * @return selection Selected offer snapshot, or zero provider when no offer matches.
     */
    function previewProviderForDeal(SharedTypes.DealRequest calldata request)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory selection);

    /**
     * @notice Selects an offer automatically and reserves pending provider capacity.
     * @param request Client deal request.
     * @return selection Selected offer snapshot.
     */
    function reserveProviderForDeal(SharedTypes.DealRequest calldata request)
        external
        returns (SharedTypes.ProviderDealSelection memory selection);

    /**
     * @notice Previews a specific offer for a deal without reserving capacity.
     * @param offerId Offer ID to validate.
     * @param request Client deal request.
     * @return selection Selected offer snapshot, or zero provider when the offer does not match.
     * @return reason OfferMatch reason code; OfferMatch.OK when the offer is eligible.
     */
    function previewOfferForDeal(uint256 offerId, SharedTypes.DealRequest calldata request)
        external
        view
        returns (SharedTypes.ProviderDealSelection memory selection, uint16 reason);

    /**
     * @notice Validates a specific offer and reserves pending provider capacity.
     * @param offerId Offer ID to validate.
     * @param request Client deal request.
     * @return selection Selected offer snapshot.
     */
    function reserveOfferForDeal(uint256 offerId, SharedTypes.DealRequest calldata request)
        external
        returns (SharedTypes.ProviderDealSelection memory selection);

    /**
     * @notice Checks whether a provider is already assigned to a manifest.
     * @param manifestHash Manifest hash used as data identity.
     * @param provider Provider actor ID.
     * @return True when provider is locked for the manifest.
     */
    function isManifestAssignedToProvider(bytes32 manifestHash, CommonTypes.FilActorId provider)
        external
        view
        returns (bool);

    /**
     * @notice Releases committed provider capacity and clears the manifest/provider assignment.
     * @param provider Provider actor ID.
     * @param sizeBytes Capacity to release.
     * @param manifestHash Manifest hash whose provider assignment should be cleared.
     */
    function releaseCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash) external;

    /**
     * @notice Releases pending provider capacity and clears the manifest/provider assignment.
     * @param provider Provider actor ID.
     * @param sizeBytes Pending capacity to release.
     * @param manifestHash Manifest hash whose provider assignment should be cleared.
     */
    function releasePendingCapacity(CommonTypes.FilActorId provider, uint256 sizeBytes, bytes32 manifestHash) external;

    /**
     * @notice Converts pending capacity into committed capacity.
     * @param provider Provider actor ID.
     * @param estimatedSizeBytes Pending bytes reserved by the deal request.
     * @param actualSizeBytes Actual activated bytes.
     */
    function commitCapacity(CommonTypes.FilActorId provider, uint256 estimatedSizeBytes, uint256 actualSizeBytes)
        external;
}

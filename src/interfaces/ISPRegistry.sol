// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SharedTypes} from "../types/SharedTypes.sol";
import {SLITypes} from "../types/SLITypes.sol";

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
     * @notice Provider registration data.
     * @param organization Address that owns the provider registration.
     * @param payee Address receiving provider payments.
     * @param paused True when the provider is temporarily excluded from matching.
     * @param blocked True when the provider is administratively blocked.
     */
    struct ProviderInfo {
        address organization;
        address payee;
        bool paused;
        bool blocked;
    }

    /**
     * @notice Provider capacity accounting.
     * @param availableBytes Total provider capacity available for deals.
     * @param committedBytes Capacity already committed to activated deals.
     * @param pendingBytes Capacity reserved by proposed deals.
     */
    struct ProviderCapacityInfo {
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
     * @notice Provider offer metadata.
     * @param provider Provider actor ID that owns the offer.
     * @param name Human-readable offer name.
     * @param active True when the offer participates in matching.
     */
    struct OfferInfo {
        CommonTypes.FilActorId provider;
        string name;
        bool active;
    }

    /**
     * @notice Payment row for one offer token.
     * @param active True when this token row can be selected.
     * @param pricePer32GiBPerMonth Monthly price per 32 GiB in token smallest units.
     */
    struct OfferPayment {
        bool active;
        uint256 pricePer32GiBPerMonth;
    }

    /**
     * @notice Returns all registered provider actor IDs.
     * @return Array of provider actor IDs.
     */
    function getProviders() external view returns (CommonTypes.FilActorId[] memory);

    /**
     * @notice Returns provider actor IDs with committed capacity.
     * @return Array of provider actor IDs where committedBytes is non-zero.
     */
    function getCommittedProviders() external view returns (CommonTypes.FilActorId[] memory);

    /**
     * @notice Returns all providers registered under an organization.
     * @param organization Organization address.
     * @return Array of provider actor IDs owned by the organization.
     */
    function getProvidersByOrganization(address organization) external view returns (CommonTypes.FilActorId[] memory);

    /**
     * @notice Returns provider registration data.
     * @param provider Provider actor ID.
     * @return info Provider registration data.
     */
    function getProviderInfo(CommonTypes.FilActorId provider) external view returns (ProviderInfo memory info);

    /**
     * @notice Returns provider capacity accounting.
     * @param provider Provider actor ID.
     * @return info Provider capacity data.
     */
    function getProviderCapacity(CommonTypes.FilActorId provider)
        external
        view
        returns (ProviderCapacityInfo memory info);

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
     * @notice Returns provider payment recipient.
     * @param provider Provider actor ID.
     * @return Provider payment recipient.
     */
    function getPayee(CommonTypes.FilActorId provider) external view returns (address);

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
     * @param name Human-readable offer name.
     * @param terms Immutable offer size and duration bounds.
     * @param slis Immutable promised SLIs.
     * @param payments Initial payment rows.
     * @return offerId Created offer ID.
     */
    function createOffer(
        CommonTypes.FilActorId provider,
        string calldata name,
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
     * @notice Updates mutable offer name.
     * @param offerId Offer ID.
     * @param name New human-readable offer name.
     */
    function setOfferName(uint256 offerId, string calldata name) external;

    /**
     * @notice Updates or adds a mutable offer payment row.
     * @param offerId Offer ID.
     * @param token ERC20 token address.
     * @param active True when the token row can be selected.
     * @param pricePer32GiBPerMonth Monthly price per 32 GiB in token smallest units.
     */
    function setOfferPayment(uint256 offerId, address token, bool active, uint256 pricePer32GiBPerMonth) external;

    /**
     * @notice Returns offer metadata.
     * @param offerId Offer ID.
     * @return info Offer metadata.
     */
    function getOffer(uint256 offerId) external view returns (OfferInfo memory info);

    /**
     * @notice Returns immutable offer size and duration bounds.
     * @param offerId Offer ID.
     * @return terms Offer terms.
     */
    function getOfferTerms(uint256 offerId) external view returns (SharedTypes.OfferTerms memory terms);

    /**
     * @notice Returns immutable promised offer SLIs.
     * @param offerId Offer ID.
     * @return slis Promised offer SLIs.
     */
    function getOfferSLIs(uint256 offerId) external view returns (SharedTypes.SLIThresholds memory slis);

    /**
     * @notice Returns payment row for an offer and token.
     * @param offerId Offer ID.
     * @param token ERC20 token address.
     * @return payment Offer payment row.
     */
    function getOfferPayment(uint256 offerId, address token) external view returns (OfferPayment memory payment);

    /**
     * @notice Returns all offer IDs created by a provider.
     * @param provider Provider actor ID.
     * @return offerIds Offer IDs for the provider.
     */
    function getOffersByProvider(CommonTypes.FilActorId provider) external view returns (uint256[] memory offerIds);

    /**
     * @notice Returns active offer IDs for a provider.
     * @param provider Provider actor ID.
     * @return offerIds Active offer IDs for the provider.
     */
    function getActiveOffersByProvider(CommonTypes.FilActorId provider)
        external
        view
        returns (uint256[] memory offerIds);

    /**
     * @notice Returns all active offer IDs.
     * @return offerIds Active offer IDs.
     */
    function getActiveOffers() external view returns (uint256[] memory offerIds);

    /**
     * @notice Disabled legacy PoRepMarket matching entrypoint kept for compile compatibility only.
     * @dev Real implementations revert until PoRepMarket migrates to the V2 reserve APIs. Do not use this method for V2 proposal creation.
     * @param requirements Required deal SLIs.
     * @param terms Legacy deal terms.
     * @return provider Unused legacy return slot.
     * @return autoApprove Unused legacy return slot.
     * @return organization Unused legacy return slot.
     */
    function getProviderForDeal(SharedTypes.SLIThresholds calldata requirements, SLITypes.DealTerms calldata terms)
        external
        returns (CommonTypes.FilActorId provider, bool autoApprove, address organization);

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

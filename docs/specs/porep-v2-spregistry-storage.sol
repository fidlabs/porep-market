// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// End location: SPRegistry storage
// Owns living provider configuration. Deals freeze what they need from it

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SharedTypes as Types} from "./porep-v2-shared-types.sol";

library SPRegistryStorageLayout {
    // Offer names are short service labels for clients and UI, not free-form descriptions
    uint256 internal constant MAX_OFFER_NAME_BYTES = 64;

    struct TokenConfig {
        bool allowed;
        uint256 minPricePer32GiBPerMonth; // Policy guard against tiny lockups
    }

    struct Provider {
        address organization; // Management/ownership address; may be shared across multiple providers under one entity
        address payee; // Payment destination for deal settlement; may differ for loan, beneficiary, or treasury arrangements
        bool paused;
        bool blocked;
    }

    struct ProviderCapacity {
        uint256 availableBytes;
        uint256 pendingBytes;
        uint256 committedBytes;
    }

    struct Offer {
        CommonTypes.FilActorId provider;
        string name; // SP-chosen service/offer name shown to clients
        bool active;
    }

    struct OfferTerms {
        uint256 minSizeBytes;
        uint256 maxSizeBytes;
        uint64 minDurationEpochs;
        uint64 maxDurationEpochs;
    }

    struct OfferPayment {
        bool active;
        uint256 pricePer32GiBPerMonth;
    }

    /// @custom:storage-location erc7201:porepmarket.storage.SPRegistry
    struct SPRegistryStorage {
        uint256 nextOfferId;
        uint256 maxOffersPerProvider;
        uint256 maxTokensPerOffer;

        EnumerableSet.UintSet providerIds;
        EnumerableSet.UintSet activeOfferIds; // Current market; historical offers stay readable by id
        EnumerableSet.AddressSet paymentTokens;

        mapping(address token => TokenConfig) tokenConfig;

        mapping(CommonTypes.FilActorId provider => Provider) providers;
        mapping(CommonTypes.FilActorId provider => ProviderCapacity) providerCapacity;

        mapping(CommonTypes.FilActorId provider => EnumerableSet.UintSet offerIds) offerIdsByProvider;
        mapping(CommonTypes.FilActorId provider => EnumerableSet.UintSet offerIds) activeOfferIdsByProvider;

        mapping(uint256 offerId => Offer) offers;
        mapping(uint256 offerId => OfferTerms) offerTerms;
        mapping(uint256 offerId => Types.SLITerms) offerSLIs;

        mapping(uint256 offerId => mapping(address token => OfferPayment)) offerPayments;
        mapping(uint256 offerId => EnumerableSet.AddressSet tokens) offerPaymentTokens; // Current tokens; history is events
    }
}

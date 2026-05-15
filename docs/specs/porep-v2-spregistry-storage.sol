// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY.
// End location: SPRegistry storage.

import {PoRepV2TypesSpec as V2} from "./porep-v2-shared-types.sol";

library PoRepV2SPRegistryStorageSpec {
    /// @custom:storage-location erc7201:porepmarket.storage.SPRegistry
    struct SPRegistryStorage {
        uint256 nextOfferId;

        V2.FilActorId[] providerIds;
        mapping(V2.FilActorId provider => V2.Provider) providers;
        mapping(V2.FilActorId provider => V2.ProviderCapacity) providerCapacity;
        mapping(address owner => V2.FilActorId[] providers) providerIdsByOwner;

        address[] allowedPaymentTokens;
        mapping(address token => bool allowed) paymentTokenAllowed;
        mapping(address token => uint256 indexPlusOne) paymentTokenIndexPlusOne;

        mapping(uint256 offerId => V2.Offer) offers;
        mapping(uint256 offerId => V2.OfferTerms) offerTerms;
        mapping(V2.FilActorId provider => uint256[] offerIds) offerIdsByProvider;

        mapping(uint256 offerId => address[] tokens) offerPaymentTokens;
        mapping(uint256 offerId => mapping(address token => uint256 indexPlusOne)) offerPaymentTokenIndexPlusOne;
        mapping(uint256 offerId => mapping(address token => V2.OfferPayment)) offerPayments;

        mapping(address market => bool allowed) marketContracts;
    }
}

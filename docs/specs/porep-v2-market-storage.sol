// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY.
// End location: PoRepMarket storage.

import {PoRepV2TypesSpec as V2} from "./porep-v2-shared-types.sol";

library PoRepV2MarketStorageSpec {
    /// @custom:storage-location erc7201:porepmarket.storage.PoRepMarket
    struct PoRepMarketStorage {
        uint256 nextDealId;
        uint64 proposalExpiryEpochs;

        address spRegistry;
        address validatorFactory;
        address clientContract;

        mapping(uint256 dealId => V2.Deal) deals;
        mapping(uint256 dealId => V2.DealTerms) dealTerms;
        mapping(uint256 dealId => V2.DealCapacity) dealCapacity;
        mapping(uint256 dealId => V2.DealPayment) dealPayments;
        mapping(uint256 dealId => V2.SLITerms) dealSLIs;
        mapping(uint256 dealId => string manifestLocation) dealManifestLocations;

        mapping(address client => uint256[] dealIds) dealIdsByClient;
        mapping(V2.FilActorId provider => uint256[] dealIds) dealIdsByProvider;
        mapping(V2.DealState state => uint256[] dealIds) dealIdsByState;
    }
}

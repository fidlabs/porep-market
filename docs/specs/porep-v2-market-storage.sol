// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// End location: PoRepMarket storage
// Owns frozen deal snapshots, lifecycle, service timing, and deal indexes

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SharedTypes as Types} from "./porep-v2-shared-types.sol";

library DealState {
    uint8 internal constant NONE = 0;
    uint8 internal constant PROPOSED = 10;
    uint8 internal constant ACCEPTED = 20;
    uint8 internal constant ACTIVE = 30;
    uint8 internal constant FINALIZED = 40;
    uint8 internal constant REJECTED = 50;
    uint8 internal constant EXPIRED = 60;
    uint8 internal constant TERMINATED = 70;
}

library MarketStorageLayout {
    struct Deal {
        address client;
        CommonTypes.FilActorId provider;
        uint256 offerId;
        uint8 state;
        address evidenceAdapter;
        address validator;
        uint256 railId;
    }

    struct DealTerms {
        uint256 requestedSizeBytes;
        uint64 durationEpochs; // Frozen paid service duration
    }

    struct DealTiming {
        CommonTypes.ChainEpoch proposedAtEpoch; // Proposal/expiry timing, not service timing
        CommonTypes.ChainEpoch expiresAtEpoch; // After this, pending capacity can be released
    }

    struct DealService {
        CommonTypes.ChainEpoch serviceStartEpoch; // Set on activation
        CommonTypes.ChainEpoch serviceEndEpoch; // Derived from start + duration
    }

    struct DealCapacity {
        uint256 reservedBytes;
        uint256 committedBytes;
    }

    struct DealPayment {
        address paymentToken;
        address payee;
        uint256 pricePer32GiBPerMonth; // Commercial price frozen from offer
        uint256 billed32GiBUnits; // Frozen once payment starts
        uint256 railMaxRatePerEpoch; // FilecoinPay ceiling rate, not earned rate
    }

    /// @custom:storage-location erc7201:porepmarket.storage.PoRepMarket
    struct PoRepMarketStorage {
        uint256 nextDealId;
        CommonTypes.ChainEpoch proposalExpiryEpochs;

        address spRegistry;
        address validatorFactory;

        // Adapter trust is a payment-gate decision, so deals choose only from this set.
        mapping(address adapter => bool) allowedEvidenceAdapters;

        mapping(uint256 dealId => Deal) deals;
        mapping(uint256 dealId => Types.DealData) dealData;
        mapping(uint256 dealId => DealTerms) dealTerms;
        mapping(uint256 dealId => DealTiming) dealTiming;
        mapping(uint256 dealId => DealService) dealService;
        mapping(uint256 dealId => DealCapacity) dealCapacity;
        mapping(uint256 dealId => DealPayment) dealPayments;
        mapping(uint256 dealId => Types.SLITerms) dealSLIs;

        mapping(address client => EnumerableSet.UintSet dealIds) dealIdsByClient;
        mapping(CommonTypes.FilActorId provider => EnumerableSet.UintSet dealIds) dealIdsByProvider;
        mapping(uint8 state => EnumerableSet.UintSet dealIds) dealIdsByState;
    }
}

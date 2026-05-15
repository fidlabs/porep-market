// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// End location: PoRepMarket storage
// Owns frozen deal snapshots, lifecycle, service timing, and deal indexes

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {PoRepV2TypesSpec as V2} from "./porep-v2-shared-types.sol";

library PoRepV2MarketStorageSpec {
    // Persist states as uint8 constants so future states can be appended without
    // reshaping storage
    uint8 internal constant DEAL_STATE_NONE = 0; // Uninitialized sentinel
    uint8 internal constant DEAL_STATE_PROPOSED = 1; // Capacity reserved; service not started
    uint8 internal constant DEAL_STATE_ACCEPTED = 2; // Provider accepted; waiting for completion
    uint8 internal constant DEAL_STATE_COMPLETED = 3; // Service/payment window started
    uint8 internal constant DEAL_STATE_REJECTED = 4; // Ended before service start
    uint8 internal constant DEAL_STATE_EXPIRED = 5; // Timed out before service start
    uint8 internal constant DEAL_STATE_TERMINATED = 6; // Started deal ended early

    struct Deal {
        address client;
        CommonTypes.FilActorId provider;
        uint256 offerId;
        uint8 state;
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
        CommonTypes.ChainEpoch serviceStartEpoch; // Set on completion
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
        address clientContract;

        mapping(uint256 dealId => Deal) deals;
        mapping(uint256 dealId => DealTerms) dealTerms;
        mapping(uint256 dealId => DealTiming) dealTiming;
        mapping(uint256 dealId => DealService) dealService;
        mapping(uint256 dealId => DealCapacity) dealCapacity;
        mapping(uint256 dealId => DealPayment) dealPayments;
        mapping(uint256 dealId => V2.SLITerms) dealSLIs;
        mapping(uint256 dealId => string manifestLocation) dealManifestLocations;

        mapping(address client => EnumerableSet.UintSet dealIds) dealIdsByClient;
        mapping(CommonTypes.FilActorId provider => EnumerableSet.UintSet dealIds) dealIdsByProvider;
        mapping(uint8 state => EnumerableSet.UintSet dealIds) dealIdsByState;
    }
}

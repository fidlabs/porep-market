// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY.
// Shared V2 types used by the per-contract storage and interface sketches.

library PoRepV2TypesSpec {
    uint256 internal constant EPOCHS_IN_DAY = 2_880;
    uint256 internal constant EPOCHS_IN_MONTH = 86_400;

    type FilActorId is uint64;
    type ChainEpoch is int64;

    enum DealState {
        Proposed,
        Accepted,
        Completed,
        Rejected,
        Expired,
        Terminated
    }

    struct Provider {
        address owner;
        address payee;
        bool paused;
        bool blocked;
    }

    struct ProviderCapacity {
        uint256 totalBytes;
        uint256 pendingBytes;
        uint256 committedBytes;
    }

    struct Offer {
        FilActorId provider;
        bool active;
        uint64 createdAt;
        uint64 updatedAt;
    }

    struct OfferTerms {
        uint256 minPieceSizeBytes;
        uint256 maxPieceSizeBytes;
        uint64 minDurationEpochs;
        uint64 maxDurationEpochs;
        SLITerms slis;
    }

    struct OfferPayment {
        bool active;
        uint256 pricePer32GiBPerMonth;
    }

    struct Deal {
        address client;
        FilActorId provider;
        uint256 offerId;
        DealState state;
        ChainEpoch proposedAtEpoch;
        ChainEpoch expiresAtEpoch;
        address validator;
        uint256 railId;
    }

    struct DealTerms {
        uint256 requestedSizeBytes;
        uint64 durationDays;
        uint64 durationEpochs;
        ChainEpoch serviceStartEpoch;
        ChainEpoch serviceEndEpoch;
    }

    struct DealCapacity {
        uint256 reservedBytes;
        uint256 committedBytes;
        uint256 billed32GiBUnits;
    }

    struct DealPayment {
        address paymentToken;
        address payee;
        uint256 pricePer32GiBPerMonth;
        uint256 agreedMonthlyTotal;
        uint256 railMaxRatePerEpoch;
    }

    struct SLITerms {
        uint16 retrievabilityBps;
        uint64 bandwidthBytesPerSecond;
        uint32 latencyMilliseconds;
        uint16 indexingAvailabilityBps;
    }
}

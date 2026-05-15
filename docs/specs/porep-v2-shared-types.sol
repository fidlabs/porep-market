// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// Shared request/selection vocabulary. Storage and external views live in their
// owning contract sketches

library PoRepV2TypesSpec {
    uint256 internal constant EPOCHS_IN_DAY = 2_880;
    uint256 internal constant EPOCHS_IN_MONTH = 86_400;

    struct SLITerms {
        uint16 retrievabilityBps;
        // Reconsider when measurement/enforcement tooling exists
        // uint64 bandwidthBytesPerSecond;
        // uint32 latencyMilliseconds;
        // uint16 indexingAvailabilityBps;
    }

    struct DealRequest {
        address paymentToken;
        uint256 requestedSizeBytes;
        uint32 durationDays; // Client-facing input; converted once before storage
        uint256 maxPricePer32GiBPerMonth;
        SLITerms requiredSLIs;
    }

    // Selection is offer-centric. The market resolves provider/payee and freezes
    // them into the deal snapshot
    struct OfferSelection {
        uint256 offerId;
        address paymentToken;
        uint256 pricePer32GiBPerMonth;
        SLITerms promisedSLIs;
    }
}

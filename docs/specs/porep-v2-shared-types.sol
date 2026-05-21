// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// Shared request/selection vocabulary. Storage and external views live in their
// owning contract sketches

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

library SharedTypes {
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
        // keccak256(manifest file bytes).
        bytes32 pieceSetCommitment;
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

    struct DealData {
        bytes32 pieceSetCommitment;
        // URL or path for humans/tools; contracts do not fetch or trust it.
        string manifestLocation;
    }

    struct ActivationContext {
        uint256 dealId;
        address client;
        CommonTypes.FilActorId provider;
        bytes32 pieceSetCommitment;
        uint256 requestedSizeBytes;
        uint64 durationEpochs;
    }

    struct ActivationDecision {
        uint8 result;
        // Accepted bytes from adapter-checked allocation/claim evidence.
        uint256 coveredBytes;
        uint16 reasonCode;
    }

    struct SettlementDecision {
        uint8 result;
        uint256 settlementAmount;
        CommonTypes.ChainEpoch settleUptoEpoch;
        uint16 reasonCode;
    }
}

library EvidenceType {
    uint8 internal constant NONE = 0;
    uint8 internal constant VERIF_REG_CLAIMS = 10;
}

library EvidenceResult {
    uint8 internal constant NONE = 0;
    uint8 internal constant ACCEPTED = 10;
    uint8 internal constant REJECTED = 20;
}

library RailStatus {
    uint8 internal constant NONE = 0;
    // Rail is authorized and ready, but payment cannot accrue until storage activates.
    uint8 internal constant PREPARED = 10;
    uint8 internal constant ACTIVE = 20;
}

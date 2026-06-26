// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// TODO: delete before release
// Shared request/selection vocabulary. Storage and external views live in their
// owning contract sketches

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

library SharedTypes {
    uint256 internal constant EPOCHS_IN_DAY = 2_880;
    uint256 internal constant EPOCHS_IN_MONTH = 86_400;

    struct SLIThresholds {
        uint16 retrievabilityBps;
        uint64 bandwidthBytesPerSecond;
        uint16 latencyMs;
        uint8 indexingPct;
    }

    struct DealRequest {
        // keccak256(manifest file bytes).
        bytes32 manifestHash;
        uint256 requestedSizeBytes;
        uint256 maxPricePer32GiBPerMonth;
        // URL or path for humans/tools; contracts do not fetch or trust it.
        string manifestLocation;
        address paymentToken;
        uint32 durationDays; // Client-facing input; converted once before storage
        SLIThresholds requiredSLIs;
    }

    // Selection is provider-and-offer centric. PoRepMarket freezes the returned
    // provider, offer, payment token, payee, price, SLIs, and reserved bytes into
    // the deal snapshot.
    struct ProviderDealSelection {
        CommonTypes.FilActorId provider;
        uint256 offerId;
        address paymentToken;
        address payee;
        uint256 pricePer32GiBPerMonth;
        SLIThresholds promisedSLIs;
        uint256 reservedBytes;
    }

    struct DealData {
        bytes32 manifestHash;
        // URL or path for humans/tools; contracts do not fetch or trust it.
        string manifestLocation;
    }

    struct ActivationContext {
        uint256 dealId;
        uint256 requestedSizeBytes;
        address client;
        uint64 durationEpochs;
        uint16 activationToleranceBps;
        CommonTypes.FilActorId provider;
    }

    struct ActivationDecision {
        uint8 result;
        // Accepted bytes from adapter-checked allocation/claim evidence.
        uint256 coveredBytes;
        uint16 reasonCode;
    }

    struct EvidenceStatus {
        uint8 result;
        // Currently active bytes from adapter-checked evidence.
        uint256 activeCoveredBytes;
        CommonTypes.ChainEpoch lastEvidenceRefreshEpoch;
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
    // FilecoinPay rail termination has been observed by Validator and settlement
    // is capped at earlyTerminatedEpoch.
    uint8 internal constant TERMINATED = 100;
}

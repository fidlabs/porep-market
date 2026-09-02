// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

/**
 * @title Shared Types
 * @notice Common types used across multiple PoRepMarket contracts
 */
library SharedTypes {
    /**
     * @notice Number of epochs in one day
     * @dev 24 hours/day * 60 minutes/hour * 2 epochs/minute = 2_880 epochs
     */
    uint256 internal constant EPOCHS_IN_DAY = 2_880;

    uint256 internal constant EPOCHS_IN_MONTH = EPOCHS_IN_DAY * 30;

    /**
     * @notice Designated sentinel meaning "latency was not measured"
     * @dev Never a valid attested latency. Attestations carrying it (or 0) are rejected by SLIOracle
     *      and never scored as meeting a latency SLA by SLIScorer.
     */
    uint16 internal constant LATENCY_UNMEASURED = type(uint16).max;

    /**
     * @notice Unified SLI thresholds for requirements, capabilities, and attestations
     * @dev STRUCT EXTENSION PROTOCOL:
     *      - This struct may be extended by appending new fields
     *      - New fields MUST be added at the end only
     *      - Field value of 0 means "do not evaluate this dimension"
     *      - Existing field order and types MUST NOT change
     *      - Contracts MUST handle 0 values as "don't care" in comparisons
     *
     * @dev Storage compatibility:
     *      - Old data reads 0 for new fields (uninitialized storage)
     *      - Old deals automatically skip new SLI dimensions
     *
     * @dev Extension example:
     *      V1: { retrievabilityBps, bandwidthBytesPerSecond, latencyMs }
     *      Extended: { retrievabilityBps, bandwidthBytesPerSecond, latencyMs, indexingPct }
     */
    // forge-lint: disable-next-line(pascal-case-struct)
    struct SLIThresholds {
        /// @dev Valid range: 0-10000 (basis points, e.g. 7550 = 75.50%). 0 means "don't care".
        uint16 retrievabilityBps;
        uint64 bandwidthBytesPerSecond;
        /// @dev In requirements/capabilities 0 means "don't care". In attestations a measurement is
        ///      mandatory: 0 (unset) and {LATENCY_UNMEASURED} are invalid and never satisfy an SLA.
        uint16 latencyMs;
        /// @dev Valid range: 0-100. 0 means "don't care".
        uint8 indexingPct;
    }

    /**
     * @notice DealRequest struct represents the client's request for a storage deal
     * @param manifestHash commitment for piece set
     * @param requestedSizeBytes requested data size in bytes
     * @param maxPricePer32GiBPerMonth maximum price per 32GiB per month
     * @param manifestLocation location of the deal manifest
     * @param paymentToken token used for payments
     * @param durationDays requested deal duration in days
     * @param dealType type of deal requested
     * @param requiredSLIs required service-level indicators
     */
    struct DealRequest {
        bytes32 manifestHash;
        uint256 requestedSizeBytes;
        uint256 maxPricePer32GiBPerMonth;
        string manifestLocation;
        address paymentToken;
        uint32 durationDays; // Client-facing input; converted once before storage
        uint8 dealType;
        SLIThresholds requiredSLIs;
    }

    /**
     * @notice Provider offer terms that define immutable offer shape
     * @param minSizeBytes Minimum request size accepted by the offer
     * @param maxSizeBytes Maximum request size accepted by the offer (0 = no maximum)
     * @param minDurationEpochs Minimum paid service duration in epochs (0 = no minimum)
     * @param maxDurationEpochs Maximum paid service duration in epochs (0 = no maximum)
     */
    struct OfferTerms {
        uint256 minSizeBytes;
        uint256 maxSizeBytes;
        uint64 minDurationEpochs;
        uint64 maxDurationEpochs;
    }

    /**
     * @notice Payment row for an offer and ERC20 token
     * @param token ERC20 token address
     * @param active True when this token row can be selected
     * @param pricePer32GiBPerMonth Monthly price per 32 GiB in token smallest units
     */
    struct OfferPaymentInput {
        address token;
        bool active;
        uint256 pricePer32GiBPerMonth;
    }

    /**
     * @notice Selected offer snapshot returned by SPRegistry
     * @param provider Selected storage provider actor ID
     * @param offerId Selected offer ID
     * @param paymentToken ERC20 token selected for the deal
     * @param payee Provider-level payment recipient frozen into the deal
     * @param pricePer32GiBPerMonth Monthly price frozen into the deal
     * @param promisedSLIs SLI terms promised by the selected offer
     * @param reservedBytes Bytes reserved by the request
     */
    struct ProviderDealSelection {
        CommonTypes.FilActorId provider;
        uint256 offerId;
        address paymentToken;
        address payee;
        uint256 pricePer32GiBPerMonth;
        SLIThresholds promisedSLIs;
        uint256 reservedBytes;
    }

    /**
     * @notice DealData struct represents the data associated with a deal
     * @param manifestHash commitment for piece set
     * @param manifestLocation URL or path for humans/tools; contracts do not fetch or trust it.
     */
    struct DealData {
        bytes32 manifestHash;
        // URL or path for humans/tools; contracts do not fetch or trust it.
        string manifestLocation;
    }

    /**
     * @notice Frozen deal facts PoRepMarket passes to the selected adapter
     * @param dealId ID of the deal
     * @param requestedSizeBytes Requested data size in bytes
     * @param client Deal client
     * @param durationEpochs Requested deal duration in epochs
     * @param activationToleranceBps Allowed activation shortfall in basis points
     * @param provider ID of the provider
     */
    struct ActivationContext {
        uint256 dealId;
        uint256 requestedSizeBytes;
        address client;
        uint64 durationEpochs;
        uint16 activationToleranceBps;
        CommonTypes.FilActorId provider;
    }

    /**
     * @notice Adapter result used by PoRepMarket to decide whether a deal can activate
     * @param coveredBytes Bytes covered by the checked storage facts
     * @param reasonCode Adapter-specific reason code
     * @param result Activation result code
     */
    struct ActivationDecision {
        uint256 coveredBytes;
        uint16 reasonCode;
        uint8 result;
    }

    /**
     * @notice Adapter status used by PoRepMarket during settlement
     * @param activeCoveredBytes Bytes still covered by the last completed check
     * @param lastEvidenceRefreshEpoch Epoch of the last completed check
     * @param reasonCode Adapter-specific reason code
     * @param result Current result code
     * @param checkedClaims Claims checked in the current refresh sweep
     * @param totalClaims Claims that must be checked for the deal
     */
    struct EvidenceStatus {
        uint256 activeCoveredBytes;
        CommonTypes.ChainEpoch lastEvidenceRefreshEpoch;
        uint16 reasonCode;
        uint8 result;
        uint256 checkedClaims;
        uint256 totalClaims;
    }

    /**
     * @notice SettlementDecision struct represents the decision for deal settlement
     * @param settlementAmount amount to be settled based on evidence and deal terms
     * @param settleUpto epoch up to which the settlement is calculated
     * @param reasonCode code representing the reason for the settlement decision
     * @param result settlement result code
     */
    struct SettlementDecision {
        uint256 settlementAmount;
        uint256 settleUpto;
        uint16 reasonCode;
        uint8 result;
        string note;
    }

    /**
     * @notice Represents an attestation record for SLI (Service Level Indicator) tracking
     * @dev Stores the timestamp of the last update and the associated SLI thresholds
     */
    struct Attestation {
        uint256 lastUpdate;
        SLIThresholds slis;
    }
}

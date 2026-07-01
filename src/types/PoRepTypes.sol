// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SharedTypes} from "./SharedTypes.sol";

/**
 * @title PoRepMarket Types
 * @notice Shared types for PoRepMarket deals and states
 */
library PoRepTypes {
    /**
     * @notice Maximum Filecoin storage deal duration: 1278 days (~3.5 years),
     * per FIP-0052 (NV21 actor policy update).
     * References:
     * https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0052.md
     * https://github.com/filecoin-project/core-devs/blob/master/Network%20Upgrades/v21.md
     */
    uint32 internal constant MAX_DEAL_DURATION_DAYS = 1278;

    /**
     * @notice Core deal snapshot and lifecycle fields.
     */
    struct Deal {
        uint256 dealId;
        address client;
        CommonTypes.FilActorId provider;
        uint256 offerId;
        uint8 state;
        address evidenceAdapter;
        address validator;
        uint256 railId;
    }

    /**
     * @notice Frozen size and duration terms for a deal.
     */
    struct DealTerms {
        uint256 requestedSizeBytes;
        uint64 durationEpochs;
    }

    /**
     * @notice Proposal timing for expiry-related checks.
     */
    struct DealTiming {
        CommonTypes.ChainEpoch proposedAtEpoch;
        CommonTypes.ChainEpoch expiresAtEpoch;
    }

    /**
     * @notice Service window established when storage activates.
     */
    struct DealService {
        CommonTypes.ChainEpoch serviceStartEpoch;
        CommonTypes.ChainEpoch serviceEndEpoch;
        CommonTypes.ChainEpoch earlyTerminationEpoch;
        uint256 minTimeBetweenSettlementsInEpochs;
        CommonTypes.ChainEpoch lastSettledEpoch;
    }

    /**
     * @notice Capacity reserved by proposal and committed at activation.
     */
    struct DealCapacity {
        uint256 reservedBytes;
        uint256 committedBytes;
    }

    /**
     * @notice Payment terms and rail accounting values frozen for a deal.
     */
    struct DealPayment {
        address paymentToken;
        address payee;
        uint256 pricePer32GiBPerMonth;
        uint256 billed32GiBUnits;
        uint256 railMaxRatePerEpoch;
    }

    /**
     * @notice Payment fields exposed through DealView.
     */
    struct DealViewPayment {
        address paymentToken;
        uint256 pricePer32GiBPerMonth;
        uint256 billed32GiBUnits;
        uint256 railMaxRatePerEpoch;
    }

    /**
     * @notice Complete generic read model for one PoRepMarket deal.
     * @dev This is for offchain tools, oracles, CLIs, and RPC consumers that need
     * PoRepMarket-owned or PoRepMarket-frozen deal facts in one bounded response.
     * It is not an adapter inventory API: allocation IDs, claim IDs, raw evidence
     * rows, and adapter-specific progress stay on the selected evidence adapter.
     * @param deal Core deal identity, actors, state, adapter, validator, and rail ID.
     * @param data Manifest hash and location stored for the deal.
     * @param requiredSLIs SLI thresholds required by the client.
     * @param terms Frozen size and duration terms.
     * @param timing Proposal and expiry epochs.
     * @param service Service start and end epochs.
     * @param capacity Reserved and committed bytes.
     * @param payment Frozen payment token, price, billing units, and rail ceiling.
     * @param providerOrganization Organization selected for the provider at proposal time.
     * @param evidenceStatus Adapter-local stored evidence status; this view does not refresh Filecoin actor state.
     */
    struct DealView {
        Deal deal;
        SharedTypes.DealData data;
        SharedTypes.SLIThresholds requiredSLIs;
        DealTerms terms;
        DealTiming timing;
        DealService service;
        DealCapacity capacity;
        DealViewPayment payment;
        address providerOrganization;
        SharedTypes.EvidenceStatus evidenceStatus;
    }
}

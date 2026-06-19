// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

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
     * @notice DealState enum
     * @dev Represents the various states a deal can be
     */
    enum DealState {
        Proposed,
        Accepted,
        Completed,
        Rejected,
        Terminated
    }

    /**
     * @notice Core deal snapshot and lifecycle fields.
     */
    struct Deal {
        uint256 dealId;
        address client;
        CommonTypes.FilActorId provider;
        uint256 offerId;
        DealState state;
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
}

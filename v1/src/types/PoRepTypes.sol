// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SLITypes} from "./SLITypes.sol";

/**
 * @title PoRepMarket Types
 * @notice Shared types for PoRepMarket deal proposals and states
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
     * @notice DealProposal struct
     * @dev Represents a proposal for a PoRep deal, including all relevant details and terms
     *      dealId: Unique identifier for the deal
     *      client: Address of the client proposing the deal
     *      provider: FilActor ID of the storage provider
     *      requirements: SLI thresholds that the provider must meet for the deal
     *      terms: Commercial terms of the deal, such as size, price, and duration
     *      validator: Address of the validator responsible for validating the deal
     *      state: Current state of the deal (Proposed, Accepted, Completed, Rejected, Terminated)
     *      railId: ID of the payment rail associated with the deal
     *      proposedAtBlock: Block number when the deal was proposed
     *      manifestLocation: Location of the deal manifest
     */
    struct DealProposal {
        uint256 dealId;
        address client;
        CommonTypes.FilActorId provider;
        SLITypes.SLIThresholds requirements;
        SLITypes.DealTerms terms;
        address validator;
        DealState state;
        uint256 railId;
        uint256 proposedAtBlock;
        string manifestLocation;
    }
}

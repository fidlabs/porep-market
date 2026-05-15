// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY.
// End location: Validator storage.

import {PoRepV2TypesSpec as V2} from "./porep-v2-shared-types.sol";

library PoRepV2ValidatorStorageSpec {
    /// @custom:storage-location erc7201:porepmarket.storage.Validator
    struct ValidatorStorage {
        address market;
        address filecoinPay;
        address sliScorer;
        address clientContract;

        uint256 dealId;
        uint256 railId;

        V2.FilActorId provider;
        V2.ChainEpoch paymentStartEpoch;
        V2.ChainEpoch serviceEndEpoch;
        V2.ChainEpoch earlyTerminatedEpoch;

        uint256 railMaxRatePerEpoch;
        uint256 agreedMonthlyTotal;
        uint256 minEpochsBetweenSettlements;
    }
}

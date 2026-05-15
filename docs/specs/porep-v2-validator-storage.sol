// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// End location: Validator storage
// Starts with rail identity only. Deal/payment truth stays in PoRepMarket

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

library PoRepV2ValidatorStorageSpec {
    /// @custom:storage-location erc7201:porepmarket.storage.Validator
    struct ValidatorStorage {
        address market;
        address filecoinPay;
        address sliScorer;
        address clientContract;

        uint256 dealId;
        uint256 railId;
        CommonTypes.ChainEpoch earlyTerminatedEpoch;
        uint256 minSettlementEpochs;
    }
}

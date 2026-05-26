// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// Validator asks the market for settlement amounts. It does not read DataCap
// allocation IDs, claim IDs, or live VerifReg state.

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SharedTypes as Types} from "./porep-v2-shared-types.sol";

interface IPoRepMarketSettlement {
    function refreshEvidenceStatus(uint256 dealId, bytes calldata evidenceData)
        external
        returns (Types.EvidenceStatus memory status);

    function validateDealSettlement(uint256 dealId, CommonTypes.ChainEpoch fromEpoch, CommonTypes.ChainEpoch toEpoch)
        external
        returns (Types.SettlementDecision memory decision);
}

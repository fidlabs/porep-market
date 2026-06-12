// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SharedTypes} from "../types/SharedTypes.sol";

/**
 * @title IPoRepMarketSettlement interface
 * @notice IPoRepMarketSettlement interface used by the Validator to drive settlement
 */
interface IPoRepMarketSettlement {
    /**
     * @notice Refreshes a deal's cached storage-evidence status through its selected adapter
     * @param dealId The id of the deal to refresh
     * @param evidenceData Opaque, adapter-specific batch selecting which evidence to verify
     * @return status The refreshed evidence status after the adapter verifies Filecoin state
     */
    function refreshEvidenceStatus(uint256 dealId, bytes calldata evidenceData)
        external
        returns (SharedTypes.EvidenceStatus memory status);

    /**
     * @notice Returns the settlement decision for a deal over the requested epoch window
     * @param dealId The id of the deal to settle
     * @param fromEpoch The epoch up to and including which the rail has already been settled
     * @param toEpoch The epoch up to and including which settlement is requested
     * @return decision The settlement decision, including amount and settle-up-to epoch
     */
    function validateDealSettlement(uint256 dealId, CommonTypes.ChainEpoch fromEpoch, CommonTypes.ChainEpoch toEpoch)
        external
        returns (SharedTypes.SettlementDecision memory decision);
}

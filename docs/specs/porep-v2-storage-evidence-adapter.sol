// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// Interface PoRepMarket uses to submit and activate storage evidence. DataCap /
// VerifReg is one implementation behind this interface.

import {SharedTypes as Types} from "./porep-v2-shared-types.sol";

interface IStorageEvidenceAdapter {
    function evidenceType() external view returns (uint8);

    // Returns false when the adapter can no longer process new evidence (e.g.,
    // DataCap adapter after FIP-1249 blocks new allocations/claims). Used by
    // the market to allow admin rejection of stuck deals on a dead adapter.
    function isOperational() external view returns (bool);

    function submitEvidenceBatch(Types.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (Types.ActivationDecision memory decision);

    function activateEvidence(Types.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (Types.ActivationDecision memory decision);
}

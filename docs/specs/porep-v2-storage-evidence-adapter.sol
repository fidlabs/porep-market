// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// Interface PoRepMarket uses to submit and activate storage evidence. DataCap /
// VerifReg is one implementation behind this interface.

import {SharedTypes as Types} from "./porep-v2-shared-types.sol";

interface IStorageEvidenceAdapter {
    function evidenceType() external view returns (uint8);

    function submitEvidenceBatch(Types.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (Types.ActivationDecision memory decision);

    function activateEvidence(Types.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (Types.ActivationDecision memory decision);
}

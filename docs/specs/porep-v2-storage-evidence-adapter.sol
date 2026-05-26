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

    // Submit one bounded batch of adapter-specific evidence for a deal.
    // evidenceData is opaque to PoRepMarket; the selected adapter defines,
    // decodes, and validates it. For DataCap / VerifReg, evidenceData identifies
    // allocation IDs that should now have matching claims; the adapter verifies
    // them with GetClaims(provider, ids) before increasing covered bytes.
    function submitEvidenceBatch(Types.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (Types.ActivationDecision memory decision);

    // Return the adapter's activation decision after submitted evidence covers
    // enough bytes for the frozen deal. This function does not set payment terms;
    // PoRepMarket consumes the returned covered bytes and derives committed
    // bytes, billed units, service start/end, rail ceiling, and deal state.
    function activateEvidence(Types.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (Types.ActivationDecision memory decision);

    // Refresh current evidence health from adapter-specific source data. The
    // caller supplies only the bounded batch to check; the adapter verifies state
    // itself before updating stored active covered bytes. A successful refresh
    // records the latest epoch through which evidence can support settlement. For
    // DataCap / VerifReg, evidenceData identifies claim IDs to check with
    // GetClaims(provider, ids).
    function refreshEvidenceStatus(Types.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (Types.EvidenceStatus memory status);

    // Cheap read used by PoRepMarket settlement logic. This must read adapter
    // storage only; it must not call Filecoin actors or refresh live state.
    function currentEvidenceStatus(Types.ActivationContext calldata context)
        external
        view
        returns (Types.EvidenceStatus memory status);
}

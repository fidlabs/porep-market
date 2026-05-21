// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY
// DataCap / VerifReg evidence adapter and guarded DataCap posting gateway.
// PoRepMarket owns deal state; this contract owns allocation and claim checks.

import {IStorageEvidenceAdapter} from "./porep-v2-storage-evidence-adapter.sol";
import {EvidenceType} from "./porep-v2-shared-types.sol";
import {SharedTypes as Types} from "./porep-v2-shared-types.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

abstract contract DataCapEvidenceAdapter is IStorageEvidenceAdapter {
    error OnlyMarket();

    event DataCapBatchSubmitted(uint256 indexed dealId, uint256 allocatedBytes, uint256 allocationCount);
    event DataCapPostingFinished(uint256 indexed dealId, uint256 allocatedBytes, uint256 allocationCount);
    event DealEvidenceReady(uint256 indexed dealId, address indexed evidenceAdapter);

    struct DataCapDealEvidence {
        uint256 allocationCount;
        uint256 allocatedBytes;
        uint256 claimCount;
        uint256 claimedBytes;
        bool postingFinished;
        CommonTypes.FilActorId[] allocationIds;
        CommonTypes.FilActorId[] claimIds;
    }

    mapping(uint256 dealId => DataCapDealEvidence) internal dealEvidence;

    function _onlyMarket() internal view {
        if (msg.sender != market()) revert OnlyMarket();
    }

    function evidenceType() external pure override returns (uint8) {
        return EvidenceType.VERIF_REG_CLAIMS;
    }

    function verifRegActor() external view virtual returns (address);

    function market() public view virtual returns (address);

    // DataCap-backed deals keep allocation posting on the guarded contract path.
    // Direct client calls are allowed only for the frozen deal client while the
    // selected deal is accepted and posting is open. Each batch validates the
    // VerifReg recipient, DataCap amount, provider, size, termMin/termMax, and
    // allocation Data CID before storing returned allocation IDs. Posting
    // batches never activate payment; finishing only emits the event SP/client
    // tools wait for.
    function submitDataCapBatch(uint256 dealId, bytes calldata transferParams) external virtual;

    function finishDataCapPosting(uint256 dealId) external virtual;

    function isDataCapPostingFinished(uint256 dealId) external view virtual returns (bool);

    function getAllocationIds(uint256 dealId, uint256 offset, uint256 limit)
        external
        view
        virtual
        returns (CommonTypes.FilActorId[] memory ids, uint256 total);

    function getClaimIds(uint256 dealId, uint256 offset, uint256 limit)
        external
        view
        virtual
        returns (CommonTypes.FilActorId[] memory ids, uint256 total);

    function submitEvidenceBatch(Types.ActivationContext calldata context, bytes calldata evidenceData)
        external
        override
        returns (Types.ActivationDecision memory decision)
    {
        _onlyMarket();
        return _submitEvidenceBatch(context, evidenceData);
    }

    function activateEvidence(Types.ActivationContext calldata context, bytes calldata evidenceData)
        external
        override
        returns (Types.ActivationDecision memory decision)
    {
        _onlyMarket();
        return _activateEvidence(context, evidenceData);
    }

    // Evidence batches validate known claim IDs through VerifReg getClaims and
    // check claim.data, claim.size, claim.provider, claim.sector, and term
    // fields. Normal settlement reads stored aggregate bytes, not getClaims.
    function _submitEvidenceBatch(Types.ActivationContext calldata context, bytes calldata evidenceData)
        internal
        virtual
        returns (Types.ActivationDecision memory decision);

    // Activation reads already-verified aggregate bytes and avoids looping over
    // every stored piece or claim for a large deal in one call.
    function _activateEvidence(Types.ActivationContext calldata context, bytes calldata evidenceData)
        internal
        virtual
        returns (Types.ActivationDecision memory decision);
}

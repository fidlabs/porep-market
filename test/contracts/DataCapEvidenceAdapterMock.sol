// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {DataCapEvidenceAdapter} from "../../src/DataCapEvidenceAdapter.sol";
import {IStorageEvidenceAdapter} from "../../src/interfaces/IStorageEvidenceAdapter.sol";
import {EvidenceResult} from "../../src/types/EvidenceResult.sol";
import {EvidenceTypes} from "../../src/types/EvidenceTypes.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";

contract DataCapEvidenceAdapterMock is IStorageEvidenceAdapter {
    mapping(CommonTypes.FilActorId provider => bool ok) public valid;
    mapping(uint256 dealId => bool matches) public dataSizeMatches;
    mapping(uint256 dealId => DataCapEvidenceAdapter.DataCapDealEvidence dealEvidence) public deals;
    mapping(uint256 dealId => CommonTypes.FilActorId[] ids) internal allocationIds;
    mapping(uint256 dealId => bytes evidenceData) public submittedEvidence;
    mapping(uint256 dealId => bytes evidenceData) public activatedEvidence;
    mapping(uint256 dealId => bytes evidenceData) public refreshedEvidence;
    mapping(uint256 dealId => address caller) public submitEvidenceCaller;
    mapping(uint256 dealId => uint8 result) public activationResult;
    bool public operational = true;

    function setValid(CommonTypes.FilActorId provider, bool ok) external {
        valid[provider] = ok;
    }

    function setDataSizeMatching(uint256 dealId, bool matches) external {
        dataSizeMatches[dealId] = matches;
    }

    function isDataSizeMatching(uint256 dealId) external view returns (bool) {
        return dataSizeMatches[dealId];
    }

    function getDataCapEvidenceAdapterDealInfo(uint256 dealId)
        external
        view
        returns (DataCapEvidenceAdapter.DataCapDealEvidence memory)
    {
        return deals[dealId];
    }

    function setAllocationIds(uint256 dealId, CommonTypes.FilActorId[] calldata ids_) external {
        delete allocationIds[dealId];
        for (uint256 i = 0; i < ids_.length; i++) {
            allocationIds[dealId].push(ids_[i]);
        }
    }

    function getAllAllocationIdsPerDeal(uint256 dealId) external view returns (CommonTypes.FilActorId[] memory) {
        return allocationIds[dealId];
    }

    function getAllocationIdsPerDeal(uint256 dealId, uint256 offset, uint256 limit)
        external
        view
        returns (CommonTypes.FilActorId[] memory ids, uint256 sumOfAllocations)
    {
        if (limit == 0) revert();
        sumOfAllocations = allocationIds[dealId].length;
        if (offset >= sumOfAllocations) {
            return (new CommonTypes.FilActorId[](0), sumOfAllocations);
        }

        uint256 end = offset + limit;
        if (end > sumOfAllocations) {
            end = sumOfAllocations;
        }

        ids = new CommonTypes.FilActorId[](end - offset);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = allocationIds[dealId][offset + i];
        }
    }

    function setDeal(DataCapEvidenceAdapter.DataCapDealEvidence memory dealEvidence) external {
        deals[dealEvidence.dealId] = dealEvidence;
    }

    function getAllocatedBytes(uint256 dealId) external view returns (uint256) {
        return deals[dealId].allocatedBytes;
    }

    function setOperational(bool operational_) external {
        operational = operational_;
    }

    function setActivationResult(uint256 dealId, uint8 result) external {
        activationResult[dealId] = result;
    }

    function isOperational() external view returns (bool) {
        return operational;
    }

    function evidenceType() external pure returns (uint8) {
        return EvidenceTypes.VERIF_REG_CLAIMS;
    }

    function submitEvidenceBatch(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (SharedTypes.ActivationDecision memory decision)
    {
        submittedEvidence[context.dealId] = evidenceData;
        submitEvidenceCaller[context.dealId] = msg.sender;
        return SharedTypes.ActivationDecision({
            coveredBytes: deals[context.dealId].allocatedBytes, reasonCode: 0, result: EvidenceResult.ACCEPTED
        });
    }

    function activateEvidence(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (SharedTypes.ActivationDecision memory decision)
    {
        activatedEvidence[context.dealId] = evidenceData;
        uint8 result = activationResult[context.dealId];
        if (result == 0) {
            result = EvidenceResult.ACCEPTED;
        }
        return SharedTypes.ActivationDecision({
            coveredBytes: deals[context.dealId].allocatedBytes, reasonCode: 0, result: result
        });
    }

    function refreshEvidenceStatus(SharedTypes.ActivationContext calldata context, bytes calldata evidenceData)
        external
        returns (SharedTypes.EvidenceStatus memory status)
    {
        refreshedEvidence[context.dealId] = evidenceData;
        return currentEvidenceStatus(context);
    }

    function currentEvidenceStatus(SharedTypes.ActivationContext memory context)
        public
        view
        returns (SharedTypes.EvidenceStatus memory status)
    {
        uint256 activeCoveredBytes = deals[context.dealId].allocatedBytes;
        return SharedTypes.EvidenceStatus({
            activeCoveredBytes: activeCoveredBytes,
            lastEvidenceRefreshEpoch: CommonTypes.ChainEpoch.wrap(int64(uint64(block.number))),
            reasonCode: 0,
            result: activeCoveredBytes == 0 ? EvidenceResult.NONE : EvidenceResult.ACCEPTED
        });
    }
}

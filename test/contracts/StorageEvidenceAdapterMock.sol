// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity =0.8.30;

import {IStorageEvidenceAdapter} from "../../src/interfaces/IStorageEvidenceAdapter.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract StorageEvidenceAdapterMock is IStorageEvidenceAdapter {
    mapping(uint256 => bool) private _submitted;

    function markEvidenceSubmitted(uint256 dealId) external {
        _submitted[dealId] = true;
    }

    function hasSubmittedEvidence(uint256 dealId) external view returns (bool) {
        return _submitted[dealId];
    }

    function getEvidenceType() external pure returns (uint8) {
        return 2;
    }

    function isOperational() external pure returns (bool) {
        return true;
    }

    function getExpiration(uint256) external pure returns (CommonTypes.ChainEpoch) {
        return CommonTypes.ChainEpoch.wrap(0);
    }

    function submitEvidenceBatch(SharedTypes.ActivationContext calldata, bytes calldata)
        external
        pure
        returns (SharedTypes.ActivationDecision memory decision)
    {}

    function activateEvidence(SharedTypes.ActivationContext calldata, bytes calldata)
        external
        pure
        returns (SharedTypes.ActivationDecision memory decision)
    {}

    function refreshEvidenceStatus(SharedTypes.ActivationContext calldata, bytes calldata)
        external
        pure
        returns (SharedTypes.EvidenceStatus memory status)
    {}

    function currentEvidenceStatus(SharedTypes.ActivationContext calldata)
        external
        pure
        returns (SharedTypes.EvidenceStatus memory status)
    {}
}

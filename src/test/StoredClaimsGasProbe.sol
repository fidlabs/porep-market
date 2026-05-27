// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";
import {VerifRegCBOR} from "filecoin-solidity/v0.8/cbor/VerifRegCbor.sol";
import {Actor} from "filecoin-solidity/v0.8/utils/Actor.sol";
import {Misc} from "filecoin-solidity/v0.8/utils/Misc.sol";

contract StoredClaimsGasProbe {
    using VerifRegCBOR for *;

    struct Sample {
        uint256 requestedCount;
        uint256 encodedLength;
        uint256 resultLength;
        int256 exitCode;
        uint256 successCount;
        uint256 failCount;
        uint256 returnedClaims;
        uint256 gasStorageLoad;
        uint256 gasEncode;
        uint256 gasActorCall;
        uint256 gasDecode;
        uint256 gasLoop;
        uint256 activeBytes;
    }

    uint64 public provider;
    uint64[] public claimIds;

    function setClaims(uint64 provider_, uint64[] calldata claimIds_) external {
        provider = provider_;
        delete claimIds;

        for (uint256 i = 0; i < claimIds_.length; ++i) {
            claimIds.push(claimIds_[i]);
        }
    }

    function claimCount() external view returns (uint256) {
        return claimIds.length;
    }

    function measureStored() external view returns (Sample memory sample) {
        uint256 beforeStorageLoad = gasleft();
        uint64 provider_ = provider;
        uint64[] memory claimIds_ = claimIds;
        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](claimIds_.length);
        for (uint256 i = 0; i < claimIds_.length; ++i) {
            ids[i] = CommonTypes.FilActorId.wrap(claimIds_[i]);
        }
        uint256 afterStorageLoad = gasleft();

        sample = _measure(CommonTypes.FilActorId.wrap(provider_), ids);
        sample.gasStorageLoad = beforeStorageLoad - afterStorageLoad;
    }

    function _measure(CommonTypes.FilActorId provider_, CommonTypes.FilActorId[] memory ids)
        internal
        view
        returns (Sample memory sample)
    {
        VerifRegTypes.GetClaimsParams memory params =
            VerifRegTypes.GetClaimsParams({provider: provider_, claim_ids: ids});

        sample.requestedCount = ids.length;

        uint256 beforeEncode = gasleft();
        bytes memory rawRequest = params.serializeGetClaimsParams();
        uint256 afterEncode = gasleft();

        (int256 exitCode, bytes memory result) =
            Actor.callByIDReadOnly(VerifRegTypes.ActorID, VerifRegTypes.GetClaimsMethodNum, Misc.CBOR_CODEC, rawRequest);
        uint256 afterActorCall = gasleft();

        sample.encodedLength = rawRequest.length;
        sample.resultLength = result.length;
        sample.exitCode = exitCode;
        sample.gasEncode = beforeEncode - afterEncode;
        sample.gasActorCall = afterEncode - afterActorCall;

        if (exitCode != 0) {
            return sample;
        }

        VerifRegTypes.GetClaimsReturn memory ret = result.deserializeGetClaimsReturn();
        uint256 afterDecode = gasleft();

        sample.successCount = ret.batch_info.success_count;
        sample.failCount = ret.batch_info.fail_codes.length;
        sample.returnedClaims = ret.claims.length;
        sample.gasDecode = afterActorCall - afterDecode;

        uint256 activeBytes;
        for (uint256 i = 0; i < ret.claims.length; ++i) {
            activeBytes += ret.claims[i].size;
        }
        uint256 afterLoop = gasleft();

        sample.gasLoop = afterDecode - afterLoop;
        sample.activeBytes = activeBytes;
    }
}

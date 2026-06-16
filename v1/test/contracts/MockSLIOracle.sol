// SPDX-License-Identifier: MIT
// solhint-disable use-natspec

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SLITypes} from "../../src/types/SLITypes.sol";

contract MockSLIOracle {
    uint256 public lastUpdate;
    uint16 public retrievabilityBps;
    uint16 public bandwidthMbps;
    uint16 public latencyMs;
    uint8 public indexingPct;

    function setLastUpdate(uint256 lastUpdate_) public {
        lastUpdate = lastUpdate_;
    }

    function setAttestations(
        uint256 lastUpdate_,
        uint16 retrievabilityBps_,
        uint16 bandwidthMbps_,
        uint16 latencyMs_,
        uint8 indexingPct_
    ) public {
        lastUpdate = lastUpdate_;
        retrievabilityBps = retrievabilityBps_;
        bandwidthMbps = bandwidthMbps_;
        latencyMs = latencyMs_;
        indexingPct = indexingPct_;
    }

    function getAttestation(CommonTypes.FilActorId) public view returns (SLITypes.Attestation memory ret) {
        ret.lastUpdate = lastUpdate;
        ret.slis.retrievabilityBps = retrievabilityBps;
        ret.slis.bandwidthMbps = bandwidthMbps;
        ret.slis.latencyMs = latencyMs;
        ret.slis.indexingPct = indexingPct;
    }
}

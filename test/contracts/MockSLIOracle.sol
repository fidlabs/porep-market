// SPDX-License-Identifier: MIT
// solhint-disable use-natspec

pragma solidity =0.8.30;

import {SharedTypes} from "../../src/types/SharedTypes.sol";

contract MockSLIOracle {
    uint256 public lastUpdate;
    uint16 public retrievabilityBps;
    uint16 public bandwidthBytesPerSecond;
    uint16 public latencyMs;
    uint8 public indexingPct;
    uint256 public healthLastUpdate;
    uint16 public sectorsHealthBps;

    function setAttestations(
        uint256 lastUpdate_,
        uint16 retrievabilityBps_,
        uint16 bandwidthBytesPerSecond_,
        uint16 latencyMs_,
        uint8 indexingPct_
    ) public {
        lastUpdate = lastUpdate_;
        retrievabilityBps = retrievabilityBps_;
        bandwidthBytesPerSecond = bandwidthBytesPerSecond_;
        latencyMs = latencyMs_;
        indexingPct = indexingPct_;
    }

    function getAttestation(uint256) public view returns (SharedTypes.Attestation memory ret) {
        ret.lastUpdate = lastUpdate;
        ret.slis.retrievabilityBps = retrievabilityBps;
        ret.slis.bandwidthBytesPerSecond = bandwidthBytesPerSecond;
        ret.slis.latencyMs = latencyMs;
        ret.slis.indexingPct = indexingPct;
    }

    function setHealth(uint256 healthLastUpdate_, uint16 sectorsHealthBps_) public {
        healthLastUpdate = healthLastUpdate_;
        sectorsHealthBps = sectorsHealthBps_;
    }

    function getDealHealth(uint256) public view returns (SharedTypes.DealHealth memory ret) {
        ret.lastUpdate = healthLastUpdate;
        ret.sectorsHealthBps = sectorsHealthBps;
    }
}

// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {PoRepTypes} from "../../src/types/PoRepTypes.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract PoRepMarketMock {
    mapping(uint256 dealId => PoRepTypes.DealProposal deal) public deals;
    uint256 public completeDealCallCount;

    SharedTypes.SettlementDecision private settlementDecision;
    uint256 public lastSettlementFromEpoch;
    uint256 public lastSettlementToEpoch;

    function setDealProposal(uint256 dealId, PoRepTypes.DealProposal calldata dealProposal) external {
        deals[dealId] = dealProposal;
    }

    function getDealProposal(uint256 dealId) external view returns (PoRepTypes.DealProposal memory) {
        return deals[dealId];
    }

    // solhint-disable-next-line no-empty-blocks
    function completeDeal(uint256, uint256) external {
        completeDealCallCount++;
    }

    function setDealState(uint256 dealId, PoRepTypes.DealState state) external {
        deals[dealId].state = state;
    }

    function updateValidator(uint256 dealId) external {
        deals[dealId].validator = msg.sender;
    }

    function updateRailId(uint256 dealId, uint256 newRailId) external {
        deals[dealId].railId = newRailId;
    }

    function terminateDeal(uint256 dealId, address, uint256) external {
        deals[dealId].state = PoRepTypes.DealState.Terminated;
    }

    function setSettlementDecision(SharedTypes.SettlementDecision calldata decision) external {
        settlementDecision = decision;
    }

    function validateDealSettlement(uint256, CommonTypes.ChainEpoch fromEpoch, CommonTypes.ChainEpoch toEpoch)
        external
        returns (SharedTypes.SettlementDecision memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        lastSettlementFromEpoch = uint256(uint64(CommonTypes.ChainEpoch.unwrap(fromEpoch)));
        // forge-lint: disable-next-line(unsafe-typecast)
        lastSettlementToEpoch = uint256(uint64(CommonTypes.ChainEpoch.unwrap(toEpoch)));
        return settlementDecision;
    }
}

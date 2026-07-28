// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {PoRepTypes} from "../../src/types/PoRepTypes.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";

contract PoRepMarketMock {
    mapping(uint256 dealId => PoRepTypes.Deal deal) public deals;
    mapping(uint256 dealId => PoRepTypes.DealTerms terms) public dealTerms;
    mapping(uint256 dealId => PoRepTypes.DealPayment payment) public dealPayments;
    mapping(uint256 dealId => PoRepTypes.DealService service) public dealServices;
    SharedTypes.SettlementDecision public settlementDecision;
    uint256 public finalizeDealCallCount;

    function setDeal(uint256 dealId, PoRepTypes.Deal calldata deal) external {
        deals[dealId] = deal;
    }

    function setDealTerms(uint256 dealId, PoRepTypes.DealTerms calldata terms) external {
        dealTerms[dealId] = terms;
    }

    function setDealPayment(uint256 dealId, PoRepTypes.DealPayment calldata payment) external {
        dealPayments[dealId] = payment;
    }

    function setDealService(uint256 dealId, PoRepTypes.DealService calldata service) external {
        dealServices[dealId] = service;
    }

    function setSettlementDecision(uint256 settlementAmount, uint256 settleUpto, string calldata note) external {
        settlementDecision = SharedTypes.SettlementDecision({
            settlementAmount: settlementAmount, settleUpto: settleUpto, reasonCode: 0, result: 0, note: note
        });
    }

    function getDeal(uint256 dealId) external view returns (PoRepTypes.Deal memory) {
        return deals[dealId];
    }

    function getDealPayment(uint256 dealId) external view returns (PoRepTypes.DealPayment memory) {
        return dealPayments[dealId];
    }

    function getDealService(uint256 dealId) external view returns (PoRepTypes.DealService memory) {
        return dealServices[dealId];
    }

    function getDealTerms(uint256 dealId) external view returns (PoRepTypes.DealTerms memory) {
        return dealTerms[dealId];
    }

    function validateDealSettlement(uint256, uint256, uint256)
        external
        view
        returns (SharedTypes.SettlementDecision memory)
    {
        return settlementDecision;
    }

    function finalizeDeal(uint256) external {
        finalizeDealCallCount++;
    }

    function setDealState(uint256 dealId, uint8 state) external {
        deals[dealId].state = state;
    }

    function updateValidator(uint256 dealId) external {
        deals[dealId].validator = msg.sender;
    }

    function updateRailId(uint256 dealId, uint256 newRailId) external {
        deals[dealId].railId = newRailId;
    }

    function terminateDeal(uint256 dealId, uint8 state) external {
        deals[dealId].state = state;
        dealServices[dealId].earlyTerminationEpoch = CommonTypes.ChainEpoch.wrap(int64(uint64(block.number)));
    }
}

// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {PoRepTypes} from "../../src/types/PoRepTypes.sol";
import {DealState} from "../../src/types/DealState.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";

contract PoRepMarketMock {
    mapping(uint256 dealId => PoRepTypes.Deal deal) public deals;
    mapping(uint256 dealId => SharedTypes.SLIThresholds slis) public dealSLIs;
    mapping(uint256 dealId => PoRepTypes.DealPayment payment) public dealPayments;
    mapping(uint256 dealId => PoRepTypes.DealService service) public dealServices;
    mapping(uint256 dealId => PoRepTypes.DealTerms terms) public dealTerms;
    uint256 public finalizeDealCallCount;

    function setDeal(uint256 dealId, PoRepTypes.Deal calldata deal) external {
        deals[dealId] = deal;
    }

    function setDealSLIs(uint256 dealId, SharedTypes.SLIThresholds calldata slis) external {
        dealSLIs[dealId] = slis;
    }

    function setDealPayment(uint256 dealId, PoRepTypes.DealPayment calldata payment) external {
        dealPayments[dealId] = payment;
    }

    function setDealService(uint256 dealId, PoRepTypes.DealService calldata service) external {
        dealServices[dealId] = service;
    }

    function setDealTerms(uint256 dealId, PoRepTypes.DealTerms calldata terms) external {
        dealTerms[dealId] = terms;
    }

    function getDeal(uint256 dealId) external view returns (PoRepTypes.Deal memory) {
        return deals[dealId];
    }

    function getDealSLIs(uint256 dealId) external view returns (SharedTypes.SLIThresholds memory) {
        return dealSLIs[dealId];
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

    function terminateDeal(uint256 dealId, uint256) external {
        deals[dealId].state = DealState.TERMINATED;
    }
}

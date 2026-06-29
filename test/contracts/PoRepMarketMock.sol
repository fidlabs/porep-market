// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {PoRepTypes} from "../../src/types/PoRepTypes.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";

contract PoRepMarketMock {
    mapping(uint256 dealId => PoRepTypes.Deal deal) public deals;
    mapping(uint256 dealId => SharedTypes.SLIThresholds slis) public dealSLIs;
    mapping(uint256 dealId => PoRepTypes.DealPayment payment) public dealPayments;
    mapping(uint256 dealId => PoRepTypes.DealService service) public dealServices;
    uint256 public completeDealCallCount;

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

    function completeDeal(uint256) external {
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
}

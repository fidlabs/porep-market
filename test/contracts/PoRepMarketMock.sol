// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {PoRepMarket} from "../../src/PoRepMarket.sol";

contract PoRepMarketMock {
    mapping(uint256 dealId => PoRepMarket.DealProposal deal) public deals;

    function getDealProposal(uint256 dealId) external view returns (PoRepMarket.DealProposal memory) {
        return deals[dealId];
    }

    function setDealProposal(uint256 dealId, PoRepMarket.DealProposal calldata deal) external {
        deals[dealId] = deal;
    }
}

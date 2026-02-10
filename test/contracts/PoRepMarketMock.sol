// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {PoRepMarket} from "../../src/PoRepMarket.sol";

contract PoRepMarketMock {
    mapping(uint256 dealId => PoRepMarket.DealProposal deal) public deals;

    function setDealProposal(uint256 dealId, PoRepMarket.DealProposal calldata dealProposal) external {
        deals[dealId] = dealProposal;
    }

    function getDealProposal(uint256 dealId) external view returns (PoRepMarket.DealProposal memory) {
        return deals[dealId];
    }

    // solhint-disable-next-line no-empty-blocks
    function completeDeal(uint256) external {
        //noop
    }
}


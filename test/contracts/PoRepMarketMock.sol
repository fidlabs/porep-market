// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity =0.8.25;

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

    function updateValidatorAddress(uint256 dealId) external {
        deals[dealId].validator = msg.sender;
    }

    function updateRailId(uint256 dealId, uint256 newRailId) external {
        deals[dealId].railId = newRailId;
    }

    function terminateDeal(uint256 dealId, address, uint256) external {
        deals[dealId].state = PoRepMarket.DealState.Terminated;
    }
}


// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {PoRepMarket} from "../../src/PoRepMarket.sol";

contract PoRepMarketContractMock is PoRepMarket {
    function setDealProposal(PoRepMarket.DealProposal calldata dealProposal) external {
        s()._dealProposals[++s()._dealIdCounter] = dealProposal;
    }
}


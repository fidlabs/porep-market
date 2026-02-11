// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {PoRepMarket} from "../../src/PoRepMarket.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract PoRepMarketContractMock is PoRepMarket {
    using EnumerableSet for EnumerableSet.UintSet;

    function setDealProposal(PoRepMarket.DealProposal calldata dealProposal) external {
        s()._dealProposals[++s()._dealIdCounter] = dealProposal;
    }

    function setDealIdsReadyForPayment(uint256[] calldata dealIds) external {
        for (uint256 i = 0; i < dealIds.length; i++) {
            s()._dealIdsReadyForPayment.add(dealIds[i]);
        }
    }

    function getDealIdsReadyForPayment() external view returns (uint256[] memory) {
        return s()._dealIdsReadyForPayment.values();
    }
}


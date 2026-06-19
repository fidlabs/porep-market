// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {PoRepMarket} from "../../src/PoRepMarket.sol";
import {PoRepTypes} from "../../src/types/PoRepTypes.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract PoRepMarketContractMock is PoRepMarket {
    using EnumerableSet for EnumerableSet.UintSet;

    function _getStorage() private pure returns (PoRepMarket.PoRepMarketStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            $.slot := 0xea093611145db18b250f1cd58e07fc50de512902beb662a10f8e6d1dd55f6700
        }
    }

    function setDeal(PoRepTypes.Deal calldata deal) external {
        _getStorage()._deals[++_getStorage()._dealIdCounter] = deal;
    }

    function setDealIdsReadyForPayment(uint256[] calldata dealIds) external {
        for (uint256 i = 0; i < dealIds.length; i++) {
            _getStorage()._dealIdsReadyForPayment.add(dealIds[i]);
        }
    }

    function getCompletedDealsIds() public view returns (uint256[] memory) {
        return _getStorage()._dealIdsReadyForPayment.values();
    }
}

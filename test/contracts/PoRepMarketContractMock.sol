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
            $.slot := 0x0abde292d09529f8839f1c315101bb9805017b92f1e5d27b754124ac2f3da000
        }
    }

    function setDeal(PoRepTypes.Deal calldata deal) external {
        _getStorage()._deals[++_getStorage()._dealIdCounter] = deal;
    }

    function setDealState(uint256 dealId, uint8 state) external {
        _getStorage()._deals[dealId].state = state;
    }

    function setDealPayment(uint256 dealId, PoRepTypes.DealPayment calldata payment) external {
        _getStorage()._dealPayments[dealId] = payment;
    }

    function setDealIdsReadyForPayment(uint256[] calldata dealIds) external {
        for (uint256 i = 0; i < dealIds.length; i++) {
            _getStorage()._dealIdsReadyForPayment.add(dealIds[i]);
        }
    }

    function getActiveDealIdsReadyForPayment() public view returns (uint256[] memory) {
        return _getStorage()._dealIdsReadyForPayment.values();
    }

    function ensureAllocationSizeWithinTolerance(uint256 actualDealSize, uint256 expectedDealSize) external view {
        _ensureAllocationSizeWithinTolerance(actualDealSize, expectedDealSize);
    }
}

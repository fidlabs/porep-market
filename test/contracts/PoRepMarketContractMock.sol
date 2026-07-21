// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {PoRepMarket} from "../../src/PoRepMarket.sol";
import {PoRepTypes} from "../../src/types/PoRepTypes.sol";
import {SharedTypes} from "../../src/types/SharedTypes.sol";
import {IStorageEvidenceAdapter} from "../../src/interfaces/IStorageEvidenceAdapter.sol";

contract PoRepMarketContractMock is PoRepMarket {
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

    function setDealService(uint256 dealId, PoRepTypes.DealService calldata service) external {
        _getStorage()._dealService[dealId] = service;
    }

    function setDealCapacity(uint256 dealId, PoRepTypes.DealCapacity calldata capacity) external {
        _getStorage()._dealCapacity[dealId] = capacity;
    }

    function setDealData(uint256 dealId, SharedTypes.DealData calldata dealData) external {
        _getStorage()._dealData[dealId] = dealData;
    }

    function setGlobalEvidenceAdapterForTest(address evidenceAdapter) external {
        _getStorage()._globalEvidenceAdapter = IStorageEvidenceAdapter(evidenceAdapter);
    }

    function getActiveDealIdsReadyForPayment() public pure returns (uint256[] memory) {
        return new uint256[](0);
    }
}

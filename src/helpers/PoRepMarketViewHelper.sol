// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IPoRepMarket} from "../interfaces/IPoRepMarket.sol";
import {PoRepTypes} from "../types/PoRepTypes.sol";
import {SharedTypes} from "../types/SharedTypes.sol";

/**
 * @title PoRepMarketViewHelper
 * @notice Composes complete deal read models without increasing PoRepMarket's implementation size.
 */
contract PoRepMarketViewHelper {
    /**
     * @notice Error indicating that the PoRepMarket address provided during deployment is invalid.
     */
    error InvalidPoRepMarketAddress();

    /**
     * @notice PoRepMarket contract used to fetch deal data.
     */
    IPoRepMarket public immutable POREPMARKET_CONTRACT;

    /**
     * @notice Initializes the helper with a PoRepMarket contract.
     * @param _poRepMarketContract Address of the PoRepMarket contract.
     */
    constructor(address _poRepMarketContract) {
        if (_poRepMarketContract == address(0)) revert InvalidPoRepMarketAddress();
        POREPMARKET_CONTRACT = IPoRepMarket(_poRepMarketContract);
    }

    /**
     * @notice Gets the complete generic read model for one deal.
     * @param dealId The id of the deal.
     * @return dealView Complete generic deal snapshot.
     */
    function getDealView(uint256 dealId) public returns (PoRepTypes.DealView memory dealView) {
        IPoRepMarket market = POREPMARKET_CONTRACT;
        PoRepTypes.Deal memory deal = market.getDeal(dealId);
        SharedTypes.EvidenceStatus memory evidenceStatus;

        if (deal.evidenceAdapter != address(0)) {
            evidenceStatus = market.currentEvidenceStatus(dealId);
        }

        dealView = PoRepTypes.DealView({
            deal: deal,
            data: market.getDealData(dealId),
            requiredSLIs: market.getDealSLIs(dealId),
            terms: market.getDealTerms(dealId),
            timing: market.getDealTiming(dealId),
            service: market.getDealService(dealId),
            capacity: market.getDealCapacity(dealId),
            payment: market.getDealPayment(dealId),
            providerOrganization: market.getDealOrganization(dealId),
            evidenceStatus: evidenceStatus
        });
    }

    /**
     * @notice Gets a caller-sized page of complete generic deal views.
     * @param offset Zero-based index in the creation-order deal ID list.
     * @param limit Maximum number of deal views to return.
     * @return dealViews Page of complete generic deal snapshots.
     * @return total Total number of created deal IDs at call time.
     */
    function getDealViews(uint256 offset, uint256 limit)
        external
        returns (PoRepTypes.DealView[] memory dealViews, uint256 total)
    {
        (uint256[] memory dealIds, uint256 dealCount) = POREPMARKET_CONTRACT.getDealIds(offset, limit);
        total = dealCount;
        dealViews = new PoRepTypes.DealView[](dealIds.length);

        for (uint256 i = 0; i < dealIds.length; i++) {
            dealViews[i] = getDealView(dealIds[i]);
        }
    }
}

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
        dealView = _getDealView(POREPMARKET_CONTRACT.getDeal(dealId));
    }

    /**
     * @notice Gets a caller-sized page of complete generic deal views.
     * @param offset Zero-based index in the creation-order deal list.
     * @param limit Maximum number of deal views to return.
     * @return dealViews Page of complete generic deal snapshots.
     * @return total Total number of created deals at call time.
     */
    function getDealViews(uint256 offset, uint256 limit)
        external
        returns (PoRepTypes.DealView[] memory dealViews, uint256 total)
    {
        (PoRepTypes.Deal[] memory deals, uint256 dealCount) = POREPMARKET_CONTRACT.getDeals(offset, limit);
        total = dealCount;
        dealViews = _getDealViews(deals);
    }

    /**
     * @notice Gets a caller-sized page of complete deal views for an organization and state.
     * @param organization The address of the organization.
     * @param state The state of the deals to retrieve.
     * @param offset Zero-based index in the organization's state-specific deal list.
     * @param limit Maximum number of deal views to return.
     * @return dealViews Page of complete generic deal snapshots.
     * @return total Total number of matching deals at call time.
     */
    function getDealViewsForOrganizationByState(address organization, uint8 state, uint256 offset, uint256 limit)
        external
        returns (PoRepTypes.DealView[] memory dealViews, uint256 total)
    {
        (PoRepTypes.Deal[] memory deals, uint256 dealCount) =
            POREPMARKET_CONTRACT.getDealsForOrganizationByState(organization, state, offset, limit);
        total = dealCount;
        dealViews = _getDealViews(deals);
    }

    function _getDealView(PoRepTypes.Deal memory deal) internal returns (PoRepTypes.DealView memory dealView) {
        IPoRepMarket market = POREPMARKET_CONTRACT;
        SharedTypes.EvidenceStatus memory evidenceStatus;

        if (deal.evidenceAdapter != address(0)) {
            evidenceStatus = market.currentEvidenceStatus(deal.dealId);
        }

        dealView = PoRepTypes.DealView({
            deal: deal,
            data: market.getDealData(deal.dealId),
            requiredSLIs: market.getDealSLIs(deal.dealId),
            terms: market.getDealTerms(deal.dealId),
            service: market.getDealService(deal.dealId),
            capacity: market.getDealCapacity(deal.dealId),
            payment: market.getDealPayment(deal.dealId),
            providerOrganization: market.getDealOrganization(deal.dealId),
            evidenceStatus: evidenceStatus
        });
    }

    function _getDealViews(PoRepTypes.Deal[] memory deals) internal returns (PoRepTypes.DealView[] memory dealViews) {
        dealViews = new PoRepTypes.DealView[](deals.length);

        for (uint256 i = 0; i < deals.length; i++) {
            dealViews[i] = _getDealView(deals[i]);
        }
    }
}

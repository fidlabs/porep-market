// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

// DESIGN DRAFT ONLY.
// This file is a PR-reviewable interface sketch, not deployed source.

import {PoRepV2TypesSpec as V2} from "./porep-v2-shared-types.sol";

interface ISPRegistryV2Spec {
    struct MatchRequest {
        address paymentToken;
        uint256 requestedSizeBytes;
        uint64 durationDays;
        uint256 maxPricePer32GiBPerMonth;
        V2.SLITerms requiredSLIs;
    }

    struct MatchResult {
        V2.FilActorId provider;
        uint256 offerId;
        address payee;
        address paymentToken;
        uint256 pricePer32GiBPerMonth;
        V2.SLITerms slis;
    }

    event PaymentTokenAllowed(address indexed token);
    event PaymentTokenDisallowed(address indexed token);
    event OfferCreated(uint256 indexed offerId, V2.FilActorId indexed provider);
    event OfferTermsUpdated(uint256 indexed offerId);
    event OfferPaymentUpdated(
        uint256 indexed offerId, address indexed token, uint256 pricePer32GiBPerMonth, bool active
    );
    event OfferDeactivated(uint256 indexed offerId);
    event PendingCapacityReserved(V2.FilActorId indexed provider, uint256 sizeBytes);
    event PendingCapacityReleased(V2.FilActorId indexed provider, uint256 sizeBytes);
    event CapacityCommitted(V2.FilActorId indexed provider, uint256 committedBytes);

    function setPaymentTokenAllowed(address token, bool allowed) external;
    function createOffer(V2.FilActorId provider, V2.OfferTerms calldata terms) external returns (uint256 offerId);
    function updateOfferTerms(uint256 offerId, V2.OfferTerms calldata terms) external;
    function setOfferPayment(uint256 offerId, address token, uint256 pricePer32GiBPerMonth, bool active) external;
    function deactivateOffer(uint256 offerId) external;

    function matchAndReserve(MatchRequest calldata request) external returns (MatchResult memory result);
    function releasePendingCapacity(V2.FilActorId provider, uint256 sizeBytes) external;
    function commitCapacity(V2.FilActorId provider, uint256 reservedBytes, uint256 actualBytes) external;

    function getOffer(uint256 offerId) external view returns (V2.Offer memory offer);
    function getOfferTerms(uint256 offerId) external view returns (V2.OfferTerms memory terms);
    function getOfferPayment(uint256 offerId, address token) external view returns (V2.OfferPayment memory payment);
    function getProviderCapacity(V2.FilActorId provider) external view returns (V2.ProviderCapacity memory capacity);
    function isPaymentTokenAllowed(address token) external view returns (bool);
}

interface IPoRepMarketV2Spec {
    event DealProposed(
        uint256 indexed dealId,
        address indexed client,
        V2.FilActorId indexed provider,
        uint256 offerId,
        address paymentToken,
        uint256 requestedSizeBytes,
        uint64 durationEpochs
    );

    event DealExpired(uint256 indexed dealId);
    event DealAccepted(uint256 indexed dealId, V2.FilActorId indexed provider);
    event DealCompleted(uint256 indexed dealId, uint256 actualSizeBytes, uint256 billed32GiBUnits);
    event DealRejected(uint256 indexed dealId, address indexed rejector);
    event DealTerminated(uint256 indexed dealId, address indexed terminator, V2.ChainEpoch endEpoch);
    event ValidatorUpdated(uint256 indexed dealId, address indexed validator);
    event RailCreated(uint256 indexed dealId, uint256 indexed railId, address indexed paymentToken);

    function proposeDealAuto(ISPRegistryV2Spec.MatchRequest calldata request, string calldata manifestLocation)
        external
        returns (uint256 dealId);

    function releaseExpiredProposal(uint256 dealId) external;
    function acceptDeal(uint256 dealId) external;
    function rejectDeal(uint256 dealId) external;
    function completeDeal(uint256 dealId, uint256 actualSizeBytes) external;
    function terminateDeal(uint256 dealId, address terminator, V2.ChainEpoch endEpoch) external;
    function updateValidator(uint256 dealId) external;
    function setRailId(uint256 dealId, uint256 railId) external;

    function getDeal(uint256 dealId) external view returns (V2.Deal memory deal);
    function getDealTerms(uint256 dealId) external view returns (V2.DealTerms memory terms);
    function getDealPayment(uint256 dealId) external view returns (V2.DealPayment memory payment);
    function getDealCapacity(uint256 dealId) external view returns (V2.DealCapacity memory capacity);
    function getDealSLIs(uint256 dealId) external view returns (V2.SLITerms memory slis);
    function getManifestLocation(uint256 dealId) external view returns (string memory manifestLocation);
}

interface IValidatorV2Spec {
    struct ValidationResult {
        uint256 modifiedAmount;
        uint256 settleUpto;
        string note;
    }

    event RailCreatedFromFrozenPayment(
        uint256 indexed dealId, uint256 indexed railId, address indexed paymentToken, uint256 railMaxRatePerEpoch
    );

    function createRail() external returns (uint256 railId);

    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate)
        external
        returns (ValidationResult memory result);
}

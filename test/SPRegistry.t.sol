// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, function-max-lines, gas-strict-inequalities
pragma solidity =0.8.30;

import {Test} from "lib/forge-std/src/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SPRegistry} from "../src/SPRegistry.sol";
import {ISPRegistry} from "../src/interfaces/ISPRegistry.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {OfferMatch} from "../src/types/OfferMatch.sol";
import {ActorIdFailingMock} from "./contracts/ActorIdFailingMock.sol";
import {MockProxy} from "./contracts/MockProxy.sol";
import {ResolveAddressPrecompileMock} from "./contracts/ResolveAddressPrecompileMock.sol";

contract SPRegistryTest is Test {
    address internal constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;

    SPRegistry internal spRegistry;

    address internal admin = vm.addr(0x001);
    address internal market = vm.addr(0x002);
    address internal owner1 = vm.addr(0x003);
    address internal owner2 = vm.addr(0x004);
    address internal operator = vm.addr(0x005);
    address internal token = vm.addr(0x100);
    address internal token2 = vm.addr(0x101);
    address internal unauthorized = vm.addr(0x999);
    ResolveAddressPrecompileMock internal resolveAddress =
        ResolveAddressPrecompileMock(payable(0xFE00000000000000000000000000000000000001));

    CommonTypes.FilActorId internal provider1 = CommonTypes.FilActorId.wrap(1000);
    CommonTypes.FilActorId internal provider2 = CommonTypes.FilActorId.wrap(2000);
    CommonTypes.FilActorId internal provider3 = CommonTypes.FilActorId.wrap(3000);

    uint256 internal defaultAvailableBytes = 10_000_000;

    SharedTypes.SLIThresholds internal defaultSLIs = SharedTypes.SLIThresholds({
        retrievabilityBps: 9500, bandwidthBytesPerSecond: 1000, latencyMs: 100, indexingPct: 90
    });

    function setUp() public {
        SPRegistry impl = new SPRegistry();
        bytes memory initData = abi.encodeCall(SPRegistry.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        spRegistry = SPRegistry(address(proxy));

        vm.prank(admin);
        spRegistry.initialize2(market);

        vm.startPrank(admin);
        spRegistry.grantRole(spRegistry.OPERATOR_ROLE(), operator);
        vm.stopPrank();
    }

    function _terms() internal pure returns (SharedTypes.OfferTerms memory) {
        return SharedTypes.OfferTerms({
            minSizeBytes: 1,
            maxSizeBytes: 10_000_000,
            minDurationEpochs: uint64(180 * SharedTypes.EPOCHS_IN_DAY),
            maxDurationEpochs: uint64(360 * SharedTypes.EPOCHS_IN_DAY)
        });
    }

    function _paymentRows(uint256 price) internal view returns (SharedTypes.OfferPaymentInput[] memory rows) {
        rows = new SharedTypes.OfferPaymentInput[](1);
        rows[0] = SharedTypes.OfferPaymentInput({token: token, active: true, pricePer32GiBPerMonth: price});
    }

    function _request(uint256 maxPrice) internal view returns (SharedTypes.DealRequest memory) {
        return SharedTypes.DealRequest({
            manifestHash: keccak256("manifest"),
            requestedSizeBytes: 1_000_000,
            maxPricePer32GiBPerMonth: maxPrice,
            manifestLocation: "https://example.com/manifest",
            paymentToken: token,
            durationDays: 180,
            requiredSLIs: SharedTypes.SLIThresholds({
                retrievabilityBps: 9000, bandwidthBytesPerSecond: 500, latencyMs: 150, indexingPct: 80
            })
        });
    }

    function _registerProvider(CommonTypes.FilActorId provider, address owner) internal {
        vm.prank(admin);
        spRegistry.registerProviderFor(provider, owner, defaultAvailableBytes, address(0));
    }

    function _allowToken() internal {
        vm.prank(admin);
        spRegistry.setPaymentToken(token, true, 86_400);
    }

    function _allowToken(address allowedToken, uint256 minimum) internal {
        vm.prank(admin);
        spRegistry.setPaymentToken(allowedToken, true, minimum);
    }

    function _createOffer(CommonTypes.FilActorId provider, string memory name, uint256 price)
        internal
        returns (uint256)
    {
        vm.prank(operator);
        return spRegistry.createOffer(provider, name, _terms(), defaultSLIs, _paymentRows(price));
    }

    function _requestWith(uint256 sizeBytes, uint32 durationDays, uint256 maxPrice, address paymentToken)
        internal
        view
        returns (SharedTypes.DealRequest memory request)
    {
        request = _request(maxPrice);
        request.requestedSizeBytes = sizeBytes;
        request.durationDays = durationDays;
        request.paymentToken = paymentToken;
    }

    function _requestWithManifest(bytes32 manifestHash, uint256 maxPrice)
        internal
        view
        returns (SharedTypes.DealRequest memory request)
    {
        request = _request(maxPrice);
        request.manifestHash = manifestHash;
    }

    function _setupTwoProviderAutoMatch() internal returns (uint256 provider1Offer, uint256 provider2Offer) {
        _allowToken();
        _registerProvider(provider1, owner1);
        _registerProvider(provider2, owner2);
        provider1Offer = _createOffer(provider1, "p1", 90_000);
        provider2Offer = _createOffer(provider2, "p2", 90_000);
    }

    function _requestWithSLIs(SharedTypes.SLIThresholds memory slis)
        internal
        view
        returns (SharedTypes.DealRequest memory request)
    {
        request = _request(100_000);
        request.requiredSLIs = slis;
    }

    function _installFalseControllingAddressMock() internal {
        ActorIdFailingMock failingMock = new ActorIdFailingMock();
        ResolveAddressPrecompileMock resolveAddressPrecompileMock = new ResolveAddressPrecompileMock();
        address actorIdProxy = address(new MockProxy(address(5555)));

        vm.etch(address(resolveAddress), address(resolveAddressPrecompileMock).code);
        vm.etch(CALL_ACTOR_ID, address(failingMock).code);
        vm.etch(address(5555), address(actorIdProxy).code);
        resolveAddress.setId(unauthorized, 1000);
    }

    function testInitializeRevertsWhenAdminIsZero() public {
        SPRegistry impl = new SPRegistry();

        vm.expectRevert(SPRegistry.InvalidAdminAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(SPRegistry.initialize, (address(0))));
    }

    function testInitialize2RevertsWhenMarketIsZero() public {
        SPRegistry impl = new SPRegistry();
        SPRegistry freshRegistry =
            SPRegistry(address(new ERC1967Proxy(address(impl), abi.encodeCall(SPRegistry.initialize, (admin)))));

        vm.prank(admin);
        vm.expectRevert(SPRegistry.InvalidPoRepMarketAddress.selector);
        freshRegistry.initialize2(address(0));
    }

    function testGetProviderInfoAndCapacityAreSeparateViews() public {
        _registerProvider(provider1, owner1);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        ISPRegistry.ProviderCapacityInfo memory capacity = spRegistry.getProviderCapacity(provider1);

        assertEq(info.organization, owner1);
        assertEq(info.payee, owner1);
        assertFalse(info.paused);
        assertFalse(info.blocked);
        assertEq(capacity.availableBytes, defaultAvailableBytes);
        assertEq(capacity.committedBytes, 0);
        assertEq(capacity.pendingBytes, 0);
    }

    function testProviderOfferLifecycleEnforcesActiveCapAndReenable() public {
        _allowToken();
        _registerProvider(provider1, owner1);

        uint256 firstOfferId;
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(operator);
            uint256 offerId = spRegistry.createOffer(
                provider1, string.concat("offer-", vm.toString(i)), _terms(), defaultSLIs, _paymentRows(90_000 + i)
            );
            if (i == 0) firstOfferId = offerId;
        }

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.TooManyActiveOffers.selector, provider1, 5));
        spRegistry.createOffer(provider1, "sixth", _terms(), defaultSLIs, _paymentRows(95_000));

        vm.prank(operator);
        spRegistry.setOfferActive(firstOfferId, false);
        assertEq(spRegistry.getActiveOffersByProvider(provider1).length, 4);

        vm.prank(operator);
        spRegistry.createOffer(provider1, "replacement", _terms(), defaultSLIs, _paymentRows(95_000));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.TooManyActiveOffers.selector, provider1, 5));
        spRegistry.setOfferActive(firstOfferId, true);

        vm.prank(operator);
        spRegistry.setOfferActive(6, false);

        vm.prank(operator);
        spRegistry.setOfferActive(firstOfferId, true);
        assertEq(spRegistry.getActiveOffersByProvider(provider1).length, 5);
    }

    function testPreviewAndReserveProviderSelectSameOfferButOnlyReserveMutatesPending() public {
        _allowToken();
        _registerProvider(provider1, owner1);

        vm.prank(operator);
        uint256 offerId = spRegistry.createOffer(provider1, "standard", _terms(), defaultSLIs, _paymentRows(90_000));

        SharedTypes.DealRequest memory request = _request(100_000);
        SharedTypes.ProviderDealSelection memory preview = spRegistry.previewProviderForDeal(request);
        ISPRegistry.ProviderCapacityInfo memory beforeReserve = spRegistry.getProviderCapacity(provider1);

        vm.prank(market);
        SharedTypes.ProviderDealSelection memory reserved = spRegistry.reserveProviderForDeal(request);
        ISPRegistry.ProviderCapacityInfo memory afterReserve = spRegistry.getProviderCapacity(provider1);

        assertEq(preview.offerId, offerId);
        assertEq(reserved.offerId, offerId);
        assertEq(beforeReserve.pendingBytes, 0);
        assertEq(afterReserve.pendingBytes, request.requestedSizeBytes);
    }

    function testAutoMatchPicksLeastLoadedProviderWithinBand() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        _registerProvider(provider2, owner2);

        vm.prank(operator);
        uint256 provider1Offer = spRegistry.createOffer(provider1, "p1", _terms(), defaultSLIs, _paymentRows(90_000));
        vm.prank(operator);
        uint256 provider2Offer = spRegistry.createOffer(provider2, "p2", _terms(), defaultSLIs, _paymentRows(90_500));

        // Load the cheaper provider; provider2 stays idle and is within the 1% band, so it wins on least-loaded.
        vm.prank(market);
        spRegistry.reserveOfferForDeal(provider1Offer, _request(100_000));

        SharedTypes.ProviderDealSelection memory preview = spRegistry.previewProviderForDeal(_request(100_000));
        assertEq(preview.offerId, provider2Offer);
    }

    function testAutoMatchExcludesIdleProviderPricedOutsideBand() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        _registerProvider(provider2, owner2);

        vm.prank(operator);
        uint256 cheapOffer = spRegistry.createOffer(provider1, "cheap", _terms(), defaultSLIs, _paymentRows(90_000));
        vm.prank(operator);
        spRegistry.createOffer(provider2, "expensive", _terms(), defaultSLIs, _paymentRows(92_000));

        // Load the cheap provider; the idle provider2 is priced outside the 1% band and must be excluded.
        vm.prank(market);
        spRegistry.reserveOfferForDeal(cheapOffer, _requestWithManifest(keccak256("manifest-a"), 100_000));

        SharedTypes.ProviderDealSelection memory preview =
            spRegistry.previewProviderForDeal(_requestWithManifest(keccak256("manifest-b"), 100_000));
        assertEq(preview.offerId, cheapOffer);
    }

    function testAutoMatchSkipsProviderAlreadyAssignedToManifest() public {
        (, uint256 provider2Offer) = _setupTwoProviderAutoMatch();
        bytes32 manifestHash = keccak256("same-manifest");
        SharedTypes.DealRequest memory request = _requestWithManifest(manifestHash, 100_000);

        vm.prank(market);
        SharedTypes.ProviderDealSelection memory first = spRegistry.reserveProviderForDeal(request);
        assertEq(CommonTypes.FilActorId.unwrap(first.provider), CommonTypes.FilActorId.unwrap(provider1));
        assertTrue(spRegistry.isManifestAssignedToProvider(manifestHash, provider1));

        SharedTypes.ProviderDealSelection memory preview = spRegistry.previewProviderForDeal(request);
        assertEq(preview.offerId, provider2Offer);

        vm.prank(market);
        SharedTypes.ProviderDealSelection memory second = spRegistry.reserveProviderForDeal(request);
        assertEq(CommonTypes.FilActorId.unwrap(second.provider), CommonTypes.FilActorId.unwrap(provider2));
        assertTrue(spRegistry.isManifestAssignedToProvider(manifestHash, provider2));
    }

    function testAutoMatchRevertsWhenAllEligibleProvidersAlreadyAssignedToManifest() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        _createOffer(provider1, "p1", 90_000);
        bytes32 manifestHash = keccak256("same-manifest");
        SharedTypes.DealRequest memory request = _requestWithManifest(manifestHash, 100_000);

        vm.prank(market);
        spRegistry.reserveProviderForDeal(request);

        vm.prank(market);
        vm.expectRevert(ISPRegistry.NoOfferMatched.selector);
        spRegistry.reserveProviderForDeal(request);
    }

    function testSameProviderCanMatchDifferentManifestHash() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "p1", 90_000);

        vm.prank(market);
        spRegistry.reserveProviderForDeal(_requestWithManifest(keccak256("manifest-a"), 100_000));

        SharedTypes.ProviderDealSelection memory preview =
            spRegistry.previewProviderForDeal(_requestWithManifest(keccak256("manifest-b"), 100_000));
        assertEq(preview.offerId, offerId);
    }

    function testReserveOfferForDealRejectsProviderAlreadyAssignedToManifest() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "p1", 90_000);
        bytes32 manifestHash = keccak256("same-manifest");
        SharedTypes.DealRequest memory request = _requestWithManifest(manifestHash, 100_000);

        vm.prank(market);
        spRegistry.reserveProviderForDeal(request);

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.INSUFFICIENT_CAPACITY)
        );
        spRegistry.reserveOfferForDeal(offerId, request);
    }

    function testPreviewOfferReturnsReasonButReserveRevertsForInactiveOffer() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        vm.prank(operator);
        uint256 offerId = spRegistry.createOffer(provider1, "standard", _terms(), defaultSLIs, _paymentRows(90_000));
        vm.prank(operator);
        spRegistry.setOfferActive(offerId, false);

        (SharedTypes.ProviderDealSelection memory preview, uint16 reason) =
            spRegistry.previewOfferForDeal(offerId, _request(100_000));

        assertEq(CommonTypes.FilActorId.unwrap(preview.provider), 0);
        assertEq(preview.offerId, 0);
        assertEq(reason, OfferMatch.OFFER_INACTIVE);

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.OFFER_INACTIVE)
        );
        spRegistry.reserveOfferForDeal(offerId, _request(100_000));
    }

    function testProviderAdminViewsAndMutableState() public {
        _registerProvider(provider1, owner1);
        _registerProvider(provider2, owner1);

        assertTrue(spRegistry.isProviderRegistered(provider1));
        assertFalse(spRegistry.isProviderRegistered(provider3));

        CommonTypes.FilActorId[] memory providers = spRegistry.getProviders();
        assertEq(providers.length, 2);
        CommonTypes.FilActorId[] memory orgProviders = spRegistry.getProvidersByOrganization(owner1);
        assertEq(orgProviders.length, 2);
        assertEq(spRegistry.getCommittedProviders().length, 0);

        vm.prank(operator);
        spRegistry.pauseProvider(provider1);
        assertTrue(spRegistry.getProviderInfo(provider1).paused);

        vm.prank(operator);
        spRegistry.unpauseProvider(provider1);
        assertFalse(spRegistry.getProviderInfo(provider1).paused);

        vm.prank(operator);
        spRegistry.setPayee(provider1, owner2);
        assertEq(spRegistry.getPayee(provider1), owner2);

        vm.prank(operator);
        spRegistry.updateAvailableSpace(provider1, defaultAvailableBytes + 1);
        assertEq(spRegistry.getProviderCapacity(provider1).availableBytes, defaultAvailableBytes + 1);

        vm.prank(admin);
        spRegistry.blockProvider(provider1);
        assertTrue(spRegistry.getProviderInfo(provider1).blocked);

        vm.prank(admin);
        spRegistry.unblockProvider(provider1);
        assertFalse(spRegistry.getProviderInfo(provider1).blocked);

        _allowToken(token2, 123);
        ISPRegistry.TokenConfig memory tokenConfig = spRegistry.getPaymentTokenConfig(token2);
        assertTrue(tokenConfig.allowed);
        assertEq(tokenConfig.minPricePer32GiBPerMonth, 123);
        address[] memory paymentTokens = spRegistry.getPaymentTokens();
        assertEq(paymentTokens.length, 1);
        assertEq(paymentTokens[0], token2);

        vm.prank(admin);
        spRegistry.setPaymentToken(token2, false, 123);
        assertFalse(spRegistry.getPaymentTokenConfig(token2).allowed);
        assertEq(spRegistry.getPaymentTokens().length, 0);

        assertTrue(spRegistry.isAuthorizedForProvider(admin, provider1));
        assertTrue(spRegistry.isAuthorizedForProvider(operator, provider1));
    }

    function testProviderAdminValidationReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotAdminOrOperator.selector, unauthorized));
        spRegistry.registerProviderFor(provider1, owner1, defaultAvailableBytes, address(0));

        vm.prank(admin);
        vm.expectRevert(SPRegistry.InvalidOrganizationAddress.selector);
        spRegistry.registerProviderFor(provider1, address(0), defaultAvailableBytes, address(0));

        vm.prank(admin);
        vm.expectRevert(SPRegistry.InvalidProviderActorId.selector);
        spRegistry.registerProviderFor(CommonTypes.FilActorId.wrap(0), owner1, defaultAvailableBytes, address(0));

        _registerProvider(provider1, owner1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderAlreadyRegistered.selector, provider1));
        spRegistry.registerProviderFor(provider1, owner1, defaultAvailableBytes, address(0));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderNotRegistered.selector, provider2));
        spRegistry.pauseProvider(provider2);

        vm.prank(admin);
        spRegistry.blockProvider(provider1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderIsBlocked.selector, provider1));
        spRegistry.pauseProvider(provider1);

        vm.prank(admin);
        spRegistry.unblockProvider(provider1);

        vm.prank(operator);
        vm.expectRevert(SPRegistry.InvalidPayeeAddress.selector);
        spRegistry.setPayee(provider1, address(0));

        _installFalseControllingAddressMock();
        assertFalse(spRegistry.isAuthorizedForProvider(unauthorized, provider1));
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.NotProviderControllerOrAdmin.selector, unauthorized, provider1)
        );
        spRegistry.updateAvailableSpace(provider1, defaultAvailableBytes);
    }

    function testMaxProviderLimitIsEnforced() public {
        for (uint64 i = 1; i <= 500; i++) {
            vm.prank(admin);
            spRegistry.registerProviderFor(CommonTypes.FilActorId.wrap(i), owner1, 0, address(0));
        }

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.MaxProvidersReached.selector, 500));
        spRegistry.registerProviderFor(CommonTypes.FilActorId.wrap(501), owner1, 0, address(0));
    }

    function testOfferGettersAndMutableMarketFields() public {
        _allowToken();
        _allowToken(token2, 10);
        _registerProvider(provider1, owner1);

        SharedTypes.OfferPaymentInput[] memory rows = new SharedTypes.OfferPaymentInput[](2);
        rows[0] = SharedTypes.OfferPaymentInput({token: token, active: true, pricePer32GiBPerMonth: 90_000});
        rows[1] = SharedTypes.OfferPaymentInput({token: token2, active: false, pricePer32GiBPerMonth: 10});

        vm.prank(operator);
        uint256 offerId = spRegistry.createOffer(provider1, "standard", _terms(), defaultSLIs, rows);

        ISPRegistry.OfferInfo memory offer = spRegistry.getOffer(offerId);
        assertEq(CommonTypes.FilActorId.unwrap(offer.provider), CommonTypes.FilActorId.unwrap(provider1));
        assertEq(offer.name, "standard");
        assertTrue(offer.active);

        SharedTypes.OfferTerms memory terms = spRegistry.getOfferTerms(offerId);
        assertEq(terms.minSizeBytes, 1);
        assertEq(terms.maxSizeBytes, 10_000_000);
        assertEq(terms.minDurationEpochs, uint64(180 * SharedTypes.EPOCHS_IN_DAY));

        SharedTypes.SLIThresholds memory slis = spRegistry.getOfferSLIs(offerId);
        assertEq(slis.retrievabilityBps, defaultSLIs.retrievabilityBps);
        assertEq(slis.indexingPct, defaultSLIs.indexingPct);

        assertEq(spRegistry.getOffersByProvider(provider1).length, 1);
        assertEq(spRegistry.getActiveOffers().length, 1);

        vm.prank(operator);
        spRegistry.setOfferActive(offerId, true);

        vm.prank(operator);
        spRegistry.setOfferName(offerId, "renamed");
        assertEq(spRegistry.getOffer(offerId).name, "renamed");

        vm.prank(operator);
        spRegistry.setOfferPayment(offerId, token2, true, 11);
        ISPRegistry.OfferPayment memory payment = spRegistry.getOfferPayment(offerId, token2);
        assertTrue(payment.active);
        assertEq(payment.pricePer32GiBPerMonth, 11);
    }

    function testOfferCreationValidationReverts() public {
        _allowToken();
        _registerProvider(provider1, owner1);

        vm.prank(operator);
        vm.expectRevert(SPRegistry.InvalidOfferName.selector);
        spRegistry.createOffer(provider1, "", _terms(), defaultSLIs, _paymentRows(90_000));

        SharedTypes.OfferTerms memory terms = _terms();
        terms.minSizeBytes = 20;
        terms.maxSizeBytes = 10;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidOfferSizeBounds.selector, 20, 10));
        spRegistry.createOffer(provider1, "bad-size", terms, defaultSLIs, _paymentRows(90_000));

        terms = _terms();
        terms.minDurationEpochs = 20;
        terms.maxDurationEpochs = 10;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidOfferDurationBounds.selector, 20, 10));
        spRegistry.createOffer(provider1, "bad-duration", terms, defaultSLIs, _paymentRows(90_000));

        SharedTypes.SLIThresholds memory slis = defaultSLIs;
        slis.retrievabilityBps = 10_001;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidRetrievabilityBps.selector, 10_001));
        spRegistry.createOffer(provider1, "bad-sli", _terms(), slis, _paymentRows(90_000));

        slis = defaultSLIs;
        slis.indexingPct = 101;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidIndexingPct.selector, 101));
        spRegistry.createOffer(provider1, "bad-index", _terms(), slis, _paymentRows(90_000));

        SharedTypes.OfferPaymentInput[] memory rows = new SharedTypes.OfferPaymentInput[](1);
        rows[0] = SharedTypes.OfferPaymentInput({token: address(0), active: true, pricePer32GiBPerMonth: 90_000});
        vm.prank(operator);
        vm.expectRevert(SPRegistry.InvalidPaymentToken.selector);
        spRegistry.createOffer(provider1, "bad-token", _terms(), defaultSLIs, rows);

        rows[0] = SharedTypes.OfferPaymentInput({token: token2, active: true, pricePer32GiBPerMonth: 90_000});
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.PaymentTokenNotAllowed.selector, token2));
        spRegistry.createOffer(provider1, "bad-token", _terms(), defaultSLIs, rows);

        rows[0] = SharedTypes.OfferPaymentInput({token: token, active: true, pricePer32GiBPerMonth: 1});
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.PriceBelowTokenMinimum.selector, token, 1, 86_400));
        spRegistry.createOffer(provider1, "bad-price", _terms(), defaultSLIs, rows);

        vm.prank(admin);
        vm.expectRevert(SPRegistry.InvalidPaymentToken.selector);
        spRegistry.setPaymentToken(address(0), true, 1);
    }

    function testOfferMutationValidationReverts() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "standard", 90_000);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.OfferNotFound.selector, 0));
        spRegistry.setOfferName(0, "missing");

        vm.prank(operator);
        vm.expectRevert(SPRegistry.InvalidOfferName.selector);
        spRegistry.setOfferName(offerId, "");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.OfferNotFound.selector, 999));
        spRegistry.setOfferPayment(999, token, true, 90_000);

        vm.prank(operator);
        vm.expectRevert(SPRegistry.InvalidPaymentToken.selector);
        spRegistry.setOfferPayment(offerId, address(0), true, 90_000);
    }

    function testCapacityAccountingAndReverts() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "standard", 90_000);

        vm.prank(market);
        spRegistry.reserveOfferForDeal(offerId, _request(100_000));
        assertEq(spRegistry.getProviderCapacity(provider1).pendingBytes, 1_000_000);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.AvailableBelowCommittedPlusPending.selector, provider1, 1, 0, 1_000_000)
        );
        spRegistry.updateAvailableSpace(provider1, 1);

        vm.prank(market);
        spRegistry.releasePendingCapacity(provider1, 400_000, bytes32(0));
        assertEq(spRegistry.getProviderCapacity(provider1).pendingBytes, 600_000);

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.ReleasePendingExceedsPending.selector, provider1, 700_000, 600_000)
        );
        spRegistry.releasePendingCapacity(provider1, 700_000, bytes32(0));

        vm.prank(market);
        spRegistry.commitCapacity(provider1, 1_000_000, 500_000);
        ISPRegistry.ProviderCapacityInfo memory capacity = spRegistry.getProviderCapacity(provider1);
        assertEq(capacity.pendingBytes, 0);
        assertEq(capacity.committedBytes, 500_000);
        assertEq(spRegistry.getCommittedProviders().length, 1);

        vm.prank(market);
        spRegistry.releaseCapacity(provider1, 100_000, bytes32(0));
        assertEq(spRegistry.getProviderCapacity(provider1).committedBytes, 400_000);

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.ReleaseExceedsCommitted.selector, provider1, 500_000, 400_000)
        );
        spRegistry.releaseCapacity(provider1, 500_000, bytes32(0));

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.CommitExceedsAvailable.selector, provider1, 10_400_000, 10_000_000)
        );
        spRegistry.commitCapacity(provider1, 0, 10_000_000);
    }

    function testCommitCapacityUsesActualBytesAndReleasesEstimatedPending() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "standard", 90_000);

        vm.prank(market);
        spRegistry.reserveOfferForDeal(offerId, _request(100_000));

        vm.prank(market);
        spRegistry.commitCapacity(provider1, 1_000_000, 900_000);

        ISPRegistry.ProviderCapacityInfo memory capacity = spRegistry.getProviderCapacity(provider1);
        assertEq(capacity.pendingBytes, 0);
        assertEq(capacity.committedBytes, 900_000);
    }

    function testReleasePendingCapacityClearsManifestProviderLock() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        _createOffer(provider1, "p1", 90_000);
        bytes32 manifestHash = keccak256("same-manifest");
        SharedTypes.DealRequest memory request = _requestWithManifest(manifestHash, 100_000);

        vm.prank(market);
        spRegistry.reserveProviderForDeal(request);
        assertTrue(spRegistry.isManifestAssignedToProvider(manifestHash, provider1));

        vm.prank(market);
        spRegistry.releasePendingCapacity(provider1, request.requestedSizeBytes, manifestHash);
        assertFalse(spRegistry.isManifestAssignedToProvider(manifestHash, provider1));
    }

    function testReleaseCapacityClearsManifestProviderLock() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        _createOffer(provider1, "p1", 90_000);
        bytes32 manifestHash = keccak256("same-manifest");
        SharedTypes.DealRequest memory request = _requestWithManifest(manifestHash, 100_000);

        vm.prank(market);
        spRegistry.reserveProviderForDeal(request);
        vm.prank(market);
        spRegistry.commitCapacity(provider1, request.requestedSizeBytes, request.requestedSizeBytes);

        vm.prank(market);
        spRegistry.releaseCapacity(provider1, request.requestedSizeBytes, manifestHash);
        assertFalse(spRegistry.isManifestAssignedToProvider(manifestHash, provider1));
    }

    function testReserveValidationFailures() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "standard", 90_000);

        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, 999, OfferMatch.OFFER_NOT_FOUND));
        spRegistry.reserveOfferForDeal(999, _request(100_000));

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.SIZE_OUT_OF_BOUNDS)
        );
        spRegistry.reserveOfferForDeal(offerId, _requestWith(0, 180, 100_000, token));

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.SIZE_OUT_OF_BOUNDS)
        );
        spRegistry.reserveOfferForDeal(offerId, _requestWith(10_000_001, 180, 100_000, token));

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.DURATION_OUT_OF_BOUNDS)
        );
        spRegistry.reserveOfferForDeal(offerId, _requestWith(1_000_000, 179, 100_000, token));

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.DURATION_OUT_OF_BOUNDS)
        );
        spRegistry.reserveOfferForDeal(offerId, _requestWith(1_000_000, 361, 100_000, token));

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.PRICE_ABOVE_CLIENT_MAX)
        );
        spRegistry.reserveOfferForDeal(offerId, _request(89_999));

        address unallowedToken = vm.addr(0x102);
        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.TOKEN_NOT_ALLOWED)
        );
        spRegistry.reserveOfferForDeal(offerId, _requestWith(1_000_000, 180, 100_000, unallowedToken));

        vm.prank(operator);
        spRegistry.updateAvailableSpace(provider1, 500_000);
        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.INSUFFICIENT_CAPACITY)
        );
        spRegistry.reserveOfferForDeal(offerId, _requestWith(1_000_000, 180, 100_000, token));
    }

    function testReserveOfferRevertsWhenProviderPausedOrBlocked() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "standard", 90_000);

        vm.prank(operator);
        spRegistry.pauseProvider(provider1);
        (SharedTypes.ProviderDealSelection memory preview, uint16 reason) =
            spRegistry.previewOfferForDeal(offerId, _request(100_000));
        assertEq(CommonTypes.FilActorId.unwrap(preview.provider), 0);
        assertEq(reason, OfferMatch.PROVIDER_PAUSED);

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.PROVIDER_PAUSED)
        );
        spRegistry.reserveOfferForDeal(offerId, _request(100_000));

        vm.prank(operator);
        spRegistry.unpauseProvider(provider1);
        vm.prank(admin);
        spRegistry.blockProvider(provider1);

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.PROVIDER_BLOCKED)
        );
        spRegistry.reserveOfferForDeal(offerId, _request(100_000));
    }

    function testPreviewValidationFailuresReturnReasonCodes() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "standard", 90_000);

        SharedTypes.ProviderDealSelection memory selection;
        uint16 reason;

        (selection, reason) = spRegistry.previewOfferForDeal(999, _requestWith(1_000_000, 180, 100_000, token));
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), 0);
        assertEq(reason, OfferMatch.OFFER_NOT_FOUND);

        (selection, reason) = spRegistry.previewOfferForDeal(offerId, _requestWith(0, 180, 100_000, token));
        assertEq(reason, OfferMatch.SIZE_OUT_OF_BOUNDS);

        (selection, reason) = spRegistry.previewOfferForDeal(offerId, _requestWith(1_000_000, 179, 100_000, token));
        assertEq(reason, OfferMatch.DURATION_OUT_OF_BOUNDS);

        (selection, reason) = spRegistry.previewOfferForDeal(
            offerId,
            _requestWithSLIs(
                SharedTypes.SLIThresholds({
                    retrievabilityBps: 9501, bandwidthBytesPerSecond: 0, latencyMs: 0, indexingPct: 0
                })
            )
        );
        assertEq(reason, OfferMatch.SLIS_NOT_MET);

        (selection, reason) = spRegistry.previewOfferForDeal(offerId, _request(89_999));
        assertEq(reason, OfferMatch.PRICE_ABOVE_CLIENT_MAX);

        vm.prank(operator);
        spRegistry.updateAvailableSpace(provider1, 500_000);
        (selection, reason) = spRegistry.previewOfferForDeal(offerId, _requestWith(1_000_000, 180, 100_000, token));
        assertEq(reason, OfferMatch.INSUFFICIENT_CAPACITY);

        vm.prank(operator);
        spRegistry.updateAvailableSpace(provider1, defaultAvailableBytes);

        vm.prank(admin);
        spRegistry.setPaymentToken(token, false, 86_400);
        (selection, reason) = spRegistry.previewOfferForDeal(offerId, _request(100_000));
        assertEq(reason, OfferMatch.TOKEN_NOT_ALLOWED);

        vm.prank(admin);
        spRegistry.setPaymentToken(token, true, 91_000);
        (selection, reason) = spRegistry.previewOfferForDeal(offerId, _request(100_000));
        assertEq(reason, OfferMatch.PRICE_BELOW_TOKEN_MIN);

        vm.prank(admin);
        spRegistry.setPaymentToken(token, true, 86_400);
        vm.prank(operator);
        spRegistry.setOfferPayment(offerId, token, false, 90_000);
        (selection, reason) = spRegistry.previewOfferForDeal(offerId, _request(100_000));
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), 0);
        assertEq(reason, OfferMatch.TOKEN_NOT_ALLOWED);
    }

    function testPaymentAndSLIValidationFailures() public {
        _allowToken();
        _allowToken(token2, 100);
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "standard", 90_000);

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.TOKEN_NOT_ALLOWED)
        );
        spRegistry.reserveOfferForDeal(offerId, _requestWith(1_000_000, 180, 100_000, token2));

        vm.prank(operator);
        spRegistry.setOfferPayment(offerId, token, false, 90_000);
        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.TOKEN_NOT_ALLOWED)
        );
        spRegistry.reserveOfferForDeal(offerId, _request(100_000));

        vm.prank(operator);
        spRegistry.setOfferPayment(offerId, token, true, 90_000);
        vm.prank(admin);
        spRegistry.setPaymentToken(token, true, 91_000);
        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.PRICE_BELOW_TOKEN_MIN)
        );
        spRegistry.reserveOfferForDeal(offerId, _request(100_000));

        vm.prank(admin);
        spRegistry.setPaymentToken(token, true, 86_400);

        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.SLIS_NOT_MET));
        spRegistry.reserveOfferForDeal(
            offerId,
            _requestWithSLIs(
                SharedTypes.SLIThresholds({
                    retrievabilityBps: 9501, bandwidthBytesPerSecond: 0, latencyMs: 0, indexingPct: 0
                })
            )
        );

        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.SLIS_NOT_MET));
        spRegistry.reserveOfferForDeal(
            offerId,
            _requestWithSLIs(
                SharedTypes.SLIThresholds({
                    retrievabilityBps: 0, bandwidthBytesPerSecond: 1001, latencyMs: 0, indexingPct: 0
                })
            )
        );

        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.SLIS_NOT_MET));
        spRegistry.reserveOfferForDeal(
            offerId,
            _requestWithSLIs(
                SharedTypes.SLIThresholds({
                    retrievabilityBps: 0, bandwidthBytesPerSecond: 0, latencyMs: 99, indexingPct: 0
                })
            )
        );

        vm.prank(market);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.SLIS_NOT_MET));
        spRegistry.reserveOfferForDeal(
            offerId,
            _requestWithSLIs(
                SharedTypes.SLIThresholds({
                    retrievabilityBps: 0, bandwidthBytesPerSecond: 0, latencyMs: 0, indexingPct: 91
                })
            )
        );
    }

    function testActiveOfferPaymentCannotHaveZeroPriceEvenWhenTokenMinimumIsZero() public {
        vm.prank(admin);
        spRegistry.setPaymentToken(token, true, 0);
        _registerProvider(provider1, owner1);

        SharedTypes.OfferPaymentInput[] memory rows = new SharedTypes.OfferPaymentInput[](1);
        rows[0] = SharedTypes.OfferPaymentInput({token: token, active: true, pricePer32GiBPerMonth: 0});

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.PriceBelowTokenMinimum.selector, token, 0, 1));
        spRegistry.createOffer(provider1, "zero-active-price", _terms(), defaultSLIs, rows);
    }

    function testLowPriceOfferRejectedWhenRequestedSizeWouldProduceZeroPerEpochPayment() public {
        _allowToken(token, 1);
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "low-price", 1);
        SharedTypes.DealRequest memory request = _request(1);

        (SharedTypes.ProviderDealSelection memory selection, uint16 reason) =
            spRegistry.previewOfferForDeal(offerId, request);
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), 0);
        assertEq(reason, OfferMatch.PER_EPOCH_FLOOR);

        selection = spRegistry.previewProviderForDeal(request);
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), 0);

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.PER_EPOCH_FLOOR)
        );
        spRegistry.reserveOfferForDeal(offerId, request);

        vm.prank(market);
        vm.expectRevert(ISPRegistry.NoOfferMatched.selector);
        spRegistry.reserveProviderForDeal(request);
    }

    function testZeroSizeOfferRequestUsesPaymentFloorValidationInsteadOfPanic() public {
        _allowToken(token, 1);
        _registerProvider(provider1, owner1);

        SharedTypes.OfferTerms memory terms = _terms();
        terms.minSizeBytes = 0;
        terms.maxSizeBytes = 0;
        vm.prank(operator);
        uint256 offerId = spRegistry.createOffer(provider1, "zero-min", terms, defaultSLIs, _paymentRows(1));

        SharedTypes.DealRequest memory request = _requestWith(0, 180, 1, token);

        (SharedTypes.ProviderDealSelection memory selection, uint16 reason) =
            spRegistry.previewOfferForDeal(offerId, request);
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), 0);
        assertEq(reason, OfferMatch.PER_EPOCH_FLOOR);

        vm.prank(market);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.OfferNotEligible.selector, offerId, OfferMatch.PER_EPOCH_FLOOR)
        );
        spRegistry.reserveOfferForDeal(offerId, request);
    }

    function testLowPriceOfferAllowedWhenLargeRequestProducesNonZeroPerEpochPayment() public {
        uint256 sectorSize = 32 * 1024 * 1024 * 1024;
        uint256 requestSize = ((SharedTypes.EPOCHS_IN_MONTH - 1) * sectorSize) + 1;

        _allowToken(token, 1);
        _registerProvider(provider1, owner1);
        vm.prank(operator);
        spRegistry.updateAvailableSpace(provider1, requestSize);

        SharedTypes.OfferTerms memory terms = _terms();
        terms.maxSizeBytes = 0;
        vm.prank(operator);
        uint256 offerId = spRegistry.createOffer(provider1, "large-low-price", terms, defaultSLIs, _paymentRows(1));

        SharedTypes.DealRequest memory request = _requestWith(requestSize, 180, 1, token);

        (SharedTypes.ProviderDealSelection memory selection, uint16 reason) =
            spRegistry.previewOfferForDeal(offerId, request);
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), CommonTypes.FilActorId.unwrap(provider1));
        assertEq(selection.pricePer32GiBPerMonth, 1);
        assertEq(reason, OfferMatch.OK);

        vm.prank(market);
        selection = spRegistry.reserveOfferForDeal(offerId, request);
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), CommonTypes.FilActorId.unwrap(provider1));
        assertEq(spRegistry.getProviderCapacity(provider1).pendingBytes, requestSize);
    }

    function testPausedBlockedAndNoMatchPreviewPaths() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        uint256 offerId = _createOffer(provider1, "standard", 90_000);

        vm.prank(operator);
        spRegistry.pauseProvider(provider1);
        (SharedTypes.ProviderDealSelection memory selection, uint16 reason) =
            spRegistry.previewOfferForDeal(offerId, _request(100_000));
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), 0);
        assertEq(reason, OfferMatch.PROVIDER_PAUSED);
        selection = spRegistry.previewProviderForDeal(_request(100_000));
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), 0);

        vm.prank(market);
        vm.expectRevert(ISPRegistry.NoOfferMatched.selector);
        spRegistry.reserveProviderForDeal(_request(100_000));

        vm.prank(operator);
        spRegistry.unpauseProvider(provider1);
        vm.prank(admin);
        spRegistry.blockProvider(provider1);
        (selection, reason) = spRegistry.previewOfferForDeal(offerId, _request(100_000));
        assertEq(CommonTypes.FilActorId.unwrap(selection.provider), 0);
        assertEq(reason, OfferMatch.PROVIDER_BLOCKED);
    }

    function testSameProviderBestOfferTieBreaks() public {
        _allowToken();
        _registerProvider(provider1, owner1);

        vm.prank(operator);
        spRegistry.createOffer(provider1, "expensive", _terms(), defaultSLIs, _paymentRows(91_000));
        vm.prank(operator);
        uint256 cheapOffer = spRegistry.createOffer(provider1, "cheap", _terms(), defaultSLIs, _paymentRows(90_000));
        vm.prank(operator);
        spRegistry.createOffer(provider1, "same-price", _terms(), defaultSLIs, _paymentRows(90_000));

        SharedTypes.ProviderDealSelection memory selection = spRegistry.previewProviderForDeal(_request(100_000));
        assertEq(selection.offerId, cheapOffer);
    }

    function testFinalSelectionTieBreaksByProviderAndOffer() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        _registerProvider(provider2, owner2);

        uint256 provider1Offer = _createOffer(provider1, "p1", 90_000);
        _createOffer(provider2, "p2", 90_000);

        SharedTypes.ProviderDealSelection memory selection = spRegistry.previewProviderForDeal(_request(100_000));
        assertEq(selection.offerId, provider1Offer);
    }

    function testFinalSelectionPrefersLowerPriceWhenEquallyLoaded() public {
        _allowToken();
        _registerProvider(provider1, owner1);
        _registerProvider(provider2, owner2);

        // Both idle and within the 1% band (90_900 <= 90_000 * 1.01); cheaper price breaks the tie.
        _createOffer(provider1, "p1", 90_900);
        uint256 provider2Offer = _createOffer(provider2, "p2", 90_000);

        SharedTypes.ProviderDealSelection memory selection = spRegistry.previewProviderForDeal(_request(100_000));
        assertEq(selection.offerId, provider2Offer);
    }

    function testUpgradeAuthorizationSuccessCoversAuthorizeUpgrade() public {
        SPRegistry newImpl = new SPRegistry();

        vm.prank(admin);
        spRegistry.upgradeToAndCall(address(newImpl), "");
    }
}

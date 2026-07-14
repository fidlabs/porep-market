// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity =0.8.30;

import {Test} from "lib/forge-std/src/Test.sol";
import {Validator} from "../src/Validator.sol";
import {IFilecoinPayValidator} from "../src/interfaces/IFilecoinPayValidator.sol";
import {IPoRepMarket} from "../src/interfaces/IPoRepMarket.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {DealState} from "../src/types/DealState.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {RailStatus} from "../src/types/RailStatus.sol";

import {FilecoinPayV1Mock} from "./contracts/FilecoinPayV1Mock.sol";
import {DataCapEvidenceAdapterMock} from "./contracts/DataCapEvidenceAdapterMock.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ValidatorTest is Test {
    Validator public validator;
    FilecoinPayV1Mock public filecoinPayMock;
    PoRepMarketMock public poRepMarketMock;
    DataCapEvidenceAdapterMock public dataCapEvidenceAdapterMock;

    address public admin;
    address public porepService;
    address public evidenceAdapter;
    IERC20 public token;
    CommonTypes.FilActorId public providerFilActorId;
    uint256 public dealId;
    uint256 public railId;
    string public expectedManifestLocation;

    SharedTypes.SLIThresholds public defaultRequirements;
    uint256 public constant EPOCHS_IN_MONTH = 86_400;
    uint256 public constant BLOCK_TIMESTAMP = 1_772_000_000;
    int64 public constant CHAIN_EPOCH = 5_800_000;

    function setUp() public {
        filecoinPayMock = new FilecoinPayV1Mock();
        dataCapEvidenceAdapterMock = new DataCapEvidenceAdapterMock();
        poRepMarketMock = new PoRepMarketMock();

        admin = address(this);
        porepService = vm.addr(0x123);
        evidenceAdapter = address(dataCapEvidenceAdapterMock);
        token = IERC20(vm.addr(0x5));
        providerFilActorId = CommonTypes.FilActorId.wrap(20000);
        dealId = 1;
        railId = 1;
        expectedManifestLocation = "https://example.com/manifest";

        defaultRequirements = SharedTypes.SLIThresholds({
            retrievabilityBps: 8000, bandwidthBytesPerSecond: 500, latencyMs: 200, indexingPct: 90
        });

        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: admin,
                provider: providerFilActorId,
                offerId: 0,
                state: DealState.PROPOSED,
                evidenceAdapter: evidenceAdapter,
                validator: address(0),
                railId: railId
            })
        );
        poRepMarketMock.setDealPayment(
            dealId,
            PoRepTypes.DealPayment({
                paymentToken: address(token),
                payee: address(0),
                pricePer32GiBPerMonth: 100,
                billed32GiBUnits: 0,
                railMaxRatePerEpoch: 0
            })
        );
        Validator impl = new Validator();
        ERC1967Proxy validatorProxy = new ERC1967Proxy(address(impl), "");
        validator = Validator(address(validatorProxy));

        validator.initialize(admin, address(filecoinPayMock), address(poRepMarketMock), dealId);

        filecoinPayMock.setOperatorApproval(token, admin, address(validator), true, 1_000_000, 1_000_000, 0, 0, 86_400);

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(1);
        dataCapEvidenceAdapterMock.setAllocationIds(dealId, ids);

        vm.prank(admin);
        validator.createRail();
    }

    function activateServiceUntil(int64 serviceEndEpoch) internal {
        vm.prank(address(poRepMarketMock));
        poRepMarketMock.setDealService(
            dealId,
            PoRepTypes.DealService({
                serviceStartEpoch: CommonTypes.ChainEpoch.wrap(int64(0)),
                serviceEndEpoch: CommonTypes.ChainEpoch.wrap(serviceEndEpoch),
                earlyTerminationEpoch: CommonTypes.ChainEpoch.wrap(0),
                minTimeBetweenSettlementsInEpochs: EPOCHS_IN_MONTH,
                lastSettledEpoch: CommonTypes.ChainEpoch.wrap(0)
            })
        );
        vm.prank(address(poRepMarketMock));
        validator.modifyRailPayment(1);
    }

    function testIsAdminSet() public view {
        bytes32 adminRole = validator.DEFAULT_ADMIN_ROLE();
        assertTrue(validator.hasRole(adminRole, admin));
    }

    function testEIP7201StorageSlotIsCorrect() public pure {
        // solhint-disable-next-line gas-small-strings
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("porepmarket.storage.ValidatorStorage")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(expected, 0xf51cddbeb47ca42a561371db80eaffa401732269b8af46b255e3f43a7c044000);
    }

    function testRailTerminatedCallerIsNotFilecoinPayRevert() public {
        vm.expectRevert(Validator.CallerIsNotFilecoinPay.selector);
        validator.railTerminated(1, address(this), 0);
    }

    function testRailTerminatedInvalidTerminatorRevert() public {
        vm.expectRevert(Validator.InvalidTerminator.selector);
        vm.prank(address(filecoinPayMock));
        validator.railTerminated(railId, address(0xBEEF), 0);
    }

    function testUpdateLockupPeriodUpdatesFilecoinPayRail() public {
        uint256 newLockup = 123;

        vm.prank(admin);
        validator.updateLockupPeriod(newLockup);

        (uint256 lockupPeriod, uint256 lockupFixed) = filecoinPayMock.getRailLockup(railId);
        assertEq(lockupPeriod, newLockup);
        assertEq(lockupFixed, 0);
    }

    function testImplementationContractCannotBeInitialized() public {
        Validator impl = new Validator();
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        impl.initialize(admin, address(filecoinPayMock), address(poRepMarketMock), dealId);
    }

    function testValidatorCannotBeReinitialized() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        validator.initialize(admin, address(filecoinPayMock), address(poRepMarketMock), dealId);
    }

    function testValidatePaymentDoesNotApplySettlementCadenceLocally() public {
        activateServiceUntil(CHAIN_EPOCH);
        poRepMarketMock.setSettlementDecision(100, 0, "payment validated successfully");

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, 0, 1);

        assertEq(result.modifiedAmount, 100);
        assertEq(result.settleUpto, 0);
        assertEq(result.note, "payment validated successfully");
    }

    function testValidatePaymentReturnsMarketDataSizeMismatchDecision() public {
        activateServiceUntil(CHAIN_EPOCH);
        uint256 maxEpoch = uint256(uint64(type(int64).max));
        poRepMarketMock.setSettlementDecision(0, maxEpoch, "data size does not match the deal");

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, maxEpoch, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, maxEpoch);
        assertEq(result.note, "data size does not match the deal");
    }

    function testValidatePaymentReturnsMarketScoreFailureDecision() public {
        activateServiceUntil(CHAIN_EPOCH);

        uint256 maxEpoch = uint256(uint64(type(int64).max));
        poRepMarketMock.setSettlementDecision(0, maxEpoch, "score below required threshold");

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, maxEpoch, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, maxEpoch);
        assertEq(result.note, "score below required threshold");
    }

    function testValidatePaymentReturnsMarketAcceptedDecision() public {
        activateServiceUntil(CHAIN_EPOCH);

        poRepMarketMock.setSettlementDecision(100, 86_400, "payment validated successfully");

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, 86_400, 1);

        assertEq(result.modifiedAmount, 100);
        assertEq(result.settleUpto, 86_400);
        assertEq(result.note, "payment validated successfully");
    }

    function testValidatePaymentDelegatesSettlementDecisionToPoRepMarket() public {
        activateServiceUntil(CHAIN_EPOCH);
        poRepMarketMock.setSettlementDecision(123, 456, "market decision");

        vm.expectCall(address(poRepMarketMock), abi.encodeCall(IPoRepMarket.validateDealSettlement, (dealId, 0, 456)));

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(railId, 123, 0, 456, 999);

        assertEq(result.modifiedAmount, 123);
        assertEq(result.settleUpto, 456);
        assertEq(result.note, "market decision");
    }

    function testValidatePaymentCallerIsNotFilecoinPayRevert() public {
        vm.expectRevert(Validator.CallerIsNotFilecoinPay.selector);
        validator.validatePayment(1, 100, 0, 0, 1);
    }

    function testCreateRailCallerIsNotClientRevert() public {
        address notClient = vm.addr(0xCAFE);
        vm.expectRevert(Validator.CallerIsNotClient.selector);
        vm.prank(notClient);
        validator.createRail();
    }

    function testValidatePaymentInvalidRailIdRevert() public {
        uint256 wrongRailId = railId + 1;

        vm.expectRevert(abi.encodeWithSelector(Validator.InvalidRailId.selector, railId, wrongRailId));
        vm.prank(address(filecoinPayMock));
        validator.validatePayment(wrongRailId, 100, 0, type(uint256).max, 1);
    }

    function testRailTerminatedInvalidRailIdRevert() public {
        uint256 wrongRailId = railId + 1;

        vm.expectRevert(abi.encodeWithSelector(Validator.InvalidRailId.selector, railId, wrongRailId));
        vm.prank(address(filecoinPayMock));
        validator.railTerminated(wrongRailId, address(this), 10);
    }

    function testInitializeRevertsWhenAdminIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidAdminAddress.selector);
        newValidator.initialize(address(0), address(filecoinPayMock), address(poRepMarketMock), dealId);
    }

    function testInitializeRevertsWhenFilecoinPayIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidFilecoinPayAddress.selector);
        newValidator.initialize(admin, address(0), address(poRepMarketMock), dealId);
    }

    function testInitializeRevertsWhenPoRepMarketIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidPoRepMarketAddress.selector);
        newValidator.initialize(admin, address(filecoinPayMock), address(0), dealId);
    }

    function testModifyRailPaymentEmitsRailPaymentModified() public {
        PoRepTypes.DealPayment memory payment = poRepMarketMock.getDealPayment(dealId);
        payment.railMaxRatePerEpoch = 2_000_000;
        poRepMarketMock.setDealPayment(dealId, payment);

        assertEq(validator.getRailStatus(), RailStatus.PREPARED);

        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.RailPaymentModified(railId, payment.railMaxRatePerEpoch);

        vm.prank(address(poRepMarketMock));
        validator.modifyRailPayment(payment.railMaxRatePerEpoch);

        assertEq(validator.getRailStatus(), RailStatus.ACTIVE);
    }

    function testUpdateLockupPeriodEmitsLockupPeriodUpdated() public {
        uint256 newLockupPeriod = 123;

        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.LockupPeriodUpdated(railId, newLockupPeriod);

        validator.updateLockupPeriod(newLockupPeriod);
    }

    function testRailTerminatedEmitsRailTerminatedWithoutChangingRailStatus() public {
        address terminator = address(validator);
        uint256 endEpoch = 777;
        uint8 statusBefore = validator.getRailStatus();

        vm.expectEmit(true, true, false, true, address(validator));
        emit Validator.RailTerminated(railId, terminator, endEpoch);

        vm.prank(address(filecoinPayMock));
        validator.railTerminated(railId, terminator, endEpoch);

        assertEq(validator.getRailStatus(), statusBefore);
    }

    function testCreateRailRevertsWhenRailAlreadyCreated() public {
        vm.expectRevert(Validator.RailAlreadyCreated.selector);
        vm.prank(admin);
        validator.createRail();
    }

    function testCreateRailUsesFrozenDealPaymentTokenAndPayee() public {
        FilecoinPayV1Mock freshFilecoinPay = new FilecoinPayV1Mock();
        PoRepMarketMock freshMarket = new PoRepMarketMock();
        Validator impl = new Validator();
        Validator freshValidator = Validator(address(new ERC1967Proxy(address(impl), "")));

        IERC20 frozenToken = IERC20(vm.addr(0xF007));
        address frozenPayee = vm.addr(0xBEEF);
        freshMarket.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: admin,
                provider: providerFilActorId,
                offerId: 123,
                state: DealState.PROPOSED,
                evidenceAdapter: evidenceAdapter,
                validator: address(0),
                railId: 0
            })
        );
        freshMarket.setDealPayment(
            dealId,
            PoRepTypes.DealPayment({
                paymentToken: address(frozenToken),
                payee: frozenPayee,
                pricePer32GiBPerMonth: 100,
                billed32GiBUnits: 0,
                railMaxRatePerEpoch: 0
            })
        );
        freshFilecoinPay.setOperatorApproval(
            frozenToken, admin, address(freshValidator), true, 1_000_000, 1_000_000, 0, 0, 86_400
        );

        freshValidator.initialize(admin, address(freshFilecoinPay), address(freshMarket), dealId);

        vm.prank(admin);
        freshValidator.createRail();

        (IERC20 railToken,, address railPayee,,,,,) = freshFilecoinPay.rails(1);
        assertEq(address(railToken), address(frozenToken));
        assertEq(railPayee, frozenPayee);
    }

    function testFinalizeDealTerminatesFilecoinPayRailWhenCalledByPoRepMarket() public {
        assertFalse(filecoinPayMock.terminated(railId));
        vm.roll(100);
        activateServiceUntil(100);
        vm.roll(101);

        vm.expectEmit(true, true, false, true, address(validator));
        emit Validator.DealFinalized(dealId, railId);
        vm.prank(address(poRepMarketMock));
        validator.finalizeDeal();
        assertTrue(filecoinPayMock.terminated(railId));
        assertEq(validator.getRailStatus(), RailStatus.TERMINATED);
    }

    function testFinalizeDealTerminatesFilecoinPayRailWithoutCheckingServiceEnd() public {
        assertFalse(filecoinPayMock.terminated(railId));
        vm.roll(100);
        activateServiceUntil(101);
        vm.prank(address(poRepMarketMock));
        validator.finalizeDeal();
        assertTrue(filecoinPayMock.terminated(railId));
        assertEq(validator.getRailStatus(), RailStatus.TERMINATED);
    }

    function testFinalizeDealRevertsWhenCallerIsNotPoRepMarket() public {
        vm.expectRevert(Validator.CallerIsNotPoRepMarket.selector);
        vm.prank(address(123));
        validator.finalizeDeal();
    }

    function testFinalizeDealRevertsWhenRailStatusIsNotActive() public {
        vm.expectRevert(abi.encodeWithSelector(Validator.InvalidRailStatusForTermination.selector, RailStatus.PREPARED));
        vm.prank(address(poRepMarketMock));
        validator.finalizeDeal();
    }

    function testValidatePaymentReturnsMarketServiceEndedDecision() public {
        activateServiceUntil(10);
        poRepMarketMock.setDealService(
            dealId,
            PoRepTypes.DealService({
                serviceStartEpoch: CommonTypes.ChainEpoch.wrap(10),
                serviceEndEpoch: CommonTypes.ChainEpoch.wrap(10),
                earlyTerminationEpoch: CommonTypes.ChainEpoch.wrap(0),
                minTimeBetweenSettlementsInEpochs: EPOCHS_IN_MONTH,
                lastSettledEpoch: CommonTypes.ChainEpoch.wrap(0)
            })
        );
        poRepMarketMock.setSettlementDecision(0, 10, "deal ended");

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(railId, 100, 10, 86_410, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 10);
        assertEq(result.note, "deal ended");
    }

    function testValidatePaymentReturnsMarketServiceEndCapDecision() public {
        activateServiceUntil(1000);

        poRepMarketMock.setSettlementDecision(10_000, 1000, "payment limited to deal endepoch");

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(railId, 10_000, 0, 86_400, 10);

        assertEq(result.modifiedAmount, 10_000);
        assertEq(result.settleUpto, 1000);
        assertEq(result.note, "payment limited to deal endepoch");
    }

    function testCreateRailRevertsWhenOperatorNotApproved() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(admin, address(filecoinPayMock), address(poRepMarketMock), dealId);

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), false, 1_000_000, 1_000_000, 0, 0, 86_400
        );

        vm.expectRevert(Validator.OperatorNotApproved.selector);
        newValidator.createRail();
    }

    function testCreateRailRevertsWhenMaxLockupPeriodLessThanMinimum() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(admin, address(filecoinPayMock), address(poRepMarketMock), dealId);

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), true, 1_000_000, 1_000_000, 0, 0, 86_399
        );

        vm.expectRevert(Validator.MaxLockupPeriodLessThanMinimum.selector);
        newValidator.createRail();
    }

    function testCreateRailRevertsWhenLockupAllowanceIsZero() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(admin, address(filecoinPayMock), address(poRepMarketMock), dealId);

        filecoinPayMock.setOperatorApproval(token, admin, address(newValidator), true, 1_000_000, 0, 0, 0, 86_400);

        vm.expectRevert(Validator.InvalidLockupAllowance.selector);
        newValidator.createRail();
    }

    function testCreateRailRevertsWhenRateAllowanceIsZero() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(admin, address(filecoinPayMock), address(poRepMarketMock), dealId);

        filecoinPayMock.setOperatorApproval(token, admin, address(newValidator), true, 0, 1_000_000, 0, 0, 86_400);

        vm.expectRevert(Validator.InvalidRateAllowance.selector);
        newValidator.createRail();
    }

    function testModifyRailPaymentRevertsWhenCallerIsNotPoRepMarket() public {
        vm.expectRevert(Validator.CallerIsNotPoRepMarket.selector);
        vm.prank(porepService);
        validator.modifyRailPayment(1);
    }

    function testValidatePaymentReturnsMarketDecisionWhenDealPaymentNotActivated() public {
        poRepMarketMock.setSettlementDecision(0, 0, "deal service not started");

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(railId, 100, 0, 86_400, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 0);
        assertEq(result.note, "deal service not started");
    }

    function testCreateRailEmitsInitialLockupPeriodUpdated() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(admin, address(filecoinPayMock), address(poRepMarketMock), dealId);

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), true, 1_000_000, 1_000_000, 0, 0, 86_400
        );

        assertEq(newValidator.getRailStatus(), RailStatus.NONE);

        vm.expectEmit(true, false, false, true, address(newValidator));
        emit Validator.LockupPeriodUpdated(2, 86_400);

        newValidator.createRail();

        assertEq(newValidator.getRailStatus(), RailStatus.PREPARED);
    }

    function testEarlyRailTerminationEmitsEarlyRailTerminated() public {
        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.EarlyRailTerminated(railId);

        vm.prank(address(poRepMarketMock));
        validator.earlyRailTermination();

        assertEq(validator.getRailStatus(), RailStatus.TERMINATED);
    }

    function testEarlyRailTerminationRevertsWhenCallerIsNotPoRepMarket() public {
        vm.expectRevert(Validator.CallerIsNotPoRepMarket.selector);
        vm.prank(porepService);
        validator.earlyRailTermination();
    }

    function testEarlyRailTerminationRevertsWhenRailStatusCannotBeTerminated() public {
        vm.prank(address(poRepMarketMock));
        validator.earlyRailTermination();

        vm.expectRevert(
            abi.encodeWithSelector(Validator.InvalidRailStatusForTermination.selector, RailStatus.TERMINATED)
        );
        vm.prank(address(poRepMarketMock));
        validator.earlyRailTermination();
    }

    function testValidatePaymentReturnsMarketEarlyTerminationCapDecision() public {
        activateServiceUntil(CHAIN_EPOCH);

        vm.warp(BLOCK_TIMESTAMP);

        vm.prank(address(poRepMarketMock));
        validator.earlyRailTermination();
        poRepMarketMock.setSettlementDecision(10, 1, "payment limited to deal termination epoch");

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result =
            validator.validatePayment(railId, 2_000_000, 0, 200_000, 10);

        assertEq(result.modifiedAmount, 10);
        assertEq(result.settleUpto, 1);
        assertEq(result.note, "payment limited to deal termination epoch");
    }

    function testValidatePaymentReturnsMarketEarlierEarlyTerminationDecision() public {
        activateServiceUntil(CHAIN_EPOCH);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 chainEpochConversion = uint256(uint64(CHAIN_EPOCH));
        uint256 earlyTerminationEpoch = chainEpochConversion - 100_000;
        vm.roll(earlyTerminationEpoch);

        vm.prank(address(poRepMarketMock));
        validator.earlyRailTermination();
        poRepMarketMock.setSettlementDecision(
            10 * earlyTerminationEpoch, earlyTerminationEpoch, "payment limited to deal termination epoch"
        );

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result =
            validator.validatePayment(railId, 50000000, 0, chainEpochConversion, 10);

        assertEq(result.modifiedAmount, 10 * earlyTerminationEpoch);
        assertEq(result.settleUpto, earlyTerminationEpoch);
        assertEq(result.note, "payment limited to deal termination epoch");
    }

    function testModifyRailPaymentRevertsWhenCalculatedAmountIsZero() public {
        PoRepTypes.DealPayment memory payment = poRepMarketMock.getDealPayment(dealId);
        payment.railMaxRatePerEpoch = 0;
        poRepMarketMock.setDealPayment(dealId, payment);

        vm.expectRevert(Validator.InvalidZeroAmount.selector);
        vm.prank(address(poRepMarketMock));
        validator.modifyRailPayment(0);
    }

    function testFuzzModifyRailPaymentZeroAmountWithNonZeroParams(uint256 sectorCount, uint256 pricePerSectorPerMonth)
        public
    {
        sectorCount = bound(sectorCount, 1, 1_000);
        uint256 maxPricePerSectorPerMonth = (EPOCHS_IN_MONTH - 1) / sectorCount;
        pricePerSectorPerMonth = bound(pricePerSectorPerMonth, 1, maxPricePerSectorPerMonth);

        PoRepTypes.DealPayment memory payment = poRepMarketMock.getDealPayment(dealId);
        payment.pricePer32GiBPerMonth = pricePerSectorPerMonth;
        payment.billed32GiBUnits = sectorCount;
        payment.railMaxRatePerEpoch = (pricePerSectorPerMonth * sectorCount) / EPOCHS_IN_MONTH;
        poRepMarketMock.setDealPayment(dealId, payment);

        assertEq(payment.railMaxRatePerEpoch, 0);

        vm.expectRevert(Validator.InvalidZeroAmount.selector);
        vm.prank(address(poRepMarketMock));
        validator.modifyRailPayment(payment.railMaxRatePerEpoch);
    }

    function testFuzzModifyRailPaymentSucceedsWhenCalculatedAmountIsNonZero(
        uint256 sectorCount,
        uint256 pricePerSectorPerMonth
    ) public {
        sectorCount = bound(sectorCount, 1, 1_000);
        uint256 minPricePerSectorPerMonth = (EPOCHS_IN_MONTH + sectorCount - 1) / sectorCount;
        pricePerSectorPerMonth = bound(pricePerSectorPerMonth, minPricePerSectorPerMonth, 1_000_000);

        PoRepTypes.DealPayment memory payment = poRepMarketMock.getDealPayment(dealId);
        payment.pricePer32GiBPerMonth = pricePerSectorPerMonth;
        payment.billed32GiBUnits = sectorCount;
        payment.railMaxRatePerEpoch = (pricePerSectorPerMonth * sectorCount) / EPOCHS_IN_MONTH;
        poRepMarketMock.setDealPayment(dealId, payment);

        uint256 expectedAmount = payment.railMaxRatePerEpoch;
        assertGt(expectedAmount, 0);

        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.RailPaymentModified(railId, expectedAmount);

        vm.prank(address(poRepMarketMock));
        validator.modifyRailPayment(expectedAmount);
    }
}

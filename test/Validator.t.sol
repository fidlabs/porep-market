// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity =0.8.30;

import {Test} from "lib/forge-std/src/Test.sol";
import {Validator} from "../src/Validator.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {SLIScorer} from "../src/SLIScorer.sol";
import {IFilecoinPayValidator} from "../src/interfaces/IFilecoinPayValidator.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {DealState} from "../src/types/DealState.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {RailStatus} from "../src/types/RailStatus.sol";
import {SPRegistry} from "../src/SPRegistry.sol";

import {FilecoinPayV1Mock} from "./contracts/FilecoinPayV1Mock.sol";
import {DataCapEvidenceAdapterMock} from "./contracts/DataCapEvidenceAdapterMock.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ValidatorTest is Test {
    Validator public validator;
    FilecoinPayV1Mock public filecoinPayMock;
    PoRepMarketMock public poRepMarketMock;
    SPRegistryMock public spRegistryMock;
    DataCapEvidenceAdapterMock public dataCapEvidenceAdapterMock;
    SLIOracle public sliOracle;
    SLIScorer public sliScorer;
    SPRegistry public spRegistry;

    address public admin;
    address public porepService;
    address public oracleUpdater;
    address public dataCapEvidenceAdapter;
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
        spRegistryMock = new SPRegistryMock();

        admin = address(this);
        porepService = vm.addr(0x123);
        oracleUpdater = vm.addr(0xA11CE);
        dataCapEvidenceAdapter = address(dataCapEvidenceAdapterMock);
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
                evidenceAdapter: dataCapEvidenceAdapter,
                validator: address(0),
                railId: railId
            })
        );
        poRepMarketMock.setDealSLIs(dealId, defaultRequirements);
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
        SLIOracle oracleImpl = new SLIOracle();
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(oracleImpl), "");
        sliOracle = SLIOracle(address(oracleProxy));
        sliOracle.initialize(admin, oracleUpdater);

        SLIScorer scorerImpl = new SLIScorer();
        ERC1967Proxy scorerProxy = new ERC1967Proxy(address(scorerImpl), "");
        sliScorer = SLIScorer(address(scorerProxy));
        sliScorer.initialize(admin, sliOracle);

        Validator impl = new Validator();
        ERC1967Proxy validatorProxy = new ERC1967Proxy(address(impl), "");
        validator = Validator(address(validatorProxy));

        validator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(token, admin, address(validator), true, 1_000_000, 1_000_000, 0, 0, 86_400);

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(1);
        dataCapEvidenceAdapterMock.setAllocationIds(dealId, ids);

        vm.prank(admin);
        validator.createRail(token);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(dealId, defaultRequirements);
    }

    function activateServiceUntil(int64 serviceEndEpoch) internal {
        vm.prank(address(poRepMarketMock));
        poRepMarketMock.setDealService(
            dealId,
            PoRepTypes.DealService({
                serviceStartEpoch: CommonTypes.ChainEpoch.wrap(int64(0)),
                serviceEndEpoch: CommonTypes.ChainEpoch.wrap(serviceEndEpoch)
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
        impl.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testValidatorCannotBeReinitialized() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        validator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testValidatePaymentTooEarlyForNextPayout() public {
        activateServiceUntil(CHAIN_EPOCH);

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, 0, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 0);
        assertEq(result.note, "too early for settlement");
    }

    function testValidatePaymentDatacapMismatch() public {
        activateServiceUntil(CHAIN_EPOCH);

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result =
            validator.validatePayment(1, 100, 0, type(uint256).max, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, type(uint256).max);
        assertEq(result.note, "data size does not match the deal");
    }

    function testValidatePaymentFullSlashWhenScoreZero() public {
        activateServiceUntil(CHAIN_EPOCH);
        dataCapEvidenceAdapterMock.setDataSizeMatching(dealId, true);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(
            dealId,
            SharedTypes.SLIThresholds({retrievabilityBps: 0, bandwidthBytesPerSecond: 0, latencyMs: 0, indexingPct: 0})
        );

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result =
            validator.validatePayment(1, 100, 0, type(uint256).max, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, type(uint256).max);
        assertEq(result.note, "score below required threshold");
    }

    function testValidatePaymentOkWhenScorePositiveAndDatacapMatches() public {
        activateServiceUntil(CHAIN_EPOCH);
        dataCapEvidenceAdapterMock.setDataSizeMatching(dealId, true);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(dealId, defaultRequirements);

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, 86_400, 1);

        assertEq(result.modifiedAmount, 100);
        assertEq(result.settleUpto, 86_400);
        assertEq(result.note, "payment validated successfully");
    }

    function testValidatePaymentCallerIsNotFilecoinPayRevert() public {
        vm.expectRevert(Validator.CallerIsNotFilecoinPay.selector);
        validator.validatePayment(1, 100, 0, 0, 1);
    }

    function testCreateRailCallerIsNotClientRevert() public {
        address notClient = vm.addr(0xCAFE);
        vm.expectRevert(Validator.CallerIsNotClient.selector);
        vm.prank(notClient);
        validator.createRail(token);
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
        newValidator.initialize(
            address(0),
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testInitializeRevertsWhenPoRepServiceIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidPoRepServiceAddress.selector);
        newValidator.initialize(
            admin,
            address(0),
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testInitializeRevertsWhenFilecoinPayIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidFilecoinPayAddress.selector);
        newValidator.initialize(
            admin,
            porepService,
            address(0),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testInitializeRevertsWhenSLIScorerIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidSLIScorerAddress.selector);
        newValidator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(0),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testInitializeRevertsWhenDataCapEvidenceAdapterIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidDataCapEvidenceAdapterAddress.selector);
        newValidator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            address(0),
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testInitializeRevertsWhenPoRepMarketIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidPoRepMarketAddress.selector);
        newValidator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(0),
            address(spRegistryMock),
            dealId
        );
    }

    function testInitializeRevertsWhenSpRegistryIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidSPRegistryAddress.selector);
        newValidator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(0),
            dealId
        );
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
        address terminator = address(0xBEEF);
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
        validator.createRail(token);
    }

    function testFinalizeDealTerminatesFilecoinPayRailAsAnAdmin() public {
        assertFalse(filecoinPayMock.terminated(railId));
        vm.roll(100);
        activateServiceUntil(100);
        vm.roll(101);

        vm.expectEmit(true, true, false, true, address(validator));
        emit Validator.DealFinalized(dealId, railId);
        vm.prank(admin);
        validator.finalizeDeal();
        assertTrue(filecoinPayMock.terminated(railId));
        assertEq(validator.getRailStatus(), RailStatus.TERMINATED);
        assertEq(poRepMarketMock.finalizeDealCallCount(), 1);
    }

    function testFinalizeDealTerminatesFilecoinPayRailAsPoRepService() public {
        assertFalse(filecoinPayMock.terminated(railId));
        vm.roll(100);
        activateServiceUntil(100);
        vm.roll(101);
        vm.prank(porepService);
        validator.finalizeDeal();
        assertTrue(filecoinPayMock.terminated(railId));
        assertEq(validator.getRailStatus(), RailStatus.TERMINATED);
    }

    function testFinalizeDealRevertsBeforeServiceEnds() public {
        vm.roll(100);
        uint256 serviceEndEpoch = 101;
        activateServiceUntil(101);

        vm.expectRevert(abi.encodeWithSelector(Validator.ServiceNotEnded.selector, serviceEndEpoch, block.number));
        vm.prank(porepService);
        validator.finalizeDeal();
    }

    function testFinalizeDealRevertsWhenCallerIsNotPoRepServiceOrAdmin() public {
        vm.expectRevert(Validator.UnauthorizedCaller.selector);
        vm.prank(address(123));
        validator.finalizeDeal();
    }

    function testFinalizeDealRevertsWhenCallerLacksAdminRole() public {
        vm.expectRevert(Validator.UnauthorizedCaller.selector);
        vm.prank(address(123));
        validator.finalizeDeal();
    }

    function testValidatePaymentReturnsServiceEndedWhenFromEpochPastServiceEndEpoch() public {
        activateServiceUntil(10);
        dataCapEvidenceAdapterMock.setDataSizeMatching(dealId, true);

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(railId, 100, 10, 86_410, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 10);
        assertEq(result.note, "service ended");
    }

    function testValidatePaymentCapsSettlementToServiceEndEpoch() public {
        dataCapEvidenceAdapterMock.setDataSizeMatching(dealId, true);
        activateServiceUntil(1000);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(dealId, defaultRequirements);

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(railId, 10_000, 0, 86_400, 10);

        assertEq(result.modifiedAmount, 10 * 1000);
        assertEq(result.settleUpto, 1000);
        assertEq(result.note, "limited to service end epoch");
    }

    function testCreateRailRevertsWhenOperatorNotApproved() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), false, 1_000_000, 1_000_000, 0, 0, 86_400
        );

        vm.expectRevert(Validator.OperatorNotApproved.selector);
        newValidator.createRail(token);
    }

    function testCreateRailRevertsWhenMaxLockupPeriodLessThanMinimum() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), true, 1_000_000, 1_000_000, 0, 0, 86_399
        );

        vm.expectRevert(Validator.MaxLockupPeriodLessThanMinimum.selector);
        newValidator.createRail(token);
    }

    function testCreateRailRevertsWhenLockupAllowanceIsZero() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(token, admin, address(newValidator), true, 1_000_000, 0, 0, 0, 86_400);

        vm.expectRevert(Validator.InvalidLockupAllowance.selector);
        newValidator.createRail(token);
    }

    function testCreateRailRevertsWhenRateAllowanceIsZero() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(token, admin, address(newValidator), true, 0, 1_000_000, 0, 0, 86_400);

        vm.expectRevert(Validator.InvalidRateAllowance.selector);
        newValidator.createRail(token);
    }

    function testModifyRailPaymentRevertsWhenCallerIsNotPoRepMarket() public {
        vm.expectRevert(Validator.CallerIsNotPoRepMarket.selector);
        vm.prank(porepService);
        validator.modifyRailPayment(1);
    }

    function testValidatePaymentRevertsWhenDealPaymentNotActivated() public {
        vm.expectRevert(abi.encodeWithSelector(Validator.DealPaymentNotActivated.selector, dealId));
        vm.prank(address(filecoinPayMock));
        validator.validatePayment(railId, 100, 0, 86_400, 1);
    }

    function testCreateRailEmitsInitialLockupPeriodUpdated() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        newValidator.initialize(
            admin,
            porepService,
            address(filecoinPayMock),
            address(sliScorer),
            dataCapEvidenceAdapter,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), true, 1_000_000, 1_000_000, 0, 0, 86_400
        );

        assertEq(newValidator.getRailStatus(), RailStatus.NONE);

        vm.expectEmit(true, false, false, true, address(newValidator));
        emit Validator.LockupPeriodUpdated(2, 86_400);

        newValidator.createRail(token);

        assertEq(newValidator.getRailStatus(), RailStatus.PREPARED);
    }

    function testEarlyRailTerminationEmitsEarlyRailTerminated() public {
        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.EarlyRailTerminated(railId);

        vm.prank(porepService);
        validator.earlyRailTermination();

        assertEq(validator.getRailStatus(), RailStatus.TERMINATED);
    }

    function testValidatePaymentCapsSettlementToEarlyTerminatedEpoch() public {
        activateServiceUntil(CHAIN_EPOCH);
        dataCapEvidenceAdapterMock.setDataSizeMatching(dealId, true);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(dealId, defaultRequirements);

        vm.warp(BLOCK_TIMESTAMP);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(dealId, defaultRequirements);

        vm.prank(porepService);
        validator.earlyRailTermination();

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result =
            validator.validatePayment(railId, 2_000_000, 0, 200_000, 10);

        assertEq(result.modifiedAmount, 10);
        assertEq(result.settleUpto, 1);
        assertEq(result.note, "limited to service end epoch");
    }

    function testValidatePaymentUsesEarlyTerminatedEpochWhenEarlierThanServiceEndEpoch() public {
        activateServiceUntil(CHAIN_EPOCH);
        dataCapEvidenceAdapterMock.setDataSizeMatching(dealId, true);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 chainEpochConversion = uint256(uint64(CHAIN_EPOCH));
        uint256 earlyTerminationEpoch = chainEpochConversion - 100_000;
        vm.roll(earlyTerminationEpoch);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(dealId, defaultRequirements);

        vm.prank(porepService);
        validator.earlyRailTermination();

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result =
            validator.validatePayment(railId, 50000000, 0, chainEpochConversion, 10);

        assertEq(result.modifiedAmount, 10 * earlyTerminationEpoch);
        assertEq(result.settleUpto, earlyTerminationEpoch);
        assertEq(result.note, "limited to service end epoch");
    }

    function testModifyRailPaymentRevertsWhenCalculatedAmountIsZero() public {
        PoRepTypes.DealPayment memory payment = poRepMarketMock.getDealPayment(dealId);
        payment.railMaxRatePerEpoch = 0;
        poRepMarketMock.setDealPayment(dealId, payment);

        vm.expectRevert(Validator.InvalidZeroAmount.selector);
        vm.prank(address(poRepMarketMock));
        validator.modifyRailPayment(0);
    }

    function testSetMinEpochsBetweenSettlementsRevertsMinTimeNotReached() public {
        vm.expectRevert(Validator.InvalidMinEpochsBetweenSettlements.selector);
        vm.prank(admin);
        validator.setMinEpochsBetweenSettlements(0);
    }

    function testSetMinEpochsBetweenSettlementsRevertsUnathorized() public {
        address unauthorized = vm.addr(0x321);
        bytes32 expectedRole = validator.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, expectedRole)
        );
        vm.prank(unauthorized);
        validator.setMinEpochsBetweenSettlements(0);
    }

    function testSetMinEpochsBetweenSettlementsEmitEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Validator.MinEpochsBetweenSettlementsUpdated(dealId, 1000);
        vm.prank(admin);
        validator.setMinEpochsBetweenSettlements(1000);
    }

    function testSetMinEpochsBetweenSettlementsSuccessful() public {
        uint256 minEpochsBefore = validator.getMinEpochsBetweenSettlements();
        assertEq(minEpochsBefore, 86400);
        vm.prank(admin);
        validator.setMinEpochsBetweenSettlements(1000);
        uint256 minEpochsAfter = validator.getMinEpochsBetweenSettlements();
        assertEq(minEpochsAfter, 1000);
    }

    function testSetMinEpochsBetweenSettlementsRevertsMinTimeExceeded() public {
        vm.expectRevert(Validator.MinEpochsBetweenSettlementsExceeded.selector);
        vm.prank(admin);
        validator.setMinEpochsBetweenSettlements(11051200);
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

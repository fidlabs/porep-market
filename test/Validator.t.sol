// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity =0.8.30;

import {Test} from "lib/forge-std/src/Test.sol";
import {Validator} from "../src/Validator.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {SLIScorer} from "../src/SLIScorer.sol";
import {IFilecoinPayValidator} from "../src/interfaces/IFilecoinPayValidator.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {SLITypes} from "../src/types/SLITypes.sol";
import {SPRegistry} from "../src/SPRegistry.sol";

import {FilecoinPayV1Mock} from "./contracts/FilecoinPayV1Mock.sol";
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
    SLIOracle public sliOracle;
    SLIScorer public sliScorer;
    SPRegistry public spRegistry;

    address public admin;
    address public porepService;
    address public oracleUpdater;
    IERC20 public token;
    CommonTypes.FilActorId public providerFilActorId;
    uint256 public dealId;
    uint256 public railId;
    string public expectedManifestLocation;
    SLITypes.SLIThresholds public defaultRequirements;
    uint256 public constant EPOCHS_IN_MONTH = 86_400;

    function setUp() public {
        filecoinPayMock = new FilecoinPayV1Mock();
        poRepMarketMock = new PoRepMarketMock();
        spRegistryMock = new SPRegistryMock();

        admin = address(this);
        porepService = vm.addr(0x123);
        oracleUpdater = vm.addr(0xA11CE);
        token = IERC20(vm.addr(0x5));
        providerFilActorId = CommonTypes.FilActorId.wrap(20000);
        dealId = 1;
        railId = 1;
        expectedManifestLocation = "https://example.com/manifest";

        defaultRequirements =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: admin,
                provider: providerFilActorId,
                terms: SLITypes.DealTerms({dealSizeBytes: 1024, pricePerSectorPerMonth: 100, durationDays: 365}),
                requirements: defaultRequirements,
                validator: address(0),
                state: PoRepTypes.DealState.Proposed,
                railId: railId,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
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
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(
            token, admin, address(validator), true, 1_000_000, 1_000_000, 0, 0, EPOCHS_IN_MONTH
        );

        vm.prank(admin);
        validator.createRail(token);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(providerFilActorId, defaultRequirements);
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
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testValidatePaymentTooEarlyForNextPayout() public {
        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, 0, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 0);
        assertEq(result.note, "too early for settlement");
    }

    function testValidatePaymentFullSlashWhenScoreZero() public {
        vm.prank(oracleUpdater);
        sliOracle.setSLI(
            providerFilActorId,
            SLITypes.SLIThresholds({retrievabilityBps: 0, bandwidthMbps: 0, latencyMs: 0, indexingPct: 0})
        );

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result =
            validator.validatePayment(1, 100, 0, type(uint256).max, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, type(uint256).max);
        assertEq(result.note, "score below required threshold");
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
            address(poRepMarketMock),
            address(0),
            dealId
        );
    }

    function testUpdateLockupPeriodEmitsLockupPeriodUpdated() public {
        uint256 newLockupPeriod = 123;

        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.LockupPeriodUpdated(railId, newLockupPeriod);

        validator.updateLockupPeriod(newLockupPeriod);
    }

    function testRailTerminatedEmitsRailTerminated() public {
        address terminator = address(0xBEEF);
        uint256 endEpoch = 777;

        vm.expectEmit(true, true, false, true, address(validator));
        emit Validator.RailTerminated(railId, terminator, endEpoch);

        vm.prank(address(filecoinPayMock));
        validator.railTerminated(railId, terminator, endEpoch);
    }

    function testCreateRailRevertsWhenRailAlreadyCreated() public {
        vm.expectRevert(Validator.RailAlreadyCreated.selector);
        vm.prank(admin);
        validator.createRail(token);
    }

    function testTerminateRailTerminatesFilecoinPayRailAsAnAdmin() public {
        assertFalse(filecoinPayMock.terminated(railId));
        vm.prank(admin);
        validator.terminateRail();
        assertTrue(filecoinPayMock.terminated(railId));
    }

    function testTerminateRailTerminatesFilecoinPayRailAsPoRepService() public {
        assertFalse(filecoinPayMock.terminated(railId));
        vm.prank(porepService);
        validator.terminateRail();
        assertTrue(filecoinPayMock.terminated(railId));
    }

    function testTerminateRailRevertsWhenCallerHasPoRepServiceRole() public {
        vm.expectRevert(Validator.UnauthorizedCaller.selector);
        vm.prank(address(123));
        validator.terminateRail();
    }

    function testTerminateRailRevertsWhenCallerHasAdminRole() public {
        vm.expectRevert(Validator.UnauthorizedCaller.selector);
        vm.prank(address(123));
        validator.terminateRail();
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
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), false, 1_000_000, 1_000_000, 0, 0, EPOCHS_IN_MONTH
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
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), true, 1_000_000, 0, 0, 0, EPOCHS_IN_MONTH
        );

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
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), true, 0, 1_000_000, 0, 0, EPOCHS_IN_MONTH
        );

        vm.expectRevert(Validator.InvalidRateAllowance.selector);
        newValidator.createRail(token);
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
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), true, 1_000_000, 1_000_000, 0, 0, EPOCHS_IN_MONTH
        );

        vm.expectEmit(true, false, false, true, address(newValidator));
        emit Validator.LockupPeriodUpdated(2, EPOCHS_IN_MONTH);

        newValidator.createRail(token);
    }

    function testDisableFutureRailPaymentsEmitsRailDisabled() public {
        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.RailDisabled(railId);

        vm.prank(porepService);
        validator.disableFutureRailPayments();
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

    function testValidatePaymentReturnsMarketSettlement() public {
        poRepMarketMock.setSettlementDecision(
            SharedTypes.SettlementDecision({
                settlementAmount: 500,
                // forge-lint: disable-next-line(unsafe-typecast)
                settleUptoEpoch: CommonTypes.ChainEpoch.wrap(int64(uint64(EPOCHS_IN_MONTH))),
                reasonCode: 0,
                result: 0
            })
        );

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result =
            validator.validatePayment(railId, 100, 0, EPOCHS_IN_MONTH, 1);

        assertEq(result.modifiedAmount, 500);
        assertEq(result.settleUpto, EPOCHS_IN_MONTH);
        assertEq(result.note, "payment validated by market");
        assertEq(poRepMarketMock.lastSettlementToEpoch(), EPOCHS_IN_MONTH);
    }

    function testValidatePaymentCapsSettlementToEarlyTerminatedEpoch() public {
        vm.roll(1000);

        vm.prank(porepService);
        validator.disableFutureRailPayments();

        poRepMarketMock.setSettlementDecision(
            SharedTypes.SettlementDecision({
                settlementAmount: 250,
                settleUptoEpoch: CommonTypes.ChainEpoch.wrap(int64(1000)),
                reasonCode: 0,
                result: 0
            })
        );

        vm.prank(address(filecoinPayMock));
        IFilecoinPayValidator.ValidationResult memory result =
            validator.validatePayment(railId, 100, 0, EPOCHS_IN_MONTH, 1);

        assertEq(poRepMarketMock.lastSettlementToEpoch(), 1000);
        assertEq(result.modifiedAmount, 250);
        assertEq(result.settleUpto, 1000);
    }

    function testModifyRailPaymentEmitsRailPaymentModified() public {
        uint256 newRate = 2_000_000;

        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.RailPaymentModified(railId, newRate);

        vm.prank(address(poRepMarketMock));
        validator.modifyRailPayment(newRate);
    }

    function testModifyRailPaymentRevertsWhenCallerIsNotPoRepMarket() public {
        address notMarket = vm.addr(0xAAA);

        vm.expectRevert(Validator.CallerIsNotPoRepMarket.selector);
        vm.prank(notMarket);
        validator.modifyRailPayment(2_000_000);
    }
}

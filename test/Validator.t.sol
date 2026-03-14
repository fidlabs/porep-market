// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {Validator} from "../src/Validator.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {SLIScorer} from "../src/SLIScorer.sol";
import {IValidator} from "../src/interfaces/IValidator.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {SLITypes} from "../src/types/SLITypes.sol";
import {SPRegistry} from "../src/SPRegistry.sol";

import {FilecoinPayV1Mock} from "./contracts/FilecoinPayV1Mock.sol";
import {ClientSCMock} from "./contracts/ClientSCMock.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ValidatorTest is Test {
    Validator public validator;
    FilecoinPayV1Mock public filecoinPayMock;
    PoRepMarketMock public poRepMarketMock;
    SPRegistryMock public spRegistryMock;
    ClientSCMock public clientSCMock;
    SLIOracle public sliOracle;
    SLIScorer public sliScorer;
    SPRegistry public spRegistry;

    address public admin;
    address public porepService;
    address public oracleUpdater;
    address public clientSC;
    IERC20 public token;
    CommonTypes.FilActorId public providerFilActorId;
    uint256 public dealId;
    uint256 public railId;
    string public expectedManifestLocation;

    SLITypes.SLIThresholds public defaultRequirements;
    uint256 public constant BLOCK_TIMESTAMP = 1_772_000_000;
    int64 public constant CHAIN_EPOCH = 5_800_000;

    function setUp() public {
        filecoinPayMock = new FilecoinPayV1Mock();
        clientSCMock = new ClientSCMock();
        poRepMarketMock = new PoRepMarketMock();
        spRegistryMock = new SPRegistryMock();

        admin = address(this);
        porepService = vm.addr(0x123);
        oracleUpdater = vm.addr(0xA11CE);
        clientSC = address(clientSCMock);
        token = IERC20(vm.addr(0x5));
        providerFilActorId = CommonTypes.FilActorId.wrap(20000);
        dealId = 1;
        railId = 1;
        expectedManifestLocation = "https://example.com/manifest";

        defaultRequirements =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: admin,
                provider: providerFilActorId,
                terms: SLITypes.DealTerms({dealSizeBytes: 1024, pricePerSector: 100, durationDays: 365}),
                requirements: defaultRequirements,
                validator: address(0),
                state: PoRepTypes.DealState.Proposed,
                railId: railId,
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
            clientSC,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(token, admin, address(validator), true, 1_000_000, 1_000_000, 0, 0, 86_400);

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(1);
        clientSCMock.setAllocationIds(dealId, ids);

        vm.prank(admin);
        validator.createRail(token);

        vm.prank(clientSC);
        validator.setDealEndEpoch(dealId, CommonTypes.ChainEpoch.wrap(int64(CHAIN_EPOCH)));

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
        validator.updateLockupPeriod(railId, newLockup);

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
            clientSC,
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
            clientSC,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testValidatePaymentTooEarlyForNextPayout() public {
        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, 0, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 0);
        assertEq(result.note, "1mo payout period not reached");
    }

    function testValidatePaymentDatacapMismatch() public {
        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, type(uint256).max, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, type(uint256).max);
        assertEq(result.note, "data size does not match the deal proposal");
    }

    function testValidatePaymentFullSlashWhenScoreZero() public {
        clientSCMock.setDataSizeMatching(dealId, true);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(
            providerFilActorId,
            SLITypes.SLIThresholds({retrievabilityPct: 0, bandwidthMbps: 0, latencyMs: 0, indexingPct: 0})
        );

        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, type(uint256).max, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, type(uint256).max);
        assertEq(result.note, "score below required threshold");
    }

    function testValidatePaymentOkWhenScorePositiveAndDatacapMatches() public {
        clientSCMock.setDataSizeMatching(dealId, true);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(providerFilActorId, defaultRequirements);

        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, 86_400, 1);

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

    function testUpdateLockupPeriodInvalidRailIdRevert() public {
        uint256 wrongRailId = railId + 1;

        vm.expectRevert(abi.encodeWithSelector(Validator.InvalidRailId.selector, railId, wrongRailId));
        vm.prank(admin);
        validator.updateLockupPeriod(wrongRailId, 123);
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
            clientSC,
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
            clientSC,
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
            clientSC,
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
            clientSC,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );
    }

    function testInitializeRevertsWhenClientSCIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator newValidator = Validator(address(proxy));

        vm.expectRevert(Validator.InvalidClientSCAddress.selector);
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
            clientSC,
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
            clientSC,
            address(poRepMarketMock),
            address(0),
            dealId
        );
    }

    function testModifyRailPaymentEmitsRailPaymentModified() public {
        PoRepTypes.DealProposal memory dealProposal = poRepMarketMock.getDealProposal(dealId);
        dealProposal.terms.pricePerSector = 2_000_000;
        poRepMarketMock.setDealProposal(dealId, dealProposal);

        uint256 sectorCount = clientSCMock.getClientAllocationIdsPerDeal(dealId).length;
        uint256 durationMonths = (uint256(dealProposal.terms.durationDays) + 29) / 30;
        uint256 totalEpochs = durationMonths * 86_400;
        uint256 expectedRate = (dealProposal.terms.pricePerSector * sectorCount) / totalEpochs;

        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.RailPaymentModified(railId, expectedRate);

        vm.prank(porepService);
        validator.modifyRailPayment(railId);
    }

    function testUpdateLockupPeriodEmitsLockupPeriodUpdated() public {
        uint256 newLockupPeriod = 123;

        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.LockupPeriodUpdated(railId, newLockupPeriod);

        validator.updateLockupPeriod(railId, newLockupPeriod);
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
        validator.terminateRail(railId);
        assertTrue(filecoinPayMock.terminated(railId));
    }

    function testTerminateRailTerminatesFilecoinPayRailAsPoRepService() public {
        assertFalse(filecoinPayMock.terminated(railId));
        vm.prank(porepService);
        validator.terminateRail(railId);
        assertTrue(filecoinPayMock.terminated(railId));
    }

    function testTerminateRailRevertsWhenCallerHasPoRepServiceRole() public {
        vm.expectRevert(Validator.UnauthorizedCaller.selector);
        vm.prank(address(123));
        validator.terminateRail(railId);
    }

    function testTerminateRailRevertsWhenCallerHasAdminRole() public {
        vm.expectRevert(Validator.UnauthorizedCaller.selector);
        vm.prank(address(123));
        validator.terminateRail(railId);
    }

    function testValidatePaymentReturnsDealEndedWhenFromEpochPastDealEndEpoch() public {
        vm.prank(clientSC);
        validator.setDealEndEpoch(dealId, CommonTypes.ChainEpoch.wrap(int64(10)));

        clientSCMock.setDataSizeMatching(dealId, true);

        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(railId, 100, 10, 86_410, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 10);
        assertEq(result.note, "deal ended");
    }

    function testValidatePaymentCapsSettlementToDealEndEpoch() public {
        clientSCMock.setDataSizeMatching(dealId, true);

        vm.prank(clientSC);
        validator.setDealEndEpoch(dealId, CommonTypes.ChainEpoch.wrap(int64(1000)));

        vm.prank(oracleUpdater);
        sliOracle.setSLI(providerFilActorId, defaultRequirements);

        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(railId, 10_000, 0, 86_400, 10);

        assertEq(result.modifiedAmount, 10 * 1000);
        assertEq(result.settleUpto, 1000);
        assertEq(result.note, "payment limited to deal endepoch");
    }

    function testSetDealEndEpochCallerIsNotClientSCRevert() public {
        vm.expectRevert(Validator.CallerIsNotClientSC.selector);
        validator.setDealEndEpoch(dealId, CommonTypes.ChainEpoch.wrap(int64(1_000_000)));
    }

    function testSetDealEndEpochInvalidDealIdRevert() public {
        uint256 wrongDealId = dealId + 1;

        vm.expectRevert(Validator.InvalidDealId.selector);
        vm.prank(clientSC);
        validator.setDealEndEpoch(wrongDealId, CommonTypes.ChainEpoch.wrap(int64(1_000_000)));
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
            clientSC,
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
            clientSC,
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
            clientSC,
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
            clientSC,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(token, admin, address(newValidator), true, 0, 1_000_000, 0, 0, 86_400);

        vm.expectRevert(Validator.InvalidRateAllowance.selector);
        newValidator.createRail(token);
    }

    function testModifyRailPaymentRevertsWhenSectorCountIsZero() public {
        CommonTypes.FilActorId[] memory emptyIds = new CommonTypes.FilActorId[](0);
        clientSCMock.setAllocationIds(dealId, emptyIds);

        vm.expectRevert(Validator.InvalidSectorCount.selector);
        vm.prank(porepService);
        validator.modifyRailPayment(railId);
    }

    function testModifyRailPaymentRevertsWhenDealDurationIsZero() public {
        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(1);
        clientSCMock.setAllocationIds(dealId, ids);

        PoRepTypes.DealProposal memory dealProposal = poRepMarketMock.getDealProposal(dealId);
        dealProposal.terms.durationDays = 0;
        poRepMarketMock.setDealProposal(dealId, dealProposal);

        vm.expectRevert(Validator.InvalidDealDuration.selector);
        vm.prank(porepService);
        validator.modifyRailPayment(railId);
    }

    function testValidatePaymentRevertsWhenDealNotCompleted() public {
        vm.prank(clientSC);
        validator.setDealEndEpoch(dealId, CommonTypes.ChainEpoch.wrap(int64(0)));

        vm.expectRevert(abi.encodeWithSelector(Validator.DealNotCompleted.selector, dealId));
        vm.prank(address(filecoinPayMock));
        validator.validatePayment(railId, 100, 0, 86_400, 1);
    }

    function testDisableFutureRailPaymentsInvalidRailIdRevert() public {
        uint256 wrongRailId = railId + 1;

        vm.expectRevert(abi.encodeWithSelector(Validator.InvalidRailId.selector, railId, wrongRailId));
        vm.prank(porepService);
        validator.disableFutureRailPayments(wrongRailId);
    }

    function testModifyRailPaymentInvalidRailIdRevert() public {
        uint256 wrongRailId = railId + 1;

        vm.expectRevert(abi.encodeWithSelector(Validator.InvalidRailId.selector, railId, wrongRailId));
        vm.prank(porepService);
        validator.modifyRailPayment(wrongRailId);
    }

    function testTerminateRailInvalidRailIdRevert() public {
        uint256 wrongRailId = railId + 1;

        vm.expectRevert(abi.encodeWithSelector(Validator.InvalidRailId.selector, railId, wrongRailId));
        validator.terminateRail(wrongRailId);
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
            clientSC,
            address(poRepMarketMock),
            address(spRegistryMock),
            dealId
        );

        filecoinPayMock.setOperatorApproval(
            token, admin, address(newValidator), true, 1_000_000, 1_000_000, 0, 0, 86_400
        );

        vm.expectEmit(true, false, false, true, address(newValidator));
        emit Validator.LockupPeriodUpdated(2, 86_400);

        newValidator.createRail(token);
    }

    function testSetDealEndEpochEmitsDealEndEpochUpdated() public {
        CommonTypes.ChainEpoch newEndEpoch = CommonTypes.ChainEpoch.wrap(int64(123_456));

        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.DealEndEpochUpdated(dealId, newEndEpoch);

        vm.prank(clientSC);
        validator.setDealEndEpoch(dealId, newEndEpoch);
    }

    function testDisableFutureRailPaymentsEmitsRailDisabled() public {
        vm.expectEmit(true, false, false, true, address(validator));
        emit Validator.RailDisabled(railId);

        vm.prank(porepService);
        validator.disableFutureRailPayments(railId);
    }

    function testValidatePaymentCapsSettlementToEarlyTerminatedEpoch() public {
        clientSCMock.setDataSizeMatching(dealId, true);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(providerFilActorId, defaultRequirements);

        vm.roll(BLOCK_TIMESTAMP);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(providerFilActorId, defaultRequirements);

        vm.prank(porepService);
        validator.disableFutureRailPayments(railId);

        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(railId, 2_000_000, 0, 200_000, 10);

        assertEq(result.modifiedAmount, 2_000_000);
        assertEq(result.settleUpto, 200_000);
        assertEq(result.note, "payment validated successfully");
    }

    function testValidatePaymentUsesEarlyTerminatedEpochWhenEarlierThanDealEndEpoch() public {
        clientSCMock.setDataSizeMatching(dealId, true);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 chainEpochConversion = uint256(uint64(CHAIN_EPOCH));
        uint256 earlyTerminationEpoch = chainEpochConversion - 100_000;
        vm.roll(earlyTerminationEpoch);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(providerFilActorId, defaultRequirements);

        vm.prank(porepService);
        validator.disableFutureRailPayments(railId);

        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result =
            validator.validatePayment(railId, 50000000, 0, chainEpochConversion, 10);

        assertEq(result.modifiedAmount, 10 * earlyTerminationEpoch);
        assertEq(result.settleUpto, earlyTerminationEpoch);
        assertEq(result.note, "payment limited to deal endepoch");
    }

    function testModifyRailPaymentRevertsWhenCalculatedAmountIsZero() public {
        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(1);
        clientSCMock.setAllocationIds(dealId, ids);

        PoRepTypes.DealProposal memory dealProposal = poRepMarketMock.getDealProposal(dealId);
        dealProposal.terms.pricePerSector = 1;
        dealProposal.terms.durationDays = 3650;
        poRepMarketMock.setDealProposal(dealId, dealProposal);

        vm.expectRevert(Validator.InvalidZeroAmount.selector);
        vm.prank(porepService);
        validator.modifyRailPayment(railId);
    }

    function testSetDealEndEpochNegativeEndEpochRevert() public {
        vm.expectRevert(Validator.NegativeEndEpoch.selector);
        vm.prank(clientSC);
        validator.setDealEndEpoch(dealId, CommonTypes.ChainEpoch.wrap(int64(-1)));
    }
}

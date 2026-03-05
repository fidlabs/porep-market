// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {Validator} from "../src/Validator.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {SLIScorer} from "../src/SLIScorer.sol";
import {IValidator} from "../src/interfaces/IValidator.sol";
import {SLITypes} from "../src/types/SLITypes.sol";

import {FilecoinPayV1Mock} from "./contracts/FilecoinPayV1Mock.sol";
import {ClientSCMock} from "./contracts/ClientSCMock.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ValidatorTest is Test {
    Validator public validator;
    FilecoinPayV1Mock public filecoinPayMock;
    PoRepMarketMock public poRepMarketMock;
    ClientSCMock public clientSCMock;
    SLIOracle public sliOracle;
    SLIScorer public sliScorer;

    address public admin;
    address public oracleUpdater;
    address public clientSC;
    IERC20 public token;
    CommonTypes.FilActorId public providerFilActorId;
    uint256 public dealId;
    uint256 public railId;
    uint256 public totalDealSize;

    SLITypes.SLIThresholds public defaultRequirements;

    function setUp() public {
        filecoinPayMock = new FilecoinPayV1Mock();
        clientSCMock = new ClientSCMock();
        poRepMarketMock = new PoRepMarketMock();

        admin = address(this);
        oracleUpdater = vm.addr(0xA11CE);
        clientSC = address(clientSCMock);
        token = IERC20(vm.addr(0x5));
        providerFilActorId = CommonTypes.FilActorId.wrap(20000);
        dealId = 1;
        railId = 1;
        totalDealSize = 1024;

        defaultRequirements =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepMarket.DealProposal({
                dealId: dealId,
                client: admin,
                provider: providerFilActorId,
                requirements: defaultRequirements,
                validator: address(0),
                state: PoRepMarket.DealState.Proposed,
                railId: railId,
                totalDealSize: totalDealSize
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
            admin, address(filecoinPayMock), address(sliScorer), clientSC, address(poRepMarketMock), dealId
        );

        vm.prank(clientSC);
        validator.createRail(token, address(clientSCMock), address(this));

        vm.prank(oracleUpdater);
        sliOracle.setSLI(providerFilActorId, defaultRequirements);
    }

    function testIsAdminSet() public view {
        bytes32 adminRole = validator.DEFAULT_ADMIN_ROLE();
        assertTrue(validator.hasRole(adminRole, admin));
    }

    function testUpdateLockupPeriodCallerIsNotClientSCRevert() public {
        vm.expectRevert(Validator.CallerIsNotClientSC.selector);
        validator.updateLockupPeriod(1, 2);
    }

    function testRailTerminatedCallerIsNotFilecoinPayRevert() public {
        vm.expectRevert(Validator.CallerIsNotFilecoinPay.selector);
        validator.railTerminated(1, address(this), 0);
    }

    function testUpdateLockupPeriodUpdatesFilecoinPayRail() public {
        uint256 newLockup = 123;

        vm.prank(clientSC);
        validator.updateLockupPeriod(railId, newLockup);

        (uint256 lockupPeriod, uint256 lockupFixed) = filecoinPayMock.getRailLockup(railId);
        assertEq(lockupPeriod, newLockup);
        assertEq(lockupFixed, 0);
    }

    function testImplementationContractCannotBeInitialized() public {
        Validator impl = new Validator();
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        impl.initialize(admin, address(filecoinPayMock), address(sliScorer), clientSC, address(poRepMarketMock), dealId);
    }

    function testValidatorCannotBeReinitialized() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        validator.initialize(
            admin, address(filecoinPayMock), address(sliScorer), clientSC, address(poRepMarketMock), dealId
        );
    }

    function testValidatePaymentTooEarlyForNextPayout() public {
        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, 0, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 0);
        assertEq(result.note, "too early for next payout");
    }

    function testValidatePaymentDatacapMismatch() public {
        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, type(uint256).max, 1);
        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 0);
        assertEq(result.note, "datacap mismatch");
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
        assertEq(result.note, "full slash");
    }

    function testValidatePaymentOkWhenScorePositiveAndDatacapMatches() public {
        clientSCMock.setDataSizeMatching(dealId, true);

        vm.prank(oracleUpdater);
        sliOracle.setSLI(providerFilActorId, defaultRequirements);

        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, type(uint256).max, 1);

        assertEq(result.modifiedAmount, 100);
        assertEq(result.settleUpto, type(uint256).max);
        assertEq(result.note, "ok");
    }

    function testValidatePaymentCallerIsNotFilecoinPayRevert() public {
        vm.expectRevert(Validator.CallerIsNotFilecoinPay.selector);
        validator.validatePayment(1, 100, 0, 0, 1);
    }

    function testCreateRailCallerIsNotClientSCRevert() public {
        vm.expectRevert(Validator.CallerIsNotClientSC.selector);
        validator.createRail(token, address(clientSCMock), address(this));
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
        vm.prank(clientSC);
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
        Validator validator = Validator(address(proxy));

        vm.expectRevert(Validator.AdminCannotBeZeroAddress.selector);
        validator.initialize(
            address(0), address(filecoinPayMock), address(sliScorer), clientSC, address(poRepMarketMock), dealId
        );
    }

    function testInitializeRevertsWhenFilecoinPayIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator validator = Validator(address(proxy));

        vm.expectRevert(Validator.FilecoinPayCannotBeZeroAddress.selector);
        validator.initialize(admin, address(0), address(sliScorer), clientSC, address(poRepMarketMock), dealId);
    }

    function testInitializeRevertsWhenSLCIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator validator = Validator(address(proxy));

        vm.expectRevert(Validator.SLCCannotBeZeroAddress.selector);
        validator.initialize(admin, address(filecoinPayMock), address(0), clientSC, address(poRepMarketMock), dealId);
    }

    function testInitializeRevertsWhenClientSCIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator validator = Validator(address(proxy));

        vm.expectRevert(Validator.ClientSCCannotBeZeroAddress.selector);
        validator.initialize(
            admin, address(filecoinPayMock), address(sliScorer), address(0), address(poRepMarketMock), dealId
        );
    }

    function testInitializeRevertsWhenPoRepMarketIsZeroAddress() public {
        Validator impl = new Validator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Validator validator = Validator(address(proxy));

        vm.expectRevert(Validator.PoRepMarketCannotBeZeroAddress.selector);
        validator.initialize(admin, address(filecoinPayMock), address(sliScorer), clientSC, address(0), dealId);
    }
}

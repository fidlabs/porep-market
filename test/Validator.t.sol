// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {Validator} from "../src/Validator.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {Client} from "../src/Client.sol";
import {IFilecoinPayV1} from "../src/interfaces/IFilecoinPayV1.sol";
import {IValidator} from "../src/interfaces/IValidator.sol";
import {SLITypes} from "../src/types/SLITypes.sol";

import {FilecoinPayV1Mock} from "./contracts/FilecoinPayV1Mock.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorFactoryMock} from "./contracts/ValidatorFactoryMock.sol";
import {ClientSCMock} from "./contracts/ClientSCMock.sol";
import {SLCMock} from "./contracts/SLCMock.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ValidatorTest is Test {
    Validator public validator;
    FilecoinPayV1Mock public filecoinPayMock;
    PoRepMarketMock public poRepMarketMock;
    SPRegistryMock public spRegistry;
    ValidatorFactoryMock public validatorFactory;
    SLCMock public slcMock;
    ClientSCMock public clientSCMock;

    address public admin;
    address public slc;
    address public clientSC;
    address public providerOwner;
    IERC20 public token;
    CommonTypes.FilActorId public providerFilActorId;
    uint256 public dealId;
    uint256 public railId;
    uint256 public totalDealSize;

    SLITypes.SLIThresholds public defaultRequirements;

    function setUp() public {
        filecoinPayMock = new FilecoinPayV1Mock();
        spRegistry = new SPRegistryMock();
        validatorFactory = new ValidatorFactoryMock();
        slcMock = new SLCMock();
        clientSCMock = new ClientSCMock();
        poRepMarketMock = new PoRepMarketMock();

        admin = address(this);
        slc = address(slcMock);
        clientSC = address(clientSCMock);
        providerOwner = vm.addr(0x4);
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

        Validator impl = new Validator();
        ERC1967Proxy validatorProxy = new ERC1967Proxy(address(impl), "");
        validator = Validator(address(validatorProxy));

        validatorFactory.setValidator(address(validator), true);

        validator.initialize(admin, address(filecoinPayMock), slc, clientSC, address(poRepMarketMock), dealId);

        vm.prank(clientSC);
        validator.createRail(token, address(clientSCMock), address(this));
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
        impl.initialize(admin, address(filecoinPayMock), slc, clientSC, address(poRepMarketMock), dealId);
    }

    function testValidatorCannotBeReinitialized() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        validator.initialize(admin, address(filecoinPayMock), slc, clientSC, address(poRepMarketMock), dealId);
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
        clientSCMock.setValid(providerFilActorId, true);

        vm.prank(address(filecoinPayMock));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, type(uint256).max, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, type(uint256).max);
        assertEq(result.note, "full slash");
    }

    function testValidatePaymentOkWhenScorePositiveAndDatacapMatches() public {
        slcMock.setScore(providerFilActorId, 100);
        clientSCMock.setValid(providerFilActorId, true);

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
}

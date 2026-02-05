// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {Validator} from "../src/Validator.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {Operator} from "../src/abstracts/Operator.sol";
import {IFilecoinPayV1} from "../src/interfaces/IFilecoinPayV1.sol";
import {MinerUtils} from "../src/libs/MinerUtils.sol";
import {IValidator} from "../src/interfaces/IValidator.sol";

import {FilecoinPayV1Mock} from "./contracts/FilecoinPayV1Mock.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ActorIdMock} from "./contracts/ActorIdMock.sol";
import {ValidatorRegistryMock} from "./contracts/ValidatorRegistryMock.sol";
import {ResolveAddressPrecompileMock} from "./contracts/ResolveAddressPrecompileMock.sol";
import {ActorIdExitCodeErrorFailingMock} from "./contracts/ActorIdExitCodeErrorFailingMock.sol";
import {ClientSCMock} from "./contracts/ClientSCMock.sol";
import {SLCMock} from "./contracts/SLCMock.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ValidatorTest is Test {
    Validator public validator;
    IFilecoinPayV1 public filecoinPay;
    FilecoinPayV1Mock public filecoinPayMock;
    PoRepMarket public poRepMarket;
    SPRegistryMock public spRegistry;
    ValidatorRegistryMock public validatorRegistry;
    SLCMock public slcMock;
    ClientSCMock public clientSCMock;

    ActorIdMock public actorIdMock;
    ResolveAddressPrecompileMock public resolveAddressPrecompileMock;
    ResolveAddressPrecompileMock public resolveAddress =
        ResolveAddressPrecompileMock(payable(0xFE00000000000000000000000000000000000001));
    address public constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;

    address public admin;
    address public slc;
    address public clientSC;
    address public providerOwner;
    IERC20 public token;
    CommonTypes.FilActorId public providerFilActorId;
    uint256 public dealId;

    function setUp() public {
        filecoinPay = IFilecoinPayV1(address(new FilecoinPayV1Mock()));
        filecoinPayMock = FilecoinPayV1Mock(address(filecoinPay));
        spRegistry = new SPRegistryMock();
        validatorRegistry = new ValidatorRegistryMock();
        slcMock = new SLCMock();
        clientSCMock = new ClientSCMock();

        admin = address(this);
        slc = address(slcMock);
        clientSC = address(clientSCMock);
        providerOwner = vm.addr(0x4);
        token = IERC20(vm.addr(0x5));
        providerFilActorId = CommonTypes.FilActorId.wrap(20000);
        dealId = 1;

        actorIdMock = new ActorIdMock();
        resolveAddressPrecompileMock = new ResolveAddressPrecompileMock();

        vm.etch(CALL_ACTOR_ID, address(actorIdMock).code);
        vm.etch(address(resolveAddress), address(resolveAddressPrecompileMock).code);

        resolveAddress.setAddress(hex"00C2A101", uint64(20000));
        resolveAddress.setId(providerOwner, uint64(20000));

        spRegistry.setProvider(slc, providerFilActorId);
        spRegistry.setIsOwner(providerOwner, providerFilActorId, true);

        PoRepMarket poRepImpl = new PoRepMarket();
        bytes memory poRepInit = abi.encodeWithSignature(
            "initialize(address,address,address)", address(validatorRegistry), address(spRegistry), clientSC
        );
        ERC1967Proxy poRepProxy = new ERC1967Proxy(address(poRepImpl), poRepInit);
        poRepMarket = PoRepMarket(address(poRepProxy));

        vm.prank(clientSC);
        poRepMarket.proposeDeal(100, 150, slc);
        vm.prank(providerOwner);
        poRepMarket.acceptDeal(dealId);

        Validator impl = new Validator();
        ERC1967Proxy validatorProxy = new ERC1967Proxy(address(impl), "");
        validator = Validator(address(validatorProxy));

        validatorRegistry.setValidator(address(validator), true);

        Operator.DepositWithRailParams memory initParams = Operator.DepositWithRailParams({
            token: token,
            payer: address(0),
            payee: address(0),
            v: 27,
            amount: 100,
            deadline: block.timestamp + 1 days,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2)),
            dealId: dealId
        });

        validator.initialize(admin, address(filecoinPay), slc, clientSC, address(poRepMarket), initParams);
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

    function testInitializeRevertExitCodeError() public {
        ActorIdExitCodeErrorFailingMock failing = new ActorIdExitCodeErrorFailingMock();
        vm.etch(CALL_ACTOR_ID, address(failing).code);

        Validator impl = new Validator();
        ERC1967Proxy validatorProxy = new ERC1967Proxy(address(impl), "");
        Validator badValidator = Validator(address(validatorProxy));

        Operator.DepositWithRailParams memory params = Operator.DepositWithRailParams({
            token: token,
            payer: address(0),
            payee: address(0),
            v: 27,
            amount: 100,
            deadline: block.timestamp + 1 days,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2)),
            dealId: dealId
        });

        vm.expectRevert(MinerUtils.ExitCodeError.selector);
        badValidator.initialize(admin, address(filecoinPay), slc, clientSC, address(poRepMarket), params);
    }

    function testUpdateLockupPeriodUpdatesFilecoinPayRail() public {
        uint256 newLockup = 123;

        vm.prank(clientSC);
        validator.updateLockupPeriod(1, newLockup);

        (uint256 lockupPeriod, uint256 lockupFixed) = filecoinPayMock.getRailLockup(1);
        assertEq(lockupPeriod, newLockup);
        assertEq(lockupFixed, 0);
    }

    function testImplementationContractCannotBeInitialized() public {
        Validator impl = new Validator();

        Operator.DepositWithRailParams memory params = Operator.DepositWithRailParams({
            token: token,
            payer: address(0),
            payee: address(0),
            v: 27,
            amount: 100,
            deadline: block.timestamp + 1 days,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2)),
            dealId: dealId
        });

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        impl.initialize(admin, address(filecoinPay), slc, clientSC, address(poRepMarket), params);
    }

    function testValidatorCannotBeReinitialized() public {
        Operator.DepositWithRailParams memory params = Operator.DepositWithRailParams({
            token: token,
            payer: address(0),
            payee: address(0),
            v: 27,
            amount: 100,
            deadline: block.timestamp + 1 days,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2)),
            dealId: dealId
        });

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        validator.initialize(admin, address(filecoinPay), slc, clientSC, address(poRepMarket), params);
    }

    function testValidatePaymentTooEarlyForNextPayout() public {
        vm.prank(address(filecoinPay));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, 0, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 0);
        assertEq(result.note, "too early for next payout");
    }

    function testValidatePaymentDatacapMismatch() public {
        vm.prank(address(filecoinPay));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, type(uint256).max, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, 0);
        assertEq(result.note, "datacap mismatch");
    }

    function testValidatePaymentFullSlashWhenScoreZero() public {
        clientSCMock.setValid(providerFilActorId, true);

        vm.prank(address(filecoinPay));
        IValidator.ValidationResult memory result = validator.validatePayment(1, 100, 0, type(uint256).max, 1);

        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, type(uint256).max);
        assertEq(result.note, "full slash");
    }

    function testValidatePaymentOkWhenScorePositiveAndDatacapMatches() public {
        slcMock.setScore(providerFilActorId, 100);
        clientSCMock.setValid(providerFilActorId, true);

        vm.prank(address(filecoinPay));
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

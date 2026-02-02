// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {Validator} from "../src/Validator.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {Operator} from "../src/abstracts/Operator.sol";
import {FilecoinPayV1Mock} from "./contracts/FilecoinPayV1Mock.sol";
import {SPRegistryMock} from "./contracts/SPRegistryMock.sol";
import {ValidatorRegistryMock} from "./contracts/ValidatorRegistryMock.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract ValidatorTest is Test {
    Validator public validator;
    FilecoinPayV1Mock public filecoinPay;
    PoRepMarket public poRepMarket;
    SPRegistryMock public spRegistry;
    ValidatorRegistryMock public validatorRegistry;

    address public admin;
    address public slc;
    address public clientSC;
    address public providerOwner;
    IERC20 public token;
    CommonTypes.FilActorId public providerFilActorId;
    uint256 public dealId;

    function setUp() public {
        filecoinPay = new FilecoinPayV1Mock();
        spRegistry = new SPRegistryMock();
        validatorRegistry = new ValidatorRegistryMock();

        admin = address(this);
        slc = vm.addr(0x2);
        clientSC = vm.addr(0x3);
        providerOwner = vm.addr(0x4);
        token = IERC20(vm.addr(0x5));
        providerFilActorId = CommonTypes.FilActorId.wrap(1);
        dealId = 1;

        spRegistry.setProvider(slc, providerFilActorId);
        spRegistry.setIsOwner(providerOwner, providerFilActorId, true);

        PoRepMarket poRepImpl = new PoRepMarket();
        bytes memory poRepInit = abi.encodeWithSignature(
            "initialize(address,address,address)", address(validatorRegistry), address(spRegistry), clientSC
        );
        ERC1967Proxy poRepProxy = new ERC1967Proxy(address(poRepImpl), poRepInit);
        poRepMarket = PoRepMarket(address(poRepProxy));

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

        Validator impl = new Validator();
        bytes memory initData = abi.encodeWithSelector(
            Validator.initialize.selector, admin, address(filecoinPay), slc, clientSC, address(poRepMarket), initParams
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        validator = Validator(address(proxy));

        validatorRegistry.setValidator(address(validator), true);

        vm.prank(clientSC);
        poRepMarket.proposeDeal(100, 150, slc);
        vm.prank(providerOwner);
        poRepMarket.acceptDeal(dealId);
    }

    function testIsAdminSet() public view {
        bytes32 adminRole = validator.DEFAULT_ADMIN_ROLE();
        assertTrue(validator.hasRole(adminRole, address(this)));
    }

    function testImplementationInitializeRevert() public {
        Validator impl = new Validator();

        vm.expectRevert(Initializable.InvalidInitialization.selector);

        Operator.DepositWithRailParams memory dummyParams = Operator.DepositWithRailParams({
            token: IERC20(address(0)),
            payer: address(0),
            payee: address(0),
            v: 0,
            amount: 0,
            deadline: 0,
            r: bytes32(0),
            s: bytes32(0),
            dealId: 0
        });

        impl.initialize(vm.addr(0x1), vm.addr(0x2), vm.addr(0x3), vm.addr(0x4), vm.addr(0x5), dummyParams);
    }

    function testDepositWithPermitAndCreateRailForDeal() public {
        address payer = vm.addr(0xA);
        address payee = vm.addr(0xB);

        uint256 amount = 100;
        uint256 deadline = block.timestamp + 1 days;
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));

        Operator.DepositWithRailParams memory params = Operator.DepositWithRailParams({
            token: token,
            payer: payer,
            payee: payee,
            v: v,
            amount: amount,
            deadline: deadline,
            r: r,
            s: s,
            dealId: dealId
        });

        validator.depositWithPermitAndCreateRailForDeal(params);

        PoRepMarket.DealProposal memory dp = poRepMarket.getDealProposal(dealId);
        assertEq(dp.validator, address(validator));
        assertEq(dp.railId, 1);
    }

    function testUpdateLockupPeriod() public {
        uint256 railId = 1;
        uint256 newLockupPeriod = 60 days;
        uint256 lockupFixed = 500;

        vm.prank(clientSC);
        validator.updateLockupPeriod(railId, newLockupPeriod, lockupFixed);

        assertEq(filecoinPay.lastRailIdForLockup(), railId);
        assertEq(filecoinPay.lastNewLockupPeriod(), newLockupPeriod);
        assertEq(filecoinPay.lastLockupFixed(), lockupFixed);
    }

    function testUpdateLockupPeriodCallerIsNotClientSCRevert() public {
        vm.expectRevert(Validator.CallerIsNotClientSC.selector);
        validator.updateLockupPeriod(1, 2, 3);
    }

    function testRailTerminatedRevert() public {
        vm.expectRevert(Validator.CallerIsNotFilecoinPay.selector);
        validator.railTerminated(1, address(this), 0);
    }
}

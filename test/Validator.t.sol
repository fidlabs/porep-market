// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {Validator} from "../src/Validator.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
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

        Validator impl = new Validator();
        bytes memory initData = abi.encodeWithSelector(
            Validator.initialize.selector,
            admin,
            address(filecoinPay),
            slc,
            providerFilActorId,
            clientSC,
            address(poRepMarket)
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

        impl.initialize(
            vm.addr(0x1), vm.addr(0x2), vm.addr(0x3), CommonTypes.FilActorId.wrap(1), vm.addr(0x4), vm.addr(0x5)
        );
    }

    function testDepositWithPermitAndCreateRailForDeal() public {
        address payer = vm.addr(0xA);
        address payee = vm.addr(0xB);
        address feeRecipient = vm.addr(0xC);

        uint256 amount = 100;
        uint256 deadline = block.timestamp + 1 days;
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));
        uint256 rateAllowance = 1_000;
        uint256 lockupAllowance = 2_000;
        uint256 maxLockup = 30 days;
        uint256 commission = 500;

        validator.depositWithPermitAndCreateRailForDeal(
            token,
            payer,
            payee,
            amount,
            deadline,
            v,
            r,
            s,
            rateAllowance,
            lockupAllowance,
            maxLockup,
            commission,
            feeRecipient,
            dealId
        );

        assertEq(address(filecoinPay.lastToken()), address(token));
        assertEq(filecoinPay.lastPayer(), payer);
        assertEq(filecoinPay.lastAmount(), amount);
        assertEq(filecoinPay.lastDeadline(), deadline);
        assertEq(filecoinPay.lastV(), v);
        assertEq(filecoinPay.lastR(), r);
        assertEq(filecoinPay.lastS(), s);
        assertEq(filecoinPay.lastOperator(), address(validator));
        assertEq(filecoinPay.lastRateAllowance(), rateAllowance);
        assertEq(filecoinPay.lastLockupAllowance(), lockupAllowance);
        assertEq(filecoinPay.lastMaxLockupPeriod(), maxLockup);

        assertEq(address(filecoinPay.lastRailToken()), address(token));
        assertEq(filecoinPay.lastRailPayer(), payer);
        assertEq(filecoinPay.lastRailPayee(), payee);
        assertEq(filecoinPay.lastRailOperator(), address(validator));
        assertEq(filecoinPay.lastCommissionRateBps(), commission);
        assertEq(filecoinPay.lastServiceFeeRecipient(), feeRecipient);

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

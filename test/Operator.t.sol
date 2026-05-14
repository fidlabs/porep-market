// SPDX-License-Identifier: MIT
// solhint-disable one-contract-per-file, use-natspec
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FilecoinPayV1} from "filecoin-pay/FilecoinPayV1.sol";

import {Operator} from "../src/Operator.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock USDFC", "mUSDFC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OperatorTest is Test {
    FilecoinPayV1 internal filecoinPay;
    MockToken internal token;
    Operator internal operator;

    address internal admin = makeAddr("admin");
    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");

    uint256 internal constant DEPOSIT_AMOUNT = 10_000e18;
    uint256 internal constant RETRIEVAL_PRICE = 100e18;

    function setUp() public {
        filecoinPay = new FilecoinPayV1();
        token = new MockToken();
        Operator implementation = new Operator();
        operator = _deployOperatorProxy(address(implementation), admin, address(filecoinPay), IERC20(address(token)));

        token.mint(payer, DEPOSIT_AMOUNT);

        vm.startPrank(payer);
        token.approve(address(filecoinPay), DEPOSIT_AMOUNT);
        filecoinPay.deposit(IERC20(address(token)), payer, DEPOSIT_AMOUNT);
        filecoinPay.setOperatorApproval(IERC20(address(token)), address(operator), true, 0, RETRIEVAL_PRICE, 0);
        vm.stopPrank();
    }

    function testInitializeRejectsZeroAdmin() public {
        Operator implementation = new Operator();

        vm.expectRevert(Operator.InvalidAdminAddress.selector);
        _deployOperatorProxy(address(implementation), address(0), address(filecoinPay), IERC20(address(token)));
    }

    function testInitializeRejectsZeroFilecoinPay() public {
        Operator implementation = new Operator();

        vm.expectRevert(Operator.InvalidFilecoinPayAddress.selector);
        _deployOperatorProxy(address(implementation), admin, address(0), IERC20(address(token)));
    }

    function testInitializeRejectsZeroToken() public {
        Operator implementation = new Operator();

        vm.expectRevert(Operator.InvalidTokenAddress.selector);
        _deployOperatorProxy(address(implementation), admin, address(filecoinPay), IERC20(address(0)));
    }

    function testCreateRailRevertsWhenOperatorNotApproved() public {
        vm.prank(payer);
        filecoinPay.setOperatorApproval(IERC20(address(token)), address(operator), false, 0, RETRIEVAL_PRICE, 0);

        vm.prank(admin);
        vm.expectRevert(Operator.OperatorNotApproved.selector);
        operator.createRail(payer, payee, RETRIEVAL_PRICE);
    }

    function testCreateRailRevertsForZeroFixedLockup() public {
        vm.prank(admin);
        vm.expectRevert(Operator.InvalidFixedLockupAmount.selector);
        operator.createRail(payer, payee, 0);
    }

    function testCreateRailRevertsForInsufficientLockupAllowance() public {
        vm.prank(payer);
        filecoinPay.setOperatorApproval(IERC20(address(token)), address(operator), true, 0, RETRIEVAL_PRICE - 1, 0);

        vm.prank(admin);
        vm.expectRevert(Operator.InvalidLockupAllowance.selector);
        operator.createRail(payer, payee, RETRIEVAL_PRICE);
    }

    function testModifyRailPaymentRevertsForUnknownRail() public {
        vm.prank(admin);
        vm.expectRevert(Operator.InvalidRailId.selector);
        operator.modifyRailPayment(999);
    }

    function testTerminateRailRevertsForUnknownRail() public {
        vm.prank(admin);
        vm.expectRevert(Operator.InvalidRailId.selector);
        operator.terminateRail(999);
    }

    function testCreateRailWorksWithFixedLockupOnlyApproval() public {
        vm.prank(admin);
        operator.createRail(payer, payee, RETRIEVAL_PRICE);

        FilecoinPayV1.RailView memory rail = filecoinPay.getRail(1);
        assertEq(rail.from, payer);
        assertEq(rail.to, payee);
        assertEq(rail.operator, address(operator));
        assertEq(rail.paymentRate, 0);
        assertEq(rail.lockupPeriod, 0);
        assertEq(rail.lockupFixed, RETRIEVAL_PRICE);

        (,,,, uint256 lockupUsage, uint256 maxLockupPeriod) =
            filecoinPay.operatorApprovals(IERC20(address(token)), payer, address(operator));
        assertEq(lockupUsage, RETRIEVAL_PRICE);
        assertEq(maxLockupPeriod, 0);
    }

    function testModifyRailPaymentPaysAndFinalizesRail() public {
        vm.prank(admin);
        operator.createRail(payer, payee, RETRIEVAL_PRICE);

        vm.prank(admin);
        operator.modifyRailPayment(1);

        (uint256 payerFunds,,,) = filecoinPay.accounts(IERC20(address(token)), payer);
        (uint256 payeeFunds,,,) = filecoinPay.accounts(IERC20(address(token)), payee);
        (,,,, uint256 lockupUsage,) = filecoinPay.operatorApprovals(IERC20(address(token)), payer, address(operator));

        assertEq(payerFunds, DEPOSIT_AMOUNT - RETRIEVAL_PRICE);
        assertEq(payeeFunds, RETRIEVAL_PRICE - _networkFee(RETRIEVAL_PRICE));
        assertEq(lockupUsage, 0);

        vm.expectRevert();
        filecoinPay.getRail(1);
    }

    function testTerminateRailReleasesLockupAndFinalizesRail() public {
        vm.prank(admin);
        operator.createRail(payer, payee, RETRIEVAL_PRICE);

        vm.prank(admin);
        operator.terminateRail(1);

        (uint256 payerFunds,,,) = filecoinPay.accounts(IERC20(address(token)), payer);
        (uint256 payeeFunds,,,) = filecoinPay.accounts(IERC20(address(token)), payee);
        (,,,, uint256 lockupUsage,) = filecoinPay.operatorApprovals(IERC20(address(token)), payer, address(operator));

        assertEq(payerFunds, DEPOSIT_AMOUNT);
        assertEq(payeeFunds, 0);
        assertEq(lockupUsage, 0);

        vm.expectRevert();
        filecoinPay.getRail(1);
    }

    function testTerminateRailFinalizesRailAlreadyTerminatedByPayer() public {
        vm.prank(admin);
        operator.createRail(payer, payee, RETRIEVAL_PRICE);

        vm.prank(payer);
        filecoinPay.terminateRail(1);

        vm.prank(admin);
        operator.terminateRail(1);

        (uint256 payerFunds,,,) = filecoinPay.accounts(IERC20(address(token)), payer);
        (uint256 payeeFunds,,,) = filecoinPay.accounts(IERC20(address(token)), payee);
        (,,,, uint256 lockupUsage,) = filecoinPay.operatorApprovals(IERC20(address(token)), payer, address(operator));

        assertEq(payerFunds, DEPOSIT_AMOUNT);
        assertEq(payeeFunds, 0);
        assertEq(lockupUsage, 0);

        vm.expectRevert();
        filecoinPay.getRail(1);
    }

    function _networkFee(uint256 amount) internal pure returns (uint256) {
        return (amount + 199) / 200;
    }

    function _deployOperatorProxy(
        address implementation,
        address operatorAdmin,
        address filecoinPayAddress,
        IERC20 paymentToken
    ) internal returns (Operator) {
        bytes memory init = abi.encodeCall(Operator.initialize, (operatorAdmin, filecoinPayAddress, paymentToken));
        return Operator(address(new ERC1967Proxy(implementation, init)));
    }
}

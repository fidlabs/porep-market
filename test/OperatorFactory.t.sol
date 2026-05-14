// SPDX-License-Identifier: MIT
// solhint-disable one-contract-per-file, use-natspec, gas-custom-errors
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FilecoinPayV1} from "filecoin-pay/FilecoinPayV1.sol";

import {Operator} from "../src/Operator.sol";
import {OperatorFactory} from "../src/OperatorFactory.sol";

contract FactoryMockToken is ERC20 {
    constructor() ERC20("Mock USDFC", "mUSDFC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OperatorFactoryTest is Test {
    bytes32 internal constant PROXY_CREATED_TOPIC = keccak256("ProxyCreated(address)");
    bytes32 internal constant DISABLED_ROLE = keccak256("DISABLED_ROLE");

    address internal admin = makeAddr("admin");
    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");

    uint256 internal constant DEPOSIT_AMOUNT = 10_000e18;
    uint256 internal constant RETRIEVAL_PRICE = 100e18;

    function testInitializeRejectsZeroAdmin() public {
        FilecoinPayV1 filecoinPay = new FilecoinPayV1();
        FactoryMockToken token = new FactoryMockToken();
        Operator implementation = new Operator();
        OperatorFactory factoryImplementation = new OperatorFactory();

        vm.expectRevert(OperatorFactory.InvalidAdminAddress.selector);
        _deployFactoryProxyWithParams(
            address(factoryImplementation),
            address(0),
            address(implementation),
            address(filecoinPay),
            IERC20(address(token))
        );
    }

    function testInitializeRejectsZeroImplementation() public {
        FilecoinPayV1 filecoinPay = new FilecoinPayV1();
        FactoryMockToken token = new FactoryMockToken();
        OperatorFactory factoryImplementation = new OperatorFactory();

        vm.expectRevert(OperatorFactory.InvalidImplementationAddress.selector);
        _deployFactoryProxyWithParams(
            address(factoryImplementation), admin, address(0), address(filecoinPay), IERC20(address(token))
        );
    }

    function testInitializeRejectsZeroFilecoinPay() public {
        FactoryMockToken token = new FactoryMockToken();
        Operator implementation = new Operator();
        OperatorFactory factoryImplementation = new OperatorFactory();

        vm.expectRevert(OperatorFactory.InvalidFilecoinPayAddress.selector);
        _deployFactoryProxyWithParams(
            address(factoryImplementation), admin, address(implementation), address(0), IERC20(address(token))
        );
    }

    function testInitializeRejectsZeroToken() public {
        FilecoinPayV1 filecoinPay = new FilecoinPayV1();
        Operator implementation = new Operator();
        OperatorFactory factoryImplementation = new OperatorFactory();

        vm.expectRevert(OperatorFactory.InvalidTokenAddress.selector);
        _deployFactoryProxyWithParams(
            address(factoryImplementation), admin, address(implementation), address(filecoinPay), IERC20(address(0))
        );
    }

    function testCreateDeploysUsableInitializedOperator() public {
        FilecoinPayV1 filecoinPay = new FilecoinPayV1();
        FactoryMockToken token = new FactoryMockToken();
        OperatorFactory factory = _deployFactory(filecoinPay, IERC20(address(token)));

        vm.recordLogs();
        vm.prank(admin);
        factory.create();
        address operatorProxy = _operatorProxyFromLogs(vm.getRecordedLogs());

        token.mint(payer, DEPOSIT_AMOUNT);

        vm.startPrank(payer);
        token.approve(address(filecoinPay), DEPOSIT_AMOUNT);
        filecoinPay.deposit(IERC20(address(token)), payer, DEPOSIT_AMOUNT);
        filecoinPay.setOperatorApproval(IERC20(address(token)), operatorProxy, true, 0, RETRIEVAL_PRICE, 0);
        vm.stopPrank();

        vm.prank(admin);
        Operator(operatorProxy).createRail(payer, payee, RETRIEVAL_PRICE);

        FilecoinPayV1.RailView memory rail = filecoinPay.getRail(1);
        assertEq(rail.from, payer);
        assertEq(rail.to, payee);
        assertEq(rail.operator, operatorProxy);
        assertEq(rail.lockupFixed, RETRIEVAL_PRICE);
        assertTrue(factory.isOperatorContract(operatorProxy));
        assertEq(UpgradeableBeacon(factory.getBeacon()).owner(), address(factory));
    }

    function testCreateCanDeployMultipleOperatorsInSameBlock() public {
        FilecoinPayV1 filecoinPay = new FilecoinPayV1();
        FactoryMockToken token = new FactoryMockToken();
        OperatorFactory factory = _deployFactory(filecoinPay, IERC20(address(token)));

        vm.recordLogs();
        vm.startPrank(admin);
        factory.create();
        factory.create();
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address firstOperatorProxy = _operatorProxyFromLog(logs, 0);
        address secondOperatorProxy = _operatorProxyFromLog(logs, 1);

        assertTrue(firstOperatorProxy != secondOperatorProxy);
        assertTrue(factory.isOperatorContract(firstOperatorProxy));
        assertTrue(factory.isOperatorContract(secondOperatorProxy));
    }

    function testCreateRequiresAdminRole() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));

        vm.expectRevert();
        factory.create();
    }

    function testSetAdminUpdatesDefaultAdmin() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        factory.setAdmin(newAdmin);

        assertFalse(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertFalse(factory.hasRole(factory.UPGRADER_ROLE(), admin));
        assertTrue(factory.hasRole(factory.UPGRADER_ROLE(), newAdmin));
    }

    function testSetAdminRejectsZeroAddress() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));

        vm.prank(admin);
        vm.expectRevert(OperatorFactory.InvalidNewAdminAddress.selector);
        factory.setAdmin(address(0));
    }

    function testSetUpgraderRoleUpdatesRole() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));
        address newUpgrader = makeAddr("newUpgrader");

        vm.prank(admin);
        factory.setUpgraderRole(newUpgrader);

        assertFalse(factory.hasRole(factory.UPGRADER_ROLE(), admin));
        assertTrue(factory.hasRole(factory.UPGRADER_ROLE(), newUpgrader));
    }

    function testSetFilecoinPayConfigUpdatesFutureOperatorConfig() public {
        FilecoinPayV1 oldFilecoinPay = new FilecoinPayV1();
        FilecoinPayV1 newFilecoinPay = new FilecoinPayV1();
        FactoryMockToken oldToken = new FactoryMockToken();
        FactoryMockToken newToken = new FactoryMockToken();
        OperatorFactory factory = _deployFactory(oldFilecoinPay, IERC20(address(oldToken)));

        vm.prank(admin);
        factory.setFilecoinPayConfig(address(newFilecoinPay), IERC20(address(newToken)));

        vm.recordLogs();
        vm.prank(admin);
        factory.create();
        address operatorProxy = _operatorProxyFromLogs(vm.getRecordedLogs());

        newToken.mint(payer, DEPOSIT_AMOUNT);

        vm.startPrank(payer);
        newToken.approve(address(newFilecoinPay), DEPOSIT_AMOUNT);
        newFilecoinPay.deposit(IERC20(address(newToken)), payer, DEPOSIT_AMOUNT);
        newFilecoinPay.setOperatorApproval(IERC20(address(newToken)), operatorProxy, true, 0, RETRIEVAL_PRICE, 0);
        vm.stopPrank();

        vm.prank(admin);
        Operator(operatorProxy).createRail(payer, payee, RETRIEVAL_PRICE);

        FilecoinPayV1.RailView memory rail = newFilecoinPay.getRail(1);
        assertEq(rail.operator, operatorProxy);
        assertEq(rail.lockupFixed, RETRIEVAL_PRICE);
    }

    function testSetFilecoinPayConfigRejectsZeroValues() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));
        FactoryMockToken token = new FactoryMockToken();
        FilecoinPayV1 filecoinPay = new FilecoinPayV1();

        vm.prank(admin);
        vm.expectRevert(OperatorFactory.InvalidNewFilecoinPayAddress.selector);
        factory.setFilecoinPayConfig(address(0), IERC20(address(token)));

        vm.prank(admin);
        vm.expectRevert(OperatorFactory.InvalidNewTokenAddress.selector);
        factory.setFilecoinPayConfig(address(filecoinPay), IERC20(address(0)));
    }

    function testSetUpgraderRoleRejectsZeroAddress() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));

        vm.prank(admin);
        vm.expectRevert(OperatorFactory.InvalidNewUpgraderRoleAddress.selector);
        factory.setUpgraderRole(address(0));
    }

    function testRoleManagementFunctionsAreDisabled() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));

        vm.expectRevert(OperatorFactory.RoleManagementDisabled.selector);
        factory.grantRole(DISABLED_ROLE, admin);

        vm.expectRevert(OperatorFactory.RoleManagementDisabled.selector);
        factory.revokeRole(DISABLED_ROLE, admin);

        vm.expectRevert(OperatorFactory.RoleManagementDisabled.selector);
        factory.renounceRole(DISABLED_ROLE, admin);
    }

    function testAdminCanUpgradeFactoryImplementation() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));
        address beaconBefore = factory.getBeacon();
        OperatorFactory newImplementation = new OperatorFactory();

        vm.prank(admin);
        factory.upgradeToAndCall(address(newImplementation), "");

        assertEq(factory.getBeacon(), beaconBefore);
    }

    function testUpgraderCanUpgradeOperatorBeaconImplementation() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));
        address beacon = factory.getBeacon();
        Operator newOperatorImplementation = new Operator();

        vm.prank(admin);
        factory.upgradeOperatorImplementation(address(newOperatorImplementation));

        assertEq(UpgradeableBeacon(beacon).implementation(), address(newOperatorImplementation));
    }

    function testRotatedUpgraderControlsOperatorBeaconImplementation() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));
        address newUpgrader = makeAddr("newUpgrader");

        vm.prank(admin);
        factory.setUpgraderRole(newUpgrader);

        Operator rejectedImplementation = new Operator();
        vm.prank(admin);
        vm.expectRevert();
        factory.upgradeOperatorImplementation(address(rejectedImplementation));

        Operator newOperatorImplementation = new Operator();
        vm.prank(newUpgrader);
        factory.upgradeOperatorImplementation(address(newOperatorImplementation));

        assertEq(UpgradeableBeacon(factory.getBeacon()).implementation(), address(newOperatorImplementation));
    }

    function testUpgradeOperatorImplementationRejectsZeroAddress() public {
        OperatorFactory factory = _deployFactory(new FilecoinPayV1(), IERC20(address(new FactoryMockToken())));

        vm.prank(admin);
        vm.expectRevert(OperatorFactory.InvalidImplementationAddress.selector);
        factory.upgradeOperatorImplementation(address(0));
    }

    function _deployFactory(FilecoinPayV1 filecoinPay, IERC20 paymentToken) internal returns (OperatorFactory) {
        Operator implementation = new Operator();

        return _deployFactoryWithParams(admin, address(implementation), address(filecoinPay), paymentToken);
    }

    function _deployFactoryWithParams(
        address factoryAdmin,
        address operatorImplementation,
        address filecoinPay,
        IERC20 paymentToken
    ) internal returns (OperatorFactory) {
        OperatorFactory factoryImplementation = new OperatorFactory();

        return _deployFactoryProxyWithParams(
            address(factoryImplementation), factoryAdmin, operatorImplementation, filecoinPay, paymentToken
        );
    }

    function _deployFactoryProxyWithParams(
        address factoryImplementation,
        address factoryAdmin,
        address operatorImplementation,
        address filecoinPay,
        IERC20 paymentToken
    ) internal returns (OperatorFactory) {
        bytes memory init = abi.encodeCall(
            OperatorFactory.initialize, (factoryAdmin, operatorImplementation, filecoinPay, paymentToken)
        );

        return OperatorFactory(address(new ERC1967Proxy(factoryImplementation, init)));
    }

    function _operatorProxyFromLogs(Vm.Log[] memory logs) internal pure returns (address) {
        return _operatorProxyFromLog(logs, 0);
    }

    function _operatorProxyFromLog(Vm.Log[] memory logs, uint256 matchIndex) internal pure returns (address) {
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PROXY_CREATED_TOPIC) {
                if (seen == matchIndex) {
                    return address(uint160(uint256(logs[i].topics[1])));
                }
                seen++;
            }
        }
        revert("ProxyCreated not emitted");
    }
}

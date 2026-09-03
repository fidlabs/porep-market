// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, no-empty-blocks, no-inline-assembly, avoid-low-level-calls
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {AccessManager} from "../src/AccessManager.sol";
import {AccessControlledUpgradeable} from "../src/abstracts/AccessControlledUpgradeable.sol";

contract AccessControlledHarness is AccessControlledUpgradeable {
    function initialize(address manager) external initializer {
        __AccessControlled_init(manager);
    }

    function hasManagedRole(bytes32 role, address account) external view returns (bool) {
        return _hasRole(role, account);
    }

    function checkRole(bytes32 role) external view {
        _checkRole(role);
    }

    function checkRole(bytes32 role, address account) external view {
        _checkRole(role, account);
    }

    function adminOnly() external view onlyRole(bytes32(0)) {}
}

contract RevertingManager {
    error ManagerUnavailable();

    function hasRole(bytes32, address) external pure returns (bool) {
        revert ManagerUnavailable();
    }
}

contract MalformedManager {
    fallback() external {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

contract RawReturnManager {
    uint256 private immutable RETURN_SIZE;
    uint256 private immutable RETURN_VALUE;

    constructor(uint256 size, uint256 value) {
        RETURN_SIZE = size;
        RETURN_VALUE = value;
    }

    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        uint256 size = RETURN_SIZE;
        uint256 value = RETURN_VALUE;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, value)
            mstore(add(pointer, 0x20), 0)
            return(pointer, size)
        }
    }
}

contract BeaconImplementationV1 {}

contract BeaconImplementationV2 {}

contract AccessManagerTest is Test {
    bytes32 internal constant ACCESS_MANAGER_STORAGE_LOCATION =
        0x5fb8a3382c2de59c0ced6c5b31ee681f5bd1a0ad890fb5581ffeccfdb2f2e900;

    address internal admin = vm.addr(1);
    address internal newAdmin = vm.addr(2);
    address internal upgrader = vm.addr(3);
    address internal newUpgrader = vm.addr(4);

    AccessManager internal manager;
    AccessControlledHarness internal target;

    function setUp() public {
        manager = new AccessManager(admin, upgrader);
        target = new AccessControlledHarness();
        target.initialize(address(manager));
    }

    function testConstructorRejectsZeroAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new AccessManager(address(0), upgrader);
    }

    function testConstructorRejectsZeroUpgrader() public {
        vm.expectRevert(abi.encodeWithSelector(AccessManager.InvalidInitialUpgrader.selector, address(0)));
        new AccessManager(admin, address(0));
    }

    function testInitialAdminAndUpgraderCanMatchButRemainSeparateRoles() public {
        AccessManager sameAccountManager = new AccessManager(admin, admin);

        assertTrue(sameAccountManager.hasRole(sameAccountManager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(sameAccountManager.hasRole(sameAccountManager.UPGRADER_ROLE(), admin));
        assertEq(sameAccountManager.getRoleAdmin(sameAccountManager.UPGRADER_ROLE()), bytes32(0));
        assertFalse(sameAccountManager.hasRole(sameAccountManager.DEFAULT_ADMIN_ROLE(), address(sameAccountManager)));
        assertFalse(sameAccountManager.hasRole(sameAccountManager.UPGRADER_ROLE(), address(sameAccountManager)));
    }

    function testDelayedAdminTransferDoesNotMoveUpgraderRole() public {
        bytes32 upgraderRole = manager.UPGRADER_ROLE();
        vm.prank(admin);
        manager.beginDefaultAdminTransfer(newAdmin);
        (address pending, uint48 schedule) = manager.pendingDefaultAdmin();
        assertEq(pending, newAdmin);
        assertEq(schedule, block.timestamp + 3 days);

        vm.prank(newAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        manager.acceptDefaultAdminTransfer();

        vm.warp(uint256(schedule) + 1);
        vm.prank(newAdmin);
        manager.acceptDefaultAdminTransfer();

        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertFalse(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(manager.hasRole(upgraderRole, upgrader));
        assertFalse(manager.hasRole(upgraderRole, newAdmin));

        vm.startPrank(newAdmin);
        manager.grantRole(upgraderRole, newUpgrader);
        manager.revokeRole(upgraderRole, upgrader);
        vm.stopPrank();
        assertTrue(manager.hasRole(upgraderRole, newUpgrader));
        assertFalse(manager.hasRole(upgraderRole, upgrader));
    }

    function testAdminTransferChangesTargetAdminAccess() public {
        bytes32 adminRole = manager.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        target.adminOnly();

        vm.prank(admin);
        manager.beginDefaultAdminTransfer(newAdmin);
        (, uint48 schedule) = manager.pendingDefaultAdmin();
        vm.warp(uint256(schedule) + 1);
        vm.prank(newAdmin);
        manager.acceptDefaultAdminTransfer();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, adminRole)
        );
        target.adminOnly();
        vm.prank(newAdmin);
        target.adminOnly();
    }

    function testGlobalRoleGrantAndRevokeTakeEffectImmediately() public {
        bytes32 role = manager.ORACLE_ROLE();
        assertFalse(target.hasManagedRole(role, newAdmin));

        vm.prank(admin);
        manager.grantRole(role, newAdmin);
        assertTrue(target.hasManagedRole(role, newAdmin));
        target.checkRole(role, newAdmin);

        vm.prank(admin);
        manager.revokeRole(role, newAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, newAdmin, role)
        );
        target.checkRole(role, newAdmin);
    }

    function testCheckRoleUsesCallerAndExpectedError() public {
        bytes32 role = manager.OPERATOR_ROLE();
        vm.prank(newAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, newAdmin, role)
        );
        target.checkRole(role);
    }

    function testTargetRejectsZeroAndNonContractManagers() public {
        AccessControlledHarness zeroTarget = new AccessControlledHarness();
        vm.expectRevert(abi.encodeWithSelector(AccessControlledUpgradeable.InvalidAccessManager.selector, address(0)));
        zeroTarget.initialize(address(0));

        AccessControlledHarness eoaTarget = new AccessControlledHarness();
        vm.expectRevert(abi.encodeWithSelector(AccessControlledUpgradeable.InvalidAccessManager.selector, newAdmin));
        eoaTarget.initialize(newAdmin);
    }

    function testManagerUsesDeclaredErc7201StorageSlot() public view {
        assertEq(address(uint160(uint256(vm.load(address(target), ACCESS_MANAGER_STORAGE_LOCATION)))), address(manager));
    }

    function testRevertingAndMalformedManagersFailClosed() public {
        bytes32 adminRole = manager.DEFAULT_ADMIN_ROLE();
        RevertingManager revertingManager = new RevertingManager();
        AccessControlledHarness revertingTarget = new AccessControlledHarness();
        revertingTarget.initialize(address(revertingManager));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), adminRole)
        );
        revertingTarget.adminOnly();

        MalformedManager malformedManager = new MalformedManager();
        AccessControlledHarness malformedTarget = new AccessControlledHarness();
        malformedTarget.initialize(address(malformedManager));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), adminRole)
        );
        malformedTarget.adminOnly();
    }

    function testManagerReturnDataMustBeExactlyOneAbiBoolean() public {
        uint256[8] memory sizes = [uint256(0), 1, 31, 32, 33, 64, 32, 32];
        uint256[8] memory values = [uint256(1), 1, 1, 2, 1, 1, 0, type(uint256).max];
        for (uint256 i; i < sizes.length; ++i) {
            AccessControlledHarness malformedTarget = new AccessControlledHarness();
            malformedTarget.initialize(address(new RawReturnManager(sizes[i], values[i])));
            assertFalse(malformedTarget.hasManagedRole(bytes32(0), admin));
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, bytes32(0))
            );
            malformedTarget.adminOnly();
        }

        AccessControlledHarness validTarget = new AccessControlledHarness();
        validTarget.initialize(address(new RawReturnManager(32, 1)));
        assertTrue(validTarget.hasManagedRole(bytes32(0), admin));
        vm.prank(admin);
        validTarget.adminOnly();
    }

    function testShortManagerResponseCannotReuseCalldataAsTrue() public {
        // A 31-byte return leaves the final byte of the output buffer unchanged from the role calldata.
        bytes32 role = bytes32(uint256(1) << 32);
        AccessControlledHarness shortTarget = new AccessControlledHarness();
        shortTarget.initialize(address(new RawReturnManager(31, 0)));
        assertFalse(shortTarget.hasManagedRole(role, admin));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        shortTarget.checkRole(role);
    }

    function testTargetsDoNotExposeLocalRoleAdministration() public {
        (bool grantSuccess,) =
            address(target).call(abi.encodeWithSignature("grantRole(bytes32,address)", manager.ORACLE_ROLE(), newAdmin));
        (bool revokeSuccess,) = address(target)
            .call(abi.encodeWithSignature("revokeRole(bytes32,address)", manager.ORACLE_ROLE(), newAdmin));
        (bool adminSuccess,) =
            address(target).call(abi.encodeWithSignature("getRoleAdmin(bytes32)", manager.ORACLE_ROLE()));
        (bool hasRoleSuccess,) =
            address(target).call(abi.encodeWithSignature("hasRole(bytes32,address)", manager.ORACLE_ROLE(), newAdmin));

        assertFalse(grantSuccess);
        assertFalse(revokeSuccess);
        assertFalse(adminSuccess);
        assertFalse(hasRoleSuccess);
    }

    function testDefaultAdminCannotBePermanentlyRenounced() public {
        bytes32 adminRole = manager.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        manager.renounceRole(adminRole, admin);
    }

    function testOrdinaryRoleCanBeRenounced() public {
        bytes32 operatorRole = manager.OPERATOR_ROLE();
        vm.prank(admin);
        manager.grantRole(operatorRole, newAdmin);
        vm.prank(newAdmin);
        manager.renounceRole(operatorRole, newAdmin);
        assertFalse(manager.hasRole(operatorRole, newAdmin));
    }

    function testUpgradeBeaconRejectsNonContractTarget() public {
        BeaconImplementationV2 implementationV2 = new BeaconImplementationV2();
        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(AccessManager.InvalidBeacon.selector, newAdmin));
        manager.upgradeBeacon(newAdmin, address(implementationV2));
    }

    function testUpgradeBeaconRejectsBeaconNotOwnedByManager() public {
        BeaconImplementationV1 implementationV1 = new BeaconImplementationV1();
        BeaconImplementationV2 implementationV2 = new BeaconImplementationV2();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementationV1), admin);

        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(AccessManager.InvalidBeacon.selector, address(beacon)));
        manager.upgradeBeacon(address(beacon), address(implementationV2));
        assertEq(beacon.implementation(), address(implementationV1));
    }

    function testManagerDoesNotExposeGenericExecute() public {
        BeaconImplementationV1 implementationV1 = new BeaconImplementationV1();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementationV1), address(manager));
        bytes memory transferOwnership = abi.encodeWithSignature("transferOwnership(address)", newAdmin);

        vm.prank(upgrader);
        (bool success,) =
            address(manager).call(abi.encodeWithSignature("execute(address,bytes)", address(beacon), transferOwnership));

        assertFalse(success);
        assertEq(beacon.owner(), address(manager));
    }

    function testOnlyUpgraderCanUpgradeBeacon() public {
        BeaconImplementationV1 implementationV1 = new BeaconImplementationV1();
        BeaconImplementationV2 implementationV2 = new BeaconImplementationV2();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementationV1), address(manager));
        bytes32 upgraderRole = manager.UPGRADER_ROLE();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, upgraderRole)
        );
        manager.upgradeBeacon(address(beacon), address(implementationV2));
    }

    function testUpgradeBeaconUpgradesManagerOwnedBeacon() public {
        BeaconImplementationV1 implementationV1 = new BeaconImplementationV1();
        BeaconImplementationV2 implementationV2 = new BeaconImplementationV2();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementationV1), address(manager));
        assertEq(beacon.owner(), address(manager));

        vm.prank(upgrader);
        manager.upgradeBeacon(address(beacon), address(implementationV2));
        assertEq(beacon.implementation(), address(implementationV2));
    }

    function testUpgradeBeaconBubblesBeaconRevert() public {
        BeaconImplementationV1 implementationV1 = new BeaconImplementationV1();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementationV1), address(manager));

        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableBeacon.BeaconInvalidImplementation.selector, newAdmin));
        manager.upgradeBeacon(address(beacon), newAdmin);
    }
}

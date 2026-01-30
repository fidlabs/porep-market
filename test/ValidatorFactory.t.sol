// SPDX-License-Identifier: MIT
// solhint-disable use-natspec

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ValidatorFactory} from "../src/ValidatorFactory.sol";
import {Validator} from "../src/Validator.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ValidatorFactoryTest is Test {
    ValidatorFactory public factory;
    address public validatorAddress;
    address public admin;
    address public filecoinPay;
    address public slcAddress;
    address public poRepMarket;
    address public clientSmartContract;
    CommonTypes.FilActorId public provider;
    ValidatorFactory public factoryImpl;
    bytes public initData;
    Validator.DepositWithRailParams public params;

    function setUp() public {
        admin = vm.addr(1);
        filecoinPay = vm.addr(2);
        slcAddress = vm.addr(3);
        poRepMarket = vm.addr(4);
        clientSmartContract = vm.addr(5);
        provider = CommonTypes.FilActorId.wrap(1);
        validatorAddress = address(new Validator());
        factoryImpl = new ValidatorFactory();
        params = Validator.DepositWithRailParams({
            token: IERC20(vm.addr(7)),
            payer: vm.addr(8),
            payee: vm.addr(9),
            amount: 100,
            deadline: 1000,
            v: 0,
            r: bytes32(0),
            s: bytes32(0),
            dealId: 100
        });
        initData = abi.encodeCall(
            ValidatorFactory.initialize, (admin, validatorAddress, poRepMarket, clientSmartContract, filecoinPay)
        );
        factory = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));
    }

    function testEmitsUpgradedInConstructor() public {
        vm.expectEmit(true, true, true, true);
        emit UpgradeableBeacon.Upgraded(validatorAddress);
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function testDeployEmitsEvent() public {
        vm.expectEmit(true, true, true, true);

        address expectedProxy = computeProxyAddress(admin, provider, factory.getNonce(admin, provider) + 1);
        emit ValidatorFactory.ProxyCreated(expectedProxy, provider);

        factory.create(admin, slcAddress, provider, params);
        assertTrue(factory.isValidatorContract(expectedProxy));
    }

    function testDeployMarksProxyAsDeployed() public {
        address expectedProxy = computeProxyAddress(admin, provider, factory.getNonce(admin, provider) + 1);
        factory.create(admin, slcAddress, provider, params);

        assertTrue(factory.getInstance(params.dealId) == expectedProxy);
    }

    function testDeployIncrementsNonce() public {
        factory.create(admin, slcAddress, provider, params);
        assertEq(factory.getNonce(admin, provider), 1);
    }

    function testDeployRevertsIfInstanceExists() public {
        factory.create(admin, slcAddress, provider, params);

        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InstanceAlreadyExists.selector));
        factory.create(admin, slcAddress, provider, params);
    }

    function computeProxyAddress(address admin_, CommonTypes.FilActorId provider_, uint256 nonce)
        private
        view
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(
                address(factory.getBeacon()),
                abi.encodeCall(
                    Validator.initialize,
                    (admin_, filecoinPay, slcAddress, provider_, clientSmartContract, poRepMarket, params)
                )
            )
        );
        bytes32 salt = keccak256(abi.encode(admin, provider, nonce));
        bytes32 bytecodeHash = keccak256(initCode);
        return Create2.computeAddress(salt, bytecodeHash, address(factory));
    }

    function testAuthorizeUpgradeRevert() public {
        address newImpl = address(new ValidatorFactory());
        address unauthorized = vm.addr(999);
        bytes32 upgraderRole = factory.UPGRADER_ROLE();
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, upgraderRole)
        );
        factory.upgradeToAndCall(newImpl, "");
    }

    function testShouldReturnFalseIfValidatorDoesNotExist() public view {
        assertFalse(factory.isValidatorContract(address(0)));
    }
}

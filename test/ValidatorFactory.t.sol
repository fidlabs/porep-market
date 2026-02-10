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
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SLIThresholds} from "../src/types/SLITypes.sol";

contract ValidatorFactoryTest is Test {
    ValidatorFactory public factory;
    address public validatorAddress;
    address public admin;
    address public filecoinPay;
    address public slcAddress;
    address public poRepMarket;
    address public clientSmartContract;
    address public client;
    CommonTypes.FilActorId public provider;
    ValidatorFactory public factoryImpl;
    bytes public initData;
    Validator.DepositWithRailParams public params;
    PoRepMarketMock public poRepMarketMock;

    function setUp() public {
        admin = vm.addr(1);
        filecoinPay = vm.addr(2);
        slcAddress = vm.addr(3);
        poRepMarketMock = new PoRepMarketMock();
        poRepMarket = address(poRepMarketMock);
        clientSmartContract = vm.addr(5);
        client = vm.addr(6);
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
        poRepMarketMock.setDealProposal(
            params.dealId,
            PoRepMarket.DealProposal({
                dealId: params.dealId,
                client: client,
                provider: provider,
                requirements: SLIThresholds({
                    retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                validator: vm.addr(10),
                state: PoRepMarket.DealState.Accepted,
                railId: 200
            })
        );

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

        address expectedProxy = computeProxyAddress(admin, provider, 1);
        emit ValidatorFactory.ProxyCreated(expectedProxy, provider);

        vm.prank(client);
        factory.create(admin, slcAddress, provider, params);
        assertTrue(factory.isValidatorContract(expectedProxy));
    }

    function testDeployMarksProxyAsDeployed() public {
        address expectedProxy = computeProxyAddress(admin, provider, 1);
        vm.prank(client);
        factory.create(admin, slcAddress, provider, params);

        assertTrue(factory.getInstance(params.dealId) == expectedProxy);
    }

    function testDeployRevertsIfInstanceExists() public {
        vm.prank(client);
        factory.create(admin, slcAddress, provider, params);

        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InstanceAlreadyExists.selector));
        vm.prank(client);
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

    function testShouldRevertWhenAdminAddressIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidAdminAddress.selector));
        vm.prank(client);
        factory.create(address(0), slcAddress, provider, params);
    }

    function testShouldRevertWhenSlcAddressIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidSlcAddress.selector));
        vm.prank(client);
        factory.create(admin, address(0), provider, params);
    }

    function testShouldRevertWhenIncorrectClientAddress() public {
        address incorrectClient = vm.addr(999);
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidClientAddress.selector));
        vm.prank(incorrectClient);
        factory.create(admin, slcAddress, provider, params);
    }
}

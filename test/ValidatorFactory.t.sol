// SPDX-License-Identifier: MIT
// solhint-disable use-natspec

pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ValidatorFactory} from "../src/ValidatorFactory.sol";
import {Validator} from "../src/Validator.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {DealState} from "../src/types/DealState.sol";
import {DealType} from "../src/types/DealType.sol";
import {AccessManager} from "../src/AccessManager.sol";
import {AccessControlledUpgradeable} from "../src/abstracts/AccessControlledUpgradeable.sol";

contract ValidatorFactoryTest is Test {
    ValidatorFactory public factory;
    AccessManager public accessManager;
    address public validatorAddress;
    address public admin;
    address public poRepService;
    address public filecoinPay;
    address public dataCapEvidenceAdapter;
    address public poRepMarket;
    address public client;
    uint256 public dealId;
    CommonTypes.FilActorId public provider;
    ValidatorFactory public factoryImpl;
    bytes public initialData;
    PoRepMarketMock public poRepMarketMock;

    function setUp() public {
        admin = vm.addr(1);
        accessManager = new AccessManager(admin, admin);
        poRepService = vm.addr(2);
        filecoinPay = vm.addr(3);
        dataCapEvidenceAdapter = vm.addr(5);
        poRepMarketMock = new PoRepMarketMock();
        poRepMarket = address(poRepMarketMock);
        client = vm.addr(6);
        dealId = 1;
        provider = CommonTypes.FilActorId.wrap(1);
        validatorAddress = address(new Validator());
        factoryImpl = new ValidatorFactory();
        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: client,
                provider: provider,
                offerId: 0,
                state: DealState.ACCEPTED,
                evidenceAdapter: dataCapEvidenceAdapter,
                validator: vm.addr(10),
                railId: 200,
                proposedAtEpoch: CommonTypes.ChainEpoch.wrap(0),
                dealType: DealType.PUBLIC
            })
        );

        initialData = abi.encodeCall(ValidatorFactory.initialize, (address(accessManager), validatorAddress));
        factory = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.prank(admin);
        factory.initialize2(filecoinPay, poRepMarket);
    }

    function testEmitsUpgradedInConstructor() public {
        vm.expectEmit(true, true, true, true);
        emit UpgradeableBeacon.Upgraded(validatorAddress);
        new ERC1967Proxy(address(factoryImpl), initialData);
    }

    function testDeployEmitsEvent() public {
        vm.expectEmit(true, true, true, true);

        address expectedProxy = computeProxyAddress(address(accessManager), dealId);
        emit ValidatorFactory.ProxyCreated(expectedProxy, dealId);

        vm.prank(client);
        factory.create(dealId);
        assertTrue(factory.isValidatorContract(expectedProxy));
    }

    function testDeployMarksProxyAsDeployed() public {
        address expectedProxy = computeProxyAddress(address(accessManager), dealId);
        vm.prank(client);
        factory.create(dealId);

        assertTrue(factory.getInstance(dealId) == expectedProxy);
        assertEq(Validator(expectedProxy).accessManager(), address(accessManager));
        assertEq(UpgradeableBeacon(factory.getBeacon()).owner(), address(accessManager));
    }

    function testBeaconUpgradeMustGoThroughManager() public {
        UpgradeableBeacon beacon = UpgradeableBeacon(factory.getBeacon());
        address replacement = address(new Validator());

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        beacon.upgradeTo(replacement);

        vm.prank(admin);
        accessManager.upgradeBeacon(address(beacon), replacement);
        assertEq(beacon.implementation(), replacement);
    }

    function testDeployRevertsIfInstanceExists() public {
        vm.prank(client);
        factory.create(dealId);

        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InstanceAlreadyExists.selector));
        vm.prank(client);
        factory.create(dealId);
    }

    function computeProxyAddress(address manager_, uint256 dealId_) private view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(
                address(factory.getBeacon()),
                abi.encodeCall(Validator.initialize, (manager_, filecoinPay, poRepMarket, dealId_))
            )
        );
        bytes32 salt = keccak256(abi.encode(manager_, dealId_));
        bytes32 bytecodeHash = keccak256(initCode);
        return Create2.computeAddress(salt, bytecodeHash, address(factory));
    }

    function testAuthorizeUpgradeRevert() public {
        address newImpl = address(new ValidatorFactory());
        address unauthorized = vm.addr(999);
        bytes32 upgraderRole = accessManager.UPGRADER_ROLE();
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, upgraderRole)
        );
        factory.upgradeToAndCall(newImpl, "");
    }

    function testShouldReturnFalseIfValidatorDoesNotExist() public view {
        assertFalse(factory.isValidatorContract(address(0)));
    }

    function testShouldRevertWhenIncorrectClientAddress() public {
        address incorrectClient = vm.addr(999);
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidClientAddress.selector));
        vm.prank(incorrectClient);
        factory.create(dealId);
    }

    function testInitialize2RevertsWhenFilecoinPayIsZero() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidFilecoinPayAddress.selector));
        vm.prank(admin);
        f.initialize2(address(0), poRepMarket);
    }

    function testInitialize2RevertsWhenPoRepMarketIsZero() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidPoRepMarketAddress.selector));
        vm.prank(admin);
        f.initialize2(filecoinPay, address(0));
    }

    function testInitialize2RevertsWhenNotAdmin() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, client, accessManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(client);
        f.initialize2(filecoinPay, poRepMarket);
    }

    function testInitializeRevertsWhenManagerIsZero() public {
        ValidatorFactory factoryImplementation = new ValidatorFactory();
        bytes memory initData = abi.encodeCall(ValidatorFactory.initialize, (address(0), address(0x1234)));
        vm.expectRevert(abi.encodeWithSelector(AccessControlledUpgradeable.InvalidAccessManager.selector, address(0)));
        new ERC1967Proxy(address(factoryImplementation), initData);
    }

    function testInitializeRevertsWhenImplementationIsZero() public {
        ValidatorFactory factoryImplementation = new ValidatorFactory();
        bytes memory initData = abi.encodeCall(ValidatorFactory.initialize, (address(accessManager), address(0)));
        vm.expectRevert(ValidatorFactory.InvalidImplementationAddress.selector);
        new ERC1967Proxy(address(factoryImplementation), initData);
    }
}

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
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";
import {SLITypes} from "../src/types/SLITypes.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";

contract ValidatorFactoryTest is Test {
    ValidatorFactory public factory;
    address public validatorAddress;
    address public admin;
    address public poRepService;
    address public filecoinPay;
    address public sliScorer;
    address public clientSmartContract;
    address public poRepMarket;
    address public spRegistry;
    address public client;
    uint256 public dealId;
    CommonTypes.FilActorId public provider;
    ValidatorFactory public factoryImpl;
    bytes public initialData;
    PoRepMarketMock public poRepMarketMock;

    function setUp() public {
        admin = vm.addr(1);
        poRepService = vm.addr(2);
        filecoinPay = vm.addr(3);
        sliScorer = vm.addr(4);
        clientSmartContract = vm.addr(5);
        spRegistry = vm.addr(6);
        poRepMarketMock = new PoRepMarketMock();
        poRepMarket = address(poRepMarketMock);
        client = vm.addr(6);
        dealId = 1;
        provider = CommonTypes.FilActorId.wrap(1);
        validatorAddress = address(new Validator());
        factoryImpl = new ValidatorFactory();
        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: client,
                provider: provider,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 365}),
                validator: vm.addr(10),
                state: PoRepTypes.DealState.Accepted,
                railId: 200,
                proposedAtBlock: block.number,
                manifestLocation: "https://example.com/manifest",
                manifestHash: keccak256("test-manifest")
            })
        );

        initialData = abi.encodeCall(ValidatorFactory.initialize, (admin, validatorAddress));
        factory = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.prank(admin);
        factory.initialize2(poRepService, filecoinPay, sliScorer, clientSmartContract, poRepMarket, spRegistry);
    }

    function testEmitsUpgradedInConstructor() public {
        vm.expectEmit(true, true, true, true);
        emit UpgradeableBeacon.Upgraded(validatorAddress);
        new ERC1967Proxy(address(factoryImpl), initialData);
    }

    function testDeployEmitsEvent() public {
        vm.expectEmit(true, true, true, true);

        address expectedProxy = computeProxyAddress(admin, dealId);
        emit ValidatorFactory.ProxyCreated(expectedProxy, dealId);

        vm.prank(client);
        factory.create(dealId);
        assertTrue(factory.isValidatorContract(expectedProxy));
    }

    function testDeployMarksProxyAsDeployed() public {
        address expectedProxy = computeProxyAddress(admin, dealId);
        vm.prank(client);
        factory.create(dealId);

        assertTrue(factory.getInstance(dealId) == expectedProxy);
    }

    function testDeployRevertsIfInstanceExists() public {
        vm.prank(client);
        factory.create(dealId);

        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InstanceAlreadyExists.selector));
        vm.prank(client);
        factory.create(dealId);
    }

    function computeProxyAddress(address admin_, uint256 dealId_) private view returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(
                address(factory.getBeacon()),
                abi.encodeCall(
                    Validator.initialize,
                    (
                        admin_,
                        poRepService,
                        filecoinPay,
                        sliScorer,
                        clientSmartContract,
                        poRepMarket,
                        spRegistry,
                        dealId_
                    )
                )
            )
        );
        bytes32 salt = keccak256(abi.encode(admin_, dealId_));
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

    function testShouldRevertWhenIncorrectClientAddress() public {
        address incorrectClient = vm.addr(999);
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidClientAddress.selector));
        vm.prank(incorrectClient);
        factory.create(dealId);
    }

    function testInitialize2RevertsWhenPoRepServiceIsZero() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidPoRepServiceAddress.selector));
        vm.prank(admin);
        f.initialize2(address(0), filecoinPay, sliScorer, clientSmartContract, poRepMarket, spRegistry);
    }

    function testInitialize2RevertsWhenFilecoinPayIsZero() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidFilecoinPayAddress.selector));
        vm.prank(admin);
        f.initialize2(poRepService, address(0), sliScorer, clientSmartContract, poRepMarket, spRegistry);
    }

    function testInitialize2RevertsWhenSliScorerIsZero() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidSliScorerAddress.selector));
        vm.prank(admin);
        f.initialize2(poRepService, filecoinPay, address(0), clientSmartContract, poRepMarket, spRegistry);
    }

    function testInitialize2RevertsWhenClientSmartContractIsZero() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidClientSmartContractAddress.selector));
        vm.prank(admin);
        f.initialize2(poRepService, filecoinPay, sliScorer, address(0), poRepMarket, spRegistry);
    }

    function testInitialize2RevertsWhenPoRepMarketIsZero() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidPoRepMarketAddress.selector));
        vm.prank(admin);
        f.initialize2(poRepService, filecoinPay, sliScorer, clientSmartContract, address(0), spRegistry);
    }

    function testInitialize2RevertsWhenSPRegistryIsZero() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.InvalidSPRegistryAddress.selector));
        vm.prank(admin);
        f.initialize2(poRepService, filecoinPay, sliScorer, clientSmartContract, poRepMarket, address(0));
    }

    function testInitialize2RevertsWhenNotAdmin() public {
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(factoryImpl), initialData)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, client, f.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(client);
        f.initialize2(poRepService, filecoinPay, sliScorer, clientSmartContract, poRepMarket, spRegistry);
    }

    function testInitializeRevertsWhenAdminIsZero() public {
        ValidatorFactory factoryImplementation = new ValidatorFactory();
        bytes memory initData = abi.encodeCall(ValidatorFactory.initialize, (address(0), address(0x1234)));
        vm.expectRevert(ValidatorFactory.InvalidAdminAddress.selector);
        new ERC1967Proxy(address(factoryImplementation), initData);
    }

    function testInitializeRevertsWhenImplementationIsZero() public {
        ValidatorFactory factoryImplementation = new ValidatorFactory();
        bytes memory initData = abi.encodeCall(ValidatorFactory.initialize, (address(0x1234), address(0)));
        vm.expectRevert(ValidatorFactory.InvalidImplementationAddress.selector);
        new ERC1967Proxy(address(factoryImplementation), initData);
    }

    function testSetAdminRevertsWhenNewAdminIsZero() public {
        Validator validatorImplementation = new Validator();
        ValidatorFactory impl = new ValidatorFactory();
        address validAdmin = address(0xABCD);

        bytes memory initData =
            abi.encodeCall(ValidatorFactory.initialize, (validAdmin, address(validatorImplementation)));
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(validAdmin);
        vm.expectRevert(ValidatorFactory.InvalidNewAdminAddress.selector);
        f.setAdmin(address(0));
    }

    function testSetsNewAdminCorrectly() public {
        Validator validatorImplementation = new Validator();
        ValidatorFactory impl = new ValidatorFactory();
        address validAdmin = address(0xABCD);
        address newValidAdmin = address(0xDCBA);

        bytes memory initData =
            abi.encodeCall(ValidatorFactory.initialize, (validAdmin, address(validatorImplementation)));
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(validAdmin);
        f.setAdmin(newValidAdmin);

        assertTrue(f.hasRole(f.DEFAULT_ADMIN_ROLE(), newValidAdmin));
    }

    function testGrantRoleReverts() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.RoleManagementDisabled.selector));
        factory.grantRole(adminRole, client);
    }

    function testRevokeRoleReverts() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.RoleManagementDisabled.selector));
        factory.revokeRole(adminRole, client);
    }

    function testRenounceRoleReverts() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ValidatorFactory.RoleManagementDisabled.selector));
        factory.renounceRole(adminRole, admin);
    }

    function testSetUpgraderRoleRevertsWhenNewUpgraderRoleIsZero() public {
        Validator validatorImplementation = new Validator();
        ValidatorFactory impl = new ValidatorFactory();
        address validAdmin = address(0xABCD);

        bytes memory initData =
            abi.encodeCall(ValidatorFactory.initialize, (validAdmin, address(validatorImplementation)));
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(validAdmin);
        vm.expectRevert(ValidatorFactory.InvalidNewUpgraderRoleAddress.selector);
        f.setUpgraderRole(address(0));
    }

    function testSetsNewUpgraderRoleCorrectly() public {
        Validator validatorImplementation = new Validator();
        ValidatorFactory impl = new ValidatorFactory();
        address validAdmin = address(0xABCD);
        address newUpgrader = address(0xDCBA);

        bytes memory initData =
            abi.encodeCall(ValidatorFactory.initialize, (validAdmin, address(validatorImplementation)));
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(validAdmin);
        f.setUpgraderRole(newUpgrader);

        assertTrue(f.hasRole(f.UPGRADER_ROLE(), newUpgrader));
    }

    function testSetAdminEmitsAdminChangedEvent() public {
        Validator validatorImplementation = new Validator();
        ValidatorFactory impl = new ValidatorFactory();
        address validAdmin = address(0xABCD);
        address newValidAdmin = address(0xDCBA);

        bytes memory initData =
            abi.encodeCall(ValidatorFactory.initialize, (validAdmin, address(validatorImplementation)));
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(impl), initData)));

        vm.expectEmit(true, false, false, false);
        emit ValidatorFactory.AdminChanged(newValidAdmin);
        vm.prank(validAdmin);
        f.setAdmin(newValidAdmin);
    }

    function testSetUpgraderRoleEmitsUpgraderRoleChangedEvent() public {
        Validator validatorImplementation = new Validator();
        ValidatorFactory impl = new ValidatorFactory();
        address validAdmin = address(0xABCD);
        address newUpgrader = address(0xDCBA);

        bytes memory initData =
            abi.encodeCall(ValidatorFactory.initialize, (validAdmin, address(validatorImplementation)));
        ValidatorFactory f = ValidatorFactory(address(new ERC1967Proxy(address(impl), initData)));

        vm.expectEmit(true, false, false, false);
        emit ValidatorFactory.UpgraderRoleChanged(newUpgrader);
        vm.prank(validAdmin);
        f.setUpgraderRole(newUpgrader);
    }
}

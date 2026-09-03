// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, max-states-count, function-max-lines, gas-small-strings
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {AccessManager} from "../src/AccessManager.sol";
import {AccessControlledUpgradeable} from "../src/abstracts/AccessControlledUpgradeable.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {ValidatorFactory} from "../src/ValidatorFactory.sol";
import {Validator} from "../src/Validator.sol";
import {DataCapEvidenceAdapter} from "../src/DataCapEvidenceAdapter.sol";
import {SPRegistry} from "../src/SPRegistry.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {SLIScorer} from "../src/SLIScorer.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {DealState} from "../src/types/DealState.sol";
import {DealType} from "../src/types/DealType.sol";
import {RailStatus} from "../src/types/RailStatus.sol";
import {Roles} from "../src/lib/Roles.sol";
import {FilecoinPayV1Mock} from "./contracts/FilecoinPayV1Mock.sol";

contract AccessManagerDeploymentFixture is Deploy {
    // Reuse the production deployment helpers without reading keys or writing deployment manifests.
    function deploy(address initialAdmin, address paymentContract)
        external
        returns (address manager, address[6] memory targets)
    {
        vm.startBroadcast(initialAdmin);
        manager = address(new AccessManager(initialAdmin, initialAdmin));
        (validatorFactory,,) = _deployValidatorFactory(manager);
        (spRegistry,) = _deploySPRegistry(manager);
        (dataCapEvidenceAdapter,) = _deployDataCapEvidenceAdapter();
        (sliOracle,) = _deploySLIOracle(manager);
        (sliScorer,) = _deploySliScorer(manager, sliOracle);
        (poRepMarket,) = _deployPoRepMarket(manager, validatorFactory, spRegistry, sliScorer);
        DataCapEvidenceAdapter(dataCapEvidenceAdapter).initialize(manager, poRepMarket, address(0xA110C));
        AccessManager(manager).grantRole(Roles.MARKET_ROLE, poRepMarket);
        ValidatorFactory(validatorFactory).initialize2(paymentContract, poRepMarket);
        vm.stopBroadcast();
        targets = [poRepMarket, validatorFactory, dataCapEvidenceAdapter, spRegistry, sliOracle, sliScorer];
    }

    function freshFactory(address manager) external returns (ValidatorFactory factory) {
        (address proxy,,) = _deployValidatorFactory(manager);
        factory = ValidatorFactory(proxy);
    }
}

contract AccessManagerValidatorV2 is Validator {
    function implementationVersion() external pure returns (uint256) {
        return 2;
    }
}

contract AccessManagerIntegrationTest is Test {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    bytes32 private constant ACCESS_MANAGER_SLOT = 0x5fb8a3382c2de59c0ced6c5b31ee681f5bd1a0ad890fb5581ffeccfdb2f2e900;
    bytes32 private constant SCORER_STORAGE = 0xfc214f7b8d05a80223ac984f4c5d514cbee885916c0eb499aae1223022938a00;
    bytes32 private constant VALIDATOR_STORAGE = 0xf51cddbeb47ca42a561371db80eaffa401732269b8af46b255e3f43a7c044000;
    uint256 private constant DEAL_BYTES = 32 << 30;
    uint256 private constant AVAILABLE_BYTES = 10 * DEAL_BYTES;

    address private admin = makeAddr("initial admin and upgrader");
    address private nextAdmin = makeAddr("next admin");
    address private nextUpgrader = makeAddr("next upgrader");
    address private operator = makeAddr("operator");
    address private oracle = makeAddr("oracle");
    address private service = makeAddr("service");
    address private terminationOracle = makeAddr("termination oracle");
    address private client = makeAddr("client");
    address private organization = makeAddr("organization");
    address private token = makeAddr("payment token");
    CommonTypes.FilActorId private provider = CommonTypes.FilActorId.wrap(1000);

    AccessManagerDeploymentFixture private deployment;
    AccessManager private manager;
    address[6] private targets;
    PoRepMarket private market;
    ValidatorFactory private factory;
    DataCapEvidenceAdapter private adapter;
    SPRegistry private registry;
    SLIOracle private sliOracle;
    SLIScorer private scorer;
    Validator private validator;
    FilecoinPayV1Mock private payments;

    function setUp() public {
        vm.roll(100);
        payments = new FilecoinPayV1Mock();
        deployment = new AccessManagerDeploymentFixture();
        (address managerAddress, address[6] memory deployed) = deployment.deploy(admin, address(payments));
        manager = AccessManager(managerAddress);
        targets = deployed;
        market = PoRepMarket(targets[0]);
        factory = ValidatorFactory(targets[1]);
        adapter = DataCapEvidenceAdapter(targets[2]);
        registry = SPRegistry(targets[3]);
        sliOracle = SLIOracle(targets[4]);
        scorer = SLIScorer(targets[5]);

        vm.startPrank(admin);
        registry.registerProviderFor(provider, organization, AVAILABLE_BYTES, organization);
        registry.setPaymentToken(token, true, 86_400);
        SharedTypes.OfferPaymentInput[] memory rows = new SharedTypes.OfferPaymentInput[](1);
        rows[0] = SharedTypes.OfferPaymentInput({token: token, active: true, pricePer32GiBPerMonth: 90_000});
        registry.createOffer(
            provider,
            SharedTypes.OfferTerms({
                minSizeBytes: DEAL_BYTES,
                maxSizeBytes: AVAILABLE_BYTES,
                minDurationEpochs: uint64(180 * SharedTypes.EPOCHS_IN_DAY),
                maxDurationEpochs: uint64(360 * SharedTypes.EPOCHS_IN_DAY)
            }),
            _slis(),
            rows
        );
        vm.stopPrank();
        validator = _createDealAndRail(1);
    }

    function testFreshDeploymentSharesManagerWithExistingBeaconValidator() public view {
        for (uint256 i; i < targets.length; ++i) {
            assertEq(AccessControlledUpgradeable(targets[i]).accessManager(), address(manager));
            assertEq(_storedAddress(targets[i], ACCESS_MANAGER_SLOT), address(manager));
            assertGt(_implementation(targets[i]).code.length, 0);
        }
        assertEq(validator.accessManager(), address(manager));
        assertEq(_storedAddress(address(validator), ACCESS_MANAGER_SLOT), address(manager));
        assertEq(_storedAddress(address(validator), BEACON_SLOT), factory.getBeacon());
        assertEq(UpgradeableBeacon(factory.getBeacon()).owner(), address(manager));
        assertEq(factory.getInstance(1), address(validator));
        assertTrue(factory.isValidatorContract(address(validator)));
        assertEq(market.getDeal(1).validator, address(validator));
        assertEq(market.getDeal(1).railId, 1);
        assertEq(validator.getRailStatus(), RailStatus.PREPARED);
        assertTrue(manager.hasRole(Roles.MARKET_ROLE, address(market)));
        assertTrue(manager.hasRole(Roles.DEFAULT_ADMIN_ROLE, admin));
        assertTrue(manager.hasRole(Roles.UPGRADER_ROLE, admin));
    }

    function testThreeDayAdminTransferUpdatesEveryAdminConsumer() public {
        ValidatorFactory pendingFactory = deployment.freshFactory(address(manager));
        _assertAdminDenied(nextAdmin, pendingFactory);

        vm.startPrank(admin);
        market.setDealActivationPadding(1500);
        registry.setPaymentToken(token, true, 80_000);
        validator.updateLockupPeriod(43_200);
        vm.stopPrank();
        assertEq(market.getDealActivationPadding(), 1500);
        assertEq(registry.getPaymentTokenConfig(token).minPricePer32GiBPerMonth, 80_000);
        (uint256 lockup,) = payments.getRailLockup(1);
        assertEq(lockup, 43_200);

        // The only adapter admin operation is irreversible. Restore the fixture after proving old-admin access.
        uint256 snapshot = vm.snapshotState();
        vm.prank(admin);
        adapter.disableAdapter();
        assertFalse(adapter.isOperational());
        assertTrue(vm.revertToState(snapshot));

        vm.prank(admin);
        manager.beginDefaultAdminTransfer(nextAdmin);
        (address pending, uint48 schedule) = manager.pendingDefaultAdmin();
        assertEq(pending, nextAdmin);
        assertEq(schedule, block.timestamp + 3 days);
        vm.warp(uint256(schedule) - 1);
        vm.prank(nextAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        manager.acceptDefaultAdminTransfer();
        _assertAdminDenied(nextAdmin, pendingFactory);
        vm.warp(uint256(schedule) + 1);
        vm.prank(nextAdmin);
        manager.acceptDefaultAdminTransfer();

        _assertAdminDenied(admin, pendingFactory);
        assertFalse(manager.hasRole(Roles.DEFAULT_ADMIN_ROLE, admin));
        assertTrue(manager.hasRole(Roles.DEFAULT_ADMIN_ROLE, nextAdmin));
        assertTrue(manager.hasRole(Roles.UPGRADER_ROLE, admin));
        assertFalse(manager.hasRole(Roles.UPGRADER_ROLE, nextAdmin));

        vm.startPrank(nextAdmin);
        market.setDealActivationPadding(1200);
        registry.setPaymentToken(token, true, 70_000);
        validator.updateLockupPeriod(40_000);
        adapter.disableAdapter();
        pendingFactory.initialize2(address(payments), address(market));
        vm.stopPrank();
        assertEq(market.getDealActivationPadding(), 1200);
        assertEq(registry.getPaymentTokenConfig(token).minPricePer32GiBPerMonth, 70_000);
        (lockup,) = payments.getRailLockup(1);
        assertEq(lockup, 40_000);
        assertFalse(adapter.isOperational());
        _assertFactoryDependencies(pendingFactory);
    }

    function testGlobalUpgraderRotationCoversAllSixUupsAndExistingValidatorBeacon() public {
        _grant(Roles.ORACLE_ROLE, oracle);
        vm.prank(oracle);
        sliOracle.setSLI(1, _slis());
        _grant(Roles.TERMINATION_ORACLE, terminationOracle);
        vm.prank(terminationOracle);
        adapter.claimsTerminatedEarly(_claimIds(41));
        vm.prank(admin);
        market.setDealActivationPadding(1400);
        _transferAdmin();

        address[6] memory replacements = _replacementImplementations();
        address replacementValidator = address(new Validator());
        address beacon = factory.getBeacon();
        bytes32 beforeState = _protocolState();
        bytes32[6] memory managerSlots;
        for (uint256 i; i < targets.length; ++i) {
            managerSlots[i] = vm.load(targets[i], ACCESS_MANAGER_SLOT);
            _expectUnauthorized(nextAdmin, Roles.UPGRADER_ROLE);
            UUPSUpgradeable(targets[i]).upgradeToAndCall(replacements[i], "");
            // Admin transfer leaves the original upgrader authorized on every actual implementation.
            vm.prank(admin);
            UUPSUpgradeable(targets[i]).upgradeToAndCall(replacements[i], "");
            assertEq(_implementation(targets[i]), replacements[i]);
        }
        _expectUnauthorized(nextAdmin, Roles.UPGRADER_ROLE);
        manager.upgradeBeacon(beacon, replacementValidator);
        vm.prank(admin);
        manager.upgradeBeacon(beacon, replacementValidator);
        assertEq(UpgradeableBeacon(beacon).implementation(), replacementValidator);
        assertEq(_protocolState(), beforeState);

        vm.startPrank(nextAdmin);
        manager.grantRole(Roles.UPGRADER_ROLE, nextUpgrader);
        manager.revokeRole(Roles.UPGRADER_ROLE, admin);
        vm.stopPrank();
        assertFalse(manager.hasRole(Roles.UPGRADER_ROLE, admin));
        assertTrue(manager.hasRole(Roles.UPGRADER_ROLE, nextUpgrader));
        assertFalse(manager.hasRole(Roles.DEFAULT_ADMIN_ROLE, nextUpgrader));

        address[6] memory nextImplementations = _replacementImplementations();
        address nextValidator = address(new AccessManagerValidatorV2());
        for (uint256 i; i < targets.length; ++i) {
            _expectUnauthorized(admin, Roles.UPGRADER_ROLE);
            UUPSUpgradeable(targets[i]).upgradeToAndCall(nextImplementations[i], "");
            assertEq(_implementation(targets[i]), replacements[i]);
            assertEq(_protocolState(), beforeState);
            vm.prank(nextUpgrader);
            UUPSUpgradeable(targets[i]).upgradeToAndCall(nextImplementations[i], "");
            assertEq(_implementation(targets[i]), nextImplementations[i]);
            assertEq(vm.load(targets[i], ACCESS_MANAGER_SLOT), managerSlots[i]);
            // The replacement must continue consulting the same manager after its own installation.
            _expectUnauthorized(admin, Roles.UPGRADER_ROLE);
            UUPSUpgradeable(targets[i]).upgradeToAndCall(replacements[i], "");
            assertEq(_implementation(targets[i]), nextImplementations[i]);
        }
        _expectUnauthorized(admin, Roles.UPGRADER_ROLE);
        manager.upgradeBeacon(beacon, nextValidator);
        assertEq(UpgradeableBeacon(beacon).implementation(), replacementValidator);
        vm.prank(nextUpgrader);
        manager.upgradeBeacon(beacon, nextValidator);
        assertEq(UpgradeableBeacon(beacon).implementation(), nextValidator);
        assertEq(AccessManagerValidatorV2(address(validator)).implementationVersion(), 2);
        assertEq(_storedAddress(address(validator), BEACON_SLOT), beacon);
        assertEq(_storedAddress(address(validator), ACCESS_MANAGER_SLOT), address(manager));
        assertEq(_protocolState(), beforeState);
        _exerciseUpgradedContracts();
    }

    function testOracleGrantAndRevocationAffectRealOracleAndScorer() public {
        _expectUnauthorized(oracle, Roles.ORACLE_ROLE);
        sliOracle.setSLI(1, _slis());
        assertEq(sliOracle.getAttestation(1).lastUpdate, 0);
        _grant(Roles.ORACLE_ROLE, oracle);
        vm.prank(oracle);
        sliOracle.setSLI(1, _slis());
        assertEq(scorer.calculateScore(1, _slis()), 100);
        bytes32 beforeState = keccak256(abi.encode(sliOracle.getAttestation(1)));
        _revoke(Roles.ORACLE_ROLE, oracle);
        vm.roll(block.number + 1);
        SharedTypes.SLIThresholds memory changed = _slis();
        changed.retrievabilityBps = 1;
        _expectUnauthorized(oracle, Roles.ORACLE_ROLE);
        sliOracle.setSLI(1, changed);
        assertEq(keccak256(abi.encode(sliOracle.getAttestation(1))), beforeState);
        assertEq(scorer.calculateScore(1, _slis()), 100);
    }

    function testTerminationOracleGrantAndRevocationAffectRealAdapter() public {
        _expectUnauthorized(terminationOracle, Roles.TERMINATION_ORACLE);
        adapter.claimsTerminatedEarly(_claimIds(41));
        assertFalse(adapter.isClaimTerminated(41));
        _grant(Roles.TERMINATION_ORACLE, terminationOracle);
        vm.prank(terminationOracle);
        adapter.claimsTerminatedEarly(_claimIds(41));
        assertTrue(adapter.isClaimTerminated(41));
        _revoke(Roles.TERMINATION_ORACLE, terminationOracle);
        _expectUnauthorized(terminationOracle, Roles.TERMINATION_ORACLE);
        adapter.claimsTerminatedEarly(_claimIds(42));
        assertTrue(adapter.isClaimTerminated(41));
        assertFalse(adapter.isClaimTerminated(42));
    }

    function testServiceGrantAndRevocationReachRealMarketValidatorAndRegistry() public {
        Validator secondValidator = _createDealAndRail(2);
        bytes32 beforeState = _protocolState();
        _expectUnauthorized(service, Roles.POREP_SERVICE_ROLE);
        market.terminateDeal(1, DealState.EARLY_TERMINATED);
        assertEq(_protocolState(), beforeState);
        _grant(Roles.POREP_SERVICE_ROLE, service);
        vm.prank(service);
        market.terminateDeal(1, DealState.EARLY_TERMINATED);
        assertEq(market.getDeal(1).state, DealState.EARLY_TERMINATED);
        assertEq(validator.getRailStatus(), RailStatus.TERMINATED);
        assertTrue(payments.terminated(1));
        assertEq(registry.getProviderView(provider).pendingBytes, DEAL_BYTES);
        _revoke(Roles.POREP_SERVICE_ROLE, service);
        beforeState = _protocolState();
        _expectUnauthorized(service, Roles.POREP_SERVICE_ROLE);
        market.terminateDeal(2, DealState.EARLY_TERMINATED);
        assertEq(_protocolState(), beforeState);
        assertEq(market.getDeal(2).state, DealState.ACCEPTED);
        assertEq(secondValidator.getRailStatus(), RailStatus.PREPARED);
        assertFalse(payments.terminated(2));
        assertEq(registry.getProviderView(provider).pendingBytes, DEAL_BYTES);
        _grant(Roles.POREP_SERVICE_ROLE, service);
        vm.prank(service);
        market.terminateDeal(2, DealState.EARLY_TERMINATED);
        assertEq(secondValidator.getRailStatus(), RailStatus.TERMINATED);
        assertTrue(payments.terminated(2));
        assertEq(registry.getProviderView(provider).pendingBytes, 0);
    }

    function testMarketRoleRevocationBlocksRealProposalAndRestoresImmediately() public {
        assertEq(market.getDealCount(), 1);
        _revoke(Roles.MARKET_ROLE, address(market));
        SharedTypes.DealRequest memory request = _request(2);
        bytes32 beforeState = _protocolState();
        vm.prank(client);
        vm.expectRevert(_unauthorized(address(market), Roles.MARKET_ROLE));
        market.proposeDeal(request);
        assertEq(_protocolState(), beforeState);
        assertEq(market.getDealCount(), 1);
        assertFalse(registry.isManifestAssignedToOrganizationAndClient(client, request.manifestHash, organization));
        _grant(Roles.MARKET_ROLE, address(market));
        vm.prank(client);
        market.proposeDeal(request);
        assertEq(market.getDealCount(), 2);
        assertEq(registry.getProviderView(provider).pendingBytes, 2 * DEAL_BYTES);
        assertTrue(registry.isManifestAssignedToOrganizationAndClient(client, request.manifestHash, organization));
        _revoke(Roles.MARKET_ROLE, address(market));
        request = _request(3);
        beforeState = _protocolState();
        vm.prank(client);
        vm.expectRevert(_unauthorized(address(market), Roles.MARKET_ROLE));
        market.proposeDeal(request);
        assertEq(_protocolState(), beforeState);
        assertEq(market.getDealCount(), 2);
    }

    function testOperatorGrantAndRevocationAffectRealProviderRegistration() public {
        CommonTypes.FilActorId secondProvider = CommonTypes.FilActorId.wrap(2000);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotAdminOrOperator.selector, operator));
        registry.registerProviderFor(secondProvider, organization, AVAILABLE_BYTES, organization);
        _grant(Roles.OPERATOR_ROLE, operator);
        vm.prank(operator);
        registry.registerProviderFor(secondProvider, organization, AVAILABLE_BYTES, organization);
        assertEq(registry.getProviderView(secondProvider).organization, organization);
        assertEq(registry.getProviderView(secondProvider).availableBytes, AVAILABLE_BYTES);
        _revoke(Roles.OPERATOR_ROLE, operator);
        (CommonTypes.FilActorId[] memory providersBefore,) = registry.getProviders(0, 100);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotAdminOrOperator.selector, operator));
        registry.registerProviderFor(CommonTypes.FilActorId.wrap(3000), organization, AVAILABLE_BYTES, organization);
        (CommonTypes.FilActorId[] memory providersAfter,) = registry.getProviders(0, 100);
        assertEq(abi.encode(providersAfter), abi.encode(providersBefore));
        assertEq(registry.getProviderView(secondProvider).availableBytes, AVAILABLE_BYTES);
    }

    function _assertAdminDenied(address account, ValidatorFactory pendingFactory) private {
        bytes32 beforeState = _protocolState();
        _expectUnauthorized(account, Roles.DEFAULT_ADMIN_ROLE);
        market.setDealActivationPadding(1200);
        _expectUnauthorized(account, Roles.DEFAULT_ADMIN_ROLE);
        registry.setPaymentToken(token, true, 70_000);
        _expectUnauthorized(account, Roles.DEFAULT_ADMIN_ROLE);
        validator.updateLockupPeriod(40_000);
        _expectUnauthorized(account, Roles.DEFAULT_ADMIN_ROLE);
        adapter.disableAdapter();
        _expectUnauthorized(account, Roles.DEFAULT_ADMIN_ROLE);
        pendingFactory.initialize2(address(payments), address(market));
        assertEq(_protocolState(), beforeState);
    }

    function _transferAdmin() private {
        vm.prank(admin);
        manager.beginDefaultAdminTransfer(nextAdmin);
        (, uint48 schedule) = manager.pendingDefaultAdmin();
        vm.warp(uint256(schedule) + 1);
        vm.prank(nextAdmin);
        manager.acceptDefaultAdminTransfer();
    }

    function _exerciseUpgradedContracts() private {
        vm.startPrank(nextAdmin);
        market.updateManifestLocation(1, "https://example.com/updated-manifest", DEAL_BYTES, keccak256(abi.encode(1)));
        registry.setPaymentToken(token, true, 75_000);
        validator.updateLockupPeriod(42_000);
        manager.grantRole(Roles.POREP_SERVICE_ROLE, service);
        vm.stopPrank();
        assertEq(market.getDealData(1).manifestLocation, "https://example.com/updated-manifest");
        assertEq(registry.getPaymentTokenConfig(token).minPricePer32GiBPerMonth, 75_000);
        (uint256 lockup,) = payments.getRailLockup(1);
        assertEq(lockup, 42_000);
        _expectUnauthorized(admin, Roles.DEFAULT_ADMIN_ROLE);
        validator.updateLockupPeriod(1);
        vm.prank(oracle);
        sliOracle.setSLI(1, _slis());
        assertEq(scorer.calculateScore(1, _slis()), 100);
        vm.prank(terminationOracle);
        adapter.claimsTerminatedEarly(_claimIds(42));
        assertTrue(adapter.isClaimTerminated(41));
        assertTrue(adapter.isClaimTerminated(42));
        Validator secondValidator = _createDealAndRail(2);
        assertEq(secondValidator.accessManager(), address(manager));
        assertEq(secondValidator.getRailStatus(), RailStatus.PREPARED);
        assertEq(factory.getInstance(1), address(validator));
        vm.prank(service);
        market.terminateDeal(1, DealState.EARLY_TERMINATED);
        assertEq(market.getDeal(1).state, DealState.EARLY_TERMINATED);
        assertEq(validator.getRailStatus(), RailStatus.TERMINATED);
        assertTrue(payments.terminated(1));
        assertEq(registry.getProviderView(provider).pendingBytes, DEAL_BYTES);
    }

    function _replacementImplementations() private returns (address[6] memory) {
        return [
            address(new PoRepMarket()),
            address(new ValidatorFactory()),
            address(new DataCapEvidenceAdapter()),
            address(new SPRegistry()),
            address(new SLIOracle()),
            address(new SLIScorer())
        ];
    }

    function _createDealAndRail(uint256 dealId) private returns (Validator instance) {
        SharedTypes.DealRequest memory request = _request(dealId);
        vm.startPrank(client);
        market.proposeDeal(request);
        factory.create(dealId);
        vm.stopPrank();
        instance = Validator(factory.getInstance(dealId));
        payments.setOperatorApproval(IERC20(token), client, address(instance), true, 1_000_000, 1_000_000, 0, 0, 86_400);
        vm.prank(client);
        instance.createRail();
    }

    function _protocolState() private view returns (bytes32) {
        bytes32 marketState = keccak256(
            abi.encode(
                market.getDeal(1),
                market.getDealData(1),
                market.getDealTerms(1),
                market.getDealService(1),
                market.getDealCapacity(1),
                market.getDealPayment(1),
                market.getDealSLIs(1)
            )
        );
        bytes32 marketConfiguration = keccak256(
            abi.encode(
                market.getDealCount(),
                market.getDealActivationPadding(),
                market.getGlobalEvidenceAdapter(),
                market.getSPRegistryContract(),
                market.getValidatorFactoryContract()
            )
        );
        bytes32 registryState = keccak256(
            abi.encode(
                registry.getProviderView(provider), registry.getOfferView(1), registry.getPaymentTokenConfig(token)
            )
        );
        bytes32 validatorState = keccak256(
            abi.encode(
                vm.load(address(validator), VALIDATOR_STORAGE),
                vm.load(address(validator), bytes32(uint256(VALIDATOR_STORAGE) + 1)),
                vm.load(address(validator), bytes32(uint256(VALIDATOR_STORAGE) + 2)),
                vm.load(address(validator), bytes32(uint256(VALIDATOR_STORAGE) + 3)),
                validator.getRailStatus()
            )
        );
        return keccak256(
            abi.encode(
                marketState,
                marketConfiguration,
                registryState,
                validatorState,
                _factoryAndAdapterState(),
                _oracleAndPaymentState()
            )
        );
    }

    function _factoryAndAdapterState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                factory.getBeacon(),
                factory.getInstance(1),
                factory.isValidatorContract(address(validator)),
                adapter.getPoRepMarketAddress(),
                adapter.isOperational(),
                adapter.isClaimTerminated(41)
            )
        );
    }

    function _oracleAndPaymentState() private view returns (bytes32) {
        (uint256 lockup, uint256 fixedLockup) = payments.getRailLockup(1);
        return keccak256(
            abi.encode(sliOracle.getAttestation(1), vm.load(address(scorer), SCORER_STORAGE), lockup, fixedLockup)
        );
    }

    function _assertFactoryDependencies(ValidatorFactory target) private view {
        bytes32 location = 0x4535768406d1af0f5a262f9968680cf180c0f29a04172a8e056d8f1b4b87ed00;
        assertEq(_storedAddress(address(target), bytes32(uint256(location) + 2)), address(payments));
        assertEq(_storedAddress(address(target), bytes32(uint256(location) + 3)), address(market));
    }

    function _implementation(address target) private view returns (address) {
        return _storedAddress(target, IMPLEMENTATION_SLOT);
    }

    function _storedAddress(address target, bytes32 slot) private view returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(vm.load(target, slot))));
    }

    function _expectUnauthorized(address account, bytes32 role) private {
        vm.prank(account);
        vm.expectRevert(_unauthorized(account, role));
    }

    function _unauthorized(address account, bytes32 role) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    function _grant(bytes32 role, address account) private {
        vm.prank(admin);
        manager.grantRole(role, account);
    }

    function _revoke(bytes32 role, address account) private {
        vm.prank(admin);
        manager.revokeRole(role, account);
    }

    function _claimIds(uint64 claimId) private pure returns (uint64[] memory claims) {
        claims = new uint64[](1);
        claims[0] = claimId;
    }

    function _slis() private pure returns (SharedTypes.SLIThresholds memory) {
        return SharedTypes.SLIThresholds({
            retrievabilityBps: 9500, bandwidthBytesPerSecond: 1000, latencyMs: 100, indexingPct: 90
        });
    }

    function _request(uint256 id) private view returns (SharedTypes.DealRequest memory) {
        return SharedTypes.DealRequest({
            manifestHash: keccak256(abi.encode(id)),
            requestedSizeBytes: DEAL_BYTES,
            maxPricePer32GiBPerMonth: 100_000,
            manifestLocation: "https://example.com/manifest",
            paymentToken: token,
            durationDays: 180,
            requiredSLIs: _slis(),
            dealType: DealType.PUBLIC
        });
    }
}

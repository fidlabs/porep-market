// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, max-states-count, no-console, gas-small-strings
pragma solidity =0.8.30;

import {PoRepMarket} from "../src/PoRepMarket.sol";
import {Validator} from "../src/Validator.sol";
import {ValidatorFactory} from "../src/ValidatorFactory.sol";
import {DataCapEvidenceAdapter} from "../src/DataCapEvidenceAdapter.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {SLIScorer} from "../src/SLIScorer.sol";
import {SPRegistry} from "../src/SPRegistry.sol";
import {PoRepMarketClaimInspector} from "../src/helpers/PoRepMarketClaimInspector.sol";
import {PoRepMarketSectorStatusInspector} from "../src/helpers/PoRepMarketSectorStatusInspector.sol";
import {PoRepMarketViewHelper} from "../src/helpers/PoRepMarketViewHelper.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "../src/AccessManager.sol";
import {Roles} from "../src/lib/Roles.sol";

contract Deploy is DeployUtils {
    using stdJson for string;

    /**
     * @dev 0x1da2bad3
     */
    error InvalidDeploymentAddress(string name);

    address internal poRepMarket;
    address internal validatorFactory;
    address internal dataCapEvidenceAdapter;
    address internal sliOracle;
    address internal sliScorer;
    address internal claimInspector;
    address internal sectorStatusInspector;
    address internal viewHelper;
    address internal accessManager;

    address internal poRepMarketImpl;
    address internal validatorFactoryImpl;
    address internal validatorImpl;
    address internal dataCapEvidenceAdapterImpl;
    address internal sliOracleImpl;
    address internal sliScorerImpl;
    address internal validator;
    address internal validatorBeacon;
    address internal spRegistryImpl;

    address internal spRegistry;
    address internal filecoinPay;
    address internal admin;
    address internal terminationOracle;
    address internal oracleAddress;
    address internal poRepService;
    address internal operatorAddress;
    address internal metaAllocator;
    address internal usdfc;
    address internal axlUsdc;

    function run() external {
        string memory outputPath = vm.envString("DEPLOYMENT_OUTPUT");
        string memory buildInfoSha256 = vm.envString("BUILD_INFO_SHA256");

        admin = vm.addr(vm.envUint("PRIVATE_KEY"));
        terminationOracle = vm.envAddress("TERMINATION_ORACLE");
        filecoinPay = vm.envAddress("FILECOIN_PAY");
        oracleAddress = vm.envAddress("ORACLE");
        poRepService = vm.envAddress("POREP_SERVICE");
        operatorAddress = vm.envOr("OPERATOR_ADDR", address(0));
        metaAllocator = vm.envAddress("META_ALLOCATOR");
        usdfc = vm.envOr("USDFC", address(0));
        axlUsdc = vm.envOr("AXL_USDC", address(0));
        _ensureDeploymentAddress(terminationOracle, "TERMINATION_ORACLE");
        _ensureDeploymentAddress(oracleAddress, "ORACLE");
        _ensureDeploymentAddress(poRepService, "POREP_SERVICE");

        vm.startBroadcast(admin);

        accessManager = address(new AccessManager(admin, admin));
        (validatorFactory, validatorFactoryImpl, validatorImpl) = _deployValidatorFactory(accessManager);
        (spRegistry, spRegistryImpl) = _deploySPRegistry(accessManager);
        (dataCapEvidenceAdapter, dataCapEvidenceAdapterImpl) = _deployDataCapEvidenceAdapter();
        (sliOracle, sliOracleImpl) = _deploySLIOracle(accessManager);
        (sliScorer, sliScorerImpl) = _deploySliScorer(accessManager, sliOracle);
        (poRepMarket, poRepMarketImpl) = _deployPoRepMarket(accessManager, validatorFactory, spRegistry, sliScorer);
        DataCapEvidenceAdapter(dataCapEvidenceAdapter).initialize(accessManager, poRepMarket, metaAllocator);
        claimInspector = address(new PoRepMarketClaimInspector(dataCapEvidenceAdapter, poRepMarket));
        sectorStatusInspector = address(new PoRepMarketSectorStatusInspector(poRepMarket));
        viewHelper = address(new PoRepMarketViewHelper(poRepMarket));

        validatorBeacon = ValidatorFactory(validatorFactory).getBeacon();

        _configureRoles();
        ValidatorFactory(validatorFactory).initialize2(filecoinPay, poRepMarket);
        _configurePaymentToken(usdfc);
        _configurePaymentToken(axlUsdc);

        if (operatorAddress != address(0)) {
            AccessManager(accessManager).grantRole(Roles.OPERATOR_ROLE, operatorAddress);
        } else {
            // solhint-disable-next-line gas-small-strings
            console.log("WARNING: OPERATOR_ADDR not set, skipping operator role grant");
        }

        vm.stopBroadcast();

        vm.writeJson(_serializePendingManifest(buildInfoSha256), outputPath, ".result");
    }

    function _configurePaymentToken(address token) private {
        if (token != address(0)) SPRegistry(spRegistry).setPaymentToken(token, true, 1);
    }

    function _configureRoles() private {
        AccessManager manager = AccessManager(accessManager);
        manager.grantRole(Roles.POREP_SERVICE_ROLE, poRepService);
        manager.grantRole(Roles.ORACLE_ROLE, oracleAddress);
        manager.grantRole(Roles.TERMINATION_ORACLE, terminationOracle);
        manager.grantRole(Roles.MARKET_ROLE, poRepMarket);
    }

    function _ensureDeploymentAddress(address account, string memory name) private pure {
        if (account == address(0)) revert InvalidDeploymentAddress(name);
    }

    function _deployValidatorFactory(address _accessManager)
        internal
        returns (address proxy, address factoryImpl, address valImpl)
    {
        Validator _validatorImpl = new Validator();
        ValidatorFactory _impl = new ValidatorFactory();
        bytes memory init = abi.encodeCall(ValidatorFactory.initialize, (_accessManager, address(_validatorImpl)));
        proxy = createProxy(init, address(_impl));
        factoryImpl = address(_impl);
        valImpl = address(_validatorImpl);
    }

    function _deployPoRepMarket(
        address _accessManager,
        address _validatorFactory,
        address _spRegistry,
        address _sliScorer
    ) internal returns (address proxy, address impl) {
        PoRepMarket _impl = new PoRepMarket();
        bytes memory init = abi.encodeCall(
            PoRepMarket.initialize, (_accessManager, _validatorFactory, _spRegistry, dataCapEvidenceAdapter, _sliScorer)
        );
        proxy = createProxy(init, address(_impl));
        impl = address(_impl);
    }

    function _deployDataCapEvidenceAdapter() internal returns (address proxy, address impl) {
        DataCapEvidenceAdapter _impl = new DataCapEvidenceAdapter();
        proxy = createProxy("", address(_impl));
        impl = address(_impl);
    }

    function _deploySLIOracle(address _accessManager) internal returns (address proxy, address impl) {
        SLIOracle _impl = new SLIOracle();
        bytes memory init = abi.encodeCall(SLIOracle.initialize, (_accessManager));
        proxy = createProxy(init, address(_impl));
        impl = address(_impl);
    }

    function _deploySliScorer(address _accessManager, address _sliOracle)
        internal
        returns (address proxy, address impl)
    {
        SLIScorer _impl = new SLIScorer();
        bytes memory init = abi.encodeCall(SLIScorer.initialize, (_accessManager, SLIOracle(_sliOracle)));
        proxy = createProxy(init, address(_impl));
        impl = address(_impl);
    }

    function _deploySPRegistry(address _accessManager) internal returns (address proxy, address impl) {
        SPRegistry _impl = new SPRegistry();
        bytes memory init = abi.encodeCall(SPRegistry.initialize, (_accessManager));
        proxy = createProxy(init, address(_impl));
        impl = address(_impl);
    }

    function _serializePendingManifest(string memory buildInfoSha256) internal returns (string memory) {
        string memory json = "pendingDeployment";
        json.serialize("status", string("pending"));
        json.serialize("release", _serializeRelease(buildInfoSha256));
        json.serialize("deployer", admin);
        json.serialize("contracts", _serializeContracts());
        return json.serialize("externalDependencies", _serializeExternalDependencies());
    }

    function _serializeRelease(string memory buildInfoSha256) private returns (string memory) {
        string memory json = "pendingRelease";
        return json.serialize("buildInfoSha256", buildInfoSha256);
    }

    function _serializeContracts() private returns (string memory) {
        string memory json = "pendingContracts";
        json.serialize("AccessManager", _serializeAccessManager());
        json.serialize(
            "PoRepMarket",
            _serializeUupsContract(
                "pendingPoRepMarket", "src/PoRepMarket.sol:PoRepMarket", poRepMarket, poRepMarketImpl
            )
        );
        json.serialize(
            "ValidatorFactory",
            _serializeUupsContract(
                "pendingValidatorFactory",
                "src/ValidatorFactory.sol:ValidatorFactory",
                validatorFactory,
                validatorFactoryImpl
            )
        );
        json.serialize(
            "DataCapEvidenceAdapter",
            _serializeUupsContract(
                "pendingDataCapEvidenceAdapter",
                "src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter",
                dataCapEvidenceAdapter,
                dataCapEvidenceAdapterImpl
            )
        );
        json.serialize(
            "SPRegistry",
            _serializeUupsContract("pendingSPRegistry", "src/SPRegistry.sol:SPRegistry", spRegistry, spRegistryImpl)
        );
        json.serialize(
            "SLIOracle",
            _serializeUupsContract("pendingSLIOracle", "src/SLIOracle.sol:SLIOracle", sliOracle, sliOracleImpl)
        );
        json.serialize(
            "SLIScorer",
            _serializeUupsContract("pendingSLIScorer", "src/SLIScorer.sol:SLIScorer", sliScorer, sliScorerImpl)
        );
        json.serialize("Validator", _serializeValidator());
        json.serialize("ValidatorBeacon", _serializeValidatorBeacon());
        json.serialize("PoRepMarketClaimInspector", _serializeClaimInspector());
        json.serialize("PoRepMarketSectorStatusInspector", _serializeSectorStatusInspector());
        return json.serialize("PoRepMarketViewHelper", _serializeViewHelper());
    }

    function _serializeUupsContract(
        string memory objectKey,
        string memory artifact,
        address proxy,
        address implementation
    ) private returns (string memory) {
        objectKey.serialize("kind", string("uups"));
        objectKey.serialize("artifact", artifact);
        objectKey.serialize("proxy", proxy);
        objectKey.serialize("implementation", implementation);
        objectKey.serialize("proxyCodeHash", proxy.codehash);
        return objectKey.serialize("implementationCodeHash", implementation.codehash);
    }

    function _serializeValidator() private returns (string memory) {
        string memory json = "pendingValidator";
        json.serialize("kind", string("implementation"));
        json.serialize("artifact", string("src/Validator.sol:Validator"));
        json.serialize("implementation", validatorImpl);
        return json.serialize("implementationCodeHash", validatorImpl.codehash);
    }

    function _serializeAccessManager() private returns (string memory) {
        string memory json = "pendingAccessManager";
        json.serialize("kind", string("standalone"));
        json.serialize("artifact", string("src/AccessManager.sol:AccessManager"));
        json.serialize("implementation", accessManager);
        return json.serialize("implementationCodeHash", accessManager.codehash);
    }

    function _serializeClaimInspector() private returns (string memory) {
        string memory json = "pendingClaimInspector";
        json.serialize("kind", string("standalone"));
        json.serialize("artifact", string("src/helpers/PoRepMarketClaimInspector.sol:PoRepMarketClaimInspector"));
        json.serialize("implementation", claimInspector);
        return json.serialize("implementationCodeHash", claimInspector.codehash);
    }

    function _serializeViewHelper() private returns (string memory) {
        string memory json = "pendingViewHelper";
        json.serialize("kind", string("standalone"));
        json.serialize("artifact", string("src/helpers/PoRepMarketViewHelper.sol:PoRepMarketViewHelper"));
        json.serialize("implementation", viewHelper);
        return json.serialize("implementationCodeHash", viewHelper.codehash);
    }

    function _serializeSectorStatusInspector() private returns (string memory) {
        string memory json = "pendingSectorStatusInspector";
        json.serialize("kind", string("standalone"));
        json.serialize(
            "artifact", string("src/helpers/PoRepMarketSectorStatusInspector.sol:PoRepMarketSectorStatusInspector")
        );
        json.serialize("implementation", sectorStatusInspector);
        return json.serialize("implementationCodeHash", sectorStatusInspector.codehash);
    }

    function _serializeValidatorBeacon() private returns (string memory) {
        string memory json = "pendingValidatorBeacon";
        json.serialize("kind", string("beacon"));
        json.serialize(
            "artifact",
            string("lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon")
        );
        json.serialize("address", validatorBeacon);
        json.serialize("implementation", validatorImpl);
        return json.serialize("factoryProxy", validatorFactory);
    }

    function _serializeExternalDependencies() private returns (string memory) {
        string memory json = "pendingExternalDependencies";
        json.serialize("FilecoinPay", filecoinPay);
        json.serialize("PoRepService", poRepService);
        json.serialize("MetaAllocator", metaAllocator);
        json.serialize("TerminationOracle", terminationOracle);
        json.serialize("Oracle", oracleAddress);
        if (usdfc != address(0)) json.serialize("USDFC", usdfc);
        if (axlUsdc != address(0)) json.serialize("AxlUSDC", axlUsdc);
        return json.serialize("Operator", operatorAddress);
    }
}

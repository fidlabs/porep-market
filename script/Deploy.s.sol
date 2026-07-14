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
import {console} from "forge-std/console.sol";

contract Deploy is DeployUtils {
    using stdJson for string;

    address internal poRepMarket;
    address internal validatorFactory;
    address internal dataCapEvidenceAdapter;
    address internal sliOracle;
    address internal sliScorer;

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

    function run() external {
        string memory outputPath = vm.envString("DEPLOYMENT_OUTPUT");
        string memory gitCommit = vm.envString("GIT_COMMIT");
        string memory buildInfoSha256 = vm.envString("BUILD_INFO_SHA256");

        admin = vm.addr(vm.envUint("PRIVATE_KEY"));
        terminationOracle = vm.envAddress("TERMINATION_ORACLE");
        filecoinPay = vm.envAddress("FILECOIN_PAY");
        oracleAddress = vm.envAddress("ORACLE");
        poRepService = vm.envAddress("POREP_SERVICE");
        operatorAddress = vm.envOr("OPERATOR_ADDR", address(0));
        metaAllocator = vm.envAddress("META_ALLOCATOR");

        vm.startBroadcast(admin);

        (validatorFactory, validatorFactoryImpl, validatorImpl) = _deployValidatorFactory(admin);
        (spRegistry, spRegistryImpl) = _deploySPRegistry(admin);
        (dataCapEvidenceAdapter, dataCapEvidenceAdapterImpl) = _deployDataCapEvidenceAdapter();
        (sliOracle, sliOracleImpl) = _deploySLIOracle(admin, oracleAddress);
        (sliScorer, sliScorerImpl) = _deploySliScorer(admin, sliOracle);
        (poRepMarket, poRepMarketImpl) = _deployPoRepMarket(admin, validatorFactory, spRegistry, sliScorer);
        DataCapEvidenceAdapter(dataCapEvidenceAdapter).initialize(admin, terminationOracle, poRepMarket, metaAllocator);

        validatorBeacon = ValidatorFactory(validatorFactory).getBeacon();

        PoRepMarket(poRepMarket).grantRole(PoRepMarket(poRepMarket).POREP_SERVICE_ROLE(), poRepService);
        ValidatorFactory(validatorFactory).initialize2(poRepService, filecoinPay, dataCapEvidenceAdapter, poRepMarket);
        SPRegistry(spRegistry).initialize2(poRepMarket);

        if (operatorAddress != address(0)) {
            SPRegistry(spRegistry).grantRole(SPRegistry(spRegistry).OPERATOR_ROLE(), operatorAddress);
        } else {
            // solhint-disable-next-line gas-small-strings
            console.log("WARNING: OPERATOR_ADDR not set, skipping operator role grant");
        }

        vm.stopBroadcast();

        vm.writeJson(_serializePendingManifest(gitCommit, buildInfoSha256), outputPath, ".result");
    }

    function _deployValidatorFactory(address _admin)
        internal
        returns (address proxy, address factoryImpl, address valImpl)
    {
        Validator _validatorImpl = new Validator();
        ValidatorFactory _impl = new ValidatorFactory();
        bytes memory init = abi.encodeCall(ValidatorFactory.initialize, (_admin, address(_validatorImpl)));
        proxy = createProxy(init, address(_impl));
        factoryImpl = address(_impl);
        valImpl = address(_validatorImpl);
    }

    function _deployPoRepMarket(address _admin, address _validatorFactory, address _spRegistry, address _sliScorer)
        internal
        returns (address proxy, address impl)
    {
        PoRepMarket _impl = new PoRepMarket();
        bytes memory init = abi.encodeCall(
            PoRepMarket.initialize, (_admin, _validatorFactory, _spRegistry, dataCapEvidenceAdapter, _sliScorer)
        );
        proxy = createProxy(init, address(_impl));
        impl = address(_impl);
    }

    function _deployDataCapEvidenceAdapter() internal returns (address proxy, address impl) {
        DataCapEvidenceAdapter _impl = new DataCapEvidenceAdapter();
        proxy = createProxy("", address(_impl));
        impl = address(_impl);
    }

    function _deploySLIOracle(address _admin, address _oracleAddress) internal returns (address proxy, address impl) {
        SLIOracle _impl = new SLIOracle();
        bytes memory init = abi.encodeCall(SLIOracle.initialize, (_admin, _oracleAddress));
        proxy = createProxy(init, address(_impl));
        impl = address(_impl);
    }

    function _deploySliScorer(address _admin, address _sliOracle) internal returns (address proxy, address impl) {
        SLIScorer _impl = new SLIScorer();
        bytes memory init = abi.encodeCall(SLIScorer.initialize, (_admin, SLIOracle(_sliOracle)));
        proxy = createProxy(init, address(_impl));
        impl = address(_impl);
    }

    function _deploySPRegistry(address _admin) internal returns (address proxy, address impl) {
        SPRegistry _impl = new SPRegistry();
        bytes memory init = abi.encodeCall(SPRegistry.initialize, (_admin));
        proxy = createProxy(init, address(_impl));
        impl = address(_impl);
    }

    function _serializePendingManifest(string memory gitCommit, string memory buildInfoSha256)
        internal
        returns (string memory)
    {
        string memory json = "pendingDeployment";
        json.serialize("status", string("pending"));
        json.serialize("release", _serializeRelease(gitCommit, buildInfoSha256));
        json.serialize("deployer", admin);
        json.serialize("contracts", _serializeContracts());
        return json.serialize("externalDependencies", _serializeExternalDependencies());
    }

    function _serializeRelease(string memory gitCommit, string memory buildInfoSha256) private returns (string memory) {
        string memory json = "pendingRelease";
        json.serialize("gitCommit", gitCommit);
        return json.serialize("buildInfoSha256", buildInfoSha256);
    }

    function _serializeContracts() private returns (string memory) {
        string memory json = "pendingContracts";
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
        return json.serialize("ValidatorBeacon", _serializeValidatorBeacon());
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
        return json.serialize("Operator", operatorAddress);
    }
}

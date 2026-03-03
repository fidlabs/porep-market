// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, max-states-count
pragma solidity =0.8.25;

import {Script} from "forge-std/Script.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {Validator} from "../src/Validator.sol";
import {ValidatorFactory} from "../src/ValidatorFactory.sol";
import {Client} from "../src/Client.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {SLIScorer} from "../src/SLIScorer.sol";

contract Deploy is Script, DeployUtils {
    using stdJson for string;

    address public porepMarket;
    address public validatorFactory;
    address public clientSmartContract;
    address public sliOracle;
    address public sliScorer;

    address public porepMarketImpl;
    address public validatorFactoryImpl;
    address public validatorImpl;
    address public clientSmartContractImpl;
    address public sliOracleImpl;
    address public sliScorerImpl;
    address public validator;
    address public validatorBeacon;

    address public spRegistry;
    address public filecoinPay;
    address public admin;
    address public allocator;
    address public terminationOracle;
    address public oracleAddress;

    error InvalidEnv();

    function run() external {
        admin = vm.addr(vm.envUint("PRIVATE_KEY_TEST"));
        allocator = vm.envAddress("ALLOCATOR");
        terminationOracle = vm.envAddress("TERMINATION_ORACLE");
        filecoinPay = vm.envAddress("FILECOIN_PAY");
        spRegistry = vm.envAddress("SP_REGISTRY");
        oracleAddress = vm.envAddress("ORACLE");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY_TEST"));

        (validatorFactory, validatorFactoryImpl, validatorImpl) = _deployValidatorFactory(admin);
        (porepMarket, porepMarketImpl) = _deployPoRepMarket(admin, validatorFactory, spRegistry);
        (clientSmartContract, clientSmartContractImpl) =
            _deployClientSmartContract(admin, allocator, terminationOracle, porepMarket);
        (sliOracle, sliOracleImpl) = _deploySLIOracle(admin, oracleAddress);
        (sliScorer, sliScorerImpl) = _deploySliScorer(admin, sliOracle);

        validatorBeacon = ValidatorFactory(validatorFactory).getBeacon();

        // circular dependencies
        PoRepMarket(porepMarket).setClientSmartContract(clientSmartContract);
        ValidatorFactory(validatorFactory).initialize2(porepMarket, clientSmartContract, filecoinPay);

        vm.stopBroadcast();

        _serializeAndSaveArtifact();
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

    function _deployPoRepMarket(address _admin, address _validatorFactory, address _spRegistry)
        internal
        returns (address proxy, address impl)
    {
        PoRepMarket _impl = new PoRepMarket();
        bytes memory init = abi.encodeCall(PoRepMarket.initialize, (_admin, _validatorFactory, _spRegistry));
        proxy = createProxy(init, address(_impl));
        impl = address(_impl);
    }

    function _deployClientSmartContract(
        address _admin,
        address _allocator,
        address _terminationOracle,
        address _porepMarket
    ) internal returns (address proxy, address impl) {
        Client _impl = new Client();
        bytes memory init = abi.encodeCall(Client.initialize, (_admin, _allocator, _terminationOracle, _porepMarket));
        proxy = createProxy(init, address(_impl));
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

    function _serializeAndSaveArtifact() internal {
        string memory json = "deployment";

        json.serialize("chainId", block.chainid);
        json.serialize("block", block.number);
        json.serialize("timestamp", block.timestamp);
        json.serialize("deployer", admin);

        serializeContract(json, "PoRepMarket", porepMarket, porepMarketImpl);
        serializeContract(json, "ValidatorFactory", validatorFactory, validatorFactoryImpl);
        serializeContract(json, "Client", clientSmartContract, clientSmartContractImpl);
        serializeContract(json, "SLIOracle", sliOracle, sliOracleImpl);
        serializeContract(json, "SLIScorer", sliScorer, sliScorerImpl);

        json.serialize("FilecoinPay", filecoinPay);
        json.serialize("SPRegistry", spRegistry);
        json.serialize("Allocator", allocator);
        string memory output = json.serialize("TerminationOracle", terminationOracle);

        save(output);
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.25;

import {Script} from "forge-std/Script.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {Validator} from "../src/Validator.sol";
import {ValidatorFactory} from "../src/ValidatorFactory.sol";
import {Client} from "../src/Client.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";
// import {SLIOracle} from "../src/SLIOracle.sol";
// import {SLIScorer} from "../src/SLIScorer.sol";

contract Deploy is Script, DeployUtils {
    using stdJson for string;

    address public porepMarket;
    address public validatorFactory;
    address public clientSmartContract;
    address public spRegistry;
    address public filecoinPay;
    address public admin;
    address public allocator;
    address public terminationOracle;
    // address public oracleAddress;
    // address public oracleSmartContract;
    // address public sliScorer;

    error InvalidEnv();

    function run() external {
        _ensureEnvsExist();

        admin = vm.addr(vm.envUint("PRIVATE_KEY_TEST"));
        allocator = vm.envAddress("ALLOCATOR");
        terminationOracle = vm.envAddress("TERMINATION_ORACLE");
        filecoinPay = vm.envAddress("FILECOIN_PAY");
        spRegistry = vm.envAddress("SP_REGISTRY");
        // oracleAddress = vm.envAddress("ORACLE");
        // oracleSmartContract = vm.envAddress("ORACLE_SMART_CONTRACT");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY_TEST"));

        validatorFactory = _deployValidatorFactory(admin);
        porepMarket = _deployPoRepMarket(admin, validatorFactory, spRegistry);
        clientSmartContract = _deployClientSmartContract(admin, allocator, terminationOracle, porepMarket);
        // oracleSmartContract = _deployOracleSmartContract(admin, oracleAddress);
        // sliScorer = _deploySliScorer(admin, oracleSmartContract);

        // circular dependencies
        PoRepMarket(porepMarket).setClientSmartContract(clientSmartContract);
        ValidatorFactory(validatorFactory).initialize2(porepMarket, clientSmartContract, filecoinPay);

        vm.stopBroadcast();

        _serializeAndSaveArtifact();
    }

    function _ensureEnvsExist() internal view {
        if (
            !vm.envExists("RPC_TEST") || !vm.envExists("PRIVATE_KEY_TEST") || !vm.envExists("FILECOIN_PAY")
                || !vm.envExists("SP_REGISTRY") || !vm.envExists("ALLOCATOR") || !vm.envExists("TERMINATION_ORACLE")
                || !vm.envExists("ORACLE")
        ) {
            revert InvalidEnv();
        }
    }

    function _deployValidatorFactory(address _admin) internal returns (address proxy) {
        Validator validatorImpl = new Validator();
        ValidatorFactory impl = new ValidatorFactory();
        bytes memory init = abi.encodeCall(ValidatorFactory.initialize, (_admin, address(validatorImpl)));
        proxy = createProxy(init, address(impl));
    }

    function _deployPoRepMarket(address _admin, address _validatorFactory, address _spRegistry)
        internal
        returns (address proxy)
    {
        PoRepMarket impl = new PoRepMarket();
        bytes memory init = abi.encodeCall(PoRepMarket.initialize, (_admin, _validatorFactory, _spRegistry));
        proxy = createProxy(init, address(impl));
    }

    function _deployClientSmartContract(
        address _admin,
        address _allocator,
        address _terminationOracle,
        address _porepMarket
    ) internal returns (address proxy) {
        Client impl = new Client();
        bytes memory init = abi.encodeCall(Client.initialize, (_admin, _allocator, _terminationOracle, _porepMarket));
        proxy = createProxy(init, address(impl));
    }

    // function _deployOracle(address _admin, address _oracleAddress) internal returns (address proxy) {
    //     SLIOracle impl = new SLIOracle();
    //     bytes memory init = abi.encodeCall(SLIOracle.initialize, (_admin, _oracleAddress));
    //     proxy = _createProxy(init, address(impl));
    // }

    // function _deploySliScorer(address _admin, address _oracleSmartContract) internal returns (address proxy) {
    //     SLIScorer impl = new SLIScorer();
    //     bytes memory init = abi.encodeCall(SLIScorer.initialize, (_admin, _oracleSmartContract));
    //     proxy = _createProxy(init, address(impl));
    // }

    function _serializeAndSaveArtifact() internal {
        string memory json = "deployment";
        json.serialize("chainId", block.chainid);
        json.serialize("block", block.number);
        json.serialize("timestamp", block.timestamp);
        json.serialize("deployer", admin);
        json.serialize("PoRepMarket", porepMarket);
        json.serialize("ValidatorFactory", validatorFactory);
        json.serialize("ClientSmartContract", clientSmartContract);
        json.serialize("FilecoinPay", filecoinPay);
        json.serialize("SPRegistry", spRegistry);
        json.serialize("Allocator", allocator);
        // OracleSmartContract and SLIScorer intentionally omitted (commented out)
        // json.serialize("OracleSmartContract", oracleSmartContract);
        // json.serialize("SLIScorer", sliScorer);
        string memory output = json.serialize("TerminationOracle", terminationOracle);

        save(output);
    }
}

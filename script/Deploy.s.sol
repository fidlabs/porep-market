// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Operator} from "../src/Operator.sol";
import {OperatorFactory} from "../src/OperatorFactory.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";

contract Deploy is Script, DeployUtils {
    using stdJson for string;

    address internal admin;
    address internal filecoinPay;
    IERC20 internal token;

    address internal operatorFactory;
    address internal operatorFactoryImpl;
    address internal operatorImpl;
    address internal operatorBeacon;

    function run() external {
        admin = vm.addr(vm.envUint("PRIVATE_KEY"));
        filecoinPay = vm.envAddress("FILECOIN_PAY");
        token = IERC20(vm.envAddress("TOKEN"));

        vm.startBroadcast(admin);

        Operator operatorImplementation = new Operator();
        OperatorFactory factoryImplementation = new OperatorFactory();

        bytes memory init =
            abi.encodeCall(OperatorFactory.initialize, (admin, address(operatorImplementation), filecoinPay, token));

        operatorFactory = createProxy(init, address(factoryImplementation));
        operatorFactoryImpl = address(factoryImplementation);
        operatorImpl = address(operatorImplementation);
        operatorBeacon = OperatorFactory(operatorFactory).getBeacon();

        vm.stopBroadcast();

        _serializeAndSaveArtifact();
    }

    function _serializeAndSaveArtifact() internal {
        string memory json = "deployment";

        json.serialize("chainId", block.chainid);
        json.serialize("block", block.number);
        json.serialize("timestamp", block.timestamp);
        json.serialize("deployer", admin);

        serializeContract(json, "OperatorFactory", operatorFactory, operatorFactoryImpl);
        serializeBeaconContract(json, "Operator", operatorBeacon, operatorImpl);

        json.serialize("FilecoinPay", filecoinPay);
        json.serialize("Token", address(token));
        string memory output = json.serialize("OperatorBeacon", operatorBeacon);

        save(output);
    }
}

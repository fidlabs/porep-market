// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {OperatorFactory} from "../src/OperatorFactory.sol";

interface IUpgradeable {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

contract Upgrade is Script, DeployUtils {
    using stdJson for string;

    address internal admin;
    address internal proxy;
    address internal beacon;
    address internal prevImpl;
    address internal impl;
    string internal name;
    bytes32 internal deployedCodeHash;
    bytes internal cd;

    error ContractAlreadyDeployed();

    function run() external {
        admin = vm.addr(vm.envUint("PRIVATE_KEY"));
        name = vm.envString("UPGRADE_CONTRACT_NAME");
        cd = vm.envOr("UPGRADE_CALLDATA", bytes(""));

        bytes32 hash = generateContractHash(name);
        string memory json = readLatestDeploymentArtifact();

        if (_isOperatorBeaconUpgrade(name)) {
            (beacon, prevImpl,, deployedCodeHash) = deserializeBeaconContract(json, name);
            (proxy,,,) = deserializeContract(json, "OperatorFactory");

            if (hash == deployedCodeHash) {
                revert ContractAlreadyDeployed();
            }

            vm.startBroadcast(admin);

            impl = vm.deployCode(string.concat(name, ".sol:", name));
            OperatorFactory(proxy).upgradeOperatorImplementation(impl);

            vm.stopBroadcast();
            serializeAndSaveBeaconArtifact();
            return;
        }

        (proxy, prevImpl,, deployedCodeHash) = deserializeContract(json, name);

        if (hash == deployedCodeHash) {
            revert ContractAlreadyDeployed();
        }

        vm.startBroadcast(admin);

        impl = vm.deployCode(string.concat(name, ".sol:", name));
        IUpgradeable(proxy).upgradeToAndCall(impl, cd);

        vm.stopBroadcast();
        serializeAndSaveArtifact();
    }

    function _isOperatorBeaconUpgrade(string memory contractName) internal pure returns (bool) {
        return keccak256(bytes(contractName)) == keccak256("Operator");
    }

    function serializeAndSaveArtifact() internal {
        string memory json = name;

        json.serialize("proxy", proxy);
        json.serialize("prevImpl", prevImpl);
        json.serialize("newImpl", impl);
        json.serialize("prevCodeHash", vm.toString(prevImpl.codehash));
        json.serialize("newCodeHash", vm.toString(impl.codehash));
        json.serialize("upgradedAt", block.timestamp);
        json.serialize("chainId", block.chainid);
        json.serialize("deployer", admin);

        string memory output =
            json.serialize("deployedCodeHash", keccak256(vm.getDeployedCode(string.concat(name, ".sol:", name))));

        saveUpgrade(output, name);
        updateLatestImpl(name, impl);
    }

    function serializeAndSaveBeaconArtifact() internal {
        string memory json = name;

        json.serialize("beacon", beacon);
        json.serialize("prevImpl", prevImpl);
        json.serialize("newImpl", impl);
        json.serialize("prevCodeHash", vm.toString(prevImpl.codehash));
        json.serialize("newCodeHash", vm.toString(impl.codehash));
        json.serialize("upgradedAt", block.timestamp);
        json.serialize("chainId", block.chainid);
        json.serialize("deployer", admin);

        string memory output =
            json.serialize("deployedCodeHash", keccak256(vm.getDeployedCode(string.concat(name, ".sol:", name))));

        saveUpgrade(output, name);
        updateLatestBeaconImpl(name, impl);
    }
}

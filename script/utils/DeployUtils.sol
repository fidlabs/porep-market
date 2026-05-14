// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUtils is Script {
    using stdJson for string;

    string internal constant LATEST_DEPLOYMENT_FILE = "retrieval-operator-latest.json";

    function save(string memory json) internal {
        if (!_shouldWriteDeploymentArtifacts()) return;

        string memory base = string.concat("./deployments/", network());

        vm.createDir(base, true);
        vm.writeJson(json, string.concat(base, "/", LATEST_DEPLOYMENT_FILE));
        vm.writeJson(json, string.concat(base, "/", vm.toString(block.number), ".json"));
    }

    function saveUpgrade(string memory json, string memory contractName) internal {
        if (!_shouldWriteDeploymentArtifacts()) return;

        string memory base = string.concat("./deployments/", network(), "/upgrades");
        vm.createDir(base, true);
        vm.writeJson(json, string.concat(base, "/", vm.toString(block.number), "_", contractName, ".json"));
    }

    function updateLatestImpl(string memory contractName, address newImpl) internal {
        if (!_shouldWriteDeploymentArtifacts()) return;

        string memory path = string.concat("./deployments/", network(), "/", LATEST_DEPLOYMENT_FILE);
        vm.writeJson(vm.toString(newImpl), path, string.concat(".", contractName, ".impl"));
        vm.writeJson(vm.toString(newImpl.codehash), path, string.concat(".", contractName, ".codeHash"));
        vm.writeJson(
            vm.toString(keccak256(vm.getDeployedCode(string.concat(contractName, ".sol:", contractName)))),
            path,
            string.concat(".", contractName, ".deployedCodeHash")
        );
    }

    function createProxy(bytes memory init, address impl) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(address(impl), init));
    }

    function serializeContract(string memory json, string memory contractName, address proxy, address impl) internal {
        string memory obj = contractName;
        obj.serialize("proxy", proxy);
        obj.serialize("impl", impl);
        obj.serialize("codeHash", vm.toString(impl.codehash));
        string memory serialized = obj.serialize(
            "deployedCodeHash",
            keccak256(vm.getDeployedCode(string.concat(contractName, ".sol:", contractName))) // <-- fix
        );
        json.serialize(contractName, serialized);
    }

    function serializeBeaconContract(string memory json, string memory contractName, address beacon, address impl)
        internal
    {
        string memory obj = contractName;
        obj.serialize("beacon", beacon);
        obj.serialize("impl", impl);
        obj.serialize("codeHash", vm.toString(impl.codehash));
        string memory serialized = obj.serialize(
            "deployedCodeHash", keccak256(vm.getDeployedCode(string.concat(contractName, ".sol:", contractName)))
        );
        json.serialize(contractName, serialized);
    }

    function readLatestDeploymentArtifact() internal view returns (string memory json) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        json = vm.readFile(string.concat("./deployments/", network(), "/", LATEST_DEPLOYMENT_FILE));
    }

    function deserializeContract(string memory json, string memory contractName)
        internal
        pure
        returns (address proxy, address impl, bytes32 codeHash, bytes32 deployedCodeHash)
    {
        proxy = abi.decode(json.parseRaw(string.concat(".", contractName, ".proxy")), (address));
        impl = abi.decode(json.parseRaw(string.concat(".", contractName, ".impl")), (address));
        codeHash = abi.decode(json.parseRaw(string.concat(".", contractName, ".codeHash")), (bytes32));
        deployedCodeHash = abi.decode(json.parseRaw(string.concat(".", contractName, ".deployedCodeHash")), (bytes32));
    }

    function deserializeBeaconContract(string memory json, string memory contractName)
        internal
        pure
        returns (address beacon, address impl, bytes32 codeHash, bytes32 deployedCodeHash)
    {
        beacon = abi.decode(json.parseRaw(string.concat(".", contractName, ".beacon")), (address));
        impl = abi.decode(json.parseRaw(string.concat(".", contractName, ".impl")), (address));
        codeHash = abi.decode(json.parseRaw(string.concat(".", contractName, ".codeHash")), (bytes32));
        deployedCodeHash = abi.decode(json.parseRaw(string.concat(".", contractName, ".deployedCodeHash")), (bytes32));
    }

    function updateLatestBeaconImpl(string memory contractName, address newImpl) internal {
        if (!_shouldWriteDeploymentArtifacts()) return;

        string memory path = string.concat("./deployments/", network(), "/", LATEST_DEPLOYMENT_FILE);
        vm.writeJson(vm.toString(newImpl), path, string.concat(".", contractName, ".impl"));
        vm.writeJson(vm.toString(newImpl.codehash), path, string.concat(".", contractName, ".codeHash"));
        vm.writeJson(
            vm.toString(keccak256(vm.getDeployedCode(string.concat(contractName, ".sol:", contractName)))),
            path,
            string.concat(".", contractName, ".deployedCodeHash")
        );
    }

    function generateContractHash(string memory contractName) internal view returns (bytes32 hash) {
        hash = keccak256(vm.getDeployedCode(string.concat(contractName, ".sol:", contractName)));
    }

    function _shouldWriteDeploymentArtifacts() internal view returns (bool) {
        return
            vmSafe.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vmSafe.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    function network() internal view returns (string memory) {
        if (block.chainid == 31415926) return "devnet";
        else if (block.chainid == 314159) return "calibnet";
        else if (block.chainid == 314) return "mainnet";
        else return vm.toString(block.chainid);
    }
}

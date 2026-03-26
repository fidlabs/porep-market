// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

interface IUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external;
}

struct UpgradeParams {
    string contractName;
    bytes cd;
    bool isBeacon;
    address proxy;
}

contract DeployUtils is Script {
    using stdJson for string;

    function _root() internal view returns (string memory) {
        return string.concat("./deployments/", network());
    }

    function _upgradeRoot() internal view returns (string memory) {
        return string.concat(_root(), "/upgrades/");
    }

    function saveDeploymentArtifact(string memory json) internal {
        vm.createDir(_root(), true);
        vm.writeJson(json, string.concat(_root(), "/", vm.toString(block.number), ".json"));
        vm.writeJson(json, string.concat(_root(), "/latest.json"));
    }

    function saveUpgradeArtifact(string memory json, string memory contractName) internal {
        vm.createDir(_upgradeRoot(), true);
        vm.writeJson(json, string.concat(_upgradeRoot(), vm.toString(block.number), "_", contractName, ".json"));
    }

    function updateLatestImpl(string memory contractName, address newImpl) internal {
        string memory path = string.concat("./deployments/", network(), "/latest.json");
        vm.writeJson(vm.toString(newImpl), path, string.concat(".", contractName, ".impl"));
        vm.writeJson(vm.toString(newImpl.codehash), path, string.concat(".", contractName, ".codeHash"));
        vm.writeJson(
            vm.toString(keccak256(vm.getDeployedCode(string.concat(contractName, ".sol:", contractName)))),
            path,
            string.concat(".", contractName, ".deployedCodeHash")
        );
    }

    function createProxy(bytes memory init, address impl) internal returns (address proxyAddr) {
        proxyAddr = address(new ERC1967Proxy(address(impl), init));
    }

    function serializeContract(string memory json, string memory contractName, address proxyAddr, address impl)
        internal
    {
        string memory obj = contractName;
        obj.serialize("proxy", proxyAddr);
        obj.serialize("impl", impl);
        obj.serialize("codeHash", vm.toString(impl.codehash));
        string memory serialized = obj.serialize(
            "deployedCodeHash",
            keccak256(vm.getDeployedCode(string.concat(contractName, ".sol:", contractName))) // <-- fix
        );
        json.serialize(contractName, serialized);
    }

    function serializePreviousVersion(
        string memory json,
        string memory contractName,
        address prevImpl,
        bytes32 prevImplCodeHash
    ) internal {
        string memory obj = contractName;
        obj.serialize("prevImpl", prevImpl);
        obj.serialize("prevCodeHash", vm.toString(prevImplCodeHash));
        string memory serialized = obj.serialize(
            "prevDeployedCodeHash",
            keccak256(vm.getDeployedCode(string.concat(contractName, ".sol:", contractName))) // <-- fix
        );
        json.serialize(contractName, serialized);
    }

    function readLatestDeploymentArtifact() internal view returns (string memory json) {
        json = vm.readFile(string.concat(_root(), "/latest.json"));
    }

    function deserializeContract(string memory json, string memory contractName)
        internal
        pure
        returns (address proxyAddr, address impl, bytes32 codeHash, bytes32 deployedCodeHash)
    {
        proxyAddr = json.readAddress(string.concat(".", contractName, ".proxy"));
        impl = json.readAddress(string.concat(".", contractName, ".impl"));
        codeHash = json.readBytes32(string.concat(".", contractName, ".codeHash"));
        deployedCodeHash = json.readBytes32(string.concat(".", contractName, ".deployedCodeHash"));
    }

    function generateContractHash(string memory contractName) internal view returns (bytes32 hash) {
        hash = keccak256(vm.getDeployedCode(string.concat(contractName, ".sol:", contractName)));
    }

    function upgrade(address proxyAddr, string memory contractName, bytes memory cd) internal returns (address impl) {
        impl = vm.deployCode(string.concat(contractName, ".sol:", contractName));
        IUpgradeable(proxyAddr).upgradeToAndCall(impl, cd);
    }

    function upgradeBeacon(address beaconAddr, string memory contractName) internal returns (address impl) {
        impl = vm.deployCode(string.concat(contractName, ".sol:", contractName));
        UpgradeableBeacon(beaconAddr).upgradeTo(impl);
    }

    function network() internal view returns (string memory) {
        if (block.chainid == 31415926) return "devnet";
        else if (block.chainid == 314159) return "calibnet";
        else if (block.chainid == 314) return "mainnet";
        else return vm.toString(block.chainid);
    }

    function beacon(string memory name) internal pure returns (UpgradeParams memory) {
        return UpgradeParams({contractName: name, cd: bytes(""), isBeacon: true, proxy: address(0)});
    }

    function proxy(string memory name, bytes memory cd) internal pure returns (UpgradeParams memory) {
        return UpgradeParams({contractName: name, cd: cd, isBeacon: false, proxy: address(0)});
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, gas-small-strings
pragma solidity =0.8.30;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IValidatorFactory} from "../src/interfaces/IValidatorFactory.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";

interface IUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external;
}

contract Upgrade is DeployUtils {
    using stdJson for string;
    error StaleValidatorBeacon(address manifestBeacon, address factoryBeacon);
    error StaleValidatorImpl(address manifestImpl, address beaconImpl);

    struct Operation {
        string target;
        string artifact;
        address destination;
        address newImplementation;
        bool beacon;
    }

    function run() external {
        string memory manifest = vm.readFile(vm.envString("DEPLOYMENT_MANIFEST"));
        string[] memory names = vm.envString("UPGRADE_CONTRACT_NAMES", ",");
        Operation[] memory operations = new Operation[](names.length);
        for (uint256 i; i < names.length; ++i) {
            if (keccak256(bytes(names[i])) == keccak256("Validator")) {
                address beacon = manifest.readAddress(".contracts.ValidatorBeacon.address");
                address factory = manifest.readAddress(".contracts.ValidatorFactory.proxy");
                address previous = manifest.readAddress(".contracts.Validator.implementation");
                _ensureCode(beacon);
                _ensureCode(factory);
                _ensureCode(previous);
                address factoryBeacon = IValidatorFactory(factory).getBeacon();
                if (factoryBeacon != beacon) revert StaleValidatorBeacon(beacon, factoryBeacon);
                address live = UpgradeableBeacon(beacon).implementation();
                if (live != previous) revert StaleValidatorImpl(previous, live);
                operations[i] = Operation(names[i], "src/Validator.sol:Validator", beacon, address(0), true);
            } else {
                string memory artifact = _uupsArtifact(names[i]);
                address proxy = _manifestUupsTarget(manifest, names[i]);
                operations[i] = Operation(names[i], artifact, proxy, address(0), false);
            }
        }
        vm.startBroadcast(vm.addr(vm.envUint("PRIVATE_KEY")));
        for (uint256 i; i < operations.length; ++i) {
            operations[i].newImplementation = vm.deployCode(operations[i].artifact);
        }
        for (uint256 i; i < operations.length; ++i) {
            if (operations[i].beacon) {
                UpgradeableBeacon(operations[i].destination).upgradeTo(operations[i].newImplementation);
            } else {
                IUpgradeable(operations[i].destination).upgradeToAndCall(operations[i].newImplementation, "");
            }
        }
        vm.stopBroadcast();
        _writeOperations(operations);
    }

    function _writeOperations(Operation[] memory operations) private {
        string memory json = "[";
        for (uint256 i; i < operations.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            Operation memory operation = operations[i];
            json = string.concat(
                json,
                "{\"target\":\"",
                operation.target,
                "\",\"kind\":\"",
                operation.beacon ? "beacon" : "uups",
                "\",\"artifact\":\"",
                operation.artifact,
                "\",\"newImplementation\":\"",
                vm.toString(operation.newImplementation),
                "\",\"newImplementationCodeHash\":\"",
                vm.toString(operation.newImplementation.codehash),
                "\"}"
            );
        }
        vm.writeJson(string.concat(json, "]"), vm.envString("UPGRADE_OUTPUT"), ".operations");
    }
}

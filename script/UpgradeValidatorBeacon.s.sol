// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";

contract UpgradeValidatorBeacon is DeployUtils {
    using stdJson for string;

    address internal admin;
    address internal beacon;
    address internal prevImpl;
    address internal prevManifestImpl;
    address internal impl;
    bytes32 internal deployedCodeHash;

    error ContractAlreadyDeployed();
    error MissingValidatorBeacon();
    error MissingValidatorImpl();
    error StaleValidatorImpl(address manifestImpl, address beaconImpl);

    function run() external {
        admin = vm.addr(vm.envUint("PRIVATE_KEY"));

        string memory json = readLatestDeploymentArtifact();
        beacon = _readRequiredAddress(json, ".ValidatorBeacon", true);
        prevManifestImpl = _readRequiredAddress(json, ".ValidatorImpl", false);
        prevImpl = UpgradeableBeacon(beacon).implementation();

        if (prevManifestImpl != prevImpl) {
            revert StaleValidatorImpl(prevManifestImpl, prevImpl);
        }

        deployedCodeHash = generateContractHash("Validator");
        if (deployedCodeHash == prevImpl.codehash) {
            revert ContractAlreadyDeployed();
        }

        vm.startBroadcast(admin);

        impl = vm.deployCode("Validator.sol:Validator");
        UpgradeableBeacon(beacon).upgradeTo(impl);

        vm.stopBroadcast();

        _serializeAndSaveArtifact();
    }

    function _readRequiredAddress(string memory json, string memory key, bool isBeacon)
        internal
        view
        returns (address value)
    {
        if (!json.keyExists(key)) {
            if (isBeacon) revert MissingValidatorBeacon();
            revert MissingValidatorImpl();
        }

        value = json.readAddress(key);

        if (value == address(0)) {
            if (isBeacon) revert MissingValidatorBeacon();
            revert MissingValidatorImpl();
        }
    }

    function _serializeAndSaveArtifact() internal {
        string memory json = "ValidatorBeacon";

        json.serialize("beacon", beacon);
        json.serialize("prevImpl", prevImpl);
        json.serialize("prevManifestImpl", prevManifestImpl);
        json.serialize("newImpl", impl);
        json.serialize("prevCodeHash", vm.toString(prevImpl.codehash));
        json.serialize("newCodeHash", vm.toString(impl.codehash));
        json.serialize("upgradedAt", block.timestamp);
        json.serialize("chainId", block.chainid);
        json.serialize("deployer", admin);
        string memory output = json.serialize("deployedCodeHash", deployedCodeHash);

        saveUpgrade(output, "ValidatorBeacon");
        _updateLatestValidatorImpl(impl);
    }

    function _updateLatestValidatorImpl(address newImpl) internal {
        string memory path = string.concat("./deployments/", network(), "/latest.json");
        vm.writeJson(vm.toString(newImpl), path, ".ValidatorImpl");
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract Upgrade is Script, DeployUtils {
    using stdJson for string;

    address internal admin;
    address internal proxyAddr;
    address internal prevImpl;
    address internal impl;
    string internal name;
    bytes32 internal deployedCodeHash;
    bytes internal cd;

    string internal upgradeArtifact;
    string internal latestArtifact;

    error ContractAlreadyDeployed();

    function run() external {
        admin = vm.addr(vm.envUint("PRIVATE_KEY"));
        name = vm.envString("UPGRADE_CONTRACT_NAME");
        cd = vm.envOr("UPGRADE_CALLDATA", bytes(""));
        upgradeArtifact = name;
        latestArtifact = readLatestDeploymentArtifact();

        bytes32 hash = generateContractHash(name);
        (proxyAddr, prevImpl,, deployedCodeHash) = deserializeContract(latestArtifact, name);

        if (hash == deployedCodeHash) {
            revert ContractAlreadyDeployed();
        }

        vm.startBroadcast(admin);
        impl = upgrade(proxyAddr, name, cd);
        vm.stopBroadcast();

        serializeAndSaveArtifact();
    }

    function serializeAndSaveArtifact() internal {
        upgradeArtifact.serialize("proxy", proxyAddr);
        upgradeArtifact.serialize("prevImpl", prevImpl);
        upgradeArtifact.serialize("newImpl", impl);
        upgradeArtifact.serialize("prevCodeHash", vm.toString(prevImpl.codehash));
        upgradeArtifact.serialize("newCodeHash", vm.toString(impl.codehash));
        upgradeArtifact.serialize("upgradedAt", block.timestamp);
        upgradeArtifact.serialize("chainId", block.chainid);
        upgradeArtifact.serialize("deployer", admin);

        string memory output = upgradeArtifact.serialize(
            "deployedCodeHash", keccak256(vm.getDeployedCode(string.concat(name, ".sol:", name)))
        );

        saveUpgradeArtifact(output, name);

        serializeContract(latestArtifact, name, proxyAddr, impl);
        updateLatestImpl(name, impl);
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.25;

import {Script} from "forge-std/Script.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";
import {stdJson} from "forge-std/StdJson.sol";

interface IUpgradeable {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

contract Upgrade is Script, DeployUtils {
    using stdJson for string;

    address internal proxy;
    string internal name;
    bytes internal cd;

    function run() external {
        proxy = vm.envAddress("UPGRADE_PROXY_ADDRESS_TEST");
        name = vm.envString("UPGRADE_CONTRACT_NAME");
        cd = vm.envOr("UPGRADE_CALLDATA", bytes(""));

        string memory json = readLatestDeploymentArtifact(name);
        (,,, bytes memory deployedCodeHash) = deserializeContract(json, name);
        bytes32 hash = generateContractHash(name);

        if (hash == abi.decode(deployedCodeHash, (bytes32))) {
            revert("Code hash is unchanged, upgrade skipped");
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY_TEST"));

        address impl = vm.deployCode(string.concat(name, ".sol:", name));

        IUpgradeable(proxy).upgradeToAndCall(impl, cd);

        vm.stopBroadcast();
    }
}

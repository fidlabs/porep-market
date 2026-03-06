// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.25;

import {Script} from "forge-std/Script.sol";

interface IUpgradeable {
    function upgradeToAndCall(address newImpl, bytes calldata data) external;
}

contract Upgrade is Script {
    address internal proxy;
    string internal name;
    bytes internal cd;

    function run() external {
        proxy = vm.envAddress("UPGRADE_PROXY_ADDRESS_TEST");
        name = vm.envString("UPGRADE_CONTRACT_NAME");
        cd = vm.envOr("UPGRADE_CALLDATA", bytes(""));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY_TEST"));

        address impl = vm.deployCode(string.concat(name, ".sol:", name));

        IUpgradeable(proxy).upgradeToAndCall(impl, cd);

        vm.stopBroadcast();
    }
}

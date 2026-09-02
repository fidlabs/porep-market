// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, no-console
pragma solidity =0.8.30;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {ISPRegistry} from "../src/interfaces/ISPRegistry.sol";
import {SPRegistry} from "../src/SPRegistry.sol";

contract ConfigurePaymentTokens is Script {
    function run() external {
        SPRegistry registry = SPRegistry(vm.envAddress("SP_REGISTRY"));
        address usdfc = vm.envOr("USDFC", address(0));
        address axlUsdc = vm.envOr("AXL_USDC", address(0));

        vm.startBroadcast(vm.addr(vm.envUint("PRIVATE_KEY")));
        _configure(registry, "USDFC", usdfc);
        _configure(registry, "axlUSDC", axlUsdc);
        vm.stopBroadcast();
    }

    function _configure(SPRegistry registry, string memory name, address token) private {
        if (token == address(0)) return;

        ISPRegistry.TokenConfig memory config = registry.getPaymentTokenConfig(token);
        if (config.allowed && config.minPricePer32GiBPerMonth == 1) {
            console.log(name, "already configured");
            return;
        }

        console.log("Configuring", name, token);
        registry.setPaymentToken(token, true, 1);
    }
}

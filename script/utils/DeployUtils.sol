// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.25;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUtils is Script {
    using stdJson for string;

    function save(string memory json) internal {
        string memory base = string.concat("./deployments/", network());

        vm.createDir(base, true);
        vm.writeJson(json, string.concat(base, "/latest.json"));
        vm.writeJson(json, string.concat(base, "/", vm.toString(block.number), ".json"));
    }

    function createProxy(bytes memory init, address impl) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(address(impl), init));
    }

    function serializeContract(
        string memory json,
        string memory contractName,
        address proxy,
        address impl
    ) internal {
        string memory obj = contractName;
        obj.serialize("proxy", proxy);
        obj.serialize("impl", impl);
        obj.serialize("codeHash", vm.toString(impl.codehash));
        string memory serialized = obj.serialize("deployedCodeHash", keccak256(vm.getDeployedCode(contractName)));
        json.serialize(contractName, serialized);
    }

    function network() internal view returns (string memory) {
        if (block.chainid == 31415926) return "devnet";
        else if (block.chainid == 314159) return "calibnet";
        else if (block.chainid == 314) return "mainnet";
        else return vm.toString(block.chainid);
    }
}

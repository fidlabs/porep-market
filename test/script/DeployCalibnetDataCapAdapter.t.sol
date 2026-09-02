// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, no-empty-blocks, gas-small-strings, quotes
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployCalibnetDataCapAdapter} from "../../script/DeployCalibnetDataCapAdapter.s.sol";
import {DataCapEvidenceAdapter} from "../../src/DataCapEvidenceAdapter.sol";

contract DeployCalibnetDataCapAdapterTestHarness is DeployCalibnetDataCapAdapter {
    function runWithInputs(string calldata manifest, string calldata outputPath, uint256 privateKey) external {
        _run(manifest, outputPath, privateKey);
    }
}

contract DeployCalibnetDataCapAdapterTest is Test {
    using stdJson for string;

    address private constant CALIBNET_ADAPTER_PROXY = 0xfEBd13e0DecCD8B96c2781da32b30BbEB12884Db;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function testDeploysAndUpgradesExpectedCalibnetProxy() public {
        vm.chainId(314159);
        address admin = vm.addr(1);
        address previous = address(new DataCapEvidenceAdapter());
        address template = address(new ERC1967Proxy(previous, ""));
        vm.etch(CALIBNET_ADAPTER_PROXY, template.code);
        vm.store(CALIBNET_ADAPTER_PROXY, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(previous))));
        DataCapEvidenceAdapter(CALIBNET_ADAPTER_PROXY).initialize(admin, vm.addr(2), vm.addr(3), vm.addr(4));
        string memory outputPath = string.concat(vm.projectRoot(), "/.deployment/calibnet-adapter-output.json");
        vm.createDir(string.concat(vm.projectRoot(), "/.deployment"), true);
        if (vm.exists(outputPath)) vm.removeFile(outputPath);

        new DeployCalibnetDataCapAdapterTestHarness()
            .runWithInputs(_manifest(CALIBNET_ADAPTER_PROXY, previous), outputPath, 1);

        string memory output = vm.readFile(outputPath);
        address implementation = output.readAddress(".operations[0].newImplementation");
        assertEq(address(uint160(uint256(vm.load(CALIBNET_ADAPTER_PROXY, IMPLEMENTATION_SLOT)))), implementation);
        assertEq(output.readString(".operations[0].target"), "DataCapEvidenceAdapter");
        assertEq(output.readString(".operations[0].artifact"), "src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter");
        assertEq(
            output.readString(".operations[0].newArtifact"), "src/CalibnetDataCapAdapter.sol:CalibnetDataCapAdapter"
        );
    }

    function _manifest(address proxy, address implementation) private view returns (string memory) {
        return string.concat(
            '{"contracts":{"DataCapEvidenceAdapter":{"kind":"uups","artifact":',
            '"src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter","proxy":"',
            vm.toString(proxy),
            '","implementation":"',
            vm.toString(implementation),
            '","proxyCodeHash":"',
            vm.toString(proxy.codehash),
            '","implementationCodeHash":"',
            vm.toString(implementation.codehash),
            '"}}}'
        );
    }
}

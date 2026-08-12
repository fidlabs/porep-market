// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, no-empty-blocks, gas-small-strings, quotes
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployCalibnetDataCapAdapter} from "../../script/DeployCalibnetDataCapAdapter.s.sol";

contract LegacyCalibnetAdapter is UUPSUpgradeable {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    address private immutable _ADMIN;

    error Unauthorized();

    constructor(address admin) {
        _ADMIN = admin;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == UPGRADER_ROLE && account == _ADMIN;
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != _ADMIN) revert Unauthorized();
    }
}

contract DeployCalibnetDataCapAdapterHarness is DeployCalibnetDataCapAdapter {
    function runWithExpectedProxy(address expectedProxy) external {
        _run(expectedProxy);
    }
}

contract DeployCalibnetDataCapAdapterTest is Test {
    using stdJson for string;

    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function testDeploysAndUpgradesExpectedCalibnetProxy() public {
        vm.chainId(314159);
        address admin = vm.addr(1);
        address previous = address(new LegacyCalibnetAdapter(admin));
        address proxy = address(new ERC1967Proxy(previous, ""));
        string memory manifestPath = string.concat(vm.projectRoot(), "/.deployment/calibnet-adapter-manifest.json");
        string memory outputPath = string.concat(vm.projectRoot(), "/.deployment/calibnet-adapter-output.json");
        vm.createDir(string.concat(vm.projectRoot(), "/.deployment"), true);
        vm.writeFile(manifestPath, _manifest(proxy, previous));
        vm.writeFile(outputPath, "{}");
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("DEPLOYMENT_MANIFEST", manifestPath);
        vm.setEnv("UPGRADE_OUTPUT", outputPath);

        new DeployCalibnetDataCapAdapterHarness().runWithExpectedProxy(proxy);

        string memory output = vm.readFile(outputPath);
        address implementation = output.readAddress(".operations[0].newImplementation");
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), implementation);
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
            '","proxyCodeHash":"0x',
            _hex(proxy.codehash),
            '","implementationCodeHash":"0x',
            _hex(implementation.codehash),
            '"}}}'
        );
    }

    function _hex(bytes32 value) private pure returns (string memory result) {
        bytes16 symbols = "0123456789abcdef";
        bytes memory encoded = new bytes(64);
        for (uint256 i; i < 32; ++i) {
            encoded[i * 2] = symbols[uint8(value[i] >> 4)];
            encoded[i * 2 + 1] = symbols[uint8(value[i] & 0x0f)];
        }
        return string(encoded);
    }
}

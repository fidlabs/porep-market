// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUtils is Script {
    using stdJson for string;

    error InvalidUpgradeTarget(string name);
    error MissingContractCode(address target);
    error StaleManifestImplementation(address manifestImplementation, address liveImplementation);

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function createProxy(bytes memory init, address implementation) internal returns (address) {
        return address(new ERC1967Proxy(implementation, init));
    }

    function _uupsArtifact(string memory name) internal pure returns (string memory) {
        bytes32 target = keccak256(bytes(name));
        if (target == keccak256("PoRepMarket")) return "src/PoRepMarket.sol:PoRepMarket";
        if (target == keccak256("ValidatorFactory")) return "src/ValidatorFactory.sol:ValidatorFactory";
        if (target == keccak256("DataCapEvidenceAdapter")) {
            return "src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter";
        }
        if (target == keccak256("SPRegistry")) return "src/SPRegistry.sol:SPRegistry";
        if (target == keccak256("SLIOracle")) return "src/SLIOracle.sol:SLIOracle";
        if (target == keccak256("SLIScorer")) return "src/SLIScorer.sol:SLIScorer";
        revert InvalidUpgradeTarget(name);
    }

    function _manifestUupsTarget(string memory json, string memory name) internal view returns (address proxy) {
        string memory key = string.concat(".contracts.", name);
        proxy = json.readAddress(string.concat(key, ".proxy"));
        address implementation = json.readAddress(string.concat(key, ".implementation"));
        _ensureCode(proxy);
        _ensureCode(implementation);
        address live = _erc1967Implementation(proxy);
        if (live != implementation) revert StaleManifestImplementation(implementation, live);
    }

    function _erc1967Implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _ensureCode(address target) internal view {
        if (target.code.length == 0) revert MissingContractCode(target);
    }
}

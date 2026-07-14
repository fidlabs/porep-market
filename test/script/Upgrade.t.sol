// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, no-empty-blocks, gas-small-strings, gas-calldata-parameters
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Upgrade} from "../../script/Upgrade.s.sol";
import {DeployUtils} from "../../script/utils/DeployUtils.sol";

contract LegacyUups is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal override {}
}

contract LegacyValidator {}

contract LegacyValidatorFactory is UUPSUpgradeable {
    address internal immutable BEACON;

    constructor(address beacon_) {
        BEACON = beacon_;
    }

    function getBeacon() external view returns (address) {
        return BEACON;
    }
    function _authorizeUpgrade(address) internal override {}
}

contract UpgradeHarness is Upgrade {
    string internal manifest;
    string[] internal names;

    function configure(string memory manifest_, string[] memory names_) external {
        manifest = manifest_;
        names = names_;
    }

    function _manifestContents(string memory) internal view override returns (string memory) {
        return manifest;
    }

    function _manifestPath() internal pure override returns (string memory) {
        return "unused";
    }

    function _outputPath() internal pure override returns (string memory) {
        return "./.deployment/upgrade.json";
    }

    function _upgradeNames() internal view override returns (string[] memory) {
        return names;
    }

    function _upgradeAdmin() internal pure override returns (address) {
        return vm.addr(1);
    }
}

contract UpgradeTest is Test {
    using stdJson for string;
    bytes32 private constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function testUpgradesOrderedBatchAndWritesOperations() public {
        string[] memory names = _allTargets();
        (string memory manifest, address[] memory destinations) = _manifestFor(names);
        UpgradeHarness script = new UpgradeHarness();
        script.configure(manifest, names);
        vm.createDir("./.deployment", true);
        vm.writeFile("./.deployment/upgrade.json", "{\"operations\":[]}");
        script.run();
        string memory json = vm.readFile("./.deployment/upgrade.json");
        for (uint256 i; i < names.length; ++i) {
            string memory key = string.concat(".operations[", vm.toString(i), "]");
            address implementation = json.readAddress(string.concat(key, ".newImplementation"));
            assertEq(json.readString(string.concat(key, ".target")), names[i]);
            assertEq(json.readString(string.concat(key, ".kind")), i == names.length - 1 ? "beacon" : "uups");
            assertEq(json.readString(string.concat(key, ".artifact")), _artifact(names[i]));
            assertEq(json.readBytes32(string.concat(key, ".newImplementationCodeHash")), implementation.codehash);
            if (i == names.length - 1) assertEq(UpgradeableBeacon(destinations[i]).implementation(), implementation);
            else assertEq(address(uint160(uint256(vm.load(destinations[i], SLOT)))), implementation);
        }
    }

    function testRejectsUnsupportedTarget() public {
        UpgradeHarness script = new UpgradeHarness();
        string[] memory names = new string[](1);
        names[0] = "Unknown";
        script.configure("{}", names);
        vm.expectRevert(abi.encodeWithSelector(DeployUtils.InvalidUpgradeTarget.selector, "Unknown"));
        script.run();
    }

    function testRejectsStaleValidatorBeacon() public {
        string[] memory names = new string[](1);
        names[0] = "Validator";
        address previous = address(new LegacyValidator());
        UpgradeableBeacon beacon = new UpgradeableBeacon(previous, vm.addr(1));
        address factory =
            address(new ERC1967Proxy(address(new LegacyValidatorFactory(address(new LegacyValidator()))), ""));
        string memory manifest = _validatorManifest(address(beacon), factory, previous);
        UpgradeHarness script = new UpgradeHarness();
        script.configure(manifest, names);
        vm.expectPartialRevert(Upgrade.StaleValidatorBeacon.selector);
        script.run();
    }

    function testRejectsStaleValidatorImplementation() public {
        string[] memory names = new string[](1);
        names[0] = "Validator";
        address live = address(new LegacyValidator());
        UpgradeableBeacon beacon = new UpgradeableBeacon(live, vm.addr(1));
        address factory = address(new ERC1967Proxy(address(new LegacyValidatorFactory(address(beacon))), ""));
        UpgradeHarness script = new UpgradeHarness();
        script.configure(_validatorManifest(address(beacon), factory, address(new LegacyValidator())), names);
        vm.expectPartialRevert(Upgrade.StaleValidatorImpl.selector);
        script.run();
    }

    function _allTargets() private pure returns (string[] memory names) {
        names = new string[](7);
        names[0] = "PoRepMarket";
        names[1] = "ValidatorFactory";
        names[2] = "DataCapEvidenceAdapter";
        names[3] = "SPRegistry";
        names[4] = "SLIOracle";
        names[5] = "SLIScorer";
        names[6] = "Validator";
    }

    function _manifestFor(string[] memory names)
        private
        returns (string memory manifest, address[] memory destinations)
    {
        destinations = new address[](names.length);
        address validator = address(new LegacyValidator());
        UpgradeableBeacon beacon = new UpgradeableBeacon(validator, vm.addr(1));
        string memory contractsJson = "{";
        for (uint256 i; i < names.length - 1; ++i) {
            address previous = i == 1 ? address(new LegacyValidatorFactory(address(beacon))) : address(new LegacyUups());
            address proxy = address(new ERC1967Proxy(previous, ""));
            destinations[i] = proxy;
            if (i != 0) contractsJson = string.concat(contractsJson, ",");
            contractsJson = string.concat(contractsJson, "\"", names[i], "\":", _contract(proxy, previous));
        }
        destinations[names.length - 1] = address(beacon);
        contractsJson = string.concat(
            contractsJson,
            ",\"ValidatorBeacon\":{\"address\":\"",
            vm.toString(address(beacon)),
            "\"},\"Validator\":{\"implementation\":\"",
            vm.toString(validator),
            "\"}}"
        );
        manifest = string.concat("{\"contracts\":", contractsJson, "}");
    }

    function _contract(address proxy, address implementation) private returns (string memory json) {
        json = string.concat(
            "{\"proxy\":\"", vm.toString(proxy), "\",\"implementation\":\"", vm.toString(implementation), "\"}"
        );
    }

    function _validatorManifest(address beacon, address factory, address implementation)
        private
        returns (string memory manifest)
    {
        manifest = string.concat(
            "{\"contracts\":{\"ValidatorBeacon\":{\"address\":\"",
            vm.toString(beacon),
            "\"},\"ValidatorFactory\":{\"proxy\":\"",
            vm.toString(factory),
            "\"},\"Validator\":{\"implementation\":\"",
            vm.toString(implementation),
            "\"}}}"
        );
    }

    function _artifact(string memory name) private pure returns (string memory) {
        bytes32 target = keccak256(bytes(name));
        if (target == keccak256("PoRepMarket")) return "src/PoRepMarket.sol:PoRepMarket";
        if (target == keccak256("ValidatorFactory")) return "src/ValidatorFactory.sol:ValidatorFactory";
        if (target == keccak256("DataCapEvidenceAdapter")) {
            return "src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter";
        }
        if (target == keccak256("SPRegistry")) return "src/SPRegistry.sol:SPRegistry";
        if (target == keccak256("SLIOracle")) return "src/SLIOracle.sol:SLIOracle";
        if (target == keccak256("Validator")) return "src/Validator.sol:Validator";
        return "src/SLIScorer.sol:SLIScorer";
    }
}

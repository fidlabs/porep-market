// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, no-empty-blocks, gas-small-strings, gas-calldata-parameters
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {ConfigurePaymentTokens} from "../../script/ConfigurePaymentTokens.s.sol";
import {Upgrade} from "../../script/Upgrade.s.sol";
import {DeployUtils} from "../../script/utils/DeployUtils.sol";
import {ValidatorFactory} from "../../src/ValidatorFactory.sol";
import {PoRepMarket} from "../../src/PoRepMarket.sol";
import {DataCapEvidenceAdapter} from "../../src/DataCapEvidenceAdapter.sol";
import {SectorEvidenceAdapter} from "../../src/SectorEvidenceAdapter.sol";
import {SPRegistry} from "../../src/SPRegistry.sol";
import {ISPRegistry} from "../../src/interfaces/ISPRegistry.sol";

interface IAccessProbe {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

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

contract DeploymentScriptsTest is Test {
    using stdJson for string;
    bytes32 private constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        vm.createDir(string.concat(vm.projectRoot(), "/.deployment"), true);
        vm.setEnv("PRIVATE_KEY", "1");
    }

    function testDeploymentScripts() public {
        _assertOrderedBatchUpgrade();
        _assertLiveDeploymentTopology();
        _assertUnsupportedTargetRejected();
        _assertStaleProxyRejected();
        _assertStaleValidatorBeaconRejected();
        _assertStaleValidatorImplementationRejected();
    }

    function _assertOrderedBatchUpgrade() private {
        string[] memory names = _allTargets();
        (string memory manifest, address[] memory destinations) = _manifestFor(names);
        string memory outputPath = _configure(manifest, names);
        new Upgrade().run();
        string memory json = vm.readFile(outputPath);
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

    // solhint-disable-next-line function-max-lines
    function _assertLiveDeploymentTopology() private {
        address admin = vm.addr(1);
        address service = address(0x101);
        address oracle = address(0x102);
        address termination = address(0x103);
        _env("PRIVATE_KEY", "1");
        _env("DEPLOYMENT_OUTPUT", "./.deployment/deploy-run.json");
        _env("BUILD_INFO_SHA256", "build");
        _envAddress("FILECOIN_PAY", address(0x100));
        _envAddress("POREP_SERVICE", service);
        _envAddress("ORACLE", oracle);
        _envAddress("TERMINATION_ORACLE", termination);
        _envAddress("META_ALLOCATOR", address(0x104));
        _envAddress("OPERATOR_ADDR", address(0));
        _envAddress("USDFC", address(0x105));
        _envAddress("AXL_USDC", address(0x106));
        if (vm.exists("./.deployment/deploy-run.json")) vm.removeFile("./.deployment/deploy-run.json");
        vm.writeFile("./.deployment/deploy-run.json", "{\"result\":{}}");

        new Deploy().run();
        string memory json = vm.readFile("./.deployment/deploy-run.json");
        string[7] memory names = [
            "PoRepMarket",
            "ValidatorFactory",
            "DataCapEvidenceAdapter",
            "SectorEvidenceAdapter",
            "SPRegistry",
            "SLIOracle",
            "SLIScorer"
        ];
        for (uint256 i; i < names.length; ++i) {
            address proxy = json.readAddress(string.concat(".result.contracts.", names[i], ".proxy"));
            address implementation = json.readAddress(string.concat(".result.contracts.", names[i], ".implementation"));
            assertTrue(proxy.code.length > 0 && implementation.code.length > 0);
            assertEq(address(uint160(uint256(vm.load(proxy, SLOT)))), implementation);
            assertTrue(IAccessProbe(proxy).hasRole(0, admin));
        }
        address factory = json.readAddress(".result.contracts.ValidatorFactory.proxy");
        address beacon = json.readAddress(".result.contracts.ValidatorBeacon.address");
        address validator = json.readAddress(".result.contracts.Validator.implementation");
        address market = json.readAddress(".result.contracts.PoRepMarket.proxy");
        address registry = json.readAddress(".result.contracts.SPRegistry.proxy");
        address adapter = json.readAddress(".result.contracts.DataCapEvidenceAdapter.proxy");
        address sectorAdapter = json.readAddress(".result.contracts.SectorEvidenceAdapter.proxy");
        assertEq(UpgradeableBeacon(beacon).implementation(), validator);
        assertEq(UpgradeableBeacon(beacon).owner(), admin);
        assertEq(ValidatorFactory(factory).getBeacon(), beacon);
        assertEq(PoRepMarket(market).getValidatorFactoryContract(), factory);
        assertEq(PoRepMarket(market).getSPRegistryContract(), registry);
        assertEq(DataCapEvidenceAdapter(adapter).getPoRepMarketAddress(), market);
        assertTrue(DataCapEvidenceAdapter(adapter).isOperational());
        assertEq(SectorEvidenceAdapter(sectorAdapter).getPoRepMarketAddress(), market);
        assertTrue(IAccessProbe(market).hasRole(PoRepMarket(market).POREP_SERVICE_ROLE(), service));
        assertTrue(IAccessProbe(registry).hasRole(SPRegistry(registry).MARKET_ROLE(), market));
        _assertPaymentTokens(registry, admin, json);
        assertTrue(
            IAccessProbe(json.readAddress(".result.contracts.SLIOracle.proxy"))
                .hasRole(keccak256("ORACLE_ROLE"), oracle)
        );
        assertTrue(IAccessProbe(adapter).hasRole(keccak256("TERMINATION_ORACLE"), termination));
    }

    function _assertPaymentTokens(address registry, address admin, string memory json) private {
        address usdfc = address(0x105);
        address axlUsdc = address(0x106);
        assertEq(json.readAddress(".result.externalDependencies.USDFC"), usdfc);
        assertEq(json.readAddress(".result.externalDependencies.AxlUSDC"), axlUsdc);

        ISPRegistry.TokenConfig memory config = SPRegistry(registry).getPaymentTokenConfig(usdfc);
        assertTrue(config.allowed);
        assertEq(config.minPricePer32GiBPerMonth, 1);

        vm.prank(admin);
        SPRegistry(registry).setPaymentToken(usdfc, true, 2);
        _envAddress("SP_REGISTRY", registry);
        new ConfigurePaymentTokens().run();
        new ConfigurePaymentTokens().run();

        config = SPRegistry(registry).getPaymentTokenConfig(usdfc);
        assertTrue(config.allowed);
        assertEq(config.minPricePer32GiBPerMonth, 1);
        config = SPRegistry(registry).getPaymentTokenConfig(axlUsdc);
        assertTrue(config.allowed);
        assertEq(config.minPricePer32GiBPerMonth, 1);
    }

    function _assertUnsupportedTargetRejected() private {
        string[] memory names = new string[](1);
        names[0] = "Unknown";
        _configure("{}", names);
        Upgrade script = new Upgrade();
        vm.expectRevert(abi.encodeWithSelector(DeployUtils.InvalidUpgradeTarget.selector, "Unknown"));
        script.run();
    }

    function _assertStaleProxyRejected() private {
        string[] memory names = new string[](1);
        names[0] = "PoRepMarket";
        address live = address(new LegacyUups());
        address proxy = address(new ERC1967Proxy(live, ""));
        address stale = address(new LegacyUups());
        _configure(string.concat("{\"contracts\":{\"PoRepMarket\":", _contract(proxy, stale), "}}"), names);
        Upgrade script = new Upgrade();
        vm.expectPartialRevert(DeployUtils.StaleManifestImplementation.selector);
        script.run();
    }

    function _assertStaleValidatorBeaconRejected() private {
        string[] memory names = new string[](1);
        names[0] = "Validator";
        address previous = address(new LegacyValidator());
        UpgradeableBeacon beacon = new UpgradeableBeacon(previous, vm.addr(1));
        address factory =
            address(new ERC1967Proxy(address(new LegacyValidatorFactory(address(new LegacyValidator()))), ""));
        string memory manifest = _validatorManifest(address(beacon), factory, previous);
        _configure(manifest, names);
        Upgrade script = new Upgrade();
        vm.expectPartialRevert(Upgrade.StaleValidatorBeacon.selector);
        script.run();
    }

    function _assertStaleValidatorImplementationRejected() private {
        string[] memory names = new string[](1);
        names[0] = "Validator";
        address live = address(new LegacyValidator());
        UpgradeableBeacon beacon = new UpgradeableBeacon(live, vm.addr(1));
        address factory = address(new ERC1967Proxy(address(new LegacyValidatorFactory(address(beacon))), ""));
        _configure(_validatorManifest(address(beacon), factory, address(new LegacyValidator())), names);
        Upgrade script = new Upgrade();
        vm.expectPartialRevert(Upgrade.StaleValidatorImpl.selector);
        script.run();
    }

    function _configure(string memory manifest, string[] memory names) private returns (string memory outputPath) {
        string memory suffix = vm.toString(uint256(keccak256(abi.encode(manifest))));
        string memory manifestPath =
            string.concat(vm.projectRoot(), "/.deployment/upgrade-test-manifest-", suffix, ".json");
        outputPath = string.concat(vm.projectRoot(), "/.deployment/upgrade-test-output-", suffix, ".json");
        vm.setEnv("DEPLOYMENT_MANIFEST", manifestPath);
        vm.setEnv("UPGRADE_OUTPUT", outputPath);
        if (vm.exists(manifestPath)) vm.removeFile(manifestPath);
        if (vm.exists(outputPath)) vm.removeFile(outputPath);
        vm.writeFile(manifestPath, manifest);
        vm.writeFile(outputPath, "{\"operations\":[]}");
        string memory csv;
        for (uint256 i; i < names.length; ++i) {
            if (i != 0) csv = string.concat(csv, ",");
            csv = string.concat(csv, names[i]);
        }
        vm.setEnv("UPGRADE_CONTRACT_NAMES", csv);
    }

    function _allTargets() private pure returns (string[] memory names) {
        names = new string[](8);
        names[0] = "PoRepMarket";
        names[1] = "ValidatorFactory";
        names[2] = "DataCapEvidenceAdapter";
        names[3] = "SectorEvidenceAdapter";
        names[4] = "SPRegistry";
        names[5] = "SLIOracle";
        names[6] = "SLIScorer";
        names[7] = "Validator";
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

    function _contract(address proxy, address implementation) private pure returns (string memory json) {
        json = string.concat(
            "{\"proxy\":\"", vm.toString(proxy), "\",\"implementation\":\"", vm.toString(implementation), "\"}"
        );
    }

    function _validatorManifest(address beacon, address factory, address implementation)
        private
        pure
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
        if (target == keccak256("SectorEvidenceAdapter")) {
            return "src/SectorEvidenceAdapter.sol:SectorEvidenceAdapter";
        }
        if (target == keccak256("SPRegistry")) return "src/SPRegistry.sol:SPRegistry";
        if (target == keccak256("SLIOracle")) return "src/SLIOracle.sol:SLIOracle";
        if (target == keccak256("Validator")) return "src/Validator.sol:Validator";
        return "src/SLIScorer.sol:SLIScorer";
    }

    function _env(string memory key, string memory value) private {
        vm.setEnv(key, value);
    }

    function _envAddress(string memory key, address value) private {
        vm.setEnv(key, vm.toString(value));
    }
}

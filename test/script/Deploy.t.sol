// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, gas-small-strings
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ValidatorFactory} from "../../src/ValidatorFactory.sol";
import {PoRepMarket} from "../../src/PoRepMarket.sol";
import {DataCapEvidenceAdapter} from "../../src/DataCapEvidenceAdapter.sol";
import {SPRegistry} from "../../src/SPRegistry.sol";

interface IAccessProbe {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract DeployTest is Test {
    using stdJson for string;
    bytes32 private constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function testRunDeploysAndLinksLiveTopology() public {
        address admin = vm.addr(1);
        address service = address(0x101);
        address oracle = address(0x102);
        address termination = address(0x103);
        _env("PRIVATE_KEY", "1");
        _env("DEPLOYMENT_OUTPUT", "./.deployment/deploy-run.json");
        _env("GIT_COMMIT", "commit");
        _env("BUILD_INFO_SHA256", "build");
        _envAddress("FILECOIN_PAY", address(0x100));
        _envAddress("POREP_SERVICE", service);
        _envAddress("ORACLE", oracle);
        _envAddress("TERMINATION_ORACLE", termination);
        _envAddress("META_ALLOCATOR", address(0x104));
        _envAddress("OPERATOR_ADDR", address(0));
        vm.createDir("./.deployment", true);
        if (vm.exists("./.deployment/deploy-run.json")) vm.removeFile("./.deployment/deploy-run.json");
        vm.writeFile("./.deployment/deploy-run.json", "{\"result\":{}}");

        new Deploy().run();
        string memory json = vm.readFile("./.deployment/deploy-run.json");
        string[6] memory names =
            ["PoRepMarket", "ValidatorFactory", "DataCapEvidenceAdapter", "SPRegistry", "SLIOracle", "SLIScorer"];
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
        assertEq(UpgradeableBeacon(beacon).implementation(), validator);
        assertEq(UpgradeableBeacon(beacon).owner(), admin);
        assertEq(ValidatorFactory(factory).getBeacon(), beacon);
        assertEq(PoRepMarket(market).getValidatorFactoryContract(), factory);
        assertEq(PoRepMarket(market).getSPRegistryContract(), registry);
        assertEq(DataCapEvidenceAdapter(adapter).getPoRepMarketAddress(), market);
        assertTrue(DataCapEvidenceAdapter(adapter).isOperational());
        assertTrue(IAccessProbe(market).hasRole(PoRepMarket(market).POREP_SERVICE_ROLE(), service));
        assertTrue(IAccessProbe(registry).hasRole(SPRegistry(registry).MARKET_ROLE(), market));
        assertTrue(
            IAccessProbe(json.readAddress(".result.contracts.SLIOracle.proxy"))
                .hasRole(keccak256("ORACLE_ROLE"), oracle)
        );
        assertTrue(IAccessProbe(adapter).hasRole(keccak256("TERMINATION_ORACLE"), termination));
    }

    function _env(string memory key, string memory value) private {
        vm.setEnv(key, value);
    }

    function _envAddress(string memory key, address value) private {
        vm.setEnv(key, vm.toString(value));
    }
}

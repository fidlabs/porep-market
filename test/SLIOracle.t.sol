// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Test} from "lib/forge-std/src/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {AccessManager} from "../src/AccessManager.sol";
import {AccessControlledUpgradeable} from "../src/abstracts/AccessControlledUpgradeable.sol";

contract SLIOracleTest is Test {
    SLIOracle public sliOracle;
    AccessManager public accessManager;
    address public oracle = address(0x123);
    uint256 public dealId = 1;
    SharedTypes.SLIThresholds public slis = SharedTypes.SLIThresholds({
        retrievabilityBps: 8000, bandwidthBytesPerSecond: 500, latencyMs: 200, indexingPct: 90
    });

    function setUp() public {
        SLIOracle impl = new SLIOracle();
        accessManager = new AccessManager(address(this), address(this));
        accessManager.grantRole(accessManager.ORACLE_ROLE(), oracle);
        bytes memory initData = abi.encodeCall(SLIOracle.initialize, (address(accessManager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        sliOracle = SLIOracle(address(proxy));
    }

    function testIsAdminSet() public view {
        bytes32 adminRole = accessManager.DEFAULT_ADMIN_ROLE();
        assertTrue(accessManager.hasRole(adminRole, address(this)));
    }

    function testAuthorizeUpgradeRevert() public {
        address newImpl = address(new SLIOracle());
        address unauthorized = vm.addr(1);
        bytes32 upgraderRole = accessManager.UPGRADER_ROLE();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, upgraderRole)
        );
        sliOracle.upgradeToAndCall(newImpl, "");
    }

    function testIsOracleRoleSet() public view {
        bytes32 oracleRole = accessManager.ORACLE_ROLE();
        assertTrue(accessManager.hasRole(oracleRole, oracle));
    }

    function testSLIAttestationEvent() public {
        vm.expectEmit(true, true, false, false);
        emit SLIOracle.SLIAttestationUpdate(dealId, block.number, slis);
        vm.prank(oracle);
        sliOracle.setSLI(dealId, slis);
    }

    function testSetSLIAttestation() public {
        vm.prank(oracle);
        sliOracle.setSLI(dealId, slis);

        SharedTypes.Attestation memory storedAttestation = sliOracle.getAttestation(dealId);
        assertEq(storedAttestation.lastUpdate, block.number);
        assertEq(storedAttestation.slis.retrievabilityBps, slis.retrievabilityBps);
        assertEq(storedAttestation.slis.latencyMs, slis.latencyMs);
        assertEq(storedAttestation.slis.indexingPct, slis.indexingPct);
        assertEq(storedAttestation.slis.bandwidthBytesPerSecond, slis.bandwidthBytesPerSecond);
    }

    function testInitializeRevertInvalidManager() public {
        SLIOracle impl = new SLIOracle();
        bytes memory initData = abi.encodeCall(SLIOracle.initialize, (address(0)));
        vm.expectRevert(abi.encodeWithSelector(AccessControlledUpgradeable.InvalidAccessManager.selector, address(0)));
        new ERC1967Proxy(address(impl), initData);
    }

    function testSetSLIRevertsInvalidRetrievabilityBps() public {
        SharedTypes.SLIThresholds memory invalidSlis = SharedTypes.SLIThresholds({
            retrievabilityBps: 10_001, bandwidthBytesPerSecond: 500, latencyMs: 200, indexingPct: 90
        });

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(SLIOracle.InvalidRetrievabilityBps.selector, uint16(10_001)));
        sliOracle.setSLI(dealId, invalidSlis);
    }

    function testSetSLIAcceptsMaxRetrievabilityBps() public {
        SharedTypes.SLIThresholds memory maxSlis = SharedTypes.SLIThresholds({
            retrievabilityBps: 10_000, bandwidthBytesPerSecond: 500, latencyMs: 200, indexingPct: 90
        });

        vm.prank(oracle);
        sliOracle.setSLI(dealId, maxSlis);

        SharedTypes.Attestation memory stored = sliOracle.getAttestation(dealId);
        assertEq(stored.slis.retrievabilityBps, 10_000);
    }

    function testSetSLIRevertsInvalidIndexingPct() public {
        SharedTypes.SLIThresholds memory invalidSlis = SharedTypes.SLIThresholds({
            retrievabilityBps: 8000, bandwidthBytesPerSecond: 500, latencyMs: 200, indexingPct: 101
        });

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(SLIOracle.InvalidIndexingPct.selector, uint8(101)));
        sliOracle.setSLI(dealId, invalidSlis);
    }

    function testSetSLIAcceptsMaxIndexingPct() public {
        SharedTypes.SLIThresholds memory maxSlis = SharedTypes.SLIThresholds({
            retrievabilityBps: 8000, bandwidthBytesPerSecond: 500, latencyMs: 200, indexingPct: 100
        });

        vm.prank(oracle);
        sliOracle.setSLI(dealId, maxSlis);

        SharedTypes.Attestation memory stored = sliOracle.getAttestation(dealId);
        assertEq(stored.slis.indexingPct, 100);
    }

    function testSetSLIRevertsInvalidDealId() public {
        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(SLIOracle.InvalidDealId.selector));
        sliOracle.setSLI(0, slis);
    }

    function testGetAttestationRevertsInvalidDealId() public {
        vm.expectRevert(abi.encodeWithSelector(SLIOracle.InvalidDealId.selector));
        sliOracle.getAttestation(0);
    }

    function testSetSLIRevertsUnsetLatencyMs() public {
        SharedTypes.SLIThresholds memory invalidSlis = SharedTypes.SLIThresholds({
            retrievabilityBps: 8000, bandwidthBytesPerSecond: 500, latencyMs: 0, indexingPct: 90
        });

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(SLIOracle.InvalidLatencyMs.selector, uint16(0)));
        sliOracle.setSLI(dealId, invalidSlis);
    }

    function testSetSLIRevertsUnmeasuredLatencySentinel() public {
        SharedTypes.SLIThresholds memory invalidSlis = SharedTypes.SLIThresholds({
            retrievabilityBps: 8000,
            bandwidthBytesPerSecond: 500,
            latencyMs: SharedTypes.LATENCY_UNMEASURED,
            indexingPct: 90
        });

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(SLIOracle.InvalidLatencyMs.selector, SharedTypes.LATENCY_UNMEASURED));
        sliOracle.setSLI(dealId, invalidSlis);
    }

    function testSetSLIAcceptsHighestValidLatencyMs() public {
        uint16 highestValidLatencyMs = SharedTypes.LATENCY_UNMEASURED - 1;
        SharedTypes.SLIThresholds memory maxSlis = SharedTypes.SLIThresholds({
            retrievabilityBps: 8000, bandwidthBytesPerSecond: 500, latencyMs: highestValidLatencyMs, indexingPct: 90
        });

        vm.prank(oracle);
        sliOracle.setSLI(dealId, maxSlis);

        SharedTypes.Attestation memory stored = sliOracle.getAttestation(dealId);
        assertEq(stored.slis.latencyMs, highestValidLatencyMs);
    }
}

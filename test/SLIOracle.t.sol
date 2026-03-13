// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.25;

import {Test} from "lib/forge-std/src/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SLITypes} from "../src/types/SLITypes.sol";

contract SLIOracleTest is Test {
    SLIOracle public sliOracle;
    address public oracle = address(0x123);
    CommonTypes.FilActorId public provider = CommonTypes.FilActorId.wrap(1000);
    SLITypes.SLIThresholds public slis =
        SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90});

    function setUp() public {
        SLIOracle impl = new SLIOracle();
        bytes memory initData = abi.encodeCall(SLIOracle.initialize, (address(this), oracle));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        sliOracle = SLIOracle(address(proxy));
    }

    function testIsAdminSet() public view {
        bytes32 adminRole = sliOracle.DEFAULT_ADMIN_ROLE();
        assertTrue(sliOracle.hasRole(adminRole, address(this)));
    }

    function testAuthorizeUpgradeRevert() public {
        address newImpl = address(new SLIOracle());
        address unauthorized = vm.addr(1);
        bytes32 upgraderRole = sliOracle.UPGRADER_ROLE();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, upgraderRole)
        );
        sliOracle.upgradeToAndCall(newImpl, "");
    }

    function testIsOracleRoleSet() public view {
        bytes32 oracleRole = sliOracle.ORACLE_ROLE();
        assertTrue(sliOracle.hasRole(oracleRole, oracle));
    }

    function testSLIAttestationEvent() public {
        vm.expectEmit(true, true, false, false);
        emit SLIOracle.SLIAttestationUpdate(provider, block.number, slis);
        vm.prank(oracle);
        sliOracle.setSLI(provider, slis);
    }

    function testSetSLIAttestation() public {
        vm.prank(oracle);
        sliOracle.setSLI(provider, slis);

        SLITypes.Attestation memory storedAttestation = sliOracle.getAttestation(provider);
        assertEq(storedAttestation.lastUpdate, block.number);
        assertEq(storedAttestation.slis.retrievabilityBps, slis.retrievabilityBps);
        assertEq(storedAttestation.slis.latencyMs, slis.latencyMs);
        assertEq(storedAttestation.slis.indexingPct, slis.indexingPct);
        assertEq(storedAttestation.slis.bandwidthMbps, slis.bandwidthMbps);
    }

    function testInitializeRevertInvalidAdmin() public {
        SLIOracle impl = new SLIOracle();
        bytes memory initData = abi.encodeCall(SLIOracle.initialize, (address(0), oracle));
        vm.expectRevert(abi.encodeWithSelector(SLIOracle.InvalidAdmin.selector));
        new ERC1967Proxy(address(impl), initData);
    }

    function testInitializeRevertInvalidOracle() public {
        SLIOracle impl = new SLIOracle();
        bytes memory initData = abi.encodeCall(SLIOracle.initialize, (address(this), address(0)));
        vm.expectRevert(abi.encodeWithSelector(SLIOracle.InvalidOracle.selector));
        new ERC1967Proxy(address(impl), initData);
    }
}

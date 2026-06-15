// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Test} from "lib/forge-std/src/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SLIScorer} from "../src/SLIScorer.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {SLIOracle} from "../src/SLIOracle.sol";
import {MockSLIOracle} from "./contracts/MockSLIOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract SLIScorerTest is Test {
    SLIScorer public sliScorer;
    address public client = vm.addr(1);
    uint256 public dealId;
    SharedTypes.SLIThresholds public sliParams;
    MockSLIOracle public oracle;

    function setUp() public {
        SLIScorer impl = new SLIScorer();
        oracle = new MockSLIOracle();
        bytes memory initData = abi.encodeCall(SLIScorer.initialize, (address(this), SLIOracle(address(oracle))));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        sliScorer = SLIScorer(address(proxy));
        dealId = 1;
        sliParams = SharedTypes.SLIThresholds({
            retrievabilityBps: 9900, bandwidthBytesPerSecond: 99, latencyMs: 99, indexingPct: 99
        });
    }

    function testIsAdminSet() public view {
        bytes32 adminRole = sliScorer.DEFAULT_ADMIN_ROLE();
        assertTrue(sliScorer.hasRole(adminRole, address(this)));
    }

    function testAuthorizeUpgradeRevert() public {
        address newImpl = address(new SLIScorer());
        address unauthorized = vm.addr(2);
        bytes32 upgraderRole = sliScorer.UPGRADER_ROLE();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, upgraderRole)
        );
        sliScorer.upgradeToAndCall(newImpl, "");
    }

    function testCalculateScoreRevertNoAttestation() public {
        vm.expectRevert(abi.encodeWithSelector(SLIScorer.NoAttestation.selector, dealId));
        sliScorer.calculateScore(dealId, sliParams);
    }

    function testCalculateScoreForNoSLAsDefined() public {
        vm.prank(client);
        oracle.setAttestations(block.timestamp, 0, 0, 0, 0);
        sliParams =
            SharedTypes.SLIThresholds({retrievabilityBps: 0, bandwidthBytesPerSecond: 0, latencyMs: 0, indexingPct: 0});
        uint256 score = sliScorer.calculateScore(dealId, sliParams);
        assertEq(score, 100);
    }

    function testCalculateScoreIsNonZeroForSLI() public {
        vm.prank(client);
        oracle.setAttestations(1000, 10000, 100, 100, 80);
        vm.roll(1001);
        uint256 score = sliScorer.calculateScore(dealId, sliParams);
        assertEq(score, 50);
    }

    function testCalculateScore() public {
        vm.prank(client);
        oracle.setAttestations(1000, 10000, 100, 95, 100);
        vm.roll(1001);
        uint256 score = sliScorer.calculateScore(dealId, sliParams);
        assertEq(score, 100);
    }

    function testCalculateScoreForLatency() public {
        sliParams = SharedTypes.SLIThresholds({
            retrievabilityBps: 0, bandwidthBytesPerSecond: 0, latencyMs: 40, indexingPct: 0
        });
        oracle.setAttestations(1000, 0, 0, 40, 0);
        vm.roll(1001);
        uint256 score = sliScorer.calculateScore(dealId, sliParams);
        assertEq(score, 100);
    }

    function testCalculateRevertAttestationExpired() public {
        oracle.setAttestations(1000, 0, 0, 40, 0);
        vm.roll(1000000);
        vm.expectRevert(abi.encodeWithSelector(SLIScorer.AttestationExpired.selector, dealId));
        sliScorer.calculateScore(dealId, sliParams);
    }

    function testInitializeRevertInvalidAdmin() public {
        SLIScorer impl = new SLIScorer();
        bytes memory initData = abi.encodeCall(SLIScorer.initialize, (address(0), SLIOracle(address(oracle))));
        vm.expectRevert(abi.encodeWithSelector(SLIScorer.InvalidAdmin.selector));
        new ERC1967Proxy(address(impl), initData);
    }

    function testInitializeRevertInvalidOracle() public {
        SLIScorer impl = new SLIScorer();
        bytes memory initData = abi.encodeCall(SLIScorer.initialize, (address(this), SLIOracle(address(0))));
        vm.expectRevert(abi.encodeWithSelector(SLIScorer.InvalidOracle.selector));
        new ERC1967Proxy(address(impl), initData);
    }

    function testCalculateScoreRevertsInvalidDealId() public {
        vm.expectRevert(abi.encodeWithSelector(SLIScorer.InvalidDealId.selector));
        sliScorer.calculateScore(0, sliParams);
    }
}

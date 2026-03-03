// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {SPRegistry} from "../src/SPRegistry.sol";
import {ISPRegistry} from "../src/interfaces/ISPRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SLITypes} from "../src/types/SLITypes.sol";

// solhint-disable-next-line max-states-count
contract SPRegistryTest is Test {
    SPRegistry public spRegistry;
    address public adminAddress;
    address public poRepMarketAddress;
    address public owner1;
    address public owner2;
    address public unauthorizedAddress;

    CommonTypes.FilActorId public provider1;
    CommonTypes.FilActorId public provider2;
    CommonTypes.FilActorId public provider3;

    SLITypes.SLIThresholds internal defaultCapabilities =
        SLITypes.SLIThresholds({retrievabilityPct: 95, bandwidthMbps: 1000, latencyMs: 100, indexingPct: 90});

    SLITypes.DealTerms internal defaultTerms = SLITypes.DealTerms({dealSizeBytes: 1_000_000, priceForDeal: 100, durationDays: 365});

    uint256 internal defaultAvailableBytes = 10_000_000;

    function setUp() public {
        SPRegistry impl = new SPRegistry();
        adminAddress = vm.addr(0x001);
        poRepMarketAddress = vm.addr(0x002);
        owner1 = vm.addr(0x003);
        owner2 = vm.addr(0x004);
        unauthorizedAddress = vm.addr(0x005);

        provider1 = CommonTypes.FilActorId.wrap(1000);
        provider2 = CommonTypes.FilActorId.wrap(2000);
        provider3 = CommonTypes.FilActorId.wrap(3000);

        bytes memory initData = abi.encodeCall(SPRegistry.initialize, (adminAddress, poRepMarketAddress));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        spRegistry = SPRegistry(address(proxy));
    }

    function testInitializeSetsAdminRole() public view {
        assertTrue(spRegistry.hasRole(spRegistry.DEFAULT_ADMIN_ROLE(), adminAddress));
    }

    function testInitializeSetsUpgraderRole() public view {
        assertTrue(spRegistry.hasRole(spRegistry.UPGRADER_ROLE(), adminAddress));
    }

    function testInitializeSetsMarketRole() public view {
        assertTrue(spRegistry.hasRole(spRegistry.MARKET_ROLE(), poRepMarketAddress));
    }

    function testInitializeRevertsForZeroAdmin() public {
        SPRegistry impl = new SPRegistry();
        bytes memory initData = abi.encodeCall(SPRegistry.initialize, (address(0), poRepMarketAddress));
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidAdminAddress.selector));
        new ERC1967Proxy(address(impl), initData);
    }

    function testInitializeRevertsForZeroPoRepMarket() public {
        SPRegistry impl = new SPRegistry();
        bytes memory initData = abi.encodeCall(SPRegistry.initialize, (adminAddress, address(0)));
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidPoRepMarketAddress.selector));
        new ERC1967Proxy(address(impl), initData);
    }

    function testAuthorizeUpgradeRevertsForNonUpgrader() public {
        address newImpl = address(new SPRegistry());
        bytes32 upgraderRole = spRegistry.UPGRADER_ROLE();
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedAddress, upgraderRole
            )
        );
        spRegistry.upgradeToAndCall(newImpl, "");
    }

    function testStubFunctionsRevertNotImplemented() public {
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotImplemented.selector));
        spRegistry.addOwner(owner1);
    }

    function testRemoveOwnerRevertsNotImplemented() public {
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotImplemented.selector));
        spRegistry.removeOwner(owner1);
    }

    function testRegisterProviderRevertsNotImplemented() public {
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotImplemented.selector));
        spRegistry.registerProvider(provider1);
    }

    function testPauseProviderRevertsNotImplemented() public {
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotImplemented.selector));
        spRegistry.pauseProvider(provider1);
    }

    function testUnpauseProviderRevertsNotImplemented() public {
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotImplemented.selector));
        spRegistry.unpauseProvider(provider1);
    }

    function testSetDefaultPriceRevertsNotImplemented() public {
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotImplemented.selector));
        spRegistry.setDefaultPrice(provider1, 100);
    }

    function testRegisterProviderForRevertsForActorIdZero() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidProviderActorId.selector));
        spRegistry.registerProviderFor(
            CommonTypes.FilActorId.wrap(0), owner1, defaultCapabilities, defaultAvailableBytes, 0
        );
    }

    function testRegisterProviderForRevertsForZeroOwner() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidOwnerAddress.selector));
        spRegistry.registerProviderFor(provider1, address(0), defaultCapabilities, defaultAvailableBytes, 0);
    }

    function testIsProviderRegisteredReturnsFalseForUnregistered() public view {
        assertFalse(spRegistry.isProviderRegistered(provider1));
    }

    function testRegisterProviderForEmitsEvents() public {
        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, false);
        emit SPRegistry.OwnerAdded(owner1);
        vm.expectEmit(true, true, false, false);
        emit SPRegistry.ProviderRegistered(provider1, owner1);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.CapabilitiesUpdated(provider1, defaultCapabilities);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
    }

    function testRegisterProviderForSetsAllFields() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        assertTrue(spRegistry.isProviderRegistered(provider1));
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.owner, owner1);
        assertFalse(info.paused);
        assertEq(info.availableBytes, defaultAvailableBytes);
        assertEq(info.capabilities.retrievabilityPct, defaultCapabilities.retrievabilityPct);
    }

    function testRegisterProviderForRevertsIfAlreadyRegistered() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderAlreadyRegistered.selector, provider1));
        spRegistry.registerProviderFor(provider1, owner2, defaultCapabilities, defaultAvailableBytes, 0);
        vm.stopPrank();
    }

    function testRegisterProviderForRevertsForNonAdmin() public {
        bytes32 adminRole = spRegistry.DEFAULT_ADMIN_ROLE();
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedAddress, adminRole
            )
        );
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
    }

    function testRegisterProviderForSetsDefaultPrice() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 250);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.defaultPricePerDeal, 250);
    }

    function testRegisterProviderForEmitsDefaultPriceEvent() public {
        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.DefaultPriceUpdated(provider1, 0, 250);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 250);
    }

    function testRegisterProviderForZeroPriceEmitsDefaultPriceEvent() public {
        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.DefaultPriceUpdated(provider1, 0, 0);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
    }

    function testUpdateAvailableSpaceEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.prank(owner1);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.AvailableSpaceUpdated(provider1, 5_000_000);
        spRegistry.updateAvailableSpace(provider1, 5_000_000);
    }

    function testUpdateAvailableSpaceSetsValue() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.prank(owner1);
        spRegistry.updateAvailableSpace(provider1, 5_000_000);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.availableBytes, 5_000_000);
    }

    function testSetCapabilitiesEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.prank(owner1);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.CapabilitiesUpdated(provider1, defaultCapabilities);
        spRegistry.setCapabilities(provider1, defaultCapabilities);
    }

    function testSetCapabilitiesSetsValues() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.prank(owner1);
        spRegistry.setCapabilities(provider1, defaultCapabilities);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.capabilities.retrievabilityPct, 95);
        assertEq(info.capabilities.bandwidthMbps, 1000);
        assertEq(info.capabilities.latencyMs, 100);
        assertEq(info.capabilities.indexingPct, 90);
    }

    function testSetCapabilitiesRevertsInvalidRetrievabilityPct() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        SLITypes.SLIThresholds memory bad =
            SLITypes.SLIThresholds({retrievabilityPct: 101, bandwidthMbps: 100, latencyMs: 100, indexingPct: 50});
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidRetrievabilityPct.selector, uint8(101)));
        spRegistry.setCapabilities(provider1, bad);
    }

    function testSetCapabilitiesRevertsInvalidIndexingPct() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        SLITypes.SLIThresholds memory bad =
            SLITypes.SLIThresholds({retrievabilityPct: 50, bandwidthMbps: 100, latencyMs: 100, indexingPct: 101});
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidIndexingPct.selector, uint8(101)));
        spRegistry.setCapabilities(provider1, bad);
    }

    function testSetCapabilitiesAdminCanSet() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        SLITypes.SLIThresholds memory newCaps =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(adminAddress);
        spRegistry.setCapabilities(provider1, newCaps);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.capabilities.retrievabilityPct, 80);
    }

    function testSetCapabilitiesRevertsForNonOwnerNonAdmin() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.NotProviderOwnerOrAdmin.selector, unauthorizedAddress, provider1)
        );
        spRegistry.setCapabilities(provider1, defaultCapabilities);
    }

    function testUpdateAvailableSpaceAdminCanSet() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.prank(adminAddress);
        spRegistry.updateAvailableSpace(provider1, 5_000_000);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.availableBytes, 5_000_000);
    }

    function testUpdateAvailableSpaceRevertsForNonOwnerNonAdmin() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.NotProviderOwnerOrAdmin.selector, unauthorizedAddress, provider1)
        );
        spRegistry.updateAvailableSpace(provider1, 5_000_000);
    }

    function testIsStorageProviderOwnerReturnsTrue() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        assertTrue(spRegistry.isStorageProviderOwner(owner1, provider1));
    }

    function testIsStorageProviderOwnerReturnsFalseForNonOwner() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        assertFalse(spRegistry.isStorageProviderOwner(owner2, provider1));
    }

    function testIsStorageProviderOwnerReturnsFalseForUnregistered() public view {
        assertFalse(spRegistry.isStorageProviderOwner(owner1, provider1));
    }

    function testGetProviderInfoDefaultPriceIsZeroByDefault() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.defaultPricePerDeal, 0);
    }

    function testGetProviderForDealAutoApproveTrueWhenPriceMatches() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (, bool autoApprove) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertTrue(autoApprove);
    }

    function testGetProviderForDealAutoApproveTrueWhenPriceExceeds() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 50);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (, bool autoApprove) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertTrue(autoApprove);
    }

    function testGetProviderForDealAutoApproveFalseWhenPriceBelowDefault() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 200);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (, bool autoApprove) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertFalse(autoApprove);
    }

    function testGetProviderForDealAutoApproveFalseWhenPriceNotSet() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (, bool autoApprove) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertFalse(autoApprove);
    }

    function testGetProviderForDealAutoApproveFalseWhenNoProviderMatches() public {
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result, bool autoApprove) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
        assertFalse(autoApprove);
    }

    function testGetProvidersReturnsEmpty() public view {
        CommonTypes.FilActorId[] memory providers = spRegistry.getProviders();
        assertEq(providers.length, 0);
    }

    function testGetProvidersReturnsRegistered() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        spRegistry.registerProviderFor(provider2, owner2, defaultCapabilities, defaultAvailableBytes, 0);
        vm.stopPrank();

        CommonTypes.FilActorId[] memory providers = spRegistry.getProviders();
        assertEq(providers.length, 2);
    }

    function testGetCommittedProvidersReturnsEmpty() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        CommonTypes.FilActorId[] memory committed = spRegistry.getCommittedProviders();
        assertEq(committed.length, 0);
    }

    function testGetCommittedProvidersReturnsOnlyCommitted() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        spRegistry.registerProviderFor(provider2, owner2, defaultCapabilities, defaultAvailableBytes, 0);
        vm.stopPrank();

        // Commit capacity for provider1 only
        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 1000);

        CommonTypes.FilActorId[] memory committed = spRegistry.getCommittedProviders();
        assertEq(committed.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(committed[0]), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderInfoReturnsZeroedForUnregistered() public view {
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.owner, address(0));
        assertEq(info.availableBytes, 0);
    }

    function testGetProviderInfoReturnsFullData() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.owner, owner1);
        assertFalse(info.paused);
        assertEq(info.capabilities.retrievabilityPct, 95);
        assertEq(info.capabilities.bandwidthMbps, 1000);
        assertEq(info.capabilities.latencyMs, 100);
        assertEq(info.capabilities.indexingPct, 90);
        assertEq(info.availableBytes, defaultAvailableBytes);
        assertEq(info.committedBytes, 0);
    }

    function testGetProviderForDealReturnsZeroWhenNoProviders() public {
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealReturnsMatchingProvider() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderForDealSkipsInsufficientCapacity() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, 500, 0); // less than defaultTerms.dealSizeBytes

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealSkipsUnmetRequirements() public {
        SLITypes.SLIThresholds memory lowCapabilities =
            SLITypes.SLIThresholds({retrievabilityPct: 50, bandwidthMbps: 100, latencyMs: 500, indexingPct: 30});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, lowCapabilities, defaultAvailableBytes, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealPicksLeastCommitted() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        spRegistry.registerProviderFor(provider2, owner2, defaultCapabilities, defaultAvailableBytes, 0);
        vm.stopPrank();

        // Commit some capacity to provider1 so provider2 has less committed
        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 5000);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), CommonTypes.FilActorId.unwrap(provider2));
    }

    function testGetProviderForDealZeroRequirementSkipsDimension() public {
        SLITypes.SLIThresholds memory lowCapabilities =
            SLITypes.SLIThresholds({retrievabilityPct: 10, bandwidthMbps: 50, latencyMs: 999, indexingPct: 5});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, lowCapabilities, defaultAvailableBytes, 0);

        // All zeros = don't care about any SLI dimension
        SLITypes.SLIThresholds memory req = SLITypes.SLIThresholds({retrievabilityPct: 0, bandwidthMbps: 0, latencyMs: 0, indexingPct: 0});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderForDealSkipsUnmetBandwidth() public {
        SLITypes.SLIThresholds memory lowBandwidth =
            SLITypes.SLIThresholds({retrievabilityPct: 95, bandwidthMbps: 100, latencyMs: 100, indexingPct: 90});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, lowBandwidth, defaultAvailableBytes, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 0, bandwidthMbps: 500, latencyMs: 0, indexingPct: 0});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealLatencyLowerIsBetter() public {
        // Provider with high latency should NOT match low latency requirement
        SLITypes.SLIThresholds memory highLatency =
            SLITypes.SLIThresholds({retrievabilityPct: 95, bandwidthMbps: 1000, latencyMs: 500, indexingPct: 90});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, highLatency, defaultAvailableBytes, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 0, bandwidthMbps: 0, latencyMs: 100, indexingPct: 0});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealSkipsUnmetIndexing() public {
        SLITypes.SLIThresholds memory lowIndexing =
            SLITypes.SLIThresholds({retrievabilityPct: 95, bandwidthMbps: 1000, latencyMs: 100, indexingPct: 30});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, lowIndexing, defaultAvailableBytes, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 0, bandwidthMbps: 0, latencyMs: 0, indexingPct: 80});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealRevertsForNonMarketRole() public {
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        bytes32 marketRole = spRegistry.MARKET_ROLE();
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedAddress, marketRole
            )
        );
        spRegistry.getProviderForDeal(req, defaultTerms);
    }

    function testCommitCapacityIncrementsCommittedBytes() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 1000);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.committedBytes, 1000);
    }

    function testCommitCapacityAccumulates() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        vm.startPrank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 1000);
        spRegistry.commitCapacity(provider1, 2000);
        vm.stopPrank();

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.committedBytes, 3000);
    }

    function testCommitCapacityEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        vm.prank(poRepMarketAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.CapacityCommitted(provider1, 1000);
        spRegistry.commitCapacity(provider1, 1000);
    }

    function testCommitCapacityRevertsForUnregistered() public {
        vm.prank(poRepMarketAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderNotRegistered.selector, provider1));
        spRegistry.commitCapacity(provider1, 1000);
    }

    function testCommitCapacityRevertsForNonMarketRole() public {
        bytes32 marketRole = spRegistry.MARKET_ROLE();
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedAddress, marketRole
            )
        );
        spRegistry.commitCapacity(provider1, 1000);
    }

    function testReleaseCapacityEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 3000);

        vm.prank(poRepMarketAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.CapacityReleased(provider1, 1000);
        spRegistry.releaseCapacity(provider1, 1000);
    }

    function testReleaseCapacityDecrementsCommittedBytes() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        vm.startPrank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 3000);
        spRegistry.releaseCapacity(provider1, 1000);
        vm.stopPrank();

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.committedBytes, 2000);
    }

    function testReleaseCapacityRevertsForUnregistered() public {
        vm.prank(poRepMarketAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderNotRegistered.selector, provider1));
        spRegistry.releaseCapacity(provider1, 1000);
    }

    function testReleaseCapacityRevertsForNonMarketRole() public {
        bytes32 marketRole = spRegistry.MARKET_ROLE();
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedAddress, marketRole
            )
        );
        spRegistry.releaseCapacity(provider1, 1000);
    }

    function testGetProviderForDealTiebreakEqualCommitted() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);
        spRegistry.registerProviderFor(provider2, owner2, defaultCapabilities, defaultAvailableBytes, 0);
        vm.stopPrank();

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityPct: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,) = spRegistry.getProviderForDeal(req, defaultTerms);

        // Both have 0 committed bytes; first registered wins (EnumerableSet insertion order)
        assertEq(CommonTypes.FilActorId.unwrap(result), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testCommitCapacityRevertsWhenExceedingAvailable() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        vm.prank(poRepMarketAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                SPRegistry.CommitExceedsAvailable.selector, provider1, defaultAvailableBytes + 1, defaultAvailableBytes
            )
        );
        spRegistry.commitCapacity(provider1, defaultAvailableBytes + 1);
    }

    function testCommitCapacityRevertsWhenAccumulatedExceedsAvailable() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        vm.startPrank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, defaultAvailableBytes);
        vm.expectRevert(
            abi.encodeWithSelector(
                SPRegistry.CommitExceedsAvailable.selector, provider1, defaultAvailableBytes + 1, defaultAvailableBytes
            )
        );
        spRegistry.commitCapacity(provider1, 1);
        vm.stopPrank();
    }

    function testCommitCapacitySucceedsAtExactAvailable() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, defaultAvailableBytes);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.committedBytes, defaultAvailableBytes);
    }

    function testReleaseCapacityRevertsWhenExceedingCommitted() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        vm.startPrank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 1000);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ReleaseExceedsCommitted.selector, provider1, 1001, 1000));
        spRegistry.releaseCapacity(provider1, 1001);
        vm.stopPrank();
    }

    function testReleaseCapacityRevertsWhenNothingCommitted() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0);

        vm.prank(poRepMarketAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ReleaseExceedsCommitted.selector, provider1, 1, 0));
        spRegistry.releaseCapacity(provider1, 1);
    }

    function testRegisterProviderForRevertsInvalidRetrievabilityPct() public {
        SLITypes.SLIThresholds memory bad =
            SLITypes.SLIThresholds({retrievabilityPct: 101, bandwidthMbps: 100, latencyMs: 100, indexingPct: 50});
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidRetrievabilityPct.selector, uint8(101)));
        spRegistry.registerProviderFor(provider1, owner1, bad, defaultAvailableBytes, 0);
    }

    function testRegisterProviderForRevertsInvalidIndexingPct() public {
        SLITypes.SLIThresholds memory bad =
            SLITypes.SLIThresholds({retrievabilityPct: 50, bandwidthMbps: 100, latencyMs: 100, indexingPct: 101});
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidIndexingPct.selector, uint8(101)));
        spRegistry.registerProviderFor(provider1, owner1, bad, defaultAvailableBytes, 0);
    }
}

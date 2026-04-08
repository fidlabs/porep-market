// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Test} from "lib/forge-std/src/Test.sol";
import {SPRegistry} from "../src/SPRegistry.sol";
import {ISPRegistry} from "../src/interfaces/ISPRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SLITypes} from "../src/types/SLITypes.sol";
import {ResolveAddressPrecompileMock} from "./contracts/ResolveAddressPrecompileMock.sol";
import {ActorIdFailingMock} from "./contracts/ActorIdFailingMock.sol";
import {MockProxy} from "./contracts/MockProxy.sol";

// solhint-disable-next-line max-states-count
contract SPRegistryTest is Test {
    SPRegistry public spRegistry;
    address public adminAddress;
    address public poRepMarketAddress;
    address public owner1;
    address public owner2;
    address public unauthorizedAddress;
    address public operatorAddress;

    CommonTypes.FilActorId public provider1;
    CommonTypes.FilActorId public provider2;
    CommonTypes.FilActorId public provider3;

    SLITypes.SLIThresholds internal defaultCapabilities =
        SLITypes.SLIThresholds({retrievabilityBps: 9500, bandwidthMbps: 1000, latencyMs: 100, indexingPct: 90});

    SLITypes.DealTerms internal defaultTerms =
        SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 365});

    uint256 internal defaultAvailableBytes = 10_000_000;

    function setUp() public {
        SPRegistry impl = new SPRegistry();
        adminAddress = vm.addr(0x001);
        poRepMarketAddress = vm.addr(0x002);
        owner1 = vm.addr(0x003);
        owner2 = vm.addr(0x004);
        unauthorizedAddress = vm.addr(0x005);
        operatorAddress = vm.addr(0x006);

        provider1 = CommonTypes.FilActorId.wrap(1000);
        provider2 = CommonTypes.FilActorId.wrap(2000);
        provider3 = CommonTypes.FilActorId.wrap(3000);

        bytes memory initData = abi.encodeCall(SPRegistry.initialize, (adminAddress));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        spRegistry = SPRegistry(address(proxy));

        vm.prank(adminAddress);
        spRegistry.initialize2(poRepMarketAddress);

        bytes32 operatorRole = spRegistry.OPERATOR_ROLE();
        vm.prank(adminAddress);
        spRegistry.grantRole(operatorRole, operatorAddress);
    }

    function testInitializeSetsAdminRole() public view {
        assertTrue(spRegistry.hasRole(spRegistry.DEFAULT_ADMIN_ROLE(), adminAddress));
    }

    function testInitializeSetsUpgraderRole() public view {
        assertTrue(spRegistry.hasRole(spRegistry.UPGRADER_ROLE(), adminAddress));
    }

    function testInitialize2GrantsMarketRole() public view {
        assertTrue(spRegistry.hasRole(spRegistry.MARKET_ROLE(), poRepMarketAddress));
    }

    function testInitializeRevertsForZeroAdmin() public {
        SPRegistry impl = new SPRegistry();
        bytes memory initData = abi.encodeCall(SPRegistry.initialize, (address(0)));
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidAdminAddress.selector));
        new ERC1967Proxy(address(impl), initData);
    }

    function testInitialize2RevertsForZeroAddress() public {
        SPRegistry impl = new SPRegistry();
        bytes memory initData = abi.encodeCall(SPRegistry.initialize, (adminAddress));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        SPRegistry registry = SPRegistry(address(proxy));

        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidPoRepMarketAddress.selector));
        registry.initialize2(address(0));
    }

    function testInitialize2RevertsForNonAdmin() public {
        SPRegistry impl = new SPRegistry();
        bytes memory initData = abi.encodeCall(SPRegistry.initialize, (adminAddress));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        SPRegistry registry = SPRegistry(address(proxy));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.DEFAULT_ADMIN_ROLE()
            )
        );
        registry.initialize2(poRepMarketAddress);
    }

    function testInitialize2CannotBeCalledTwice() public {
        SPRegistry impl = new SPRegistry();
        bytes memory initData = abi.encodeCall(SPRegistry.initialize, (adminAddress));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        SPRegistry registry = SPRegistry(address(proxy));

        vm.prank(adminAddress);
        registry.initialize2(poRepMarketAddress);

        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        registry.initialize2(poRepMarketAddress);
    }

    function testEIP7201StorageSlotIsCorrect() public pure {
        // solhint-disable-next-line gas-small-strings
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("porepmarket.storage.SPRegistryStorage")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(expected, 0x29a3c97291f1bc298e74d2ad6fe62e764c2656f8f0c161acf9b2bd013019df00);
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

    function testPauseProviderSetsPausedTrue() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(adminAddress);
        spRegistry.pauseProvider(provider1);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertTrue(info.paused);
    }

    function testUnpauseProviderSetsPausedFalse() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.pauseProvider(provider1);
        spRegistry.unpauseProvider(provider1);
        vm.stopPrank();

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertFalse(info.paused);
    }

    function testPauseProviderEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, false);
        emit SPRegistry.ProviderPaused(provider1);
        spRegistry.pauseProvider(provider1);
    }

    function testUnpauseProviderEmitsEvent() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.pauseProvider(provider1);
        vm.expectEmit(true, false, false, false);
        emit SPRegistry.ProviderUnpaused(provider1);
        spRegistry.unpauseProvider(provider1);
        vm.stopPrank();
    }

    function testPauseProviderRevertsForUnregistered() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderNotRegistered.selector, provider1));
        spRegistry.pauseProvider(provider1);
    }

    function testPauseProviderRevertsWhenBlocked() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderIsBlocked.selector, provider1));
        spRegistry.pauseProvider(provider1);
        vm.stopPrank();
    }

    function testUnpauseProviderRevertsWhenBlocked() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.pauseProvider(provider1);
        spRegistry.blockProvider(provider1);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderIsBlocked.selector, provider1));
        spRegistry.unpauseProvider(provider1);
        vm.stopPrank();
    }

    function testBlockProviderSetsBlockedTrue() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.stopPrank();

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertTrue(info.blocked);
    }

    function testUnblockProviderSetsBlockedFalse() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        spRegistry.unblockProvider(provider1);
        vm.stopPrank();

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertFalse(info.blocked);
    }

    function testBlockProviderRevertsForNonAdmin() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(unauthorizedAddress);
        vm.expectRevert();
        spRegistry.blockProvider(provider1);
    }

    function testUnblockProviderRevertsForNonAdmin() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.stopPrank();

        vm.prank(unauthorizedAddress);
        vm.expectRevert();
        spRegistry.unblockProvider(provider1);
    }

    function testBlockProviderRevertsForUnregistered() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderNotRegistered.selector, provider1));
        spRegistry.blockProvider(provider1);
    }

    function testBlockedProviderCannotUpdateAvailableSpace() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderIsBlocked.selector, provider1));
        spRegistry.updateAvailableSpace(provider1, 999);
        vm.stopPrank();
    }

    function testBlockedProviderCannotSetCapabilities() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderIsBlocked.selector, provider1));
        spRegistry.setCapabilities(provider1, defaultCapabilities);
        vm.stopPrank();
    }

    function testBlockedProviderCannotSetPrice() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderIsBlocked.selector, provider1));
        spRegistry.setPrice(provider1, 500);
        vm.stopPrank();
    }

    function testBlockProviderEmitsEvent() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        vm.expectEmit(true, false, false, false);
        emit SPRegistry.ProviderBlocked(provider1);
        spRegistry.blockProvider(provider1);
        vm.stopPrank();
    }

    function testUnblockProviderEmitsEvent() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.expectEmit(true, false, false, false);
        emit SPRegistry.ProviderUnblocked(provider1);
        spRegistry.unblockProvider(provider1);
        vm.stopPrank();
    }

    function testSetPriceUpdatesProviderPrice() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.prank(adminAddress);
        spRegistry.setPrice(provider1, 250);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.pricePerSectorPerMonth, 250);
    }

    function testRegisterProviderForRevertsForActorIdZero() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidProviderActorId.selector));
        spRegistry.registerProviderFor(
            CommonTypes.FilActorId.wrap(0), owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
    }

    function testRegisterProviderForRevertsForZeroOwner() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidOrganizationAddress.selector));
        spRegistry.registerProviderFor(
            provider1, address(0), defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
    }

    function testIsProviderRegisteredReturnsFalseForUnregistered() public view {
        assertFalse(spRegistry.isProviderRegistered(provider1));
    }

    function testRegisterProviderForEmitsEvents() public {
        vm.prank(adminAddress);
        vm.expectEmit(true, true, false, false);
        emit SPRegistry.ProviderRegistered(provider1, owner1);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.CapabilitiesUpdated(provider1, defaultCapabilities);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
    }

    function testRegisterProviderForSetsAllFields() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        assertTrue(spRegistry.isProviderRegistered(provider1));
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.organization, owner1);
        assertFalse(info.paused);
        assertEq(info.availableBytes, defaultAvailableBytes);
        assertEq(info.capabilities.retrievabilityBps, defaultCapabilities.retrievabilityBps);
    }

    function testRegisterProviderForRevertsIfAlreadyRegistered() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderAlreadyRegistered.selector, provider1));
        spRegistry.registerProviderFor(
            provider1, owner2, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.stopPrank();
    }

    function testRegisterProviderForRevertsForNonAdmin() public {
        vm.prank(unauthorizedAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.NotAdminOrOperator.selector, unauthorizedAddress));
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
    }

    function testRegisterProviderForSetsDefaultPrice() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 250, address(0), 0, 0
        );

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.pricePerSectorPerMonth, 250);
    }

    function testRegisterProviderForEmitsDefaultPriceEvent() public {
        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.PriceUpdated(provider1, 0, 250);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 250, address(0), 0, 0
        );
    }

    function testRegisterProviderForZeroPriceEmitsDefaultPriceEvent() public {
        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.PriceUpdated(provider1, 0, 0);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
    }

    function testRegisterProviderForSucceedsWithOperatorRole() public {
        vm.prank(operatorAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        assertTrue(spRegistry.isProviderRegistered(provider1));
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.organization, owner1);
        assertEq(info.availableBytes, defaultAvailableBytes);
        assertEq(info.pricePerSectorPerMonth, 100);
    }

    function testRegisterProviderForStillWorksForAdmin() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        assertTrue(spRegistry.isProviderRegistered(provider1));
    }

    function testUpdateAvailableSpaceEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        // Use admin path since MinerAPI precompile is not available in Foundry
        // TODO: integration test with MinerAPI mock for controlling-address path
        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.AvailableSpaceUpdated(provider1, 5_000_000);
        spRegistry.updateAvailableSpace(provider1, 5_000_000);
    }

    function testUpdateAvailableSpaceSetsValue() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        // Use admin path since MinerAPI precompile is not available in Foundry
        // TODO: integration test with MinerAPI mock for controlling-address path
        vm.prank(adminAddress);
        spRegistry.updateAvailableSpace(provider1, 5_000_000);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.availableBytes, 5_000_000);
    }

    function testSetCapabilitiesEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        // Use admin path since MinerAPI precompile is not available in Foundry
        // TODO: integration test with MinerAPI mock for controlling-address path
        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.CapabilitiesUpdated(provider1, defaultCapabilities);
        spRegistry.setCapabilities(provider1, defaultCapabilities);
    }

    function testSetCapabilitiesSetsValues() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        // Use admin path since MinerAPI precompile is not available in Foundry
        // TODO: integration test with MinerAPI mock for controlling-address path
        vm.prank(adminAddress);
        spRegistry.setCapabilities(provider1, defaultCapabilities);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.capabilities.retrievabilityBps, 9500);
        assertEq(info.capabilities.bandwidthMbps, 1000);
        assertEq(info.capabilities.latencyMs, 100);
        assertEq(info.capabilities.indexingPct, 90);
    }

    function testSetCapabilitiesRevertsInvalidRetrievabilityBps() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        SLITypes.SLIThresholds memory bad =
            SLITypes.SLIThresholds({retrievabilityBps: 10001, bandwidthMbps: 100, latencyMs: 100, indexingPct: 50});
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidRetrievabilityBps.selector, uint16(10001)));
        spRegistry.setCapabilities(provider1, bad);
    }

    function testSetCapabilitiesAcceptsMaxRetrievabilityBps() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        SLITypes.SLIThresholds memory maxBps =
            SLITypes.SLIThresholds({retrievabilityBps: 10000, bandwidthMbps: 100, latencyMs: 100, indexingPct: 50});
        vm.prank(adminAddress);
        spRegistry.setCapabilities(provider1, maxBps);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.capabilities.retrievabilityBps, 10000);
    }

    function testSetCapabilitiesRevertsInvalidIndexingPct() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        SLITypes.SLIThresholds memory bad =
            SLITypes.SLIThresholds({retrievabilityBps: 5000, bandwidthMbps: 100, latencyMs: 100, indexingPct: 101});
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidIndexingPct.selector, uint8(101)));
        spRegistry.setCapabilities(provider1, bad);
    }

    function testSetCapabilitiesAdminCanSet() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        SLITypes.SLIThresholds memory newCaps =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(adminAddress);
        spRegistry.setCapabilities(provider1, newCaps);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.capabilities.retrievabilityBps, 8000);
    }

    function testSetCapabilitiesRevertsForNonControllerNonAdmin() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        // MinerUtils precompile doesn't exist in Foundry, so calling from a non-admin address
        // will revert when MinerUtils tries to call MinerAPI precompile
        // TODO: integration test with MinerAPI mock for controlling-address path
        vm.prank(unauthorizedAddress);
        vm.expectRevert();
        spRegistry.setCapabilities(provider1, defaultCapabilities);
    }

    function testUpdateAvailableSpaceAdminCanSet() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.prank(adminAddress);
        spRegistry.updateAvailableSpace(provider1, 5_000_000);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.availableBytes, 5_000_000);
    }

    function testUpdateAvailableSpaceRevertsForNonControllerNonAdmin() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        // MinerUtils precompile doesn't exist in Foundry, so calling from a non-admin address
        // will revert when MinerUtils tries to call MinerAPI precompile
        // TODO: integration test with MinerAPI mock for controlling-address path
        vm.prank(unauthorizedAddress);
        vm.expectRevert();
        spRegistry.updateAvailableSpace(provider1, 5_000_000);
    }

    function testUpdateAvailableSpaceRevertsWhenBelowCommittedPlusPending() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        // Create pending reservation
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        spRegistry.getProviderForDeal(req, defaultTerms);
        // pendingBytes = 1_000_000 (defaultTerms.dealSizeBytes)

        // Try to set available below pending — should revert
        vm.prank(adminAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                SPRegistry.AvailableBelowCommittedPlusPending.selector, provider1, 500_000, 0, 1_000_000
            )
        );
        spRegistry.updateAvailableSpace(provider1, 500_000);
    }

    function testUpdateAvailableSpaceAllowsExactCommittedPlusPending() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        // Create pending reservation
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        spRegistry.getProviderForDeal(req, defaultTerms);

        // Set available exactly at committed + pending — should succeed
        vm.prank(adminAddress);
        spRegistry.updateAvailableSpace(provider1, defaultTerms.dealSizeBytes);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.availableBytes, defaultTerms.dealSizeBytes);
    }

    function testIsAuthorizedForProviderReturnsTrueForAdmin() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        assertTrue(spRegistry.isAuthorizedForProvider(adminAddress, provider1));
    }

    function testIsAuthorizedForProviderRevertsForNonAdminWithoutPrecompile() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        // MinerUtils precompile doesn't exist in Foundry, so calling with a non-admin address
        // will revert when MinerUtils tries to call MinerAPI precompile
        // TODO: integration test with MinerAPI mock for controlling-address path
        vm.expectRevert();
        spRegistry.isAuthorizedForProvider(owner2, provider1);
    }

    function testIsAuthorizedForProviderReturnsTrueForAdminEvenWhenUnregistered() public view {
        // Admin check happens before MinerUtils check (no _ensureProviderRegistered in isAuthorizedForProvider)
        assertTrue(spRegistry.isAuthorizedForProvider(adminAddress, provider1));
    }

    function testGetProviderInfoDefaultPriceIsZeroByDefault() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.pricePerSectorPerMonth, 0);
    }

    function testGetProviderForDealAutoApproveTrueWhenPriceMatches() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (, bool autoApprove,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertTrue(autoApprove);
    }

    function testGetProviderForDealAutoApproveTrueWhenPriceExceeds() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 50, address(0), 0, 0
        );

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (, bool autoApprove,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertTrue(autoApprove);
    }

    function testGetProviderForDealAutoApproveFalseWhenPriceBelowDefault() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 200, address(0), 0, 0
        );

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (, bool autoApprove,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertFalse(autoApprove);
    }

    function testGetProviderForDealAutoApproveFalseWhenPriceNotSet() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (, bool autoApprove,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertFalse(autoApprove);
    }

    function testGetProviderForDealAutoApproveFalseWhenNoProviderMatches() public {
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result, bool autoApprove,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
        assertFalse(autoApprove);
    }

    function testGetProvidersReturnsEmpty() public view {
        CommonTypes.FilActorId[] memory providers = spRegistry.getProviders();
        assertEq(providers.length, 0);
    }

    function testGetProvidersReturnsRegistered() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        spRegistry.registerProviderFor(
            provider2, owner2, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.stopPrank();

        CommonTypes.FilActorId[] memory providers = spRegistry.getProviders();
        assertEq(providers.length, 2);
    }

    function testGetCommittedProvidersReturnsEmpty() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        CommonTypes.FilActorId[] memory committed = spRegistry.getCommittedProviders();
        assertEq(committed.length, 0);
    }

    function testGetCommittedProvidersReturnsOnlyCommitted() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        spRegistry.registerProviderFor(
            provider2, owner2, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.stopPrank();

        // Commit capacity for provider1 only
        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 1000, 1000);

        CommonTypes.FilActorId[] memory committed = spRegistry.getCommittedProviders();
        assertEq(committed.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(committed[0]), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderInfoReturnsZeroedForUnregistered() public view {
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.organization, address(0));
        assertEq(info.availableBytes, 0);
    }

    function testGetProviderInfoReturnsFullData() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.organization, owner1);
        assertEq(info.payee, owner1);
        assertFalse(info.paused);
        assertEq(info.capabilities.retrievabilityBps, 9500);
        assertEq(info.capabilities.bandwidthMbps, 1000);
        assertEq(info.capabilities.latencyMs, 100);
        assertEq(info.capabilities.indexingPct, 90);
        assertEq(info.availableBytes, defaultAvailableBytes);
        assertEq(info.committedBytes, 0);
        assertEq(info.pendingBytes, 0);
        assertEq(info.pricePerSectorPerMonth, 0);
    }

    function testGetProviderForDealReturnsZeroWhenNoProviders() public {
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealReturnsMatchingProvider() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderForDealSkipsInsufficientCapacity() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, defaultCapabilities, 500, 0, address(0), 0, 0); // less than defaultTerms.dealSizeBytes

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealSkipsUnmetRequirements() public {
        SLITypes.SLIThresholds memory lowCapabilities =
            SLITypes.SLIThresholds({retrievabilityBps: 5000, bandwidthMbps: 100, latencyMs: 500, indexingPct: 30});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, lowCapabilities, defaultAvailableBytes, 0, address(0), 0, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealPicksLeastPending() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        spRegistry.registerProviderFor(
            provider2, owner2, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.stopPrank();

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});

        // First call routes to provider1 (insertion order tiebreak), giving it pending bytes
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId first,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(first), CommonTypes.FilActorId.unwrap(provider1));

        // Second call must route to provider2 — it has 0 pending vs provider1's dealSizeBytes
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId second,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(second), CommonTypes.FilActorId.unwrap(provider2));
    }

    function testGetProviderForDealZeroRequirementSkipsDimension() public {
        SLITypes.SLIThresholds memory lowCapabilities =
            SLITypes.SLIThresholds({retrievabilityBps: 1000, bandwidthMbps: 50, latencyMs: 999, indexingPct: 5});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, lowCapabilities, defaultAvailableBytes, 0, address(0), 0, 0);

        // All zeros = don't care about any SLI dimension
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 0, bandwidthMbps: 0, latencyMs: 0, indexingPct: 0});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderForDealSkipsUnmetBandwidth() public {
        SLITypes.SLIThresholds memory lowBandwidth =
            SLITypes.SLIThresholds({retrievabilityBps: 9500, bandwidthMbps: 100, latencyMs: 100, indexingPct: 90});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, lowBandwidth, defaultAvailableBytes, 0, address(0), 0, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 0, bandwidthMbps: 500, latencyMs: 0, indexingPct: 0});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealLatencyLowerIsBetter() public {
        // Provider with high latency should NOT match low latency requirement
        SLITypes.SLIThresholds memory highLatency =
            SLITypes.SLIThresholds({retrievabilityBps: 9500, bandwidthMbps: 1000, latencyMs: 500, indexingPct: 90});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, highLatency, defaultAvailableBytes, 0, address(0), 0, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 0, bandwidthMbps: 0, latencyMs: 100, indexingPct: 0});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealSkipsUnmetIndexing() public {
        SLITypes.SLIThresholds memory lowIndexing =
            SLITypes.SLIThresholds({retrievabilityBps: 9500, bandwidthMbps: 1000, latencyMs: 100, indexingPct: 30});
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(provider1, owner1, lowIndexing, defaultAvailableBytes, 0, address(0), 0, 0);

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 0, bandwidthMbps: 0, latencyMs: 0, indexingPct: 80});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result), 0);
    }

    function testGetProviderForDealRevertsForNonMarketRole() public {
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
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
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 1000, 1000);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.committedBytes, 1000);
    }

    function testCommitCapacityAccumulates() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.startPrank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 1000, 1000);
        spRegistry.commitCapacity(provider1, 2000, 2000);
        vm.stopPrank();

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.committedBytes, 3000);
    }

    function testCommitCapacityEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.prank(poRepMarketAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.CapacityCommitted(provider1, 1000);
        spRegistry.commitCapacity(provider1, 1000, 1000);
    }

    function testCommitCapacityRevertsForUnregistered() public {
        vm.prank(poRepMarketAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderNotRegistered.selector, provider1));
        spRegistry.commitCapacity(provider1, 1000, 1000);
    }

    function testCommitCapacityRevertsForNonMarketRole() public {
        bytes32 marketRole = spRegistry.MARKET_ROLE();
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedAddress, marketRole
            )
        );
        spRegistry.commitCapacity(provider1, 1000, 1000);
    }

    function testReleaseCapacityEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 3000, 3000);

        vm.prank(poRepMarketAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.CapacityReleased(provider1, 1000);
        spRegistry.releaseCapacity(provider1, 1000);
    }

    function testReleaseCapacityDecrementsCommittedBytes() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.startPrank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 3000, 3000);
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

    function testGetProviderForDealTiebreakEqualPending() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        spRegistry.registerProviderFor(
            provider2, owner2, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.stopPrank();

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result,,) = spRegistry.getProviderForDeal(req, defaultTerms);

        // Both have 0 pending bytes; first registered wins (EnumerableSet insertion order)
        assertEq(CommonTypes.FilActorId.unwrap(result), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testCommitCapacityRevertsWhenExceedingAvailable() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.prank(poRepMarketAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                SPRegistry.CommitExceedsAvailable.selector, provider1, defaultAvailableBytes + 1, defaultAvailableBytes
            )
        );
        spRegistry.commitCapacity(provider1, defaultAvailableBytes + 1, defaultAvailableBytes + 1);
    }

    function testCommitCapacityRevertsWhenAccumulatedExceedsAvailable() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.startPrank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, defaultAvailableBytes, defaultAvailableBytes);
        vm.expectRevert(
            abi.encodeWithSelector(
                SPRegistry.CommitExceedsAvailable.selector, provider1, defaultAvailableBytes + 1, defaultAvailableBytes
            )
        );
        spRegistry.commitCapacity(provider1, 1, 1);
        vm.stopPrank();
    }

    function testCommitCapacitySucceedsAtExactAvailable() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, defaultAvailableBytes, defaultAvailableBytes);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.committedBytes, defaultAvailableBytes);
    }

    function testReleaseCapacityRevertsWhenExceedingCommitted() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.startPrank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, 1000, 1000);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ReleaseExceedsCommitted.selector, provider1, 1001, 1000));
        spRegistry.releaseCapacity(provider1, 1001);
        vm.stopPrank();
    }

    function testReleaseCapacityRevertsWhenNothingCommitted() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.prank(poRepMarketAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ReleaseExceedsCommitted.selector, provider1, 1, 0));
        spRegistry.releaseCapacity(provider1, 1);
    }

    function testRegisterProviderForRevertsInvalidRetrievabilityBps() public {
        SLITypes.SLIThresholds memory bad =
            SLITypes.SLIThresholds({retrievabilityBps: 10001, bandwidthMbps: 100, latencyMs: 100, indexingPct: 50});
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidRetrievabilityBps.selector, uint16(10001)));
        spRegistry.registerProviderFor(provider1, owner1, bad, defaultAvailableBytes, 0, address(0), 0, 0);
    }

    function testRegisterProviderForRevertsInvalidIndexingPct() public {
        SLITypes.SLIThresholds memory bad =
            SLITypes.SLIThresholds({retrievabilityBps: 5000, bandwidthMbps: 100, latencyMs: 100, indexingPct: 101});
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidIndexingPct.selector, uint8(101)));
        spRegistry.registerProviderFor(provider1, owner1, bad, defaultAvailableBytes, 0, address(0), 0, 0);
    }

    function testGetProviderForDealReservesPendingBytes() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        spRegistry.getProviderForDeal(req, defaultTerms);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.pendingBytes, defaultTerms.dealSizeBytes);
    }

    function testGetProviderForDealSkipsProviderWithFullPending() public {
        // Register provider1 with capacity just enough for one deal
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultTerms.dealSizeBytes, 0, address(0), 0, 0
        );

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});

        // First deal reserves pending, consuming all remaining capacity
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result1,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result1), CommonTypes.FilActorId.unwrap(provider1));

        // Second deal should not match because pending fills available
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId result2,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(result2), 0);
    }

    function testReleasePendingCapacityDecrementsPending() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        // Reserve pending via getProviderForDeal
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        spRegistry.getProviderForDeal(req, defaultTerms);

        // Release pending
        vm.prank(poRepMarketAddress);
        spRegistry.releasePendingCapacity(provider1, defaultTerms.dealSizeBytes);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.pendingBytes, 0);
    }

    function testReleasePendingCapacityRevertsWhenExceedsPending() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.prank(poRepMarketAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ReleasePendingExceedsPending.selector, provider1, 100, 0));
        spRegistry.releasePendingCapacity(provider1, 100);
    }

    function testReleasePendingCapacityRevertsForNonMarketRole() public {
        bytes32 marketRole = spRegistry.MARKET_ROLE();
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedAddress, marketRole
            )
        );
        spRegistry.releasePendingCapacity(provider1, 100);
    }

    function testSetToleranceBpsUpdatesValue() public {
        vm.prank(adminAddress);
        spRegistry.setToleranceBps(1000);
        assertEq(spRegistry.getToleranceBps(), 1000);
    }

    function testSetToleranceBpsEmitsEvent() public {
        vm.prank(adminAddress);
        vm.expectEmit(false, false, false, true);
        emit SPRegistry.ToleranceBpsUpdated(0, 1000);
        spRegistry.setToleranceBps(1000);
    }

    function testSetToleranceBpsRevertsForNonAdmin() public {
        bytes32 adminRole = spRegistry.DEFAULT_ADMIN_ROLE();
        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedAddress, adminRole
            )
        );
        spRegistry.setToleranceBps(1000);
    }

    function testSetToleranceBpsRevertsAboveMax() public {
        uint256 maxBps = spRegistry.MAX_TOLERANCE_BPS();
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ToleranceBpsTooHigh.selector, 10_001, maxBps));
        spRegistry.setToleranceBps(10_001);
    }

    function testSetToleranceBpsAllowsMax() public {
        vm.prank(adminAddress);
        spRegistry.setToleranceBps(10_000);
        assertEq(spRegistry.getToleranceBps(), 10_000);
    }

    function testCommitCapacityRevertsWhenActualExceedsTolerance() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        spRegistry.setToleranceBps(1000); // 10% tolerance
        vm.stopPrank();

        uint256 estimated = 1000;
        // 10% tolerance means max allowed = 1000 * 11000 / 10000 = 1100
        uint256 actualOverTolerance = 1101;

        vm.prank(poRepMarketAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.ActualSizeExceedsTolerance.selector, provider1, actualOverTolerance, 1100)
        );
        spRegistry.commitCapacity(provider1, estimated, actualOverTolerance);
    }

    function testCommitCapacityAllowsWithinTolerance() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        spRegistry.setToleranceBps(1000); // 10% tolerance
        vm.stopPrank();

        uint256 estimated = 1000;
        // 10% tolerance means max allowed = 1000 * 11000 / 10000 = 1100
        uint256 actualWithinTolerance = 1100;

        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, estimated, actualWithinTolerance);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.committedBytes, actualWithinTolerance);
    }

    function testSetPriceEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.PriceUpdated(provider1, 100, 500);
        spRegistry.setPrice(provider1, 500);
    }

    function testSetPriceRevertsForUnregistered() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderNotRegistered.selector, provider1));
        spRegistry.setPrice(provider1, 500);
    }

    function testCommitCapacityReleasesPendingWhenEstimatedWithinPending() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        // Reserve pending via getProviderForDeal
        vm.prank(poRepMarketAddress);
        spRegistry.getProviderForDeal(defaultCapabilities, defaultTerms);

        ISPRegistry.ProviderInfo memory infoBefore = spRegistry.getProviderInfo(provider1);
        assertEq(infoBefore.pendingBytes, defaultTerms.dealSizeBytes);

        // Commit with estimatedSizeBytes == pendingBytes (hits p.pendingBytes -= estimatedSizeBytes)
        vm.prank(poRepMarketAddress);
        spRegistry.commitCapacity(provider1, defaultTerms.dealSizeBytes, defaultTerms.dealSizeBytes);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.pendingBytes, 0);
        assertEq(info.committedBytes, defaultTerms.dealSizeBytes);
    }

    function testCommitCapacityEmitsCorrectReleasedAmountWhenEstimatedExceedsPending() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        // Reserve 500 pending via getProviderForDeal
        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        SLITypes.DealTerms memory smallTerms =
            SLITypes.DealTerms({dealSizeBytes: 500, pricePerSectorPerMonth: 100, durationDays: 365});

        vm.prank(poRepMarketAddress);
        spRegistry.getProviderForDeal(req, smallTerms);

        // Commit with estimated=1000 (exceeds pending=500), actual=800
        // Should emit PendingCapacityReleased with 500 (actual pending), NOT 1000
        vm.prank(poRepMarketAddress);
        vm.expectEmit(true, true, true, true);
        emit SPRegistry.PendingCapacityReleased(provider1, 500);
        spRegistry.commitCapacity(provider1, 1000, 800);
    }

    function testSetCapabilitiesRevertsWithNotControllerForNonControllingAddress() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        // Set up MinerAPI precompile mocks so isControllingAddress returns false (not reverts)
        address nonController = vm.addr(0x099);
        _setupMinerPrecompileMocks(nonController);

        vm.prank(nonController);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.NotProviderControllerOrAdmin.selector, nonController, provider1)
        );
        spRegistry.setCapabilities(provider1, defaultCapabilities);
    }

    function testGetProviderForDealSkipsPausedProvider() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.registerProviderFor(
            provider2, owner2, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.pauseProvider(provider1);
        vm.stopPrank();

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), CommonTypes.FilActorId.unwrap(provider2));
    }

    function testGetProviderForDealReturnsZeroWhenAllPaused() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.pauseProvider(provider1);
        vm.stopPrank();

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), 0);
    }

    function testGetProviderForDealSkipsBlockedProvider() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.registerProviderFor(
            provider2, owner2, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.stopPrank();

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), CommonTypes.FilActorId.unwrap(provider2));
    }

    function testGetProviderForDealReturnsZeroWhenAllBlocked() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.stopPrank();

        SLITypes.SLIThresholds memory req =
            SLITypes.SLIThresholds({retrievabilityBps: 8000, bandwidthMbps: 500, latencyMs: 200, indexingPct: 50});
        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(req, defaultTerms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), 0);
    }

    // ==================== R2: MAX_PROVIDERS tests ====================

    function testMaxProvidersConstantIs500() public view {
        assertEq(spRegistry.MAX_PROVIDERS(), 500);
    }

    function testRegisterProviderForAllowsExactlyMaxProviders() public {
        vm.startPrank(adminAddress);
        // solhint-disable-next-line gas-strict-inequalities
        for (uint64 i = 1; i <= 500; i++) {
            spRegistry.registerProviderFor(
                CommonTypes.FilActorId.wrap(i),
                owner1,
                defaultCapabilities,
                defaultAvailableBytes,
                100,
                address(0),
                0,
                0
            );
        }
        vm.stopPrank();
        assertEq(spRegistry.getProviders().length, 500);
    }

    function testRegisterProviderForRevertsWhenMaxProvidersReached() public {
        vm.startPrank(adminAddress);
        // solhint-disable-next-line gas-strict-inequalities
        for (uint64 i = 1; i <= 500; i++) {
            spRegistry.registerProviderFor(
                CommonTypes.FilActorId.wrap(i),
                owner1,
                defaultCapabilities,
                defaultAvailableBytes,
                100,
                address(0),
                0,
                0
            );
        }
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.MaxProvidersReached.selector, 500));
        spRegistry.registerProviderFor(
            CommonTypes.FilActorId.wrap(501), owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        vm.stopPrank();
    }

    // ==================== R3: getProvidersByOrganization tests ====================

    function testGetProvidersByOrganizationReturnsEmpty() public view {
        CommonTypes.FilActorId[] memory providers = spRegistry.getProvidersByOrganization(owner1);
        assertEq(providers.length, 0);
    }

    function testGetProvidersByOrganizationReturnsSingleProvider() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        CommonTypes.FilActorId[] memory providers = spRegistry.getProvidersByOrganization(owner1);
        assertEq(providers.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(providers[0]), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProvidersByOrganizationReturnsMultipleProviders() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.registerProviderFor(
            provider2, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        vm.stopPrank();

        CommonTypes.FilActorId[] memory providers = spRegistry.getProvidersByOrganization(owner1);
        assertEq(providers.length, 2);
    }

    function testGetProvidersByOrganizationIsolatesOrganizations() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.registerProviderFor(
            provider2, owner2, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        vm.stopPrank();

        CommonTypes.FilActorId[] memory org1Providers = spRegistry.getProvidersByOrganization(owner1);
        CommonTypes.FilActorId[] memory org2Providers = spRegistry.getProvidersByOrganization(owner2);
        assertEq(org1Providers.length, 1);
        assertEq(org2Providers.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(org1Providers[0]), CommonTypes.FilActorId.unwrap(provider1));
        assertEq(CommonTypes.FilActorId.unwrap(org2Providers[0]), CommonTypes.FilActorId.unwrap(provider2));
    }

    // ============ Payee Tests ============

    function testRegisterProviderForSetsPayeeToOrganization() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        assertEq(spRegistry.getPayee(provider1), owner1);
        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.payee, owner1);
    }

    function testSetPayeeUpdatesPayee() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        address newPayee = vm.addr(0x099);

        vm.prank(adminAddress);
        vm.expectEmit(true, true, true, true);
        emit SPRegistry.PayeeUpdated(provider1, owner1, newPayee);
        spRegistry.setPayee(provider1, newPayee);

        assertEq(spRegistry.getPayee(provider1), newPayee);
    }

    function testSetPayeeRevertsForZeroAddress() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.InvalidPayeeAddress.selector));
        spRegistry.setPayee(provider1, address(0));
    }

    function testSetPayeeRevertsForUnauthorizedCaller() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        _setupMinerPrecompileMocks(unauthorizedAddress);

        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.NotProviderControllerOrAdmin.selector, unauthorizedAddress, provider1)
        );
        spRegistry.setPayee(provider1, vm.addr(0x099));
    }

    function testAdminCanSetPayee() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );

        address newPayee = vm.addr(0x099);
        vm.prank(adminAddress);
        spRegistry.setPayee(provider1, newPayee);

        assertEq(spRegistry.getPayee(provider1), newPayee);
    }

    function testSetPayeeRevertsForUnregisteredProvider() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderNotRegistered.selector, provider1));
        spRegistry.setPayee(provider1, vm.addr(0x099));
    }

    function testSetPayeeRevertsForBlockedProvider() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 0, address(0), 0, 0
        );
        vm.prank(adminAddress);
        spRegistry.blockProvider(provider1);

        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderIsBlocked.selector, provider1));
        spRegistry.setPayee(provider1, vm.addr(0x099));
    }

    function _setupMinerPrecompileMocks(address caller) internal {
        // ResolveAddress precompile at 0xFE00000000000000000000000000000000000001
        ResolveAddressPrecompileMock resolveAddressMock = new ResolveAddressPrecompileMock();
        vm.etch(address(0xFE00000000000000000000000000000000000001), address(resolveAddressMock).code);
        ResolveAddressPrecompileMock(address(0xFE00000000000000000000000000000000000001))
            .setId(caller, uint64(CommonTypes.FilActorId.unwrap(provider1)));

        // CALL_ACTOR_ID at 0xfe00000000000000000000000000000000000005
        // Uses ActorIdFailingMock which returns (exitCode=0, controllingAddress=false)
        ActorIdFailingMock failingMock = new ActorIdFailingMock();
        vm.etch(address(0xfe00000000000000000000000000000000000005), address(failingMock).code);

        // MockProxy at address(5555) for actor dispatch
        MockProxy proxy = new MockProxy(address(5555));
        vm.etch(address(5555), address(proxy).code);
    }

    function testGetPayAddressForProviderReturnsZeroAddress() public view {
        address payAddress = spRegistry.getPayee(provider1);
        assertEq(payAddress, address(0));
    }

    function testRegisterProviderForWithDurationLimits() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 90, 365
        );

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.minDealDurationDays, 90);
        assertEq(info.maxDealDurationDays, 365);
    }

    function testRegisterProviderForRevertsMinExceedsMax() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.MinDurationExceedsMax.selector, 365, 90));
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 365, 90
        );
    }

    function testRegisterProviderForEmitsDurationEvent() public {
        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.DealDurationLimitsUpdated(provider1, 90, 365);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 90, 365
        );
    }

    // -----------------------------------------------------------------------
    // setDealDurationLimits tests
    // -----------------------------------------------------------------------

    function testSetDealDurationLimitsBothNonZero() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(adminAddress);
        spRegistry.setDealDurationLimits(provider1, 90, 365);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.minDealDurationDays, 90);
        assertEq(info.maxDealDurationDays, 365);
    }

    function testSetDealDurationLimitsMinOnly() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(adminAddress);
        spRegistry.setDealDurationLimits(provider1, 90, 0);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.minDealDurationDays, 90);
        assertEq(info.maxDealDurationDays, 0);
    }

    function testSetDealDurationLimitsMaxOnly() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(adminAddress);
        spRegistry.setDealDurationLimits(provider1, 0, 365);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.minDealDurationDays, 0);
        assertEq(info.maxDealDurationDays, 365);
    }

    function testSetDealDurationLimitsClearLimits() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 90, 365
        );

        vm.prank(adminAddress);
        spRegistry.setDealDurationLimits(provider1, 0, 0);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.minDealDurationDays, 0);
        assertEq(info.maxDealDurationDays, 0);
    }

    function testSetDealDurationLimitsRevertsMinExceedsMax() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.MinDurationExceedsMax.selector, 365, 90));
        spRegistry.setDealDurationLimits(provider1, 365, 90);
    }

    function testSetDealDurationLimitsRevertsUnauthorized() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        _setupMinerPrecompileMocks(unauthorizedAddress);

        vm.prank(unauthorizedAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.NotProviderControllerOrAdmin.selector, unauthorizedAddress, provider1)
        );
        spRegistry.setDealDurationLimits(provider1, 90, 365);
    }

    function testSetDealDurationLimitsEmitsEvent() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(adminAddress);
        vm.expectEmit(true, false, false, true);
        emit SPRegistry.DealDurationLimitsUpdated(provider1, 90, 365);
        spRegistry.setDealDurationLimits(provider1, 90, 365);
    }

    function testSetDealDurationLimitsRevertsBlockedProvider() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.blockProvider(provider1);
        vm.stopPrank();

        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderIsBlocked.selector, provider1));
        spRegistry.setDealDurationLimits(provider1, 90, 365);
    }

    function testSetDealDurationLimitsRevertsMinExceedsProtocolMax() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        uint32 protocolMax = spRegistry.MAX_DEAL_DURATION_DAYS();
        vm.prank(adminAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.DurationExceedsProtocolMax.selector, uint32(1279), protocolMax)
        );
        spRegistry.setDealDurationLimits(provider1, 1279, 0);
    }

    function testSetDealDurationLimitsRevertsMaxExceedsProtocolMax() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        uint32 protocolMax = spRegistry.MAX_DEAL_DURATION_DAYS();
        vm.prank(adminAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.DurationExceedsProtocolMax.selector, uint32(1279), protocolMax)
        );
        spRegistry.setDealDurationLimits(provider1, 0, 1279);
    }

    function testRegisterProviderForRevertsMinExceedsProtocolMax() public {
        uint32 protocolMax = spRegistry.MAX_DEAL_DURATION_DAYS();
        vm.prank(adminAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.DurationExceedsProtocolMax.selector, uint32(1279), protocolMax)
        );
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 1279, 0
        );
    }

    function testRegisterProviderForRevertsMaxExceedsProtocolMax() public {
        uint32 protocolMax = spRegistry.MAX_DEAL_DURATION_DAYS();
        vm.prank(adminAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.DurationExceedsProtocolMax.selector, uint32(1279), protocolMax)
        );
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 1279
        );
    }

    function testSetDealDurationLimitsAcceptsProtocolMax() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        vm.prank(adminAddress);
        spRegistry.setDealDurationLimits(provider1, 1278, 1278);

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.minDealDurationDays, 1278);
        assertEq(info.maxDealDurationDays, 1278);
    }

    function testRegisterProviderForAcceptsProtocolMax() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 1278, 1278
        );

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.minDealDurationDays, 1278);
        assertEq(info.maxDealDurationDays, 1278);
    }

    function testSetDealDurationLimitsRevertsProtocolMaxBeforeCrossCheck() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        uint32 protocolMax = spRegistry.MAX_DEAL_DURATION_DAYS();
        vm.prank(adminAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.DurationExceedsProtocolMax.selector, uint32(1279), protocolMax)
        );
        spRegistry.setDealDurationLimits(provider1, 1279, 90);
    }

    function testRegisterProviderForRevertsProtocolMaxBeforeCrossCheck() public {
        uint32 protocolMax = spRegistry.MAX_DEAL_DURATION_DAYS();
        vm.prank(adminAddress);
        vm.expectRevert(
            abi.encodeWithSelector(SPRegistry.DurationExceedsProtocolMax.selector, uint32(1279), protocolMax)
        );
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 1279, 90
        );
    }

    function testSetDealDurationLimitsRevertsUnregistered() public {
        vm.prank(adminAddress);
        vm.expectRevert(abi.encodeWithSelector(SPRegistry.ProviderNotRegistered.selector, provider1));
        spRegistry.setDealDurationLimits(provider1, 90, 365);
    }

    // -----------------------------------------------------------------------
    // getProviderForDeal duration filter tests
    // -----------------------------------------------------------------------

    function testGetProviderForDealSkipsBelowMinDuration() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.setDealDurationLimits(provider1, 180, 0);
        vm.stopPrank();

        SLITypes.DealTerms memory terms =
            SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 90});

        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(SLITypes.SLIThresholds(0, 0, 0, 0), terms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), 0);
    }

    function testGetProviderForDealSkipsAboveMaxDuration() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.setDealDurationLimits(provider1, 0, 180);
        vm.stopPrank();

        SLITypes.DealTerms memory terms =
            SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 360});

        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(SLITypes.SLIThresholds(0, 0, 0, 0), terms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), 0);
    }

    function testGetProviderForDealMatchesExactMinDuration() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.setDealDurationLimits(provider1, 180, 0);
        vm.stopPrank();

        SLITypes.DealTerms memory terms =
            SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 180});

        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(SLITypes.SLIThresholds(0, 0, 0, 0), terms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderForDealMatchesExactMaxDuration() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.setDealDurationLimits(provider1, 0, 360);
        vm.stopPrank();

        SLITypes.DealTerms memory terms =
            SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 360});

        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(SLITypes.SLIThresholds(0, 0, 0, 0), terms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderForDealZeroDurationLimitsMatchAll() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );

        SLITypes.DealTerms memory terms =
            SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 1080});

        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(SLITypes.SLIThresholds(0, 0, 0, 0), terms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderForDealMinOnlyNoUpperBound() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.setDealDurationLimits(provider1, 90, 0);
        vm.stopPrank();

        SLITypes.DealTerms memory terms =
            SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 1080});

        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(SLITypes.SLIThresholds(0, 0, 0, 0), terms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderForDealMaxOnlyNoLowerBound() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.setDealDurationLimits(provider1, 0, 360);
        vm.stopPrank();

        SLITypes.DealTerms memory terms =
            SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 30});

        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(SLITypes.SLIThresholds(0, 0, 0, 0), terms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), CommonTypes.FilActorId.unwrap(provider1));
    }

    function testGetProviderForDealSelectsProviderWithMatchingDuration() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.setDealDurationLimits(provider1, 360, 0);

        spRegistry.registerProviderFor(
            provider2, owner2, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.setDealDurationLimits(provider2, 30, 180);
        vm.stopPrank();

        SLITypes.DealTerms memory terms =
            SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 90});

        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(SLITypes.SLIThresholds(0, 0, 0, 0), terms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), CommonTypes.FilActorId.unwrap(provider2));
    }

    function testGetProviderForDealDurationFilterBeforeEarlyBreak() public {
        vm.startPrank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        spRegistry.setDealDurationLimits(provider1, 360, 0);

        spRegistry.registerProviderFor(
            provider2, owner2, defaultCapabilities, defaultAvailableBytes, 100, address(0), 0, 0
        );
        vm.stopPrank();

        SLITypes.DealTerms memory terms =
            SLITypes.DealTerms({dealSizeBytes: 1_000_000, pricePerSectorPerMonth: 100, durationDays: 90});

        vm.prank(poRepMarketAddress);
        (CommonTypes.FilActorId matched,,) = spRegistry.getProviderForDeal(SLITypes.SLIThresholds(0, 0, 0, 0), terms);
        assertEq(CommonTypes.FilActorId.unwrap(matched), CommonTypes.FilActorId.unwrap(provider2));
    }

    // -----------------------------------------------------------------------
    // getProviderInfo duration limits test
    // -----------------------------------------------------------------------

    function testGetProviderInfoIncludesDurationLimits() public {
        vm.prank(adminAddress);
        spRegistry.registerProviderFor(
            provider1, owner1, defaultCapabilities, defaultAvailableBytes, 100, address(0), 60, 720
        );

        ISPRegistry.ProviderInfo memory info = spRegistry.getProviderInfo(provider1);
        assertEq(info.minDealDurationDays, 60);
        assertEq(info.maxDealDurationDays, 720);
    }
}

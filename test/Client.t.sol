// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Client} from "../src/Client.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {DataCapTypes} from "filecoin-solidity/v0.8/types/DataCapTypes.sol";
import {ActorIdMock} from "./contracts/ActorIdMock.sol";
import {MockProxy} from "./contracts/MockProxy.sol";
import {ResolveAddressPrecompileMock} from "../test/contracts/ResolveAddressPrecompileMock.sol";
import {BuiltInActorForTransferFunctionMock} from "./contracts/BuiltInActorForTransferFunctionMock.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";
import {ValidatorMock} from "./contracts/ValidatorMock.sol";
import {FailingMockInvalidTopLevelArray} from "./contracts/FailingMockInvalidTopLevelArray.sol";
import {FailingMockInvalidFirstElementLength} from "./contracts/FailingMockInvalidFirstElementLength.sol";
import {FailingMockInvalidFirstElementInnerLength} from "./contracts/FailingMockInvalidFirstElementInnerLength.sol";
import {FailingMockInvalidSecondElementLength} from "./contracts/FailingMockInvalidSecondElementLength.sol";
import {FailingMockInvalidSecondElementInnerLength} from "./contracts/FailingMockInvalidSecondElementInnerLength.sol";
import {ActorIdExitCodeErrorFailingMock} from "./contracts/ActorIdExitCodeErrorFailingMock.sol";
import {FailingMockAddVerifiedClient} from "./contracts/FailingMockAddVerifiedClient.sol";
import {AllocationResponseCbor} from "../src/lib/AllocationResponseCbor.sol";
import {ClientContractMock} from "./contracts/ClientContractMock.sol";
import {ReentrantMetaAllocatorMock} from "./contracts/ReentrantMetaAllocatorMock.sol";
import {SLITypes} from "../src/types/SLITypes.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {MetaAllocatorMock} from "./contracts/MetaAllocatorMock.sol";
import {IMetaAllocator} from "../src/interfaces/IMetaAllocator.sol";
import {FilAddresses} from "filecoin-solidity/v0.8/utils/FilAddresses.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";

// solhint-disable max-states-count
contract ClientTest is Test {
    error MissingAllocationId();
    error UnexpectedAllocationId();

    address public constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;
    address public datacapContract = address(0xfF00000000000000000000000000000000000007);
    address public clientAddress;
    address public terminationOracle;
    bytes public transferTo = abi.encodePacked(vm.addr(2));
    uint256 public dealId;
    uint256 public totalDealSize;
    uint256 public pricePerSectorPerMonth;

    CommonTypes.FilActorId public providerFilActorId;
    // solhint-disable var-name-mixedcase
    CommonTypes.FilActorId public SP1 = CommonTypes.FilActorId.wrap(uint64(10000));
    CommonTypes.FilActorId public SP2 = CommonTypes.FilActorId.wrap(uint64(20000));
    // solhint-enable var-name-mixedcase

    Client public client;

    DataCapTypes.TransferParams public transferParams;

    FailingMockInvalidTopLevelArray public failingMockInvalidTopLevelArray;
    FailingMockInvalidFirstElementLength public failingMockInvalidFirstElementLength;
    FailingMockInvalidFirstElementInnerLength public failingMockInvalidFirstElementInnerLength;
    FailingMockInvalidSecondElementLength public failingMockInvalidSecondElementLength;
    FailingMockInvalidSecondElementInnerLength public failingMockInvalidSecondElementInnerLength;
    FailingMockAddVerifiedClient public failingMockAddVerifiedClient;
    BuiltInActorForTransferFunctionMock public builtInActorForTransferFunctionMock;
    ActorIdMock public actorIdMock;
    ResolveAddressPrecompileMock public resolveAddressPrecompileMock;
    PoRepMarketMock public poRepMarketMock;
    ValidatorMock public validatorMock;
    MetaAllocatorMock public metaAllocatorMock;

    ResolveAddressPrecompileMock public resolveAddress =
        ResolveAddressPrecompileMock(payable(0xFE00000000000000000000000000000000000001));

    uint64[] public earlyTerminatedClaims = new uint64[](0);

    string public expectedManifestLocation = "https://example.com/manifest";

    // solhint-disable-next-line function-max-lines
    function setUp() public {
        Client impl = new Client();
        providerFilActorId = CommonTypes.FilActorId.wrap(1);
        clientAddress = address(0x789);
        poRepMarketMock = new PoRepMarketMock();
        validatorMock = new ValidatorMock();
        metaAllocatorMock = new MetaAllocatorMock();
        terminationOracle = vm.addr(3);
        totalDealSize = 103_079_215_104; // 102 GiB
        pricePerSectorPerMonth = 86_400;
        client = Client(setupProxy(address(impl)));
        actorIdMock = new ActorIdMock();
        failingMockInvalidTopLevelArray = new FailingMockInvalidTopLevelArray();
        failingMockInvalidFirstElementLength = new FailingMockInvalidFirstElementLength();
        failingMockInvalidFirstElementInnerLength = new FailingMockInvalidFirstElementInnerLength();
        failingMockInvalidSecondElementLength = new FailingMockInvalidSecondElementLength();
        failingMockInvalidSecondElementInnerLength = new FailingMockInvalidSecondElementInnerLength();
        failingMockAddVerifiedClient = new FailingMockAddVerifiedClient();
        resolveAddressPrecompileMock = new ResolveAddressPrecompileMock();
        builtInActorForTransferFunctionMock = new BuiltInActorForTransferFunctionMock();
        earlyTerminatedClaims.push(1);
        address actorIdProxy = address(new MockProxy(address(5555)));
        vm.etch(CALL_ACTOR_ID, address(actorIdProxy).code);
        vm.etch(address(5555), address(actorIdMock).code);
        actorIdMock = ActorIdMock(payable(address(5555)));
        vm.etch(address(resolveAddress), address(resolveAddressPrecompileMock).code);
        actorIdMock.setGetClaimsResult(
            hex"8282018081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808101");
        // --- Dummy transfer params ---
        transferParams = DataCapTypes.TransferParams({
            to: CommonTypes.FilAddress(transferTo),
            amount: CommonTypes.BigInt({val: hex"DE0B6B3A7640000000", neg: false}),
            // [[[1000, 42(h'000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22'),
            //    2048, 518400, 5256000, 305], [...]], []]
            operator_data: hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710011A005034AC"
        });
        resolveAddress.setId(address(this), uint64(10000));
        resolveAddress.setAddress(hex"00C2A101", uint64(10000));
        dealId = 1;

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({
                    dealSizeBytes: totalDealSize, pricePerSectorPerMonth: pricePerSectorPerMonth, durationDays: 365
                }),
                validator: address(validatorMock),
                state: PoRepTypes.DealState.Accepted,
                railId: 1,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );
        metaAllocatorMock.setAllowance(address(client), uint256(10000));
    }

    function setupProxy(address impl) public returns (address) {
        bytes memory initData = abi.encodeCall(
            Client.initialize, (address(this), terminationOracle, address(poRepMarketMock), address(metaAllocatorMock))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return address(proxy);
    }

    function _registerDealWithOneAllocation(ClientContractMock clientMock) internal {
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));
        actorIdMock.setGetClaimsResult(hex"8282008080");
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808101");
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080";

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);
        poRepMarketMock.setDealState(dealId, PoRepTypes.DealState.Completed);
    }

    function _registerDealWithTwoAllocations(ClientContractMock clientMock) internal {
        metaAllocatorMock.setAllowance(address(clientMock), uint256(20000));
        actorIdMock.setGetClaimsResult(hex"8282008080");
        actorIdMock.setDataCapTransferResult(hex"83410041004A83820180820080820102");
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334086192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221910001A0007E9001A000816001A0050334080";

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);
        poRepMarketMock.setDealState(dealId, PoRepTypes.DealState.Completed);
    }

    function _grantRescueRole(ClientContractMock clientMock, address account) internal {
        vm.prank(address(this));
        clientMock.grantRole(clientMock.RESCUE_ROLE(), account);
    }

    function _rescueParams(bytes memory operatorData, uint256 amount)
        internal
        pure
        returns (DataCapTypes.TransferParams memory params)
    {
        params = DataCapTypes.TransferParams({
            to: FilAddresses.fromActorID(CommonTypes.FilActorId.unwrap(VerifRegTypes.ActorID)),
            amount: CommonTypes.BigInt({val: abi.encodePacked(amount * 1 ether), neg: false}),
            operator_data: operatorData
        });
    }

    function _oneAllocationRescueParams() internal pure returns (DataCapTypes.TransferParams memory params) {
        params = _rescueParams(
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080",
            2048
        );
    }

    function _twoAllocationRescueParams() internal pure returns (DataCapTypes.TransferParams memory params) {
        params = _rescueParams(
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334086192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221910001A0007E9001A000816001A0050334080",
            6144
        );
    }

    function _assertContainsAllocationId(CommonTypes.FilActorId[] memory ids, uint64 expectedId) internal pure {
        for (uint256 i = 0; i < ids.length; i++) {
            if (CommonTypes.FilActorId.unwrap(ids[i]) == expectedId) return;
        }
        revert MissingAllocationId();
    }

    function _assertDoesNotContainAllocationId(CommonTypes.FilActorId[] memory ids, uint64 unexpectedId) internal pure {
        for (uint256 i = 0; i < ids.length; i++) {
            if (CommonTypes.FilActorId.unwrap(ids[i]) == unexpectedId) revert UnexpectedAllocationId();
        }
    }

    function _assertOneAllocationDealUnchanged(ClientContractMock clientMock) internal view {
        CommonTypes.FilActorId[] memory ids = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(ids[0]), 1);

        Client.Deal memory deal = clientMock.getDeal(dealId);
        assertEq(deal.sizeOfAllocations, 2048);
    }

    function testIsAdminSet() public view {
        bytes32 adminRole = client.DEFAULT_ADMIN_ROLE();
        assertTrue(client.hasRole(adminRole, address(this)));
    }

    function testIsTerminationOracleSet() public view {
        bytes32 terminationOracleRole = client.TERMINATION_ORACLE();
        assertTrue(client.hasRole(terminationOracleRole, terminationOracle));
    }

    function testIsRescueRoleSet() public view {
        bytes32 rescueRole = client.RESCUE_ROLE();
        assertTrue(client.hasRole(rescueRole, address(this)));
    }

    function testRescueDealAllocationsRevertsWithoutRescueRole() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);

        address unauthorized = vm.addr(0x523);
        bytes32 rescueRole = clientMock.RESCUE_ROLE();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, rescueRole)
        );
        clientMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());
    }

    function testRescueDealAllocationsRejectsNonCompletedMarketDeal() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));

        PoRepTypes.DealState[3] memory states =
            [PoRepTypes.DealState.Accepted, PoRepTypes.DealState.Rejected, PoRepTypes.DealState.Terminated];
        for (uint256 i = 0; i < states.length; ++i) {
            poRepMarketMock.setDealState(dealId, states[i]);
            vm.expectRevert(abi.encodeWithSelector(Client.InvalidDealStateForTransfer.selector));
            clientMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());
        }
    }

    function testRescueDealAllocationsRejectsUnregisteredLocalDeal() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _grantRescueRole(clientMock, address(this));
        poRepMarketMock.setDealState(dealId, PoRepTypes.DealState.Completed);

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidDealStateForTransfer.selector));
        clientMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());
    }

    function testRescueDealAllocationsRejectsZeroReplacementSize() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22001A0007E9001A000816001A0050334080",
            0
        );

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        clientMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsTooTightReplacementWindow() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000815FF1A0050334080",
            2048
        );

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidClaimWindow.selector, int64(518400), int64(529919)));
        clientMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsExpiredReplacementAllocation() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001903E780",
            2048
        );
        vm.roll(1000);

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        clientMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsPartialReplacement() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithTwoAllocations(clientMock);
        _grantRescueRole(clientMock, address(this));

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        clientMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());
    }

    function testRescueDealAllocationsRejectsMismatchedAmount() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));

        DataCapTypes.TransferParams memory params = _oneAllocationRescueParams();
        params.amount.val = abi.encodePacked(uint256(2049) * 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        clientMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsWrongReceiver() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));

        DataCapTypes.TransferParams memory params = _oneAllocationRescueParams();
        params.to = FilAddresses.fromActorID(12345);

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        clientMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsDifferentReplacementProvider() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828186194E20D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080",
            2048
        );

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidProvider.selector));
        clientMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsClaimExtensions() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710011A005034AC",
            2048
        );

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        clientMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRollsBackWhenDataCapTransferFails() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));
        actorIdMock.setDataCapTransferExitCode(16);

        vm.expectRevert(abi.encodeWithSelector(Client.TransferFailed.selector, int256(16)));
        clientMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());

        _assertOneAllocationDealUnchanged(clientMock);
    }

    function testRescueDealAllocationsRollsBackWhenReturnedAllocationCountIsTooSmall() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));
        actorIdMock.setDataCapTransferResult(hex"8341004100488382018082008080");

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        clientMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());

        _assertOneAllocationDealUnchanged(clientMock);
    }

    function testRescueDealAllocationsRollsBackWhenReturnedAllocationCountIsTooLarge() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));
        actorIdMock.setDataCapTransferResult(hex"83410041004C8382018082008082182A182B");

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        clientMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());

        _assertOneAllocationDealUnchanged(clientMock);
    }

    function testRescueDealAllocationsReplacesTrackedIdsAndPreservesDealIdentity() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithOneAllocation(clientMock);
        _grantRescueRole(clientMock, address(this));
        actorIdMock.setDataCapTransferResult(hex"83410041004A8382018082008081182A");

        clientMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());

        CommonTypes.FilActorId[] memory ids = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(ids[0]), 42);

        Client.Deal memory deal = clientMock.getDeal(dealId);
        assertEq(deal.sizeOfAllocations, 2048);
        assertEq(deal.dealId, dealId);
        assertEq(deal.client, clientAddress);
        assertEq(CommonTypes.FilActorId.unwrap(deal.provider), CommonTypes.FilActorId.unwrap(SP1));
        assertEq(deal.validator, address(validatorMock));
        assertEq(deal.railId, 1);

        (uint64 provider, bytes memory data,,,,) = actorIdMock.lastDataCapTransferAllocation(0);
        assertEq(provider, CommonTypes.FilActorId.unwrap(SP1));
        assertEq(data, hex"000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22");
    }

    function testRescueDealAllocationsReplacesMultipleTrackedIdsAndPreservesAggregateSize() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        _registerDealWithTwoAllocations(clientMock);
        _grantRescueRole(clientMock, address(this));
        actorIdMock.setDataCapTransferResult(hex"83410041004C8382018082008082182A182B");

        clientMock.rescueDealAllocations(dealId, _twoAllocationRescueParams());

        CommonTypes.FilActorId[] memory ids = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 2);
        _assertDoesNotContainAllocationId(ids, 1);
        _assertDoesNotContainAllocationId(ids, 2);
        _assertContainsAllocationId(ids, 42);
        _assertContainsAllocationId(ids, 43);

        Client.Deal memory deal = clientMock.getDeal(dealId);
        assertEq(deal.sizeOfAllocations, 6144);

        (uint64 firstProvider, bytes memory firstData,,,,) = actorIdMock.lastDataCapTransferAllocation(0);
        (uint64 secondProvider, bytes memory secondData,,,,) = actorIdMock.lastDataCapTransferAllocation(1);
        assertEq(firstProvider, CommonTypes.FilActorId.unwrap(SP1));
        assertEq(secondProvider, CommonTypes.FilActorId.unwrap(SP1));
        assertEq(firstData, hex"000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22");
        assertEq(secondData, hex"000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22");
        assertEq(poRepMarketMock.completeDealCallCount(), 0);
    }

    function testAuthorizeUpgradeRevert() public {
        address newImpl = address(new Client());
        address unauthorized = vm.addr(1);
        bytes32 upgraderRole = client.UPGRADER_ROLE();
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, upgraderRole)
        );
        client.upgradeToAndCall(newImpl, "");
    }

    function testShouldAddAllocationsIdsAfterTransfer() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        CommonTypes.FilActorId[] memory clientAllocationIdsBefore = client.getClientAllocationIdsPerDeal(dealId);
        assertEq(clientAllocationIdsBefore.length, 0);

        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710021A005034AC";
        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        CommonTypes.FilActorId[] memory clientAllocationIdsAfter = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(clientAllocationIdsAfter.length, 2);
        assertEq(CommonTypes.FilActorId.unwrap(clientAllocationIdsAfter[0]), 2);
        assertEq(CommonTypes.FilActorId.unwrap(clientAllocationIdsAfter[1]), 1);
    }

    function testInvalidClaimExtensionRequest() public {
        // ClaimRequest length is 2 instead of 3
        transferParams.operator_data = hex"828081821904B001";
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidClaimExtensionRequest.selector));
        client.transfer(transferParams, dealId);
    }

    function testHandleFilecoinMethodExpectRevertInvalidCaller() public {
        bytes memory params =
            hex"821a85223bdf585b861903f3061903f34a006f05b59d3b2000000058458281861903e8d82a5828000181e2039220207dcae81b2a679a3955cc2e4b3504c23ce55b2db5dd2119841ecafa550e53900e1908001a0007e9001a005033401a0002d3028040";
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidCaller.selector, address(this), datacapContract));
        client.handle_filecoin_method(3726118371, 81, params);
    }

    function testHandleFilecoinMethodExpectRevertInvalidTokenReceived() public {
        bytes memory params =
            hex"821A85223BDF585D871903F3061903F34A006F05B59D3B2000000058458281861903E8D82A5828000181E2039220207DCAE81B2A679A3955CC2E4B3504C23CE55B2DB5DD2119841ECAFA550E53900E1908001A0007E9001A005033401A0002D3028040187B";
        vm.prank(datacapContract);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidTokenReceived.selector));
        client.handle_filecoin_method(3726118371, 81, params);
    }

    function testHandleFilecoinMethodExpectRevertUnsupportedType() public {
        bytes memory params =
            hex"821A85223BDE585B861903F3061903F34A006F05B59D3B2000000058458281861903E8D82A5828000181E2039220207DCAE81B2A679A3955CC2E4B3504C23CE55B2DB5DD2119841ECAFA550E53900E1908001A0007E9001A005033401A0002D3028040";
        vm.prank(datacapContract);
        vm.expectRevert(abi.encodeWithSelector(Client.UnsupportedType.selector));
        client.handle_filecoin_method(3726118371, 81, params);
    }

    function testHandleFilecoinMethodForDatacapContract() public {
        bytes memory params =
            hex"821A85223BDF58598607061903F34A006F05B59D3B2000000058458281861903E8D82A5828000181E2039220207DCAE81B2A679A3955CC2E4B3504C23CE55B2DB5DD2119841ECAFA550E53900E1908001A0007E9001A005033401A0002D3028040";
        vm.prank(datacapContract);
        (uint32 exitCode, uint64 codec, bytes memory data) = client.handle_filecoin_method(3726118371, 0x51, params);
        assertEq(exitCode, 0);
        assertEq(codec, 0);
        assertEq(data, "");
    }

    function testHandleFilecoinMethodForVerifregContract() public {
        bytes memory params =
            hex"821A85223BDF58598606061903F34A006F05B59D3B2000000058458281861903E8D82A5828000181E2039220207DCAE81B2A679A3955CC2E4B3504C23CE55B2DB5DD2119841ECAFA550E53900E1908001A0007E9001A005033401A0002D3028040";
        vm.prank(datacapContract);
        (uint32 exitCode, uint64 codec, bytes memory data) = client.handle_filecoin_method(3726118371, 0x51, params);
        assertEq(exitCode, 0);
        assertEq(codec, 0);
        assertEq(data, "");
    }

    function testInvalidOperatorDataLength() public {
        // operator_data == [[]]
        transferParams.operator_data = hex"8180";

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidOperatorData.selector));
        client.transfer(transferParams, dealId);
    }

    function testInvalidAllocationRequest() public {
        // AllocationRequest length is 7 instead of 6
        transferParams.operator_data =
            hex"8282871904B0D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A00503340190131190131861903E8D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013180";

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        client.transfer(transferParams, dealId);
    }

    function testTransferRevertsWhenAllocationClaimWindowIsTooSmall() public {
        // Allocation request:
        // provider = 10000
        // data = existing test CID
        // size = 2048
        // termMin = 518400
        // termMax = 518400 + 11519 (one epoch below the required four-day window)
        // expiration = 5256000
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000815FF1A0050334080";
        actorIdMock.setGetClaimsResult(hex"8282008080");

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidClaimWindow.selector, int64(518400), int64(529919)));
        client.transfer(transferParams, dealId);
    }

    function testTransferRevertsWithInvalidClaimWindowWhenTermMinCannotFitWindow() public {
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001B7FFFFFFFFFFFFFFF1B7FFFFFFFFFFFFFFF1A0050334080";
        actorIdMock.setGetClaimsResult(hex"8282008080");

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidClaimWindow.selector, type(int64).max, type(int64).max));
        client.transfer(transferParams, dealId);
    }

    function testTransferAcceptsAllocationClaimWindowAtMinimum() public {
        // Same allocation as above, but termMax = termMin + 11520.
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080";
        actorIdMock.setGetClaimsResult(hex"8282008080");

        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);

        CommonTypes.FilActorId[] memory ids = client.getClientAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);
    }

    function testTransferRevertsWhenAllocationExpirationIsBeforeCurrentBlock() public {
        // Same valid term window as above, but expiration = 999.
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001903E780";
        actorIdMock.setGetClaimsResult(hex"8282008080");
        vm.roll(1000);

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        client.transfer(transferParams, dealId);
    }

    function testTransferAcceptsAllocationExpirationAtCurrentBlock() public {
        // Same valid term window as above, but expiration = 1000.
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001903E880";
        actorIdMock.setGetClaimsResult(hex"8282008080");
        vm.roll(1000);

        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);

        CommonTypes.FilActorId[] memory ids = client.getClientAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);
    }

    function testClientCanCallTransfer() public {
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
    }

    function testShouldRevertTransferWhenDealIsNotInCorrectState() public {
        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({
                    dealSizeBytes: totalDealSize, pricePerSectorPerMonth: pricePerSectorPerMonth, durationDays: 365
                }),
                validator: address(validatorMock),
                state: PoRepTypes.DealState.Completed,
                railId: 1,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidDealStateForTransfer.selector));
        client.transfer(transferParams, dealId);
    }

    function testVerifregFailIsDetected() public {
        vm.etch(CALL_ACTOR_ID, address(builtInActorForTransferFunctionMock).code);
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.TransferFailed.selector, 1));
        client.transfer(transferParams, dealId);
    }

    function testClaimExtensionNonExistent() public {
        // 0 success_count
        actorIdMock.setGetClaimsResult(hex"8282008080");
        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        vm.expectRevert(Client.GetClaimsCallFailed.selector);
        client.transfer(transferParams, dealId);
    }

    function testClaimExtension() public {
        // params taken directly from `boost extend-deal` message
        // no allocations
        // 1 extension for provider 20000 and claim id 1
        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
    }

    function testClaimExtensionGetClaimsFail() public {
        vm.etch(CALL_ACTOR_ID, address(builtInActorForTransferFunctionMock).code);
        transferParams.operator_data = hex"82808283192710011A005034AC83192710011A005034AC";
        vm.prank(clientAddress);
        vm.expectRevert(Client.GetClaimsCallFailed.selector);
        client.transfer(transferParams, dealId);
    }

    function testTransferDoubleClaimExtension() public {
        transferParams.operator_data = hex"82808283192710011A005034AC83192710011A005034AC";
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidTopLevelArray() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidTopLevelArray).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidTopLevelArray.selector));
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidFirstElementLength() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidFirstElementLength).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidFirstElement.selector));
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidFirstElementInnerLength() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidFirstElementInnerLength).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidFirstElement.selector));
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidSecondElementLength() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidSecondElementLength).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidSecondElement.selector));
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidSecondElementInnerLength() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidSecondElementInnerLength).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidSecondElement.selector));
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
    }

    function testShouldRevertWhenAllocationsContainsDifferentAllocatorIds() public {
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186194E20D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013180";
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidProvider.selector));
        client.transfer(transferParams, dealId);
    }

    function testShouldRevertWhenClaimExtensionsContainsDifferentAllocatorIds() public {
        transferParams.operator_data = hex"82808283192710011A005034AC83194E20011A005034AC";
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidProvider.selector));
        client.transfer(transferParams, dealId);
    }

    function testShouldRevertWhenTransferIsCalledByNotTheClient() public {
        address notTheClient = vm.addr(0x523);
        vm.prank(notTheClient);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidClient.selector));
        client.transfer(transferParams, dealId);
    }

    function testShouldNotOverrideDealWhileReplayingIfAlreadyRegistered() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(1000000));

        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710011A005034AC";

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: 150,
                client: clientAddress,
                provider: SP2,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({
                    dealSizeBytes: totalDealSize, pricePerSectorPerMonth: pricePerSectorPerMonth, durationDays: 365
                }),
                validator: address(validatorMock),
                state: PoRepTypes.DealState.Accepted,
                railId: 1,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );
        vm.prank(clientAddress);
        // solhint-disable-next-line reentrancy
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221950001A0007E9001A009C7E801901318183192710011A005034AC";
        vm.expectEmit(true, true, true, true);
        emit Client.DatacapSpent(clientAddress, 24576);
        clientMock.transfer(transferParams, dealId);

        Client.Deal memory deal = clientMock.getDeal(dealId);
        assertTrue(CommonTypes.FilActorId.unwrap(deal.provider) == CommonTypes.FilActorId.unwrap(SP1));
        assertEq(deal.dealId, dealId);
        assertEq(deal.validator, address(validatorMock));
        assertEq(deal.railId, 1);
        assertEq(deal.client, clientAddress);
    }

    function testReentryAttemptWillThrowInvalidClientError() public {
        ReentrantMetaAllocatorMock reentrantMetaAllocatorMock = new ReentrantMetaAllocatorMock();
        address impl = address(new Client());
        bytes memory initData = abi.encodeCall(
            Client.initialize,
            (address(this), terminationOracle, address(poRepMarketMock), address(reentrantMetaAllocatorMock))
        );
        Client clientWithReentrancy = Client(address(new ERC1967Proxy(address(impl), initData)));

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({
                    dealSizeBytes: totalDealSize, pricePerSectorPerMonth: pricePerSectorPerMonth, durationDays: 365
                }),
                state: PoRepTypes.DealState.Accepted,
                validator: address(validatorMock),
                railId: 1,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );
        reentrantMetaAllocatorMock.setAttackParams(address(clientWithReentrancy), transferParams, dealId);
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidClient.selector));
        clientWithReentrancy.transfer(transferParams, dealId);
    }

    function testShouldAddClaimExtensionIdsAfterTransfer() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(1000000));

        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710031A005034AC";

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: 150,
                client: clientAddress,
                provider: SP1,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({
                    dealSizeBytes: totalDealSize, pricePerSectorPerMonth: pricePerSectorPerMonth, durationDays: 365
                }),
                validator: address(validatorMock),
                state: PoRepTypes.DealState.Accepted,
                railId: 1,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );
        // solhint-disable-next-line reentrancy
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221950001A0007E9001A009C7E801901318183192710041A005034AC";
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808102");
        vm.expectEmit(true, true, true, true);
        emit Client.DatacapSpent(clientAddress, 24576);

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        Client.Deal memory deal = clientMock.getDeal(dealId);
        assertEq(deal.allocationIds.length, 4);
        assertTrue(CommonTypes.FilActorId.unwrap(deal.allocationIds[0]) == 3);
        assertTrue(CommonTypes.FilActorId.unwrap(deal.allocationIds[1]) == 1);
        assertTrue(CommonTypes.FilActorId.unwrap(deal.allocationIds[2]) == 4);
        assertTrue(CommonTypes.FilActorId.unwrap(deal.allocationIds[3]) == 2);
    }

    function testIsDataSizeMatchingHappyPath() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        CommonTypes.FilActorId[] memory ids = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(ids[0]), 1);

        vm.prank(address(validatorMock));
        bool ok = clientMock.isDataSizeMatching(dealId);
        assertTrue(ok);
    }

    function testIsDataSizeMatchingRemovesTerminatedClaimAndReturnsFalse() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        uint64[] memory claims = new uint64[](1);
        claims[0] = 1;

        vm.prank(terminationOracle);
        clientMock.claimsTerminatedEarly(claims);

        CommonTypes.FilActorId[] memory beforeIds = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(beforeIds.length, 1);

        vm.prank(address(validatorMock));
        bool ok = clientMock.isDataSizeMatching(dealId);
        assertTrue(!ok);

        CommonTypes.FilActorId[] memory afterIds = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 0);
    }

    function testIsDataSizeMatchingRemovesExpiredClaimAndReturnsFalse() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));
        transferParams.operator_data = hex"82808183192710011A005034AC";

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        vm.roll(5256407);

        vm.prank(address(validatorMock));
        bool ok = clientMock.isDataSizeMatching(dealId);
        assertTrue(!ok);

        CommonTypes.FilActorId[] memory afterIds = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 0);
    }

    function testIsDataSizeMatchingSkipsFailCodes() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        actorIdMock.setGetClaimsResult(
            hex"8282008182001081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        CommonTypes.FilActorId[] memory beforeIds = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(beforeIds.length, 1);

        vm.prank(address(validatorMock));
        bool ok = clientMock.isDataSizeMatching(dealId);
        assertTrue(!ok);

        CommonTypes.FilActorId[] memory afterIds = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(afterIds[0]), 1);
    }

    function testIsDataSizeMatchingReturnsFalseWhenNoClaimsTracked() public {
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013180";

        vm.prank(clientAddress);
        vm.expectRevert(Client.GetClaimsCallFailed.selector);
        client.transfer(transferParams, dealId);
    }

    function testIsDataSizeMatchingRemovesTerminatedClaimId() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        transferParams.operator_data = hex"82808283192710011A005034AC83192710021A005034AC";
        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        CommonTypes.FilActorId[] memory beforeIds = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(beforeIds.length, 2);

        uint64[] memory claims = new uint64[](1);
        claims[0] = 1;

        vm.prank(terminationOracle);
        clientMock.claimsTerminatedEarly(claims);

        vm.prank(address(validatorMock));
        clientMock.isDataSizeMatching(dealId);

        CommonTypes.FilActorId[] memory afterIds = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(afterIds[0]), 2);
    }

    function testClaimsTerminatedEarlyRevertsWhenNotTerminationOracle() public {
        address notTerminationOracle = vm.addr(4);
        bytes32 expectedRole = client.TERMINATION_ORACLE();
        vm.prank(notTerminationOracle);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notTerminationOracle, expectedRole
            )
        );
        client.claimsTerminatedEarly(earlyTerminatedClaims);
    }

    function testClaimsTerminatedEarlySetCorrectly() public {
        bool isFirstClaimTerminated = client.terminatedClaims(1);
        assertTrue(!isFirstClaimTerminated);
        earlyTerminatedClaims.push(2);
        earlyTerminatedClaims.push(3);
        vm.prank(terminationOracle);
        client.claimsTerminatedEarly(earlyTerminatedClaims);

        isFirstClaimTerminated = client.terminatedClaims(1);
        bool isSecondClaimTerminated = client.terminatedClaims(2);
        bool isThirdClaimTerminated = client.terminatedClaims(3);
        assertTrue(isFirstClaimTerminated);
        assertTrue(isSecondClaimTerminated);
        assertTrue(isThirdClaimTerminated);
        bool isFourthClaimTerminated = client.terminatedClaims(4);
        assertTrue(!isFourthClaimTerminated);
    }

    function testDeleteDealAllocationIdByIndex() public {
        ClientContractMock mock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(mock), uint256(10000));
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710031A005034AC";

        vm.prank(clientAddress);
        mock.transfer(transferParams, dealId);

        CommonTypes.FilActorId[] memory beforeIds = mock.getClientAllocationIdsPerDeal(dealId);
        assertEq(beforeIds.length, 2);
        assertEq(CommonTypes.FilActorId.unwrap(beforeIds[0]), 3);
        assertEq(CommonTypes.FilActorId.unwrap(beforeIds[1]), 1);

        mock.deleteDealAllocationIdByIndex(dealId, 0);

        CommonTypes.FilActorId[] memory afterIds = mock.getClientAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(afterIds[0]), 1);
    }

    function testIsDataSizeMatchingRevertsWhenGetClaimsExitCodeNonZero() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        CommonTypes.FilActorId[] memory ids = clientMock.getClientAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);

        ActorIdExitCodeErrorFailingMock failing = new ActorIdExitCodeErrorFailingMock();
        vm.etch(CALL_ACTOR_ID, address(failing).code);

        vm.expectRevert(Client.GetClaimsCallFailed.selector);
        vm.prank(address(validatorMock));
        clientMock.isDataSizeMatching(dealId);
    }

    function testIsDataSizeMatchingCallerNotValidator() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);

        vm.prank(address(0x123));
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidCaller.selector, address(0x123), address(validatorMock)));
        clientMock.isDataSizeMatching(dealId);
    }

    function testIsDataSizeMatchingDealWithNoValidator() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({
                    dealSizeBytes: totalDealSize, pricePerSectorPerMonth: pricePerSectorPerMonth, durationDays: 365
                }),
                validator: address(0),
                state: PoRepTypes.DealState.Accepted,
                railId: 1,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );

        vm.prank(address(0x123));
        vm.expectRevert(abi.encodeWithSelector(Client.ValidatorNotSet.selector, dealId));
        clientMock.isDataSizeMatching(dealId);
    }

    function testShouldThrowInsufficientAllowance() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));

        transferParams.operator_data = hex"82808183192710011A005034AC";

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(IMetaAllocator.InsufficientAllowance.selector));
        clientMock.transfer(transferParams, dealId);
    }

    function testShouldThrowAmountEqualZero() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22001A0007E9001A009C7E801901318183192710011A005034AC";
        actorIdMock.setGetClaimsResult(
            hex"8282018081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C7638001A003815911A005034D60000"
        );
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        clientMock.transfer(transferParams, dealId);
    }

    function testShouldEmitMetaAllocatorDatacapAllocatedEvent() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));
        metaAllocatorMock.setAllowance(address(clientMock), uint256(10000));

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit IMetaAllocator.DatacapAllocated(
            address(clientMock), FilAddresses.fromEthAddress(address(clientMock)).data, uint256(6144)
        );
        clientMock.transfer(transferParams, dealId);
    }

    function testInitializeRevertsWhenAdminAddressIsZero() public {
        Client impl = new Client();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Client c = Client(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAdminAddress.selector));
        c.initialize(address(0), terminationOracle, address(poRepMarketMock), address(metaAllocatorMock));
    }

    function testInitializeRevertsWhenTerminationOracleIsZero() public {
        Client impl = new Client();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Client c = Client(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidTerminationOracleAddress.selector));
        c.initialize(address(clientAddress), address(0), address(poRepMarketMock), address(metaAllocatorMock));
    }

    function testInitializeRevertsWhenPoRepMarketIsZero() public {
        Client impl = new Client();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Client c = Client(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidPoRepMarketContractAddress.selector));
        c.initialize(address(clientAddress), terminationOracle, address(0), address(metaAllocatorMock));
    }

    function testInitializeRevertsWhenMetaAllocatorIsZero() public {
        Client impl = new Client();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        Client c = Client(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidMetaAllocatorContractAddress.selector));
        c.initialize(address(clientAddress), terminationOracle, address(poRepMarketMock), address(0));
    }

    function testShouldRevertWhenAlreadyRegisteredDealTransferIsCalledByNotTheClient() public {
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);

        address notTheClient = vm.addr(0x523);
        vm.prank(notTheClient);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidClient.selector));
        client.transfer(transferParams, dealId);
    }

    function testTransferEmitsDatacapSpent() public {
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710031A005034AC";

        vm.expectEmit(true, false, false, true);
        emit Client.DatacapSpent(clientAddress, 4096);

        vm.prank(clientAddress);
        client.transfer(transferParams, dealId);
    }

    function testTransferRevertsWhenDealAlreadyCompleted() public {
        vm.startPrank(clientAddress);
        poRepMarketMock.setDealState(dealId, PoRepTypes.DealState.Completed);

        vm.expectRevert(abi.encodeWithSelector(Client.InvalidDealStateForTransfer.selector));
        client.transfer(transferParams, dealId);
        vm.stopPrank();
    }

    function testRegisterDealRailIdNotSetReverts() public {
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710031A005034AC";

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({
                    dealSizeBytes: totalDealSize, pricePerSectorPerMonth: pricePerSectorPerMonth, durationDays: 365
                }),
                validator: address(validatorMock),
                state: PoRepTypes.DealState.Accepted,
                railId: 0,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidRailId.selector));
        client.transfer(transferParams, dealId);
    }

    function testShouldReturnDealAllocatedSize() public {
        ClientContractMock clientMock = ClientContractMock(setupProxy(address(new ClientContractMock())));

        uint256 sizeOfTransfer = 6144;
        metaAllocatorMock.setAllowance(address(clientMock), uint256(sizeOfTransfer * 3));

        // 2 * 2048 from allocations and 2048 from claims
        uint256 sizeOfAllocations;

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);
        sizeOfAllocations = clientMock.getDealSizeOfAllocations(dealId);
        assertEq(sizeOfAllocations, sizeOfTransfer);

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);
        sizeOfAllocations = clientMock.getDealSizeOfAllocations(dealId);
        assertEq(sizeOfAllocations, sizeOfTransfer * 2);

        vm.prank(clientAddress);
        clientMock.transfer(transferParams, dealId);
        sizeOfAllocations = clientMock.getDealSizeOfAllocations(dealId);
        assertEq(sizeOfAllocations, sizeOfTransfer * 3);
    }
}

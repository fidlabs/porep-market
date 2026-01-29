// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Client} from "../src/Client.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {DataCapTypes} from "filecoin-solidity/v0.8/types/DataCapTypes.sol";
import {ActorIdMock} from "./contracts/ActorIdMock.sol";
import {MockProxy} from "./contracts/MockProxy.sol";
import {ResolveAddressPrecompileMock} from "../test/contracts/ResolveAddressPrecompileMock.sol";
import {FilAddressIdConverter} from "filecoin-solidity/v0.8/utils/FilAddressIdConverter.sol";
import {BuiltInActorForTransferFunctionMock} from "./contracts/BuiltInActorForTransferFunctionMock.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ClientContractMock} from "./contracts/ClientContractMock.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";
import {ValidatorMock} from "./contracts/ValidatorMock.sol";
import {FailingMockInvalidTopLevelArray} from "./contracts/FailingMockInvalidTopLevelArray.sol";
import {FailingMockInvalidFirstElementLength} from "./contracts/FailingMockInvalidFirstElementLength.sol";
import {FailingMockInvalidFirstElementInnerLength} from "./contracts/FailingMockInvalidFirstElementInnerLength.sol";
import {FailingMockInvalidSecondElementLength} from "./contracts/FailingMockInvalidSecondElementLength.sol";
import {FailingMockInvalidSecondElementInnerLength} from "./contracts/FailingMockInvalidSecondElementInnerLength.sol";

// solhint-disable max-states-count
contract ClientTest is Test {
    address public constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;
    address public datacapContract = address(0xfF00000000000000000000000000000000000007);
    address public allocator;
    address public clientAddress;
    address public terminationOracle;
    bytes public transferTo = abi.encodePacked(vm.addr(2));
    uint256 dealId;

    CommonTypes.FilActorId public providerFilActorId;
    // solhint-disable-next-line var-name-mixedcase
    CommonTypes.FilActorId public SP1 = CommonTypes.FilActorId.wrap(uint64(10000));

    Client public client;

    DataCapTypes.TransferParams public transferParams;

    FailingMockInvalidTopLevelArray public failingMockInvalidTopLevelArray;
    FailingMockInvalidFirstElementLength public failingMockInvalidFirstElementLength;
    FailingMockInvalidFirstElementInnerLength public failingMockInvalidFirstElementInnerLength;
    FailingMockInvalidSecondElementLength public failingMockInvalidSecondElementLength;
    FailingMockInvalidSecondElementInnerLength public failingMockInvalidSecondElementInnerLength;
    BuiltInActorForTransferFunctionMock public builtInActorForTransferFunctionMock;
    ActorIdMock public actorIdMock;
    ResolveAddressPrecompileMock public resolveAddressPrecompileMock;
    ClientContractMock public clientContractMock;
    PoRepMarketMock public poRepMarketMock;
    ValidatorMock public validatorMock;

    ResolveAddressPrecompileMock public resolveAddress =
        ResolveAddressPrecompileMock(payable(0xFE00000000000000000000000000000000000001));

    uint64[] public earlyTerminatedClaims = new uint64[](0);

    function setUp() public {
        Client impl = new Client();
        allocator = address(0x123);
        providerFilActorId = CommonTypes.FilActorId.wrap(1);
        clientAddress = address(0x789);

        poRepMarketMock = new PoRepMarketMock();
        validatorMock = new ValidatorMock();
        terminationOracle = vm.addr(3);
        // solhint-disable-next-line gas-small-strings
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)", address(this), allocator, terminationOracle, poRepMarketMock
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        client = Client(address(proxy));
        clientContractMock = new ClientContractMock();
        actorIdMock = new ActorIdMock();
        // failingMockInvalidTopLevelArray = new FailingMockInvalidTopLevelArray();
        // failingMockInvalidFirstElementLength = new FailingMockInvalidFirstElementLength();
        // failingMockInvalidFirstElementInnerLength = new FailingMockInvalidFirstElementInnerLength();
        // failingMockInvalidSecondElementLength = new FailingMockInvalidSecondElementLength();
        // failingMockInvalidSecondElementInnerLength = new FailingMockInvalidSecondElementInnerLength();
        resolveAddressPrecompileMock = new ResolveAddressPrecompileMock();
        // resolveAddressPrecompileFailingMock = new ResolveAddressPrecompileFailingMock();
        builtInActorForTransferFunctionMock = new BuiltInActorForTransferFunctionMock();
        earlyTerminatedClaims.push(1);
        address actorIdProxy = address(new MockProxy(address(5555)));
        vm.etch(CALL_ACTOR_ID, address(actorIdProxy).code);
        vm.etch(address(5555), address(actorIdMock).code);
        actorIdMock = ActorIdMock(payable(address(5555)));
        vm.etch(address(resolveAddress), address(resolveAddressPrecompileMock).code);
        actorIdMock.setGetClaimsResult(
            hex"8282018081881927101866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        // --- Dummy transfer params ---
        transferParams = DataCapTypes.TransferParams({
            to: CommonTypes.FilAddress(transferTo),
            amount: CommonTypes.BigInt({val: hex"DE0B6B3A7640000000", neg: false}),
            // [[[10000, 42(h'000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22'),
            //    2048, 518400, 5256000, 305], [...]], []]
            operator_data: hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013180"
        });
        resolveAddress.setId(address(this), uint64(10000));
        resolveAddress.setAddress(hex"00C2A101", uint64(10000));

        dealId = 1;
        poRepMarketMock.setDealProposal(
            dealId,
            PoRepMarket.DealProposal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                SLC: vm.addr(0x001),
                validator: address(validatorMock),
                state: PoRepMarket.DealState.Proposed,
                railId: 0
            })
        );
    }

    function testIsAdminSet() public view {
        bytes32 adminRole = client.DEFAULT_ADMIN_ROLE();
        assertTrue(client.hasRole(adminRole, address(this)));
    }

    function testIsAllocatorSet() public view {
        bytes32 allocatorRole = client.ALLOCATOR_ROLE();
        assertTrue(client.hasRole(allocatorRole, allocator));
    }

    function testIsTerminationOracleSet() public view {
        bytes32 terminationOracleRole = client.TERMINATION_ORACLE();
        assertTrue(client.hasRole(terminationOracleRole, terminationOracle));
    }

    function testIncreaseAndDecreaseAllowance() public {
        uint256 amount = 100;
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, providerFilActorId, amount);
        assertEq(client.getAllowance(clientAddress, providerFilActorId), amount);

        vm.prank(allocator);
        client.decreaseAllowance(clientAddress, providerFilActorId, amount);
        assertEq(client.getAllowance(clientAddress, providerFilActorId), 0);
    }

    function testAllowanceChangedEventEmittedForIncreaseAllowance() public {
        uint256 amount = 100;
        vm.prank(allocator);
        vm.expectEmit(true, true, true, true);

        emit Client.AllowanceChanged(clientAddress, providerFilActorId, 0, amount);
        client.increaseAllowance(clientAddress, providerFilActorId, amount);
    }

    function testAllowanceChangedEventEmittedForDecreaseAllowance() public {
        uint256 initialAllowance = 200;
        uint256 amount = 100;
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, providerFilActorId, initialAllowance);

        vm.prank(allocator);
        vm.expectEmit(true, true, true, true);

        emit Client.AllowanceChanged(clientAddress, providerFilActorId, initialAllowance, initialAllowance - amount);
        client.decreaseAllowance(clientAddress, providerFilActorId, amount);
    }

    function testDecreaseAllowanceShouldSetAllowanceToZero() public {
        uint256 initialAllowance = 100;
        uint256 amount = 200;
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, providerFilActorId, initialAllowance);

        vm.prank(allocator);
        client.decreaseAllowance(clientAddress, providerFilActorId, amount);
        assertEq(client.getAllowance(clientAddress, providerFilActorId), 0);
    }

    function testRevertsWhenAmountIsZeroForIncreaseAllowance() public {
        vm.prank(allocator);
        vm.expectRevert(Client.AmountEqualsZero.selector);
        client.increaseAllowance(clientAddress, providerFilActorId, 0);
    }

    function testRevertsWhenAmountIsZeroForDecreaseAllowance() public {
        vm.prank(allocator);
        vm.expectRevert(Client.AmountEqualsZero.selector);
        client.decreaseAllowance(clientAddress, providerFilActorId, 0);
    }

    function testRevertsWhenAllowanceIsZeroForDecreaseAllowance() public {
        vm.prank(allocator);
        vm.expectRevert(Client.AlreadyZero.selector);
        client.decreaseAllowance(clientAddress, providerFilActorId, 100);
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

    function testInvalidClaimExtensionRequest() public {
        // ClaimRequest length is 2 instead of 3
        transferParams.operator_data = hex"828081821904B001";
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidClaimExtensionRequest.selector));
        client.transfer(transferParams, dealId, false);
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

    function testTransferRevertInvalidAmount() public {
        transferParams = DataCapTypes.TransferParams({
            to: CommonTypes.FilAddress(transferTo),
            amount: CommonTypes.BigInt({
                val: hex"010000000000000000000000000000000000000000000000000000000000000000", neg: false
            }),
            operator_data: hex"8282861903E8D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A00503340190131861903E8D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013180"
        });
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAmount.selector));
        client.transfer(transferParams, dealId, false);
    }

    function testInvalidOperatorDataLength() public {
        // operator_data == [[]]
        transferParams.operator_data = hex"8180";

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidOperatorData.selector));
        client.transfer(transferParams, dealId, false);
    }

    function testInvalidAllocationRequest() public {
        // AllocationRequest length is 7 instead of 6
        transferParams.operator_data =
            hex"8282871904B0D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A00503340190131190131861903E8D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013180";

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InvalidAllocationRequest.selector));
        client.transfer(transferParams, dealId, false);
    }

    function testTransferRevertInsufficientAllowance() public {
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InsufficientAllowance.selector));
        client.transfer(transferParams, dealId, false);
    }

    function testClientCanCallTransfer() public {
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, SP1, 4096);
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId, false);
    }

    function testVerifregFailIsDetected() public {
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, SP1, 4096);
        vm.etch(CALL_ACTOR_ID, address(builtInActorForTransferFunctionMock).code);
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.TransferFailed.selector, 1));
        client.transfer(transferParams, dealId, false);
    }

    function testCheckAllowanceAfterTransfer() public {
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, SP1, 4096);
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId, false);
        assertEq(client.getAllowance(clientAddress, SP1), 0);
    }

    function testClaimExtensionNonExistent() public {
        // 0 success_count
        actorIdMock.setGetClaimsResult(hex"8282008080");
        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        vm.expectRevert(Client.GetClaimsCallFailed.selector);
        client.transfer(transferParams, dealId, false);
    }

    function testClaimExtensionn() public {
        // params taken directly from `boost extend-deal` message
        // no allocations
        // 1 extension for provider 20000 and claim id 1
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, SP1, 4096);
        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId, false);
    }

    function testTransferRevertInsufficientAllowanceForClaims() public {
        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(Client.InsufficientAllowance.selector));
        client.transfer(transferParams, dealId, false);
    }

    function testClaimExtensionGetClaimsFail() public {
        vm.etch(CALL_ACTOR_ID, address(builtInActorForTransferFunctionMock).code);
        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        vm.expectRevert(Client.GetClaimsCallFailed.selector);
        client.transfer(transferParams, dealId, false);
    }

    function testTransferDoubleClaimExtension() public {
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, SP1, 4096);
        transferParams.operator_data = hex"82808283192710011A005034AC83194E20011A005034AC";
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId, false);
        assertEq(client.getAllowance(clientAddress, SP1), 0);
    }

    function testClaimExtensionDecreaseAllowance() public {
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, SP1, 4096);
        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        client.transfer(transferParams, dealId, false);
        assertEq(client.getAllowance(clientAddress, SP1), 2048);
    }

    function testSPClientsMappingUpdateAllocations() public {
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, SP1, 4096);

        Client.ClientDataUsage[] memory beforeTransfer = client.getSPClientsDataUsage(SP1);
        assertEq(beforeTransfer.length, 0);

        vm.prank(clientAddress);
        client.transfer(transferParams, dealId, false);

        Client.ClientDataUsage[] memory afterTransfer = client.getSPClientsDataUsage(SP1);
        assertEq(afterTransfer.length, 1);
        assertEq(afterTransfer[0].client, clientAddress);
        assertEq(afterTransfer[0].usage, 4096);
    }

    function testSPClientsMappingUpdateForClaimExtension() public {
        vm.prank(allocator);
        client.increaseAllowance(clientAddress, SP1, 4096);

        transferParams.operator_data = hex"82808183192710011A005034AC";
        Client.ClientDataUsage[] memory beforeTransfer = client.getSPClientsDataUsage(SP1);
        assertEq(beforeTransfer.length, 0);

        vm.prank(clientAddress);
        client.transfer(transferParams, dealId, false);

        Client.ClientDataUsage[] memory afterTransfer = client.getSPClientsDataUsage(SP1);
        assertEq(afterTransfer.length, 1);
        assertEq(afterTransfer[0].client, clientAddress);
        assertEq(afterTransfer[0].usage, 2048);
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
        bool isFirstClaimTerminated = client.getTerminatedClaim(1);
        assertTrue(!isFirstClaimTerminated);
        earlyTerminatedClaims.push(2);
        earlyTerminatedClaims.push(3);
        vm.prank(terminationOracle);
        client.claimsTerminatedEarly(earlyTerminatedClaims);    

        isFirstClaimTerminated = client.getTerminatedClaim(1);
        bool isSecondClaimTerminated = client.getTerminatedClaim(2);
        bool isThirdClaimTerminated = client.getTerminatedClaim(3);
        assertTrue(isFirstClaimTerminated);
        assertTrue(isSecondClaimTerminated);
        assertTrue(isThirdClaimTerminated);
        bool isFourthClaimTerminated = client.getTerminatedClaim(4);
        assertTrue(!isFourthClaimTerminated);
    }

    function testGetClientSpActiveDataSizeRevertGetClaimsCallFailed() public {
        vm.etch(CALL_ACTOR_ID, address(builtInActorForTransferFunctionMock).code);
        vm.expectRevert(Client.GetClaimsCallFailed.selector);
        client.getClientSpActiveDataSize(clientAddress, SP1);
    }

    function testGetClientSpActiveDataSizeWithFaileCode() public {
        actorIdMock.setGetClaimsResult(
            hex"8282008182001081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 1);
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 2);
        uint256 size = clientContractMock.getClientSpActiveDataSize(clientAddress, SP1);
        assertEq(size, 2048);
    }

    function testGetClientSpActiveDataDeleteAllocationInTerminatedSector() public {
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 1);
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 2);
        CommonTypes.FilActorId[] memory clientAllocationIdsBefore =
            clientContractMock.getClientAllocationIds(SP1, clientAddress);
        assertEq(clientAllocationIdsBefore.length, 2);
        clientContractMock.addTerminatedClaims(1);
        clientContractMock.getClientSpActiveDataSize(clientAddress, SP1);
        CommonTypes.FilActorId[] memory clientAllocationIdsAfter =
            clientContractMock.getClientAllocationIds(SP1, clientAddress);
        assertEq(clientAllocationIdsAfter.length, 1);
    }

    function testGetClientSpActiveDataDeleteExpiredAllocation() public {
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 1);
        CommonTypes.FilActorId[] memory clientAllocationIdsBefore =
            clientContractMock.getClientAllocationIds(SP1, clientAddress);
        assertEq(clientAllocationIdsBefore.length, 1);
        vm.roll(5256407); // after allocation expiry
        clientContractMock.getClientSpActiveDataSize(clientAddress, SP1);
        CommonTypes.FilActorId[] memory clientAllocationIdsAfter =
            clientContractMock.getClientAllocationIds(SP1, clientAddress);
        assertEq(clientAllocationIdsAfter.length, 0);
    }

    function testDeleteAllocationIdByValueRevertAllocationNotFound() public {
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 1);
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 2);
        vm.expectRevert(abi.encodeWithSelector(Client.AllocationNotFound.selector, 10000, clientAddress, 3));
        clientContractMock.deleteAllocationIdByValue(SP1, clientAddress, 3);
    }

    function testDeleteAllocationIdByValue() public {
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 1);
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 2);
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 3);
        clientContractMock.deleteAllocationIdByValue(SP1, clientAddress, 2);
        CommonTypes.FilActorId[] memory clientAllocationIdsAfter =
            clientContractMock.getClientAllocationIds(SP1, clientAddress);
        assertEq(clientAllocationIdsAfter.length, 2);
        assertEq(CommonTypes.FilActorId.unwrap(clientAllocationIdsAfter[0]), 1);
        assertEq(CommonTypes.FilActorId.unwrap(clientAllocationIdsAfter[1]), 3);
    }

    function testGetSPClients() public {
        address secondClientAddress = vm.addr(5);
        clientContractMock.setSpClients(SP1, clientAddress, 4096);
        clientContractMock.setSpClients(SP1, secondClientAddress, 2048);
        address[] memory spClients = clientContractMock.getSPClients(SP1);
        assertEq(spClients.length, 2);
        assertEq(spClients[0], clientAddress);
        assertEq(spClients[1], secondClientAddress);
    }

    // function testDecodeAllocationResponseRevertInvalidTopLevelArray() public {
    //     vm.etch(CALL_ACTOR_ID, address(failingMockInvalidTopLevelArray).code);
    //     vm.prank(allocator);
    //     client.increaseAllowance(clientAddress, SP1, 4096);
    //     vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidTopLevelArray.selector));
    //     vm.prank(clientAddress);
    //     client.transfer(transferParams, dealId, false);
    // }

    // function testDecodeAllocationResponseRevertInvalidFirstElementLength() public {
    //     vm.etch(CALL_ACTOR_ID, address(failingMockInvalidFirstElementLength).code);
    //     vm.prank(allocator);
    //     client.increaseAllowance(clientAddress, SP1, 4096);
    //     vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidFirstElement.selector));
    //     vm.prank(clientAddress);
    //     client.transfer(transferParams, dealId, false);
    // }

    // function testDecodeAllocationResponseRevertInvalidFirstElementInnerLength() public {
    //     vm.etch(CALL_ACTOR_ID, address(failingMockInvalidFirstElementInnerLength).code);
    //     vm.prank(allocator);
    //     client.increaseAllowance(clientAddress, SP1, 4096);
    //     vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidFirstElement.selector));
    //     vm.prank(clientAddress);
    //     client.transfer(transferParams, dealId, false);
    // }

    // function testDecodeAllocationResponseRevertInvalidSecondElementLength() public {
    //     vm.etch(CALL_ACTOR_ID, address(failingMockInvalidSecondElementLength).code);
    //     vm.prank(allocator);
    //     client.increaseAllowance(clientAddress, SP1, 4096);
    //     vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidSecondElement.selector));
    //     vm.prank(clientAddress);
    //     client.transfer(transferParams, dealId, false);
    // }

    // function testDecodeAllocationResponseRevertInvalidSecondElementInnerLength() public {
    //     vm.etch(CALL_ACTOR_ID, address(failingMockInvalidSecondElementInnerLength).code);
    //     vm.prank(allocator);
    //     client.increaseAllowance(clientAddress, SP1, 4096);
    //     vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidSecondElement.selector));
    //     vm.prank(clientAddress);
    //     client.transfer(transferParams, dealId, false);
    // }

    function testShouldReturnAllocationsIdWithCustomGetter() public {
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 1);
        clientContractMock.addClientAllocationIds(SP1, clientAddress, 2);

        CommonTypes.FilActorId[] memory ids = clientContractMock.getClientAllocationIdsPerProvider(SP1, clientAddress);
        assertEq(ids.length, 2);
        assertEq(CommonTypes.FilActorId.unwrap(ids[0]), 1);
        assertEq(CommonTypes.FilActorId.unwrap(ids[1]), 2);
    }
}

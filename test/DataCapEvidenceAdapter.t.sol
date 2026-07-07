// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {DataCapEvidenceAdapter} from "../src/DataCapEvidenceAdapter.sol";

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
import {DataCapEvidenceAdapterContractMock} from "./contracts/DataCapEvidenceAdapterContractMock.sol";
import {ReentrantMetaAllocatorMock} from "./contracts/ReentrantMetaAllocatorMock.sol";
import {SharedTypes} from "../src/types/SharedTypes.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {DealState} from "../src/types/DealState.sol";
import {DataCapAllocationStatus} from "../src/types/DataCapAllocationStatus.sol";
import {EvidenceResult} from "../src/types/EvidenceResult.sol";
import {MetaAllocatorMock} from "./contracts/MetaAllocatorMock.sol";
import {IMetaAllocator} from "../src/interfaces/IMetaAllocator.sol";
import {FilAddresses} from "filecoin-solidity/v0.8/utils/FilAddresses.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";
import {EvidenceTypes} from "../src/types/EvidenceTypes.sol";

// solhint-disable max-states-count
contract DataCapEvidenceAdapterTest is Test {
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

    DataCapEvidenceAdapter public dataCapEvidenceAdapter;

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
        DataCapEvidenceAdapter impl = new DataCapEvidenceAdapter();
        providerFilActorId = CommonTypes.FilActorId.wrap(1);
        clientAddress = address(0x789);
        poRepMarketMock = new PoRepMarketMock();
        validatorMock = new ValidatorMock();
        metaAllocatorMock = new MetaAllocatorMock();
        terminationOracle = vm.addr(3);
        totalDealSize = 103_079_215_104; // 96 GiB
        pricePerSectorPerMonth = 86_400;
        dataCapEvidenceAdapter = DataCapEvidenceAdapter(setupProxy(address(impl)));
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

        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                offerId: 0,
                validator: address(validatorMock),
                state: DealState.ACCEPTED,
                railId: 1,
                evidenceAdapter: address(dataCapEvidenceAdapter)
            })
        );
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapter), uint256(10000));
    }

    function setupProxy(address impl) public returns (address) {
        bytes memory initData = abi.encodeCall(
            DataCapEvidenceAdapter.initialize,
            (address(this), terminationOracle, address(poRepMarketMock), address(metaAllocatorMock))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return address(proxy);
    }

    function _registerDealWithOneAllocation(DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock) internal {
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));
        actorIdMock.setGetClaimsResult(hex"8282008080");
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808101");
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080";

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);
        poRepMarketMock.setDealState(dealId, DealState.ACTIVE);
    }

    function _registerDealWithTwoAllocations(DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock) internal {
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(20000));
        actorIdMock.setGetClaimsResult(hex"8282008080");
        actorIdMock.setDataCapTransferResult(hex"83410041004A83820180820080820102");
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334086192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221910001A0007E9001A000816001A0050334080";

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);
        poRepMarketMock.setDealState(dealId, DealState.ACTIVE);
    }

    function _finishPosting(DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock) internal {
        poRepMarketMock.setDealState(dealId, DealState.ACCEPTED);
        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.finishDataCapPosting(dealId);
        poRepMarketMock.setDealState(dealId, DealState.ACTIVE);
    }

    function _grantRescueRole(DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock, address account) internal {
        vm.prank(address(this));
        dataCapEvidenceAdapterMock.grantRole(dataCapEvidenceAdapterMock.RESCUE_ROLE(), account);
    }

    function _activationContext() internal pure returns (SharedTypes.ActivationContext memory context) {
        context = SharedTypes.ActivationContext({
            dealId: 1,
            requestedSizeBytes: 0,
            client: address(0x789),
            durationEpochs: 0,
            activationToleranceBps: 0,
            provider: CommonTypes.FilActorId.wrap(1)
        });
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

    function _assertOneAllocationDealUnchanged(DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock)
        internal
        view
    {
        CommonTypes.FilActorId[] memory ids = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(ids[0]), 1);

        DataCapEvidenceAdapter.DataCapDealEvidence memory dealEvidence = dataCapEvidenceAdapterMock.getDeal(dealId);
        assertEq(dealEvidence.allocatedBytes, 2048);
    }

    function testIsAdminSet() public view {
        bytes32 adminRole = dataCapEvidenceAdapter.DEFAULT_ADMIN_ROLE();
        assertTrue(dataCapEvidenceAdapter.hasRole(adminRole, address(this)));
    }

    function testIsTerminationOracleSet() public view {
        bytes32 terminationOracleRole = dataCapEvidenceAdapter.TERMINATION_ORACLE();
        assertTrue(dataCapEvidenceAdapter.hasRole(terminationOracleRole, terminationOracle));
    }

    function testIsRescueRoleSet() public view {
        bytes32 rescueRole = dataCapEvidenceAdapter.RESCUE_ROLE();
        assertTrue(dataCapEvidenceAdapter.hasRole(rescueRole, address(this)));
    }

    function testDataCapEvidenceAdapterEvidenceType() public view {
        assertEq(dataCapEvidenceAdapter.evidenceType(), EvidenceTypes.VERIF_REG_CLAIMS);
    }

    function testSubmitEvidenceBatchMovesAllClaimedAllocations() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        assertEq(mock.getDealAllocationStatus(dealId), DataCapAllocationStatus.ALLOCATED);
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        vm.prank(address(poRepMarketMock));
        SharedTypes.ActivationDecision memory decision =
            mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        assertEq(decision.coveredBytes, 4096);
        assertEq(decision.reasonCode, 0);
        assertEq(decision.result, EvidenceResult.ACCEPTED);
        assertEq(mock.getDeal(dealId).claimedBytes, 4096);

        assertEq(mock.getAllAllocationIdsPerDeal(dealId).length, 0);
        assertEq(mock.getDealAllocationStatus(dealId), DataCapAllocationStatus.CLAIMED);

        (CommonTypes.FilActorId[] memory claimIds, uint256 total) = mock.getClaimIds(dealId, 0, type(uint256).max);
        assertEq(total, 2);
        _assertContainsAllocationId(claimIds, 1);
        _assertContainsAllocationId(claimIds, 2);
    }

    function testSubmitEvidenceBatchLeavesUnclaimedAllocations() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        actorIdMock.setGetClaimsResult(
            hex"8282018182000681881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        vm.prank(address(poRepMarketMock));
        SharedTypes.ActivationDecision memory decision =
            mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        assertEq(decision.coveredBytes, 2048);
        assertEq(decision.result, EvidenceResult.PARTIAL);
        assertEq(mock.getDeal(dealId).claimedBytes, 2048);

        CommonTypes.FilActorId[] memory remaining = mock.getAllAllocationIdsPerDeal(dealId);
        assertEq(remaining.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(remaining[0]), 1);
        assertEq(mock.getDealAllocationStatus(dealId), DataCapAllocationStatus.ALLOCATED);

        (CommonTypes.FilActorId[] memory claimIds, uint256 total) = mock.getClaimIds(dealId, 0, type(uint256).max);
        assertEq(total, 1);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[0]), 2);
    }

    function testSubmitEvidenceBatchMovesNothingWhenNoneClaimed() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        actorIdMock.setGetClaimsResult(hex"8282008282000682010680");

        vm.prank(address(poRepMarketMock));
        SharedTypes.ActivationDecision memory decision =
            mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        assertEq(decision.coveredBytes, 0);
        assertEq(decision.result, EvidenceResult.NONE);
        assertEq(mock.getDeal(dealId).claimedBytes, 0);
        assertEq(mock.getAllAllocationIdsPerDeal(dealId).length, 2);
        assertEq(mock.getDealAllocationStatus(dealId), DataCapAllocationStatus.ALLOCATED);

        (, uint256 total) = mock.getClaimIds(dealId, 0, type(uint256).max);
        assertEq(total, 0);
    }

    function testSubmitEvidenceBatchRespectsBatchSizeAcrossCalls() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        bytes memory singleClaim =
            hex"8282018081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000";

        actorIdMock.setGetClaimsResult(singleClaim);
        vm.prank(address(poRepMarketMock));
        SharedTypes.ActivationDecision memory first =
            mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(1)));
        assertEq(first.coveredBytes, 2048);
        assertEq(mock.getAllAllocationIdsPerDeal(dealId).length, 1);
        assertEq(mock.getDeal(dealId).claimedBytes, 2048);
        (, uint256 claimedAfterFirst) = mock.getClaimIds(dealId, 0, type(uint256).max);
        assertEq(claimedAfterFirst, 1);
        assertEq(mock.getDealAllocationStatus(dealId), DataCapAllocationStatus.ALLOCATED);

        actorIdMock.setGetClaimsResult(singleClaim);
        vm.prank(address(poRepMarketMock));
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(1)));
        assertEq(mock.getAllAllocationIdsPerDeal(dealId).length, 0);
        assertEq(mock.getDeal(dealId).claimedBytes, 4096);
        (, uint256 claimedAfterSecond) = mock.getClaimIds(dealId, 0, type(uint256).max);
        assertEq(claimedAfterSecond, 2);
        assertEq(mock.getDealAllocationStatus(dealId), DataCapAllocationStatus.CLAIMED);
    }

    function testSubmitEvidenceBatchRevertsWhenBatchSizeIsZero() public {
        vm.prank(address(poRepMarketMock));
        vm.expectRevert(DataCapEvidenceAdapter.InvalidBatchSize.selector);
        dataCapEvidenceAdapter.submitEvidenceBatch(_activationContext(), abi.encode(uint256(0)));
    }

    function testSubmitEvidenceBatchRevertsWhenCallerIsNotPoRepMarket() public {
        vm.expectRevert(DataCapEvidenceAdapter.CallerIsNotPoRepMarket.selector);
        dataCapEvidenceAdapter.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));
    }

    function testSubmitEvidenceBatchRevertsWhenGetClaimsExitCodeNonZero() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);

        ActorIdExitCodeErrorFailingMock failing = new ActorIdExitCodeErrorFailingMock();
        vm.etch(CALL_ACTOR_ID, address(failing).code);

        vm.prank(address(poRepMarketMock));
        vm.expectRevert(DataCapEvidenceAdapter.GetClaimsCallFailed.selector);
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));
    }

    function testRefreshEvidenceStatusReturnsDummyStatus() public view {
        SharedTypes.EvidenceStatus memory status =
            dataCapEvidenceAdapter.refreshEvidenceStatus(_activationContext(), "");

        assertEq(status.activeCoveredBytes, 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(status.lastEvidenceRefreshEpoch), 0);
        assertEq(status.reasonCode, 0);
        assertEq(status.result, 0);
    }

    function testCurrentEvidenceStatusReturnsDummyStatus() public view {
        SharedTypes.EvidenceStatus memory status = dataCapEvidenceAdapter.currentEvidenceStatus(_activationContext());

        assertEq(status.activeCoveredBytes, 0);
        assertEq(CommonTypes.ChainEpoch.unwrap(status.lastEvidenceRefreshEpoch), 0);
        assertEq(status.reasonCode, 0);
        assertEq(status.result, 0);
    }

    function testGetAllocationIdsPerDealPaginates() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(dataCapEvidenceAdapterMock);

        (CommonTypes.FilActorId[] memory firstPage, uint256 sumOfAllocations) =
            dataCapEvidenceAdapterMock.getAllocationIdsPerDeal(dealId, 0, 1);
        assertEq(sumOfAllocations, 2);
        assertEq(firstPage.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(firstPage[0]), 1);

        (CommonTypes.FilActorId[] memory secondPage,) = dataCapEvidenceAdapterMock.getAllocationIdsPerDeal(dealId, 1, 2);
        assertEq(secondPage.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(secondPage[0]), 2);

        (CommonTypes.FilActorId[] memory emptyPage, uint256 emptyTotal) =
            dataCapEvidenceAdapterMock.getAllocationIdsPerDeal(dealId, 2, 1);
        assertEq(emptyTotal, 2);
        assertEq(emptyPage.length, 0);
    }

    function testGetAllocationIdsPerDealRevertsWhenLimitIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidLimit.selector));
        dataCapEvidenceAdapter.getAllocationIdsPerDeal(dealId, 0, 0);
    }

    function testGetAllocationIdsPerDealRevertsWhenDealIdIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidDealId.selector));
        dataCapEvidenceAdapter.getAllocationIdsPerDeal(0, 0, 1);
    }

    function testRescueDealAllocationsRevertsWithoutRescueRole() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);

        address unauthorized = vm.addr(0x523);
        bytes32 rescueRole = dataCapEvidenceAdapterMock.RESCUE_ROLE();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, rescueRole)
        );
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());
    }

    function testRescueDealAllocationsRejectsNonActiveMarketDeal() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        uint8[3] memory states = [DealState.ACCEPTED, DealState.REJECTED, DealState.TERMINATED];
        for (uint256 i = 0; i < states.length; ++i) {
            poRepMarketMock.setDealState(dealId, states[i]);
            vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidDealStateForTransfer.selector));
            dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());
        }
    }

    function testRescueDealAllocationsRejectsUnregisteredLocalDeal() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));
        poRepMarketMock.setDealState(dealId, DealState.ACTIVE);

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidDealStateForTransfer.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());
    }

    function testRescueDealAllocationsRejectsZeroReplacementSize() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22001A0007E9001A000816001A0050334080",
            0
        );

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsTooTightReplacementWindow() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000815FF1A0050334080",
            2048
        );

        vm.expectRevert(
            abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidClaimWindow.selector, int64(518400), int64(529919))
        );
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsExpiredReplacementAllocation() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001903E780",
            2048
        );
        vm.roll(1000);

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsPartialReplacement() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());
    }

    function testRescueDealAllocationsRejectsMismatchedAmount() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        DataCapTypes.TransferParams memory params = _oneAllocationRescueParams();
        params.amount.val = abi.encodePacked(uint256(2049) * 1 ether);

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsWrongReceiver() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        DataCapTypes.TransferParams memory params = _oneAllocationRescueParams();
        params.to = FilAddresses.fromActorID(12345);

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsDifferentReplacementProvider() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828186194E20D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080",
            2048
        );

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidProvider.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsClaimExtensions() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710011A005034AC",
            2048
        );

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRejectsNegativeValue() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        DataCapTypes.TransferParams memory params = DataCapTypes.TransferParams({
            to: FilAddresses.fromActorID(CommonTypes.FilActorId.unwrap(VerifRegTypes.ActorID)),
            amount: CommonTypes.BigInt({val: abi.encodePacked(uint256(2048) * 1 ether), neg: true}),
            operator_data: hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710011A005034AC"
        });

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, params);
    }

    function testRescueDealAllocationsRollsBackWhenDataCapTransferFails() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));
        actorIdMock.setDataCapTransferExitCode(16);

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.TransferFailed.selector, int256(16)));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());

        _assertOneAllocationDealUnchanged(dataCapEvidenceAdapterMock);
    }

    function testRescueDealAllocationsRollsBackWhenReturnedAllocationCountIsTooSmall() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));
        actorIdMock.setDataCapTransferResult(hex"8341004100488382018082008080");

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());

        _assertOneAllocationDealUnchanged(dataCapEvidenceAdapterMock);
    }

    function testRescueDealAllocationsRollsBackWhenReturnedAllocationCountIsTooLarge() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));
        actorIdMock.setDataCapTransferResult(hex"83410041004C8382018082008082182A182B");

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());

        _assertOneAllocationDealUnchanged(dataCapEvidenceAdapterMock);
    }

    function testRescueDealAllocationsReplacesTrackedIdsAndPreservesDealIdentity() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));
        actorIdMock.setDataCapTransferResult(hex"83410041004A8382018082008081182A");

        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, _oneAllocationRescueParams());

        CommonTypes.FilActorId[] memory ids = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(ids[0]), 42);

        DataCapEvidenceAdapter.DataCapDealEvidence memory dealEvidence = dataCapEvidenceAdapterMock.getDeal(dealId);
        assertEq(dealEvidence.allocatedBytes, 2048);
        assertEq(dealEvidence.dealId, dealId);
        assertEq(dealEvidence.client, clientAddress);
        assertEq(CommonTypes.FilActorId.unwrap(dealEvidence.provider), CommonTypes.FilActorId.unwrap(SP1));
        assertEq(dealEvidence.validator, address(validatorMock));
        assertEq(dealEvidence.railId, 1);

        (uint64 provider, bytes memory data,,,,) = actorIdMock.lastDataCapTransferAllocation(0);
        assertEq(provider, CommonTypes.FilActorId.unwrap(SP1));
        assertEq(data, hex"000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22");
    }

    function testRescueDealAllocationsReplacesMultipleTrackedIdsAndPreservesAggregateSize() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));
        actorIdMock.setDataCapTransferResult(hex"83410041004C8382018082008082182A182B");

        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, _twoAllocationRescueParams());

        CommonTypes.FilActorId[] memory ids = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 2);
        _assertDoesNotContainAllocationId(ids, 1);
        _assertDoesNotContainAllocationId(ids, 2);
        _assertContainsAllocationId(ids, 42);
        _assertContainsAllocationId(ids, 43);

        DataCapEvidenceAdapter.DataCapDealEvidence memory dealEvidence = dataCapEvidenceAdapterMock.getDeal(dealId);
        assertEq(dealEvidence.allocatedBytes, 6144);

        (uint64 firstProvider, bytes memory firstData,,,,) = actorIdMock.lastDataCapTransferAllocation(0);
        (uint64 secondProvider, bytes memory secondData,,,,) = actorIdMock.lastDataCapTransferAllocation(1);
        assertEq(firstProvider, CommonTypes.FilActorId.unwrap(SP1));
        assertEq(secondProvider, CommonTypes.FilActorId.unwrap(SP1));
        assertEq(firstData, hex"000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22");
        assertEq(secondData, hex"000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22");
        assertEq(poRepMarketMock.finalizeDealCallCount(), 0);
    }

    function testAuthorizeUpgradeRevert() public {
        address newImpl = address(new DataCapEvidenceAdapter());
        address unauthorized = vm.addr(1);
        bytes32 upgraderRole = dataCapEvidenceAdapter.UPGRADER_ROLE();
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, upgraderRole)
        );
        dataCapEvidenceAdapter.upgradeToAndCall(newImpl, "");
    }

    function testShouldAddAllocationsIdsAfterTransfer() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        (CommonTypes.FilActorId[] memory allocationIdsBefore,) =
            dataCapEvidenceAdapter.getAllocationIdsPerDeal(dealId, 0, type(uint256).max);
        assertEq(allocationIdsBefore.length, 0);

        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710021A005034AC";
        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        CommonTypes.FilActorId[] memory allocationIdsAfter =
            dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(allocationIdsAfter.length, 2);
        assertEq(CommonTypes.FilActorId.unwrap(allocationIdsAfter[0]), 2);
        assertEq(CommonTypes.FilActorId.unwrap(allocationIdsAfter[1]), 1);
    }

    function testInvalidClaimExtensionRequest() public {
        // ClaimRequest length is 2 instead of 3
        transferParams.operator_data = hex"828081821904B001";
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidClaimExtensionRequest.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testHandleFilecoinMethodExpectRevertInvalidCaller() public {
        bytes memory params =
            hex"821a85223bdf585b861903f3061903f34a006f05b59d3b2000000058458281861903e8d82a5828000181e2039220207dcae81b2a679a3955cc2e4b3504c23ce55b2db5dd2119841ecafa550e53900e1908001a0007e9001a005033401a0002d3028040";
        vm.expectRevert(
            abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidCaller.selector, address(this), datacapContract)
        );
        dataCapEvidenceAdapter.handle_filecoin_method(3726118371, 81, params);
    }

    function testHandleFilecoinMethodExpectRevertInvalidTokenReceived() public {
        bytes memory params =
            hex"821A85223BDF585D871903F3061903F34A006F05B59D3B2000000058458281861903E8D82A5828000181E2039220207DCAE81B2A679A3955CC2E4B3504C23CE55B2DB5DD2119841ECAFA550E53900E1908001A0007E9001A005033401A0002D3028040187B";
        vm.prank(datacapContract);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidTokenReceived.selector));
        dataCapEvidenceAdapter.handle_filecoin_method(3726118371, 81, params);
    }

    function testHandleFilecoinMethodExpectRevertUnsupportedType() public {
        bytes memory params =
            hex"821A85223BDE585B861903F3061903F34A006F05B59D3B2000000058458281861903E8D82A5828000181E2039220207DCAE81B2A679A3955CC2E4B3504C23CE55B2DB5DD2119841ECAFA550E53900E1908001A0007E9001A005033401A0002D3028040";
        vm.prank(datacapContract);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.UnsupportedType.selector));
        dataCapEvidenceAdapter.handle_filecoin_method(3726118371, 81, params);
    }

    function testHandleFilecoinMethodForDatacapContract() public {
        bytes memory params =
            hex"821A85223BDF58598607061903F34A006F05B59D3B2000000058458281861903E8D82A5828000181E2039220207DCAE81B2A679A3955CC2E4B3504C23CE55B2DB5DD2119841ECAFA550E53900E1908001A0007E9001A005033401A0002D3028040";
        vm.prank(datacapContract);
        (uint32 exitCode, uint64 codec, bytes memory data) =
            dataCapEvidenceAdapter.handle_filecoin_method(3726118371, 0x51, params);
        assertEq(exitCode, 0);
        assertEq(codec, 0);
        assertEq(data, "");
    }

    function testHandleFilecoinMethodForVerifregContract() public {
        bytes memory params =
            hex"821A85223BDF58598606061903F34A006F05B59D3B2000000058458281861903E8D82A5828000181E2039220207DCAE81B2A679A3955CC2E4B3504C23CE55B2DB5DD2119841ECAFA550E53900E1908001A0007E9001A005033401A0002D3028040";
        vm.prank(datacapContract);
        (uint32 exitCode, uint64 codec, bytes memory data) =
            dataCapEvidenceAdapter.handle_filecoin_method(3726118371, 0x51, params);
        assertEq(exitCode, 0);
        assertEq(codec, 0);
        assertEq(data, "");
    }

    function testInvalidOperatorDataLength() public {
        // operator_data == [[]]
        transferParams.operator_data = hex"8180";

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidOperatorData.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testInvalidAllocationRequest() public {
        // AllocationRequest length is 7 instead of 6
        transferParams.operator_data =
            hex"8282871904B0D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A00503340190131190131861903E8D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013180";

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
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
        vm.expectRevert(
            abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidClaimWindow.selector, int64(518400), int64(529919))
        );
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testTransferRevertsWithInvalidClaimWindowWhenTermMinCannotFitWindow() public {
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001B7FFFFFFFFFFFFFFF1B7FFFFFFFFFFFFFFF1A0050334080";
        actorIdMock.setGetClaimsResult(hex"8282008080");

        vm.prank(clientAddress);
        vm.expectRevert(
            abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidClaimWindow.selector, type(int64).max, type(int64).max)
        );
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testTransferAcceptsAllocationClaimWindowAtMinimum() public {
        // Same allocation as above, but termMax = termMin + 11520.
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080";
        actorIdMock.setGetClaimsResult(hex"8282008080");

        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);

        (CommonTypes.FilActorId[] memory ids,) =
            dataCapEvidenceAdapter.getAllocationIdsPerDeal(dealId, 0, type(uint256).max);
        assertEq(ids.length, 1);
    }

    function testTransferRevertsWhenAllocationExpirationIsBeforeCurrentBlock() public {
        // Same valid term window as above, but expiration = 999.
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001903E780";
        actorIdMock.setGetClaimsResult(hex"8282008080");
        vm.roll(1000);

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testTransferAcceptsAllocationExpirationAtCurrentBlock() public {
        // Same valid term window as above, but expiration = 1000.
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001903E880";
        actorIdMock.setGetClaimsResult(hex"8282008080");
        vm.roll(1000);

        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);

        (CommonTypes.FilActorId[] memory ids,) =
            dataCapEvidenceAdapter.getAllocationIdsPerDeal(dealId, 0, type(uint256).max);
        assertEq(ids.length, 1);
    }

    function testClientCanCallTransfer() public {
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testShouldRevertTransferWhenDealIsNotInCorrectState() public {
        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                offerId: 0,
                validator: address(validatorMock),
                state: DealState.ACTIVE,
                railId: 1,
                evidenceAdapter: address(dataCapEvidenceAdapter)
            })
        );

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidDealStateForTransfer.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testVerifregFailIsDetected() public {
        vm.etch(CALL_ACTOR_ID, address(builtInActorForTransferFunctionMock).code);
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.TransferFailed.selector, 1));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testClaimExtensionNonExistent() public {
        // 0 success_count
        actorIdMock.setGetClaimsResult(hex"8282008080");
        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        vm.expectRevert(DataCapEvidenceAdapter.GetClaimsCallFailed.selector);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testClaimExtension() public {
        // params taken directly from `boost extend-deal` message
        // no allocations
        // 1 extension for provider 20000 and claim id 1
        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testClaimExtensionGetClaimsFail() public {
        vm.etch(CALL_ACTOR_ID, address(builtInActorForTransferFunctionMock).code);
        transferParams.operator_data = hex"82808283192710011A005034AC83192710011A005034AC";
        vm.prank(clientAddress);
        vm.expectRevert(DataCapEvidenceAdapter.GetClaimsCallFailed.selector);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testTransferDoubleClaimExtension() public {
        transferParams.operator_data = hex"82808283192710011A005034AC83192710011A005034AC";
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidTopLevelArray() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidTopLevelArray).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidTopLevelArray.selector));
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidFirstElementLength() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidFirstElementLength).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidFirstElement.selector));
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidFirstElementInnerLength() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidFirstElementInnerLength).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidFirstElement.selector));
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidSecondElementLength() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidSecondElementLength).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidSecondElement.selector));
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testDecodeAllocationResponseRevertInvalidSecondElementInnerLength() public {
        vm.etch(CALL_ACTOR_ID, address(failingMockInvalidSecondElementInnerLength).code);
        vm.expectRevert(abi.encodeWithSelector(AllocationResponseCbor.InvalidSecondElement.selector));
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testShouldRevertWhenAllocationsContainsDifferentAllocatorIds() public {
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186194E20D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013180";
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidProvider.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testShouldRevertWhenClaimExtensionsContainsDifferentAllocatorIds() public {
        transferParams.operator_data = hex"82808283192710011A005034AC83194E20011A005034AC";
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidProvider.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testShouldRevertWhenTransferIsCalledByNotTheClient() public {
        address notTheClient = vm.addr(0x523);
        vm.prank(notTheClient);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidClient.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testShouldNotOverrideDealWhileReplayingIfAlreadyRegistered() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(1000000));

        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710011A005034AC";

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: 150,
                client: clientAddress,
                provider: SP2,
                offerId: 0,
                validator: address(validatorMock),
                state: DealState.ACCEPTED,
                railId: 1,
                evidenceAdapter: address(dataCapEvidenceAdapter)
            })
        );
        vm.prank(clientAddress);
        // solhint-disable-next-line reentrancy
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221950001A0007E9001A009C7E801901318183192710011A005034AC";
        vm.expectEmit(true, true, true, true);
        emit DataCapEvidenceAdapter.DatacapSpent(clientAddress, 24576);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        DataCapEvidenceAdapter.DataCapDealEvidence memory dealEvidence = dataCapEvidenceAdapterMock.getDeal(dealId);
        assertTrue(CommonTypes.FilActorId.unwrap(dealEvidence.provider) == CommonTypes.FilActorId.unwrap(SP1));
        assertEq(dealEvidence.dealId, dealId);
        assertEq(dealEvidence.validator, address(validatorMock));
        assertEq(dealEvidence.railId, 1);
        assertEq(dealEvidence.client, clientAddress);
    }

    function testReentryAttemptWillThrowInvalidClientError() public {
        ReentrantMetaAllocatorMock reentrantMetaAllocatorMock = new ReentrantMetaAllocatorMock();
        address impl = address(new DataCapEvidenceAdapter());
        bytes memory initData = abi.encodeCall(
            DataCapEvidenceAdapter.initialize,
            (address(this), terminationOracle, address(poRepMarketMock), address(reentrantMetaAllocatorMock))
        );
        DataCapEvidenceAdapter dataCapEvidenceAdapterWithReentrancy =
            DataCapEvidenceAdapter(address(new ERC1967Proxy(address(impl), initData)));

        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                offerId: 0,
                state: DealState.ACCEPTED,
                validator: address(validatorMock),
                railId: 1,
                evidenceAdapter: address(dataCapEvidenceAdapter)
            })
        );
        reentrantMetaAllocatorMock.setAttackParams(
            address(dataCapEvidenceAdapterWithReentrancy), transferParams, dealId
        );
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidClient.selector));
        dataCapEvidenceAdapterWithReentrancy.submitDataCapBatch(transferParams, dealId);
    }

    function testShouldAddClaimExtensionIdsAfterTransfer() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(1000000));

        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710031A005034AC";

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: 150,
                client: clientAddress,
                provider: SP1,
                offerId: 0,
                validator: address(validatorMock),
                state: DealState.ACCEPTED,
                railId: 1,
                evidenceAdapter: address(dataCapEvidenceAdapter)
            })
        );
        // solhint-disable-next-line reentrancy
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221950001A0007E9001A009C7E801901318183192710041A005034AC";
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808102");
        vm.expectEmit(true, true, true, true);
        emit DataCapEvidenceAdapter.DatacapSpent(clientAddress, 24576);

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        DataCapEvidenceAdapter.DataCapDealEvidence memory dealEvidence = dataCapEvidenceAdapterMock.getDeal(dealId);
        assertEq(dealEvidence.allocationIds.length, 4);
        assertTrue(CommonTypes.FilActorId.unwrap(dealEvidence.allocationIds[0]) == 3);
        assertTrue(CommonTypes.FilActorId.unwrap(dealEvidence.allocationIds[1]) == 1);
        assertTrue(CommonTypes.FilActorId.unwrap(dealEvidence.allocationIds[2]) == 4);
        assertTrue(CommonTypes.FilActorId.unwrap(dealEvidence.allocationIds[3]) == 2);
    }

    function testIsDataSizeMatchingHappyPath() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        CommonTypes.FilActorId[] memory ids = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(ids[0]), 1);

        vm.prank(address(validatorMock));
        bool ok = dataCapEvidenceAdapterMock.isDataSizeMatching(dealId);
        assertTrue(ok);
    }

    function testIsDataSizeMatchingRemovesTerminatedClaimAndReturnsFalse() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        uint64[] memory claims = new uint64[](1);
        claims[0] = 1;

        vm.prank(terminationOracle);
        dataCapEvidenceAdapterMock.claimsTerminatedEarly(claims);

        CommonTypes.FilActorId[] memory beforeIds = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(beforeIds.length, 1);

        vm.prank(address(validatorMock));
        bool ok = dataCapEvidenceAdapterMock.isDataSizeMatching(dealId);
        assertTrue(!ok);

        CommonTypes.FilActorId[] memory afterIds = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 0);
    }

    function testIsDataSizeMatchingRemovesExpiredClaimAndReturnsFalse() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));
        transferParams.operator_data = hex"82808183192710011A005034AC";

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        vm.roll(5256407);

        vm.prank(address(validatorMock));
        bool ok = dataCapEvidenceAdapterMock.isDataSizeMatching(dealId);
        assertTrue(!ok);

        CommonTypes.FilActorId[] memory afterIds = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 0);
    }

    function testIsDataSizeMatchingSkipsFailCodes() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        actorIdMock.setGetClaimsResult(
            hex"8282008182001081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        CommonTypes.FilActorId[] memory beforeIds = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(beforeIds.length, 1);

        vm.prank(address(validatorMock));
        bool ok = dataCapEvidenceAdapterMock.isDataSizeMatching(dealId);
        assertTrue(!ok);

        CommonTypes.FilActorId[] memory afterIds = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(afterIds[0]), 1);
    }

    function testIsDataSizeMatchingReturnsFalseWhenNoClaimsTracked() public {
        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A0050334019013180";

        vm.prank(clientAddress);
        vm.expectRevert(DataCapEvidenceAdapter.GetClaimsCallFailed.selector);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testIsDataSizeMatchingRemovesTerminatedClaimId() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        transferParams.operator_data = hex"82808283192710011A005034AC83192710021A005034AC";
        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        CommonTypes.FilActorId[] memory beforeIds = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(beforeIds.length, 2);

        uint64[] memory claims = new uint64[](1);
        claims[0] = 1;

        vm.prank(terminationOracle);
        dataCapEvidenceAdapterMock.claimsTerminatedEarly(claims);

        vm.prank(address(validatorMock));
        dataCapEvidenceAdapterMock.isDataSizeMatching(dealId);

        CommonTypes.FilActorId[] memory afterIds = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(afterIds[0]), 2);
    }

    function testClaimsTerminatedEarlyRevertsWhenNotTerminationOracle() public {
        address notTerminationOracle = vm.addr(4);
        bytes32 expectedRole = dataCapEvidenceAdapter.TERMINATION_ORACLE();
        vm.prank(notTerminationOracle);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notTerminationOracle, expectedRole
            )
        );
        dataCapEvidenceAdapter.claimsTerminatedEarly(earlyTerminatedClaims);
    }

    function testClaimsTerminatedEarlySetCorrectly() public {
        bool isFirstClaimTerminated = dataCapEvidenceAdapter.terminatedClaims(1);
        assertTrue(!isFirstClaimTerminated);
        earlyTerminatedClaims.push(2);
        earlyTerminatedClaims.push(3);
        vm.prank(terminationOracle);
        dataCapEvidenceAdapter.claimsTerminatedEarly(earlyTerminatedClaims);

        isFirstClaimTerminated = dataCapEvidenceAdapter.terminatedClaims(1);
        bool isSecondClaimTerminated = dataCapEvidenceAdapter.terminatedClaims(2);
        bool isThirdClaimTerminated = dataCapEvidenceAdapter.terminatedClaims(3);
        assertTrue(isFirstClaimTerminated);
        assertTrue(isSecondClaimTerminated);
        assertTrue(isThirdClaimTerminated);
        bool isFourthClaimTerminated = dataCapEvidenceAdapter.terminatedClaims(4);
        assertTrue(!isFourthClaimTerminated);
    }

    function testDeleteDealAllocationIdByIndex() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(mock), uint256(10000));
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710031A005034AC";

        vm.prank(clientAddress);
        mock.submitDataCapBatch(transferParams, dealId);

        CommonTypes.FilActorId[] memory beforeIds = mock.getAllAllocationIdsPerDeal(dealId);
        assertEq(beforeIds.length, 2);
        assertEq(CommonTypes.FilActorId.unwrap(beforeIds[0]), 3);
        assertEq(CommonTypes.FilActorId.unwrap(beforeIds[1]), 1);

        mock.deleteDealAllocationIdByIndex(dealId, 0);

        CommonTypes.FilActorId[] memory afterIds = mock.getAllAllocationIdsPerDeal(dealId);
        assertEq(afterIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(afterIds[0]), 1);
    }

    function testIsDataSizeMatchingRevertsWhenGetClaimsExitCodeNonZero() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";
        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        CommonTypes.FilActorId[] memory ids = dataCapEvidenceAdapterMock.getAllAllocationIdsPerDeal(dealId);
        assertEq(ids.length, 1);

        ActorIdExitCodeErrorFailingMock failing = new ActorIdExitCodeErrorFailingMock();
        vm.etch(CALL_ACTOR_ID, address(failing).code);

        vm.expectRevert(DataCapEvidenceAdapter.GetClaimsCallFailed.selector);
        vm.prank(address(validatorMock));
        dataCapEvidenceAdapterMock.isDataSizeMatching(dealId);
    }

    function testIsDataSizeMatchingCallerNotValidator() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);

        vm.prank(address(0x123));
        vm.expectRevert(
            abi.encodeWithSelector(
                DataCapEvidenceAdapter.InvalidCaller.selector, address(0x123), address(validatorMock)
            )
        );
        dataCapEvidenceAdapterMock.isDataSizeMatching(dealId);
    }

    function testIsDataSizeMatchingDealWithNoValidator() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        transferParams.operator_data = hex"82808183192710011A005034AC";

        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                offerId: 0,
                validator: address(0),
                state: DealState.ACCEPTED,
                railId: 1,
                evidenceAdapter: address(dataCapEvidenceAdapter)
            })
        );

        vm.prank(address(0x123));
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.ValidatorNotSet.selector, dealId));
        dataCapEvidenceAdapterMock.isDataSizeMatching(dealId);
    }

    function testShouldThrowInsufficientAllowance() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));

        transferParams.operator_data = hex"82808183192710011A005034AC";

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(IMetaAllocator.InsufficientAllowance.selector));
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);
    }

    function testShouldThrowAmountEqualZero() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        transferParams.operator_data =
            hex"828286192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22001A0007E9001A0050334019013186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA22001A0007E9001A009C7E801901318183192710011A005034AC";
        actorIdMock.setGetClaimsResult(
            hex"8282018081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C7638001A003815911A005034D60000"
        );
        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationRequest.selector));
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);
    }

    function testShouldEmitMetaAllocatorDatacapAllocatedEvent() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(10000));

        vm.prank(clientAddress);
        vm.expectEmit(true, true, true, true);
        emit IMetaAllocator.DatacapAllocated(
            address(dataCapEvidenceAdapterMock),
            FilAddresses.fromEthAddress(address(dataCapEvidenceAdapterMock)).data,
            uint256(6144)
        );
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);
    }

    function testInitializeRevertsWhenAdminAddressIsZero() public {
        DataCapEvidenceAdapter impl = new DataCapEvidenceAdapter();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        DataCapEvidenceAdapter c = DataCapEvidenceAdapter(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAdminAddress.selector));
        c.initialize(address(0), terminationOracle, address(poRepMarketMock), address(metaAllocatorMock));
    }

    function testInitializeRevertsWhenTerminationOracleIsZero() public {
        DataCapEvidenceAdapter impl = new DataCapEvidenceAdapter();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        DataCapEvidenceAdapter c = DataCapEvidenceAdapter(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidTerminationOracleAddress.selector));
        c.initialize(address(clientAddress), address(0), address(poRepMarketMock), address(metaAllocatorMock));
    }

    function testInitializeRevertsWhenPoRepMarketIsZero() public {
        DataCapEvidenceAdapter impl = new DataCapEvidenceAdapter();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        DataCapEvidenceAdapter c = DataCapEvidenceAdapter(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidPoRepMarketContractAddress.selector));
        c.initialize(address(clientAddress), terminationOracle, address(0), address(metaAllocatorMock));
    }

    function testInitializeRevertsWhenMetaAllocatorIsZero() public {
        DataCapEvidenceAdapter impl = new DataCapEvidenceAdapter();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        DataCapEvidenceAdapter c = DataCapEvidenceAdapter(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidMetaAllocatorContractAddress.selector));
        c.initialize(address(clientAddress), terminationOracle, address(poRepMarketMock), address(0));
    }

    function testGetPoRepMarketAddress() public view {
        assertEq(dataCapEvidenceAdapter.getPoRepMarketAddress(), address(poRepMarketMock));
    }

    function testShouldRevertWhenAlreadyRegisteredDealTransferIsCalledByNotTheClient() public {
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);

        address notTheClient = vm.addr(0x523);
        vm.prank(notTheClient);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidClient.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testTransferEmitsDatacapSpent() public {
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710031A005034AC";

        vm.expectEmit(true, false, false, true);
        emit DataCapEvidenceAdapter.DatacapSpent(clientAddress, 4096);

        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testTransferRevertsWhenDealAlreadyActive() public {
        vm.startPrank(clientAddress);
        poRepMarketMock.setDealState(dealId, DealState.ACTIVE);

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidDealStateForTransfer.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
        vm.stopPrank();
    }

    function testRegisterDealRailIdNotSetReverts() public {
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710031A005034AC";

        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                offerId: 0,
                validator: address(validatorMock),
                state: DealState.ACCEPTED,
                railId: 0,
                evidenceAdapter: address(dataCapEvidenceAdapter)
            })
        );

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidRailId.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testShouldReturnDealAllocatedSize() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));

        uint256 sizeOfTransfer = 6144;
        metaAllocatorMock.setAllowance(address(dataCapEvidenceAdapterMock), uint256(sizeOfTransfer * 3));

        // 2 * 2048 from allocations and 2048 from claims
        uint256 allocatedBytes;

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);
        allocatedBytes = dataCapEvidenceAdapterMock.getAllocatedBytes(dealId);
        assertEq(allocatedBytes, sizeOfTransfer);

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);
        allocatedBytes = dataCapEvidenceAdapterMock.getAllocatedBytes(dealId);
        assertEq(allocatedBytes, sizeOfTransfer * 2);

        vm.prank(clientAddress);
        dataCapEvidenceAdapterMock.submitDataCapBatch(transferParams, dealId);
        allocatedBytes = dataCapEvidenceAdapterMock.getAllocatedBytes(dealId);
        assertEq(allocatedBytes, sizeOfTransfer * 3);
    }

    function testTransferRevertsWhenAllocationSizeExceedsSector() public {
        // alloc.size = 32GiB + 1 byte = 34359738369 bytes
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221B00000008000000011A0007E9001A000816001A0050334080";
        actorIdMock.setGetClaimsResult(hex"8282008080");

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationSize.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testRescueDealAllocationsRejectsAllocationSizeExceedingSector() public {
        DataCapEvidenceAdapterContractMock dataCapEvidenceAdapterMock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(dataCapEvidenceAdapterMock);
        _grantRescueRole(dataCapEvidenceAdapterMock, address(this));

        // alloc.size = 32GiB + 1 byte = 34359738369 bytes
        DataCapTypes.TransferParams memory params = _rescueParams(
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221B00000008000000011A0007E9001A000816001A0050334080",
            2048
        );

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocationSize.selector));
        dataCapEvidenceAdapterMock.rescueDealAllocations(dealId, params);
    }

    function testGetClaimIdsRevertsWhenLimitIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidLimit.selector));
        dataCapEvidenceAdapter.getClaimIds(dealId, 0, 0);
    }

    function testGetClaimIdsRevertsWhenDealIdIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidDealId.selector));
        dataCapEvidenceAdapter.getClaimIds(0, 0, 1);
    }

    function testGetClaimIdsReturnsEmptyWhenDealHasNoClaims() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));

        (CommonTypes.FilActorId[] memory ids, uint256 total) = mock.getClaimIds(dealId, 0, type(uint256).max);
        assertEq(total, 0);
        assertEq(ids.length, 0);
    }

    function testGetClaimIdsReturnsClaimsAfterSubmit() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithOneAllocation(mock);
        _finishPosting(mock);
        actorIdMock.setGetClaimsResult(
            hex"8282018081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(address(poRepMarketMock));
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        (CommonTypes.FilActorId[] memory ids, uint256 total) = mock.getClaimIds(dealId, 0, type(uint256).max);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(ids[0]), 1);
        assertEq(mock.getDealAllocationStatus(dealId), DataCapAllocationStatus.CLAIMED);
    }

    function testGetClaimIdsPaginates() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(address(poRepMarketMock));
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        (CommonTypes.FilActorId[] memory firstPage, uint256 total) = mock.getClaimIds(dealId, 0, 1);
        assertEq(total, 2);
        assertEq(firstPage.length, 1);

        (CommonTypes.FilActorId[] memory secondPage,) = mock.getClaimIds(dealId, 1, 2);
        assertEq(secondPage.length, 1);

        CommonTypes.FilActorId[] memory both = new CommonTypes.FilActorId[](2);
        both[0] = firstPage[0];
        both[1] = secondPage[0];
        _assertContainsAllocationId(both, 1);
        _assertContainsAllocationId(both, 2);

        (CommonTypes.FilActorId[] memory emptyPage, uint256 emptyTotal) = mock.getClaimIds(dealId, 2, 1);
        assertEq(emptyTotal, 2);
        assertEq(emptyPage.length, 0);
    }

    function testIsOperationalReturnsTrueByDefault() public view {
        assertTrue(dataCapEvidenceAdapter.isOperational());
    }

    function testDisableAdapterMarksAdapterNotOperational() public {
        dataCapEvidenceAdapter.disableAdapter();
        assertFalse(dataCapEvidenceAdapter.isOperational());
    }

    function testDisableAdapterEmitsAdapterNonOperational() public {
        vm.expectEmit(true, false, false, true);
        emit DataCapEvidenceAdapter.AdapterNonOperational(address(this), block.number);
        dataCapEvidenceAdapter.disableAdapter();
    }

    function testDisableAdapterRevertsWhenAlreadyNonOperational() public {
        dataCapEvidenceAdapter.disableAdapter();

        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.AdapterAlreadyNonOperational.selector));
        dataCapEvidenceAdapter.disableAdapter();
    }

    function testDisableAdapterRevertsWhenCallerIsNotAdmin() public {
        address unauthorized = vm.addr(0x524);
        bytes32 adminRole = dataCapEvidenceAdapter.DEFAULT_ADMIN_ROLE();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, adminRole)
        );
        dataCapEvidenceAdapter.disableAdapter();
    }

    function testSubmitDataCapBatchRevertsWhenAdapterNonOperational() public {
        dataCapEvidenceAdapter.disableAdapter();

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.AdapterNotOperational.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testActivateEvidenceAcceptsWhenFullyClaimed() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(address(poRepMarketMock));
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        vm.prank(address(poRepMarketMock));
        SharedTypes.ActivationDecision memory decision = mock.activateEvidence(_activationContext(), "");

        assertEq(decision.coveredBytes, 4096);
        assertEq(decision.reasonCode, 0);
        assertEq(decision.result, EvidenceResult.ACCEPTED);
        assertEq(mock.getDeal(dealId).activeClaimedBytes, 4096);
    }

    function testActivateEvidenceAcceptsWhenCoveredBytesMeetThreshold() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(address(poRepMarketMock));
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        SharedTypes.ActivationContext memory context = SharedTypes.ActivationContext({
            dealId: dealId,
            requestedSizeBytes: 4096,
            client: clientAddress,
            durationEpochs: 0,
            activationToleranceBps: 0,
            provider: providerFilActorId
        });

        vm.prank(address(poRepMarketMock));
        SharedTypes.ActivationDecision memory decision = mock.activateEvidence(context, "");

        assertEq(decision.coveredBytes, 4096);
        assertEq(decision.result, EvidenceResult.ACCEPTED);
        assertEq(mock.getDeal(dealId).activeClaimedBytes, 4096);
    }

    function testActivateEvidenceRejectsWhenCoveredBytesBelowThreshold() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(address(poRepMarketMock));
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        SharedTypes.ActivationContext memory context = SharedTypes.ActivationContext({
            dealId: dealId,
            requestedSizeBytes: 8192,
            client: clientAddress,
            durationEpochs: 0,
            activationToleranceBps: 0,
            provider: providerFilActorId
        });

        vm.prank(address(poRepMarketMock));
        SharedTypes.ActivationDecision memory decision = mock.activateEvidence(context, "");

        assertEq(decision.coveredBytes, 4096);
        assertEq(decision.result, EvidenceResult.REJECTED);
        assertEq(mock.getDeal(dealId).activeClaimedBytes, 0);
    }

    function testActivateEvidenceRejectsWhenAllocationsRemain() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        actorIdMock.setGetClaimsResult(
            hex"8282018182000681881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(address(poRepMarketMock));
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        vm.prank(address(poRepMarketMock));
        SharedTypes.ActivationDecision memory decision = mock.activateEvidence(_activationContext(), "");

        assertEq(decision.coveredBytes, 2048);
        assertEq(decision.result, EvidenceResult.REJECTED);
        assertEq(mock.getAllAllocationIdsPerDeal(dealId).length, 1);
        assertEq(mock.getDeal(dealId).activeClaimedBytes, 0);
    }

    function testActivateEvidenceRevertsWhenCallerIsNotPoRepMarket() public {
        vm.expectRevert(DataCapEvidenceAdapter.CallerIsNotPoRepMarket.selector);
        dataCapEvidenceAdapter.activateEvidence(_activationContext(), "");
    }

    function testActivateEvidenceEmitsDealEvidenceReady() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);
        _finishPosting(mock);
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
        vm.prank(address(poRepMarketMock));
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));

        vm.expectEmit(true, true, false, false, address(mock));
        emit DataCapEvidenceAdapter.DealEvidenceReady(dealId, address(mock));

        vm.prank(address(poRepMarketMock));
        mock.activateEvidence(_activationContext(), "");
    }

    function testIsDataCapPostingFinishedDefaultsToFalse() public view {
        assertFalse(dataCapEvidenceAdapter.isDataCapPostingFinished(dealId));
    }

    function testFinishDataCapPostingMarksFinishedAndEmits() public {
        actorIdMock.setGetClaimsResult(hex"8282008080");
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808101");
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080";
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);

        vm.expectEmit(true, false, false, true);
        emit DataCapEvidenceAdapter.DataCapPostingFinished(dealId, dataCapEvidenceAdapter.getAllocatedBytes(dealId));

        vm.prank(clientAddress);
        dataCapEvidenceAdapter.finishDataCapPosting(dealId);

        assertTrue(dataCapEvidenceAdapter.isDataCapPostingFinished(dealId));
    }

    function testFinishDataCapPostingRevertsWhenCallerNotClient() public {
        actorIdMock.setGetClaimsResult(hex"8282008080");
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808101");
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080";
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);

        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidClient.selector));
        dataCapEvidenceAdapter.finishDataCapPosting(dealId);
    }

    function testFinishDataCapPostingRevertsWhenDealNotAccepted() public {
        actorIdMock.setGetClaimsResult(hex"8282008080");
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808101");
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080";
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);

        poRepMarketMock.setDealState(dealId, DealState.FINALIZED);

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidDealStateForTransfer.selector));
        dataCapEvidenceAdapter.finishDataCapPosting(dealId);
    }

    function testFinishDataCapPostingRevertsWhenAlreadyFinished() public {
        actorIdMock.setGetClaimsResult(hex"8282008080");
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808101");
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080";
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);

        vm.prank(clientAddress);
        dataCapEvidenceAdapter.finishDataCapPosting(dealId);

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.PostingAlreadyFinished.selector));
        dataCapEvidenceAdapter.finishDataCapPosting(dealId);
    }

    function testSubmitDataCapBatchRevertsWhenPostingAlreadyFinished() public {
        actorIdMock.setGetClaimsResult(hex"8282008080");
        actorIdMock.setDataCapTransferResult(hex"834100410049838201808200808101");
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A000816001A0050334080";
        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);

        vm.prank(clientAddress);
        dataCapEvidenceAdapter.finishDataCapPosting(dealId);

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.PostingAlreadyFinished.selector));
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testSubmitEvidenceBatchRevertsWhenPostingNotFinished() public {
        DataCapEvidenceAdapterContractMock mock =
            DataCapEvidenceAdapterContractMock(setupProxy(address(new DataCapEvidenceAdapterContractMock())));
        _registerDealWithTwoAllocations(mock);

        vm.prank(address(poRepMarketMock));
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.PostingNotFinished.selector));
        mock.submitEvidenceBatch(_activationContext(), abi.encode(uint256(10)));
    }

    function testSubmitDataCapBatchEmitsDataCapBatchSubmitted() public {
        transferParams.operator_data =
            hex"828186192710D82A5828000181E203922020F2B9A58BBC9D9856E52EAB85155C1BA298F7E8DF458BD20A3AD767E11572CA221908001A0007E9001A005033401901318183192710031A005034AC";

        vm.expectEmit(true, false, false, true);
        emit DataCapEvidenceAdapter.DataCapBatchSubmitted(dealId, 4096);

        vm.prank(clientAddress);
        dataCapEvidenceAdapter.submitDataCapBatch(transferParams, dealId);
    }

    function testFinishDataCapPostingRevertsWhenAllocationBelowRequestedSize() public {
        poRepMarketMock.setDealTerms(dealId, PoRepTypes.DealTerms({requestedSizeBytes: 2048, durationEpochs: 0}));

        vm.prank(clientAddress);
        vm.expectRevert(abi.encodeWithSelector(DataCapEvidenceAdapter.InvalidAllocatedBytes.selector));
        dataCapEvidenceAdapter.finishDataCapPosting(dealId);
    }
}

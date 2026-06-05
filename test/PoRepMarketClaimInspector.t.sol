// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {PoRepMarketClaimInspector} from "../src/helpers/PoRepMarketClaimInspector.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";
import {ActorIdMock} from "./contracts/ActorIdMock.sol";
import {ActorIdExitCodeErrorFailingMock} from "./contracts/ActorIdExitCodeErrorFailingMock.sol";
import {MockProxy} from "./contracts/MockProxy.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";
import {ClientSCMock} from "./contracts/ClientSCMock.sol";
import {ValidatorMock} from "./contracts/ValidatorMock.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {SLITypes} from "../src/types/SLITypes.sol";

contract PoRepMarketClaimInspectorTest is Test {
    address public constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;

    address public clientAddress;
    uint256 public dealId;

    CommonTypes.FilActorId public providerFilActorId;
    // solhint-disable var-name-mixedcase
    CommonTypes.FilActorId public SP1 = CommonTypes.FilActorId.wrap(uint64(10000));
    // solhint-enable var-name-mixedcase

    PoRepMarketClaimInspector public porepMarketClaimInspector;
    ActorIdMock public actorIdMock;
    PoRepMarketMock public poRepMarketMock;
    ClientSCMock public clientSCMock;
    ValidatorMock public validatorMock;

    string public expectedManifestLocation = "https://example.com/manifest";

    function setUp() public {
        clientAddress = address(0x789);
        providerFilActorId = CommonTypes.FilActorId.wrap(1);
        dealId = 1;

        poRepMarketMock = new PoRepMarketMock();
        clientSCMock = new ClientSCMock();
        validatorMock = new ValidatorMock();
        actorIdMock = new ActorIdMock();

        address actorIdProxy = address(new MockProxy(address(5555)));
        vm.etch(CALL_ACTOR_ID, address(actorIdProxy).code);
        vm.etch(address(5555), address(actorIdMock).code);
        actorIdMock = ActorIdMock(payable(address(5555)));

        actorIdMock.setGetClaimsResult(
            hex"8282018081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: clientAddress,
                provider: SP1,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({dealSizeBytes: 1024, pricePerSectorPerMonth: 100, durationDays: 365}),
                validator: address(validatorMock),
                state: PoRepTypes.DealState.Accepted,
                railId: 1,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(1));
        clientSCMock.setAllocationIds(dealId, ids);

        porepMarketClaimInspector = new PoRepMarketClaimInspector(address(clientSCMock), address(poRepMarketMock));
    }

    function testConstructorSetsContractAddresses() public view {
        assertEq(address(porepMarketClaimInspector.CLIENT_CONTRACT()), address(clientSCMock));
        assertEq(address(porepMarketClaimInspector.POREPMARKET_CONTRACT()), address(poRepMarketMock));
    }

    function testConstructorRevertsWhenClientContractAddressIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarketClaimInspector.InvalidClientAddress.selector));
        new PoRepMarketClaimInspector(address(0), address(poRepMarketMock));
    }

    function testConstructorRevertsWhenPoRepMarketContractAddressIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarketClaimInspector.InvalidPoRepMarketAddress.selector));
        new PoRepMarketClaimInspector(address(clientSCMock), address(0));
    }

    function testConstructorRevertsWhenBothAddressesAreZero() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarketClaimInspector.InvalidClientAddress.selector));
        new PoRepMarketClaimInspector(address(0), address(0));
    }

    function testGetClaimsRevertsWhenDealIdIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarketClaimInspector.InvalidDealId.selector));
        porepMarketClaimInspector.getClaimForDeal(0);
    }

    function testGetClaimsReturnsSingleClaim() public view {
        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimForDeal(dealId);

        assertEq(claims.length, 1);
        assertEq(claimIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[0]), 1);

        VerifRegTypes.Claim memory claim = claims[0];
        assertEq(CommonTypes.FilActorId.unwrap(claim.provider), 1000);
        assertEq(CommonTypes.FilActorId.unwrap(claim.client), 102);
        assertEq(claim.size, 2048);
        assertEq(claim.data, hex"000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C7638");
    }

    function testGetClaimsReturnsMultipleClaims() public {
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](2);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(1));
        ids[1] = CommonTypes.FilActorId.wrap(uint64(2));
        clientSCMock.setAllocationIds(dealId, ids);

        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimForDeal(dealId);

        assertEq(claims.length, 2);
        assertEq(claimIds.length, 2);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[0]), 1);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[1]), 2);

        assertEq(CommonTypes.FilActorId.unwrap(claims[0].provider), 1000);
        assertEq(claims[0].size, 2048);
        assertEq(claims[0].data, hex"000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C7638");
        assertEq(CommonTypes.FilActorId.unwrap(claims[1].provider), 1000);
        assertEq(claims[1].size, 2048);
        assertEq(claims[1].data, hex"000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C7638");
    }

    function testGetClaimsReturnsEmptyResultWhenNoAllocations() public {
        actorIdMock.setGetClaimsResult(hex"8282008080");
        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](0);
        clientSCMock.setAllocationIds(dealId, ids);

        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimForDeal(dealId);

        assertEq(claims.length, 0);
        assertEq(claimIds.length, 0);
    }

    function testGetClaimsSkipsFailedClaimIds() public {
        actorIdMock.setGetClaimsResult(
            hex"8282018182000681881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](2);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(10));
        ids[1] = CommonTypes.FilActorId.wrap(uint64(20));
        clientSCMock.setAllocationIds(dealId, ids);

        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimForDeal(dealId);

        assertEq(claims.length, 1);
        assertEq(claimIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[0]), 20);
    }

    function testGetClaimsRevertsWhenGetClaimsExitCodeNonZero() public {
        ActorIdExitCodeErrorFailingMock failing = new ActorIdExitCodeErrorFailingMock();
        vm.etch(CALL_ACTOR_ID, address(failing).code);

        vm.expectRevert(PoRepMarketClaimInspector.GetClaimsCallFailed.selector);
        porepMarketClaimInspector.getClaimForDeal(dealId);
    }

    function testGetClaimsRevertsOnClaimIdsMismatch() public {
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(1));
        clientSCMock.setAllocationIds(dealId, ids);

        vm.expectRevert(abi.encodeWithSelector(PoRepMarketClaimInspector.ClaimIdsMismatch.selector, 2, 1));
        porepMarketClaimInspector.getClaimForDeal(dealId);
    }

    function testGetClaimsUsesProviderFromDealProposal() public {
        CommonTypes.FilActorId customProvider = CommonTypes.FilActorId.wrap(uint64(20000));
        poRepMarketMock.setDealProposal(
            dealId,
            PoRepTypes.DealProposal({
                dealId: dealId,
                client: clientAddress,
                provider: customProvider,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({dealSizeBytes: 1024, pricePerSectorPerMonth: 100, durationDays: 365}),
                validator: address(validatorMock),
                state: PoRepTypes.DealState.Accepted,
                railId: 1,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );

        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimForDeal(dealId);
        assertEq(claims.length, 1);
        assertEq(claimIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[0]), 1);
    }

    function testGetClaimsHandlesDifferentDealId() public {
        uint256 secondDealId = 42;
        poRepMarketMock.setDealProposal(
            secondDealId,
            PoRepTypes.DealProposal({
                dealId: secondDealId,
                client: clientAddress,
                provider: SP1,
                requirements: SLITypes.SLIThresholds({
                    retrievabilityBps: 80, bandwidthMbps: 500, latencyMs: 200, indexingPct: 90
                }),
                terms: SLITypes.DealTerms({dealSizeBytes: 1024, pricePerSectorPerMonth: 100, durationDays: 365}),
                validator: address(validatorMock),
                state: PoRepTypes.DealState.Accepted,
                railId: 1,
                proposedAtBlock: block.number,
                manifestLocation: expectedManifestLocation
            })
        );

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(7));
        clientSCMock.setAllocationIds(secondDealId, ids);

        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimForDeal(secondDealId);
        assertEq(claims.length, 1);
        assertEq(claimIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[0]), 7);
        assertEq(CommonTypes.FilActorId.unwrap(claims[0].provider), 1000);
    }

    function testGetClaimsForProviderReturnsSingleClaim() public view {
        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(1));

        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimsForProvider(SP1, ids);

        assertEq(claims.length, 1);
        assertEq(claimIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[0]), 1);

        VerifRegTypes.Claim memory claim = claims[0];
        assertEq(CommonTypes.FilActorId.unwrap(claim.provider), 1000);
        assertEq(CommonTypes.FilActorId.unwrap(claim.client), 102);
        assertEq(claim.size, 2048);
        assertEq(claim.data, hex"000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C7638");
    }

    function testGetClaimsForProviderReturnsMultipleClaims() public {
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](2);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(1));
        ids[1] = CommonTypes.FilActorId.wrap(uint64(2));

        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimsForProvider(SP1, ids);

        assertEq(claims.length, 2);
        assertEq(claimIds.length, 2);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[0]), 1);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[1]), 2);

        assertEq(CommonTypes.FilActorId.unwrap(claims[0].provider), 1000);
        assertEq(claims[0].size, 2048);
        assertEq(claims[0].data, hex"000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C7638");
        assertEq(CommonTypes.FilActorId.unwrap(claims[1].provider), 1000);
        assertEq(claims[1].size, 2048);
        assertEq(claims[1].data, hex"000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C7638");
    }

    function testGetClaimsForProviderReturnsEmptyResultWhenNoIds() public {
        actorIdMock.setGetClaimsResult(hex"8282008080");
        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](0);

        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimsForProvider(SP1, ids);

        assertEq(claims.length, 0);
        assertEq(claimIds.length, 0);
    }

    function testGetClaimsForProviderSkipsFailedClaimIds() public {
        actorIdMock.setGetClaimsResult(
            hex"8282018182000681881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](2);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(10));
        ids[1] = CommonTypes.FilActorId.wrap(uint64(20));

        (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims) =
            porepMarketClaimInspector.getClaimsForProvider(SP1, ids);

        assertEq(claims.length, 1);
        assertEq(claimIds.length, 1);
        assertEq(CommonTypes.FilActorId.unwrap(claimIds[0]), 20);
    }

    function testGetClaimsForProviderRevertsWhenGetClaimsExitCodeNonZero() public {
        ActorIdExitCodeErrorFailingMock failing = new ActorIdExitCodeErrorFailingMock();
        vm.etch(CALL_ACTOR_ID, address(failing).code);

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(1));

        vm.expectRevert(PoRepMarketClaimInspector.GetClaimsCallFailed.selector);
        porepMarketClaimInspector.getClaimsForProvider(SP1, ids);
    }

    function testGetClaimsForProviderRevertsOnClaimIdsMismatch() public {
        actorIdMock.setGetClaimsResult(
            hex"8282028082881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );

        CommonTypes.FilActorId[] memory ids = new CommonTypes.FilActorId[](1);
        ids[0] = CommonTypes.FilActorId.wrap(uint64(1));

        vm.expectRevert(abi.encodeWithSelector(PoRepMarketClaimInspector.ClaimIdsMismatch.selector, 2, 1));
        porepMarketClaimInspector.getClaimsForProvider(SP1, ids);
    }
}

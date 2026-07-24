// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {SectorStatus} from "../lib/fvm-solidity/src/FVMSector.sol";
import {FVMSector} from "../lib/fvm-solidity/src/FVMSector.sol";
import {USR_NOT_FOUND} from "../lib/fvm-solidity/src/FVMErrors.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {PoRepMarketSectorStatusInspector} from "../src/helpers/PoRepMarketSectorStatusInspector.sol";
import {ActorIdMock} from "./contracts/ActorIdMock.sol";
import {MockProxy} from "./contracts/MockProxy.sol";
import {PoRepMarketMock} from "./contracts/PoRepMarketMock.sol";
import {ValidatorMock} from "./contracts/ValidatorMock.sol";
import {PoRepTypes} from "../src/types/PoRepTypes.sol";
import {DealState} from "../src/types/DealState.sol";

contract PoRepMarketSectorStatusInspectorTest is Test {
    address public constant CALL_ACTOR_ID = 0xfe00000000000000000000000000000000000005;

    uint64 public constant MINER_ID = 1234;
    uint64 public constant SECTOR = 42;
    int64 public constant DEADLINE = 3;
    int64 public constant PARTITION = 7;

    address public clientAddress;
    uint256 public dealId;

    CommonTypes.FilActorId public providerFilActorId;

    PoRepMarketSectorStatusInspector public porepMarketSectorStatusInspector;
    ActorIdMock public actorIdMock;
    PoRepMarketMock public poRepMarketMock;
    ValidatorMock public validatorMock;

    function setUp() public {
        clientAddress = address(0x123);
        dealId = 1;
        providerFilActorId = CommonTypes.FilActorId.wrap(MINER_ID);

        poRepMarketMock = new PoRepMarketMock();
        validatorMock = new ValidatorMock();
        actorIdMock = new ActorIdMock();

        address actorIdProxy = address(new MockProxy(address(5555)));
        vm.etch(CALL_ACTOR_ID, address(actorIdProxy).code);
        vm.etch(address(5555), address(actorIdMock).code);
        actorIdMock = ActorIdMock(payable(address(5555)));

        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: providerFilActorId,
                offerId: 0,
                state: DealState.ACCEPTED,
                evidenceAdapter: address(0),
                validator: address(validatorMock),
                railId: 1,
                proposedAtEpoch: CommonTypes.ChainEpoch.wrap(0)
            })
        );

        porepMarketSectorStatusInspector = new PoRepMarketSectorStatusInspector(address(poRepMarketMock));
    }

    function testConstructorSetsContractAddress() public view {
        assertEq(address(porepMarketSectorStatusInspector.POREPMARKET_CONTRACT()), address(poRepMarketMock));
    }

    function testConstructorRevertsWhenPoRepMarketContractAddressIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarketSectorStatusInspector.InvalidPoRepMarketAddress.selector));
        new PoRepMarketSectorStatusInspector(address(0));
    }

    function testValidateSectorStatusRevertsWhenDealIdIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepMarketSectorStatusInspector.InvalidDealId.selector));
        porepMarketSectorStatusInspector.validateSectorStatus(0, SECTOR, SectorStatus.Active, DEADLINE, PARTITION);
    }

    function testValidateSectorStatusReturnsTrueForActiveSector() public {
        actorIdMock.setValidateSectorStatusResult(0, true);

        bool valid = porepMarketSectorStatusInspector.validateSectorStatus(
            dealId, SECTOR, SectorStatus.Active, DEADLINE, PARTITION
        );
        assertTrue(valid);
    }

    function testValidateSectorStatusReturnsFalseOnStatusMismatch() public {
        actorIdMock.setValidateSectorStatusResult(0, false);

        bool valid = porepMarketSectorStatusInspector.validateSectorStatus(
            dealId, SECTOR, SectorStatus.Dead, DEADLINE, PARTITION
        );
        assertFalse(valid);
    }

    function testValidateSectorStatusRevertsOnActorError() public {
        actorIdMock.setValidateSectorStatusResult(int256(uint256(USR_NOT_FOUND)), false);

        vm.expectRevert(
            abi.encodeWithSelector(FVMSector.ValidateSectorStatusFailed.selector, int256(uint256(USR_NOT_FOUND)))
        );
        porepMarketSectorStatusInspector.validateSectorStatus(dealId, SECTOR, SectorStatus.Active, DEADLINE, PARTITION);
    }

    function testValidateSectorStatusUsesProviderFromDeal() public {
        uint64 customMinerId = 20000;
        poRepMarketMock.setDeal(
            dealId,
            PoRepTypes.Deal({
                dealId: dealId,
                client: clientAddress,
                provider: CommonTypes.FilActorId.wrap(customMinerId),
                offerId: 0,
                state: DealState.ACCEPTED,
                evidenceAdapter: address(0),
                validator: address(validatorMock),
                railId: 1,
                proposedAtEpoch: CommonTypes.ChainEpoch.wrap(0)
            })
        );

        actorIdMock.setValidateSectorStatusResult(0, true);

        bool valid = porepMarketSectorStatusInspector.validateSectorStatus(
            dealId, SECTOR, SectorStatus.Active, DEADLINE, PARTITION
        );
        assertTrue(valid);
    }
}

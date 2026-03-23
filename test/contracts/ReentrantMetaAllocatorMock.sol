// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {IMetaAllocator} from "../../src/interfaces/IMetaAllocator.sol";
import {Client} from "../../src/Client.sol";
import {DataCapTypes} from "filecoin-solidity/v0.8/types/DataCapTypes.sol";

contract ReentrantMetaAllocatorMock is IMetaAllocator {
    Client public client;
    DataCapTypes.TransferParams public attackParams;
    uint256 public attackDealId;
    bool public shouldAttack;

    function setAttackParams(address _client, DataCapTypes.TransferParams calldata _params, uint256 _dealId) external {
        client = Client(_client);
        attackParams = _params;
        attackDealId = _dealId;
        shouldAttack = true;
    }

    function addVerifiedClient(bytes calldata, uint256) external override {
        if (shouldAttack) {
            shouldAttack = false;
            client.transfer(attackParams, attackDealId, false);
        }
    }
}

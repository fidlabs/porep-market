// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.24;

import {IClient} from "../../src/interfaces/Client.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract ClientMock is IClient {
    mapping(CommonTypes.FilActorId => address[]) public SPClients;

    function getSPClients(CommonTypes.FilActorId provider) external view returns (address[] memory) {
        return SPClients[provider];
    }

    function setSPClient(CommonTypes.FilActorId provider, address client) external {
        SPClients[provider].push(client);
    }
}

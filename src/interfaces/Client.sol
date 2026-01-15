// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase, one-contract-per-file

pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

/**
 * @title IClientRegistry interface
 * @notice IClientRegistry interface
 * @dev IClientRegistry interface is an interface that contains the function to get a client
 */
interface IClient {
    /**
     * @notice getClient function
     * @dev getClient function is a function that gets a client
     * @param provider The address of the provider
     * @return address The client
     */
    function getSPClients(CommonTypes.FilActorId provider) external returns (address[] memory);
}

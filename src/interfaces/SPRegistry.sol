// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase, one-contract-per-file

pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

/**
 * @title ISPRegistry interface
 * @notice ISPRegistry interface
 * @dev ISPRegistry interface is an interface that contains the function to get a provider
 */
interface ISPRegistry {
    /**
     * @notice getProviderForDeal function
     * @dev getProviderForDeal function is a function that gets a provider for a deal
     * @param SLC The address of the SLC
     * @param expectedDealSize The expected size of the deal
     * @param priceForDeal The price for the deal
     * @return CommonTypes.FilActorId The provider
     */
    function getProviderForDeal(address SLC, uint256 expectedDealSize, uint256 priceForDeal)
        external
        returns (CommonTypes.FilActorId);

    /**
     * @notice isOwner function
     * @dev isOwner function is a function that checks if a client is the owner of a provider
     * @param ownerAddress The address of the owner
     * @param provider The address of the provider
     * @return bool True if the client is the owner of the provider, false otherwise
     */
    function isStorageProviderOwner(address ownerAddress, CommonTypes.FilActorId provider) external returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title Allocator
 * @notice This contract functions as a middle-man for Allocators. It's made a
 * Verifier (a.k.a. Notary) on Filecoin chain and granted DataCap that can then
 * be granted to Clients. Granting to clients can be done by Allocators that get
 * allowance on the contract, assigned by contract owner.
 */
interface IMetaAllocator {
    /**
     * @dev Thrown if caller doesn't have enough allowance for given action
     */
    error InsufficientAllowance();

    /**
     * @dev Thrown if trying to add 0 allowance or grant 0 datacap
     */
    error AmountEqualZero();

    // solhint-disable gas-indexed-events
    /**
     * @notice Emitted when datacap is granted to a client
     * @param allocator Allocator who granted the datacap
     * @param client Client that received datacap (Filecoin address)
     * @param amount Amount of datacap
     */
    event DatacapAllocated(address indexed allocator, bytes indexed client, uint256 amount);
    // solhint-enable gas-indexed-events

    /**
     * @notice Grant allowance to a client.
     * @param clientAddress Filecoin address of the client
     * @param amount Amount of datacap to grant
     * @dev Emits DatacapAllocated event
     * @dev Reverts with InsufficientAllowance if caller doesn't have sufficient allowance
     * @custom:oz-upgrades-unsafe-allow-reachable delegatecall
     */
    function addVerifiedClient(bytes calldata clientAddress, uint256 amount) external;
}

// SPDX-License-Identifier: MIT
// solhint-disable func-name-mixedcase

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {DataCapTypes} from "filecoin-solidity/v0.8/types/DataCapTypes.sol";

/**
 * @title IClient
 * @notice Interface for client interactions with storage providers
 */
interface IClient {
    /**
     * @notice This function transfers DataCap tokens from the client to the storage provider
     * @dev This function can only be called by the client
     * @param params The parameters for the transfer
     * @param dealId The id of the deal
     * @param dealCompleted Whether the deal is completed
     */
    function transfer(DataCapTypes.TransferParams calldata params, uint256 dealId, bool dealCompleted) external;

    /**
     * @notice The handle_filecoin_method function is a universal entry point for calls
     * coming from built-in Filecoin actors. Datacap is an FRC-46 Token. Receiving FRC46
     * tokens requires implementing a Receiver Hook:
     * https://github.com/filecoin-project/FIPs/blob/master/FRCs/frc-0046.md#receiver-hook.
     * We use handle_filecoin_method to handle the receiver hook and make sure that the token
     * sent to our contract is freshly minted Datacap and reject all other calls and transfers.
     * @param method Method number
     * @param inputCodec Codec of the payload
     * @param params Params of the call
     * @return exitCode The exit code of the operation
     * @return codec The codec used for the response
     * @return data The response data
     * @dev Reverts if trying to send a unsupported token type
     * @dev Reverts if trying to receive invalid token
     */
    function handle_filecoin_method(uint64 method, uint64 inputCodec, bytes calldata params)
        external
        view
        returns (uint32 exitCode, uint64 codec, bytes memory data);

    /**
     * @notice custom getter to retrieve allocation ids per client and provider
     * @param dealId the id of the deal
     * @return allocationIds the allocation ids for the client and provider
     */
    function getClientAllocationIdsPerDeal(uint256 dealId) external view returns (CommonTypes.FilActorId[] memory);

    /**
     * @notice custom getter to check if claim is terminated
     * @param claimId the id of the claim
     * @return isTerminated whether the claim is terminated
     */
    function terminatedClaims(uint64 claimId) external view returns (bool);

    /**
     * @notice Checks if the total active data size for the client with the specified provider matches the expected size
     * @dev This function can only be called by the validator of the deal
     * @param dealId The id of the deal
     * @return totalSizePerSp The total active data size for the client with the specified provider
     */
    function isDataSizeMatching(uint256 dealId) external returns (bool);

    /**
     * @notice Marks the given claims as terminated early.
     * @dev Only callable by TERMINATION_ORACLE role.
     * @param claims An array of claim IDs to mark as terminated.
     */
    function claimsTerminatedEarly(uint64[] calldata claims) external;
}

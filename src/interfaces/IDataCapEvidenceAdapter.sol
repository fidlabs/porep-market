// SPDX-License-Identifier: MIT
// solhint-disable func-name-mixedcase

pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {DataCapTypes} from "filecoin-solidity/v0.8/types/DataCapTypes.sol";
import {IStorageEvidenceAdapter} from "./IStorageEvidenceAdapter.sol";

/**
 * @title IDataCapEvidenceAdapter
 * @notice Interface for DataCap evidence interactions
 */
interface IDataCapEvidenceAdapter is IStorageEvidenceAdapter {
    /**
     * @notice This function transfers DataCap tokens from the client to the storage provider
     * @dev This function can only be called by the client
     * @param params The parameters for the transfer
     * @param dealId The id of the deal
     */
    function submitDataCapBatch(DataCapTypes.TransferParams calldata params, uint256 dealId) external;

    /**
     * @notice Replaces all broken tracked allocations for an active existing deal.
     * @dev Only callable by RESCUE_ROLE.
     * @param dealId The id of the deal to rescue.
     * @param params The DataCap transfer parameters that create replacement allocations.
     */
    function rescueDealAllocations(uint256 dealId, DataCapTypes.TransferParams calldata params) external;

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
     * @notice getter to retrieve allocation ids for a deal with pagination
     * @param dealId the id of the deal
     * @param offset pagination offset for the allocation ids
     * @param limit pagination limit for the allocation ids
     * @return ids list of allocation ids for the given deal
     * @return total total number of allocations for the given deal
     */
    function getAllocationIdsPerDeal(uint256 dealId, uint256 offset, uint256 limit)
        external
        view
        returns (CommonTypes.FilActorId[] memory ids, uint256 total);

    /**
     * @notice getter to retrieve claim ids for a deal with pagination
     * @param dealId the id of the deal
     * @param offset pagination offset for the claim ids
     * @param limit pagination limit for the claim ids
     * @return ids list of claim ids for the given deal
     * @return total total number of claims for the given deal
     */
    function getClaimIds(uint256 dealId, uint256 offset, uint256 limit)
        external
        view
        returns (CommonTypes.FilActorId[] memory ids, uint256 total);

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

    /**
     * @notice custom getter to retrieve allocated size in deal
     * @param dealId The id of the deal
     * @return sizeOfAllocations size of allocations for the selected deal
     */
    function getSizeOfAllocations(uint256 dealId) external view returns (uint256);

    /**
     * @notice Getter for the PoRepMarket contract address
     * @return Address of the PoRepMarket contract
     */
    function getPoRepMarketAddress() external view returns (address);

    /**
     * @notice Permanently marks the adapter as no longer operational. Reverts if the adapter is already non-operational
     * @dev Only callable by the admin
     */
    function disableAdapter() external;
}

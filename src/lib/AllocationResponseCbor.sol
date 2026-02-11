// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CBORDecoder} from "filecoin-solidity/v0.8/utils/CborDecode.sol";
import {DataCapTypes} from "filecoin-solidity/v0.8/types/DataCapTypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

/**
 * @title AllocationResponseCbor
 * @notice Decodes CBOR responses returned by DataCap allocation transfers.
 *         Extracts allocation IDs from the verifreg AllocationsResponse format
 *         used in DataCap transfer returns.
 */
library AllocationResponseCbor {
    error InvalidTopLevelArray();
    error InvalidFirstElement();
    error InvalidSecondElement();

    // solhint-disable function-max-lines
    /**
     * @notice Decode allocation IDs returned in the recipient_data of a DataCap transfer
     * @dev Decode Response from Allocation Request
     *      ref: builtin-actors/actors/verifreg/src/types.rs::AllocationsResponse
     *      cborData: [[2, []], [0, []], [5, 6]]
     *      Array with 3 elements:
     *      allocation_results
     *      extension_results
     *      new_allocations
     *      Reverts with InvalidTopLevelArray / InvalidFirstElement / InvalidSecondElement on unexpected layout
     * @param result DataCapTypes.TransferReturn containing recipient_data bytes to decode
     * @return allocationIds A uint64[] containing allocation IDs parsed from the CBOR payload
     */
    function decodeAllocationResponse(DataCapTypes.TransferReturn memory result)
        internal
        pure
        returns (CommonTypes.FilActorId[] memory allocationIds)
    {
        bytes memory cborData = result.recipient_data;
        uint256 topArrayLength;
        uint256 byteIdx = 0;
        // Read the top-level array.
        (topArrayLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
        // Expect exactly 3 elements.
        if (topArrayLength != 3) {
            revert InvalidTopLevelArray();
        }
        // First element: [1, []]
        // allocation_results: [newAllocations, [?]]
        {
            uint256 firstElemLength;
            (firstElemLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
            if (firstElemLength != 2) {
                revert InvalidFirstElement();
            }
            // First sub-element, ignore it
            // slither-disable-next-line unused-return
            (, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
            // Second sub-element
            uint256 innerLength;
            (innerLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
            if (innerLength != 0) {
                revert InvalidFirstElement();
            }
        }
        // Second element: [0, []]
        // extension_results: [extendedAllocations, [?]]
        {
            uint256 secondElemLength;
            (secondElemLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
            if (secondElemLength != 2) {
                revert InvalidSecondElement();
            }
            // First sub-element, extension are not supported atm so we ignore it
            // slither-disable-next-line unused-return
            (, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
            // Second sub-element
            uint256 innerLength;
            (innerLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
            if (innerLength != 0) {
                revert InvalidSecondElement();
            }
        }
        // third element: the allocation IDs array
        // new_allocations: [allocationID_1, ..., allocationID_N]
        uint256 allocationIdsLength;
        (allocationIdsLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
        allocationIds = new CommonTypes.FilActorId[](allocationIdsLength);
        for (uint256 i = 0; i < allocationIdsLength; i++) {
            uint64 allocationId;
            (allocationId, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
            allocationIds[i] = CommonTypes.FilActorId.wrap(allocationId);
        }
    }
}

// SPDX-License-Identifier: MIT

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SLITypes} from "../types/SLITypes.sol";

pragma solidity ^0.8.24;

/**
 * @title IPoRepMarket interface
 * @notice IPoRepMarket interface for interacting with PoRepMarket contract
 */
interface IPoRepMarket {
    /**
     * @notice DealState enum
     * @dev DealState enum is an enum that contains the states of a deal
     */
    enum DealState {
        Proposed,
        Accepted,
        Completed,
        Rejected,
        Terminated
    }

    /**
     * @notice DealProposal struct
     * @dev DealProposal struct is a struct that contains the details of a deal proposal
     */
    struct DealProposal {
        uint256 dealId;
        address client;
        CommonTypes.FilActorId provider;
        SLITypes.SLIThresholds requirements;
        address validator;
        DealState state;
        uint256 railId;
        uint256 totalDealSize;
    }

    /**
     * @notice Updates the validator address for a given deal ID
     * @param dealId The ID of the deal for which the validator address is to be updated
     */
    function updateValidatorAddress(uint256 dealId) external;

    /**
     * @notice Updates the rail ID for a given deal ID
     * @param dealId The ID of the deal for which the rail ID is to be updated
     * @param railId The new rail ID to be set for the deal
     */
    function updateRailId(uint256 dealId, uint256 railId) external;

    /**
     * @notice Terminate a deal
     * @dev Terminates a deal by setting the deal state to terminated
     * @param dealId The id of the deal proposal
     * @param terminator The address that terminated the deal
     * @param endEpoch The Filecoin epoch at which the deal was terminated
     */
    function terminateDeal(uint256 dealId, address terminator, uint256 endEpoch) external;

    /**
     * @notice Gets a deal proposal
     * @dev Gets a deal proposal by deal id
     * @param dealId The id of the deal proposal
     * @return DealProposal The deal proposal
     */
    function getDealProposal(uint256 dealId) external view returns (DealProposal memory);
}

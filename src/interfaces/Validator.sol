// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

/**
 * @title IValidatorRegistry interface
 * @notice IValidatorRegistry interface
 * @dev IValidatorRegistry interface is an interface that contains the function to check if a validator is correct
 */
interface IValidator {
    /**
     * @notice updateLockupPeriod function
     * @dev updateLockupPeriod function is a function that updates the lockup period for a validator
     * @param railId The id of the rail
     * @param newLockupPeriod The new lockup period
     */
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external;

    /**
     * @notice Sets the end epoch for the deal associated with this validator
     * @dev Only callable by POREP_SERVICE bot
     * @param dealId The ID of the deal
     * @param endEpoch The Filecoin epoch at which the deal ended
     */
    function setDealEndEpoch(uint256 dealId, CommonTypes.ChainEpoch endEpoch) external;
}


// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

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
}


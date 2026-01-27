// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/**
 * @title IValidatorRegistry interface
 * @notice IValidatorRegistry interface
 * @dev IValidatorRegistry interface is an interface that contains the function to check if a validator is correct
 */
interface IValidatorRegistry {
    /**
     * @notice isCorrectValidator function
     * @dev isCorrectValidator function is a function that checks if a validator is correct
     * @param validator The address of the validator
     * @return bool True if the validator is correct, false otherwise
     */
    function isCorrectValidator(address validator) external returns (bool);
}

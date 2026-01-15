// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {IValidatorRegistry} from "../../src/interfaces/ValidatorRegistry.sol";

contract ValidatorRegistryMock is IValidatorRegistry {
    mapping(address => bool) public validators;

    function isCorrectValidator(address _validator) external view returns (bool) {
        return validators[_validator];
    }

    function setValidator(address _validator, bool _isCorrect) external {
        validators[_validator] = _isCorrect;
    }
}

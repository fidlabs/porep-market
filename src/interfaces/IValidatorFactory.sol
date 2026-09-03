// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

/**
 * @title IValidatorFactory
 * @notice Interface for the ValidatorFactory contract
 */
interface IValidatorFactory {
    /**
     * @notice Creates a new instance of an upgradeable contract.
     * @dev Uses BeaconProxy to create a new proxy instance, pointing to the Beacon for the logic contract.
     * @dev Reverts if an instance for the given dealId already exists.
     * @param dealId The dealId for which the proxy was created.
     */
    function create(uint256 dealId) external;

    /**
     * @notice Checks if an address is a validator contract
     * @param contractAddress The address to check
     * @return True if the address is a validator contract, false otherwise
     */
    function isValidatorContract(address contractAddress) external view returns (bool);

    /**
     * @notice Gets the instance for a given deal
     * @param dealId The ID of the deal
     * @return The instance for the given deal
     */
    function getInstance(uint256 dealId) external view returns (address);

    /**
     * @notice Gets the beacon for the factory
     * @return The beacon for the factory
     */
    function getBeacon() external view returns (address);
}

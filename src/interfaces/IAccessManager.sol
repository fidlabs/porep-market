// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title IAccessManager
 * @notice Minimal role lookup used by PoRep Market protocol contracts.
 */
interface IAccessManager {
    /**
     * @notice Returns whether an account holds a global protocol role.
     * @param role Role identifier.
     * @param account Account to check.
     * @return True when the account holds the role.
     */
    function hasRole(bytes32 role, address account) external view returns (bool);
}

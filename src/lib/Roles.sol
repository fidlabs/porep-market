// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title Roles
 * @notice Internal global role identifiers shared by PoRep Market contracts.
 */
library Roles {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant POREP_SERVICE_ROLE = keccak256("POREP_SERVICE_ROLE");
    bytes32 internal constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 internal constant TERMINATION_ORACLE = keccak256("TERMINATION_ORACLE");
    bytes32 internal constant MARKET_ROLE = keccak256("MARKET_ROLE");
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
}

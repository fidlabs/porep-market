// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Roles} from "./lib/Roles.sol";

/**
 * @title AccessManager
 * @notice Stores the global roles used by PoRep Market V2 contracts.
 */
contract AccessManager is AccessControlDefaultAdminRules {
    /**
     * @notice Initial delay for default-admin transfers.
     */
    uint48 public constant INITIAL_DEFAULT_ADMIN_DELAY = 3 days;

    /**
     * @notice Global role allowed to upgrade protocol contracts.
     */
    bytes32 public constant UPGRADER_ROLE = Roles.UPGRADER_ROLE;
    /**
     * @notice Global role allowed to operate PoRep service flows.
     */
    bytes32 public constant POREP_SERVICE_ROLE = Roles.POREP_SERVICE_ROLE;
    /**
     * @notice Global role allowed to submit SLI attestations.
     */
    bytes32 public constant ORACLE_ROLE = Roles.ORACLE_ROLE;
    /**
     * @notice Global role allowed to report terminated claims.
     */
    bytes32 public constant TERMINATION_ORACLE = Roles.TERMINATION_ORACLE;
    /**
     * @notice Global role assigned to PoRepMarket.
     */
    bytes32 public constant MARKET_ROLE = Roles.MARKET_ROLE;
    /**
     * @notice Global role allowed to operate provider registry flows.
     */
    bytes32 public constant OPERATOR_ROLE = Roles.OPERATOR_ROLE;

    /**
     * @dev 0x5d869fec
     */
    error InvalidInitialUpgrader(address upgrader);
    /**
     * @dev 0x8ebc912f
     */
    error InvalidBeacon(address beacon);

    constructor(address initialAdmin, address initialUpgrader)
        AccessControlDefaultAdminRules(INITIAL_DEFAULT_ADMIN_DELAY, initialAdmin)
    {
        if (initialUpgrader == address(0)) revert InvalidInitialUpgrader(initialUpgrader);
        _grantRole(UPGRADER_ROLE, initialUpgrader);
    }

    /**
     * @notice Upgrades a beacon owned by this manager.
     * @param beacon UpgradeableBeacon to upgrade.
     * @param newImplementation New beacon implementation.
     */
    function upgradeBeacon(address beacon, address newImplementation) external onlyRole(UPGRADER_ROLE) {
        if (beacon.code.length == 0 || UpgradeableBeacon(beacon).owner() != address(this)) {
            revert InvalidBeacon(beacon);
        }
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
    }

    /// @inheritdoc AccessControlDefaultAdminRules
    function renounceRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) revert AccessControlEnforcedDefaultAdminRules();
        super.renounceRole(role, account);
    }
}

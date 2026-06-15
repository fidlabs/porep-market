// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MulticallUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {ISLIOracle} from "./interfaces/ISLIOracle.sol";
import {SharedTypes} from "./types/SharedTypes.sol";

/**
 * @title SLI Oracle
 * @notice Contract for managing and retrieving SLI values for deals
 */
contract SLIOracle is ISLIOracle, Initializable, AccessControlUpgradeable, UUPSUpgradeable, MulticallUpgradeable {
    /**
     * @notice Thrown when an invalid oracle address is provided
     * @dev 0x9589a27d
     */
    error InvalidOracle();

    /**
     * @notice Thrown when an invalid admin address is provided
     * @dev 0xb5eba9f0
     */
    error InvalidAdmin();

    /**
     * @notice Error thrown when retrievabilityBps in requirements is greater than 10_000
     * @dev 0x26f456b9
     */
    error InvalidRetrievabilityBps(uint16 value);

    /**
     * @notice Error thrown when indexingPct in requirements is greater than 100
     * @dev 0xad23dabc
     */
    error InvalidIndexingPct(uint8 value);

    /**
     * @notice Error indicating that an invalid deal ID was provided
     * @dev 0xb06db32a
     */
    error InvalidDealId();

    /**
     * @notice Upgradable role which allows for contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice Oracle role which allows to update SLI values
     */
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// @custom:storage-location erc7201:slioracle.storage.SLIOracleStorage
    struct SLIOracleStorage {
        mapping(uint256 dealId => SharedTypes.Attestation attestation) attestations;
    }

    // keccak256(abi.encode(uint256(keccak256("slioracle.storage.SLIOracleStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLIORACLE_STORAGE_LOCATION =
        0x0e62b9471a0c1cf5755a696ad58de1a3aec2ce3013fbd703781a8b7b7bd90100;

    /**
     * @notice Returns a reference to the SLIOracleStorage struct stored at a specific location in contract storage.
     * @return $ A storage pointer to the SLIOracleStorage struct
     */
    // NatSpec has been disabled due to its inability to properly handle the $ symbol
    // solhint-disable-next-line use-natspec
    function s() private pure returns (SLIOracleStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := SLIORACLE_STORAGE_LOCATION
        }
    }

    /**
     * @notice Emitted when SLI values are updated for a deal
     * @param dealId The id of the deal
     * @param lastUpdate The block numer of last update
     * @param slis New SLI values
     */
    event SLIAttestationUpdate(uint256 indexed dealId, uint256 lastUpdate, SharedTypes.SLIThresholds slis);

    /**
     * @notice Disabled constructor (proxy pattern)
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Contract initializator. Should be called during deployment
     * @param admin Contract owner
     * @param oracle Address that will get ORACLE_ROLE
     */
    function initialize(address admin, address oracle) external initializer {
        if (admin == address(0)) revert InvalidAdmin();
        if (oracle == address(0)) revert InvalidOracle();
        __AccessControl_init();
        __Multicall_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(ORACLE_ROLE, oracle);
    }

    /**
     * @notice Sets SLI values for a deal
     * @param dealId The id of the deal
     * @param slis New slis values for a deal
     */
    function setSLI(uint256 dealId, SharedTypes.SLIThresholds calldata slis) external onlyRole(ORACLE_ROLE) {
        if (dealId == 0) revert InvalidDealId();
        if (slis.retrievabilityBps > 10_000) revert InvalidRetrievabilityBps(slis.retrievabilityBps);
        if (slis.indexingPct > 100) revert InvalidIndexingPct(slis.indexingPct);

        uint256 currentEpoch = block.number;
        s().attestations[dealId] = SharedTypes.Attestation({lastUpdate: currentEpoch, slis: slis});
        emit SLIAttestationUpdate(dealId, currentEpoch, slis);
    }

    /**
     * @notice Retrieves the SLI values for a deal
     * @param dealId The id of the deal
     * @return attestation The attestation values for the deal
     */
    function getAttestation(uint256 dealId) external view returns (SharedTypes.Attestation memory attestation) {
        if (dealId == 0) revert InvalidDealId();
        SLIOracleStorage storage $ = s();
        attestation = $.attestations[dealId];
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Internal function used to implement new logic and check if upgrade is authorized
     * @dev Will revert (reject upgrade) if upgrade isn't called by UPGRADER_ROLE
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
    // solhint-enable no-empty-blocks
}

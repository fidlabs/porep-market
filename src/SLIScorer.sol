// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {SLIOracle} from "./SLIOracle.sol";
import {SLITypes} from "./types/SLITypes.sol";
import {ISLIScorer} from "./interfaces/ISLIScorer.sol";

/**
 * @title SLA Registry
 * @notice Upgradeable contract for managing SLA deals with role-based access control
 */
contract SLIScorer is ISLIScorer, Initializable, AccessControlUpgradeable, UUPSUpgradeable {
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
     * @notice Thrown when no attestation exists for the given provider
     * @param provider The FilActor ID of the provider without attestation
     * @dev 0xddd4695c
     */
    error NoAttestation(CommonTypes.FilActorId provider);

    /**
     * @notice Thrown when an attestation has expired for the given provider
     * @param provider The FilActor ID of the provider with expired attestation
     * @dev 0x06c09405
     */
    error AttestationExpired(CommonTypes.FilActorId provider);

    /**
     * @notice Upgradable role which allows for contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice Number of epochs in one month
     * @dev 30 days * 24 hours/day * 60 minutes/hour * 2 epochs/minute = 86,400 epochs
     */
    uint256 private constant EPOCHS_IN_MONTH = 86_400;

    /// @custom:storage-location erc7201:sliscorer.storage.SLIScorerStorage
    struct SLIScorerStorage {
        SLIOracle oracle;
    }

    // keccak256(abi.encode(uint256(keccak256("sliscorer.storage.SLIScorerStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLISCORER_STORAGE_LOCATION =
        0xfc214f7b8d05a80223ac984f4c5d514cbee885916c0eb499aae1223022938a00;

    /**
     * @notice Returns a reference to the SLIScorerStorage struct stored at a specific location in contract storage.
     * @return $ Storage pointer to the SLIScorerStorage struct
     */
    // NatSpec has been disabled due to its inability to properly handle the $ symbol
    // solhint-disable-next-line use-natspec
    function s() private pure returns (SLIScorerStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := SLISCORER_STORAGE_LOCATION
        }
    }

    /**
     * @notice Disabled constructor (proxy pattern)
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Contract initializator. Should be called during deployment
     * @param admin Contract owner
     * @param oracle_ SLIOracle
     */
    function initialize(address admin, SLIOracle oracle_) external initializer {
        __AccessControl_init();
        if (admin == address(0)) revert InvalidAdmin();
        if (address(oracle_) == address(0)) revert InvalidOracle();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        s().oracle = oracle_;
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Internal function used to implement new logic and check if upgrade is authorized
     * @dev Will revert (reject upgrade) if upgrade isn't called by UPGRADER_ROLE
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // solhint-enable no-empty-blocks

    // solhint-disable gas-strict-inequalities
    /**
     * @notice Calculate the score for a given provider and required SLI thresholds.
     * @param provider The ID of the provider.
     * @param required The SLI thresholds required for the client.
     * @return score The score for SLI.
     */
    function calculateScore(CommonTypes.FilActorId provider, SLITypes.SLIThresholds calldata required)
        external
        view
        returns (uint256 score)
    {
        SLITypes.Attestation memory attestation = s().oracle.getAttestation(provider);

        if (attestation.lastUpdate == 0) revert NoAttestation(provider);

        uint256 currentEpoch = block.number;
        if (currentEpoch - attestation.lastUpdate > EPOCHS_IN_MONTH) {
            revert AttestationExpired(provider);
        }

        uint256 slasDefined;
        uint256 slasMet;

        if (required.retrievabilityBps != 0) {
            slasDefined++;
            if (required.retrievabilityBps <= attestation.slis.retrievabilityBps) slasMet++;
        }

        if (required.bandwidthMbps != 0) {
            slasDefined++;
            if (required.bandwidthMbps <= attestation.slis.bandwidthMbps) slasMet++;
        }

        if (required.latencyMs != 0) {
            slasDefined++;
            if (required.latencyMs >= attestation.slis.latencyMs) slasMet++;
        }

        if (required.indexingPct != 0) {
            slasDefined++;
            if (required.indexingPct <= attestation.slis.indexingPct) slasMet++;
        }

        if (slasDefined == 0) return 100; // If no SLAs defined
        return 100 * slasMet / slasDefined;
    }
    // solhint-enable gas-strict-inequalities
}

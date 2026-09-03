// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SLIOracle} from "./SLIOracle.sol";
import {AccessControlledUpgradeable} from "./abstracts/AccessControlledUpgradeable.sol";
import {Roles} from "./lib/Roles.sol";
import {SharedTypes} from "./types/SharedTypes.sol";
import {ISLIScorer} from "./interfaces/ISLIScorer.sol";

/**
 * @title SLA Registry
 * @notice Upgradeable contract for managing SLA deals with role-based access control
 */
contract SLIScorer is ISLIScorer, AccessControlledUpgradeable, UUPSUpgradeable {
    /**
     * @notice Thrown when an invalid oracle address is provided
     * @dev 0x9589a27d
     */
    error InvalidOracle();

    /**
     * @notice Thrown when no attestation exists for the given provider
     * @param dealId The deal ID of the deal without attestation
     * @dev 0xadd9e17f
     */
    error NoAttestation(uint256 dealId);

    /**
     * @notice Thrown when an attestation has expired for the given deal
     * @param dealId The deal ID of the deal with expired attestation
     * @dev 0xa5d8657a
     */
    error AttestationExpired(uint256 dealId);

    /**
     * @notice Error indicating that an invalid deal ID was provided
     * @dev 0xb06db32a
     */
    error InvalidDealId();

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
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Contract initializator. Should be called during deployment
     * @param _accessManager Protocol AccessManager address
     * @param oracle_ SLIOracle
     */
    function initialize(address _accessManager, SLIOracle oracle_) external initializer {
        __AccessControlled_init(_accessManager);
        if (address(oracle_) == address(0)) revert InvalidOracle();
        s().oracle = oracle_;
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Internal function used to implement new logic and check if upgrade is authorized
     * @dev Will revert (reject upgrade) if upgrade isn't called by UPGRADER_ROLE
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    // solhint-enable no-empty-blocks

    // solhint-disable gas-strict-inequalities
    /**
     * @notice Calculate the score for a given deal and required SLI thresholds.
     * @param dealId The id of the deal
     * @param required The SLI thresholds required for the client.
     * @return score The score for SLI.
     */
    function calculateScore(uint256 dealId, SharedTypes.SLIThresholds calldata required)
        external
        view
        returns (uint256 score)
    {
        if (dealId == 0) revert InvalidDealId();

        SharedTypes.Attestation memory attestation = s().oracle.getAttestation(dealId);

        if (attestation.lastUpdate == 0) revert NoAttestation(dealId);

        uint256 currentEpoch = block.number;
        if (currentEpoch - attestation.lastUpdate > EPOCHS_IN_MONTH) {
            revert AttestationExpired(dealId);
        }

        uint256 slasDefined;
        uint256 slasMet;

        if (required.retrievabilityBps != 0) {
            slasDefined++;
            if (required.retrievabilityBps <= attestation.slis.retrievabilityBps) slasMet++;
        }

        if (required.bandwidthBytesPerSecond != 0) {
            slasDefined++;
            if (required.bandwidthBytesPerSecond <= attestation.slis.bandwidthBytesPerSecond) slasMet++;
        }

        if (required.latencyMs != 0) {
            slasDefined++;
            uint16 measuredLatencyMs = attestation.slis.latencyMs;
            bool latencyMeasured = measuredLatencyMs != 0 && measuredLatencyMs != SharedTypes.LATENCY_UNMEASURED;
            if (latencyMeasured && required.latencyMs >= measuredLatencyMs) slasMet++;
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

// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity =0.8.30;

/// @title IFilecoinServiceMetadata
/// @notice Minimal service identity interface for Filecoin Onchain Cloud service contracts.
/// @dev FCSS vendors this small interface locally instead of depending on the full
///      `filecoin-services` repository. Filecoin Onchain Cloud recommends this
///      interface so explorers and clients can read descriptive service metadata
///      directly instead of maintaining hard-coded address maps.
///      The returned values are self-reported and suitable only for display.
///      Callers must not use them for authorization or service verification.
/// @custom:canonical-source https://github.com/FilOzone/filecoin-services/blob/c7ad4c5a700455a97f2f776d087ae23e9779511f/service_contracts/src/IFilecoinServiceMetadata.sol
/// @custom:recommendation https://github.com/FilOzone/filecoin-services/blob/c7ad4c5a700455a97f2f776d087ae23e9779511f/README.md#service-metadata
interface IFilecoinServiceMetadata {
    /// @notice Short, human-readable service name.
    /// @return serviceName Short, human-readable service name.
    function name() external view returns (string memory);

    /// @notice Concise, human-readable service description.
    /// @dev Implementations must limit the UTF-8 encoded value to 256 bytes.
    ///      Consumers should treat the value as untrusted display-only text.
    /// @return serviceDescription Concise, human-readable service description.
    function description() external view returns (string memory);

    /// @notice Optional URL for service documentation, specifications, or source code.
    /// @dev Implementations must limit the UTF-8 encoded value to 256 bytes and
    ///      return an empty string when no homepage is provided.
    /// @return serviceHomepage Optional URL for service documentation, specifications, or source code.
    function homepage() external view returns (string memory);
}

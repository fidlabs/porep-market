// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {MinerAPI} from "filecoin-solidity/v0.8/MinerAPI.sol";
import {FilAddresses} from "filecoin-solidity/v0.8/utils/FilAddresses.sol";

/**
 * @title MinerUtils
 * @notice Library for retrieving and validating Filecoin miner actor information
 */
library MinerUtils {
    /**
     * @notice Error indicating a non-zero exit code from an FVM call
     */
    error ExitCodeError();

    /**
     * @notice Checks if the given Ethereum address is a controlling address for a miner actor.
     * @param minerID The Filecoin miner actor ID to check controlling address for.
     * @param addr The Ethereum address to verify as a controlling address.
     * @return bool True if the address is a controlling address for the miner, false otherwise.
     */
    function isControllingAddress(CommonTypes.FilActorId minerID, address addr) internal view returns (bool) {
        CommonTypes.FilAddress memory filAddr = FilAddresses.fromEthAddress(addr);
        (int256 exitCode, bool controllingAddress) = MinerAPI.isControllingAddress(minerID, filAddr);
        if (exitCode != 0) {
            revert ExitCodeError();
        }
        return controllingAddress;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MinerTypes} from "filecoin-solidity/v0.8/types/MinerTypes.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {MinerAPI} from "filecoin-solidity/v0.8/MinerAPI.sol";

/**
 * @title MinerUtils
 * @notice Library for retrieving and validating Filecoin miner actor information
 */
library MinerUtils {
    /**
     * @notice Error indicating a non-zero exit code from an FVM call
     */
    error ExitCodeError();

    // Temporarily commented out to not break coverage CI
    // /**
    //  * @notice Retrieves the owner information for a given miner actor ID.
    //  * @dev Wraps the numeric minerID into a FilActorId and calls MinerAPI.getOwner.
    //  *      Reverts with ExitCodeError if the FVM call returns a non-zero exit code.
    //  * @param minerID The numeric Filecoin miner actor id.
    //  * @return ownerData The MinerTypes.GetOwnerReturn struct returned by the actor call.
    //  */
    // function getOwner(CommonTypes.FilActorId minerID) internal view returns (MinerTypes.GetOwnerReturn memory) {
    //     (int256 exitCode, MinerTypes.GetOwnerReturn memory ownerData) = MinerAPI.getOwner(minerID);
    //     if (exitCode != 0) {
    //         revert ExitCodeError();
    //     }
    //     return ownerData;
    // }
}

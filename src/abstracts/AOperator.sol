// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFilecoinPayV1} from "../interfaces/IFilecoinPayV1.sol";
import {IOperator} from "../interfaces/IOperator.sol";

/**
 * @title Operator abstract contract
 * @notice Abstract contract defining operator functions for creating and managing payment rails in the FilecoinPayV1 system.
 * This contract provides internal helper functions for interacting with the FilecoinPayV1 interface, while leaving the implementation of the external functions to derived contracts.
 */
abstract contract AOperator is IOperator {
    /**
     * @notice Internal function to create a payment rail
     * @param filecoinPay The FilecoinPayV1 interface
     * @param token The ERC20 token to use for the payment rail
     * @param payer The address paying the tokens
     * @param payee The address receiving the tokens
     * @param commissionRateBps The commission rate in basis points for the payment rail
     * @param serviceFeeRecipient The recipient of service fees for the payment rail
     * @return railId ID of the created payment rail
     */
    function _createRail(
        IFilecoinPayV1 filecoinPay,
        IERC20 token,
        address payer,
        address payee,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) internal returns (uint256 railId) {
        railId = filecoinPay.createRail(token, payer, payee, address(0), commissionRateBps, serviceFeeRecipient);
    }

    /**
     * @notice Internal function to update the lockup period of a payment rail
     * @param filecoinPay The FilecoinPayV1 interface
     * @param railId ID of the payment rail
     * @param newLockupPeriod New lockup period to set
     * @param lockupFixed Fixed lockup amount
     */
    function _updateLockupPeriod(
        IFilecoinPayV1 filecoinPay,
        uint256 railId,
        uint256 newLockupPeriod,
        uint256 lockupFixed
    ) internal {
        filecoinPay.modifyRailLockup(railId, newLockupPeriod, lockupFixed);
    }

    /**
     * @notice Internal function to modify the payment rate and optionally make a one-time payment.
     * @param filecoinPay The FilecoinPayV1 interface
     * @param railId The ID of the rail to modify.
     * @param newRate The new payment rate (per epoch). This new rate applies starting the next epoch after the current one.
     * @param oneTimePayment Optional one-time payment amount to transfer immediately, taken out of the rail's fixed lockup.
     */
    function _modifyRailPayment(IFilecoinPayV1 filecoinPay, uint256 railId, uint256 newRate, uint256 oneTimePayment)
        internal
    {
        filecoinPay.modifyRailPayment(railId, newRate, oneTimePayment);
    }

    /**
     * @notice Internal function to terminate a payment rail, preventing further payments after the rail's lockup period. After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced.
     * @param filecoinPay The FilecoinPayV1 interface
     * @param railId The ID of the rail to terminate.
     */
    function _terminateRail(IFilecoinPayV1 filecoinPay, uint256 railId) internal {
        filecoinPay.terminateRail(railId);
    }

    /**
     * @notice Internal function to settle a payment rail.
     * @param filecoinPay The FilecoinPayV1 interface
     * @param railId The ID of the rail to settle.
     * @param untilEpoch The epoch up to which to settle.
     */
    function _settleRail(IFilecoinPayV1 filecoinPay, uint256 railId, uint256 untilEpoch) internal {
        filecoinPay.settleRail(railId, untilEpoch);
    }
}

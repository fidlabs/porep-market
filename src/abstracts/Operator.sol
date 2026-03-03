// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFilecoinPayV1} from "../interfaces/IFilecoinPayV1.sol";

/**
 * @title Operator abstract contract
 * @notice Abstract contract defining operator functions for creating payment rails and updating lockup periods in Filecoin Pay rails
 */
abstract contract Operator {
    /**
     * @notice Creates a payment rail with the specified parameters
     * @param token The ERC20 token to use for the payment rail
     * @param payer The address paying the tokens
     * @param payee The address receiving the tokens
     */
    function createRail(IERC20 token, address payer, address payee) external virtual;

    /**
     * @notice Updates the lockup period of a payment rail
     * @param railId ID of the payment rail
     * @param newLockupPeriod New lockup period to set
     */
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external virtual;

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
        railId = filecoinPay.createRail(token, payer, payee, address(this), commissionRateBps, serviceFeeRecipient);
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
}

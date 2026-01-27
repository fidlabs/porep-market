// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoRepMarket} from "../PoRepMarket.sol";

/**
 * @title Operator abstract contract
 * @notice Abstract contract defining operator functions for managing payment rails and deposits.
 */
abstract contract Operator {
    /**
     * @notice Deposits tokens with permit and creates a payment rail for a deal.
     * @param token The ERC20 token to deposit
     * @param payer The address paying the tokens
     * @param payee The address receiving the tokens
     * @param amount The amount of tokens to deposit
     * @param deadline The deadline for the permit
     * @param v The v component of the permit signature
     * @param r The r component of the permit signature
     * @param s The s component of the permit signature
     * @param rateAllowance The rate allowance for the operator
     * @param lockupAllowance The lockup allowance for the operator
     * @param maxLockupPeriod The maximum lockup period for the payment rail
     * @param commissionRateBps The commission rate in basis points for the payment rail
     * @param serviceFeeRecipient The recipient of service fees for the payment rail
     * @param dealId The ID of the deal associated with the payment rail
     * @param poRepMarket The PoRepMarket contract instance
     */
    function depositWithPermitAndCreateRailForDeal(
        IERC20 token,
        address payer,
        address payee,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod,
        uint256 commissionRateBps,
        address serviceFeeRecipient,
        uint256 dealId,
        PoRepMarket poRepMarket
    ) external virtual;

    /**
     * @notice Updates the lockup period of a payment rail.
     * @param railId ID of the payment rail
     * @param newLockupPeriod New lockup period to set
     * @param lockupFixed Fixed lockup amount
     */
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod, uint256 lockupFixed) external virtual;
}

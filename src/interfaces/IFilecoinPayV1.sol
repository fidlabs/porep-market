// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interface for FilecoinPayV1
 * @notice Includes necessary functions from FilecoinPayV1 for operator interactions
 */
interface IFilecoinPayV1 {
    /**
     * @notice Deposits tokens with permit and approves the operator in a single transaction
     * @param token The ERC20 token to deposit
     * @param payer The address paying the tokens
     * @param amount The amount of tokens to deposit
     * @param deadline The deadline for the permit
     * @param v The v component of the permit signature
     * @param r The r component of the permit signature
     * @param s The s component of the permit signature
     * @param operator The operator address to approve
     * @param rateAllowance The rate allowance for the operator
     * @param lockupAllowance The lockup allowance for the operator
     * @param maxLockupPeriod The maximum lockup period for the payment rail
     */
    function depositWithPermitAndApproveOperator(
        IERC20 token,
        address payer,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) external;

    /**
     * @notice Creates a payment rail
     * @param token The ERC20 token to use for the payment rail
     * @param payer The address paying the tokens
     * @param payee The address receiving the tokens
     * @param operator The operator address for the payment rail
     * @param commissionRateBps The commission rate in basis points for the payment rail
     * @param serviceFeeRecipient The recipient of service fees for the payment rail
     * @return railId ID of the created payment rail
     */
    function createRail(
        IERC20 token,
        address payer,
        address payee,
        address operator,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) external returns (uint256);

    /**
     * @notice Modifies the lockup period of a payment rail
     * @param railId ID of the payment rail
     * @param newLockupPeriod New lockup period to set
     * @param lockupFixed Fixed lockup amount
     */
    function modifyRailLockup(uint256 railId, uint256 newLockupPeriod, uint256 lockupFixed) external;
}

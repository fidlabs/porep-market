// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interface for FilecoinPayV1
 * @notice Includes necessary functions from FilecoinPayV1 for operator interactions
 */
interface IFilecoinPayV1 {
    /**
     * @notice Deposits tokens using permit (EIP-2612) approval in a single transaction.
     * @param token The ERC20 token address to deposit.
     * @param to The address whose account will be credited (must be the permit signer).
     * @param amount The amount of tokens to deposit.
     * @param deadline Permit deadline (timestamp).
     * @param v The v component of the permit signature.
     * @param r The r component of the permit signature.
     * @param s The s component of the permit signature.
     */
    function depositWithPermit(
        IERC20 token,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @notice Updates the approval status and allowances for an operator on behalf of the message sender.
     * @param token The ERC20 token address for which the approval is being set.
     * @param operator The address of the operator whose approval is being modified.
     * @param approved Whether the operator is approved (true) or not (false) to create new rails.
     * @param rateAllowance The maximum payment rate the operator can set across all rails created by the operator on behalf of the message sender. If this is less than the current payment rate, the operator will only be able to reduce rates until they fall below the target.
     * @param lockupAllowance The maximum amount of funds the operator can lock up on behalf of the message sender towards future payments. If this exceeds the current total amount of funds locked towards future payments, the operator will only be able to reduce future lockup.
     * @param maxLockupPeriod The maximum number of epochs (blocks) the operator can lock funds for. If this is less than the current lockup period for a rail, the operator will only be able to reduce the lockup period.
     */
    function setOperatorApproval(
        IERC20 token,
        address operator,
        bool approved,
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

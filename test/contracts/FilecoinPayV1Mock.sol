// SPDX-License-Identifier: MIT
// solhint-disable
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FilecoinPayV1Mock {
    IERC20 public lastToken;
    address public lastPayer;
    uint256 public lastAmount;
    uint256 public lastDeadline;
    uint8 public lastV;
    bytes32 public lastR;
    bytes32 public lastS;
    address public lastOperator;
    uint256 public lastRateAllowance;
    uint256 public lastLockupAllowance;
    uint256 public lastMaxLockupPeriod;

    IERC20 public lastRailToken;
    address public lastRailPayer;
    address public lastRailPayee;
    address public lastRailOperator;
    uint256 public lastCommissionRateBps;
    address public lastServiceFeeRecipient;

    uint256 public lastRailIdForLockup;
    uint256 public lastNewLockupPeriod;
    uint256 public lastLockupFixed;

    uint256 public nextRailId = 1;

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
    ) external {
        lastToken = token;
        lastPayer = payer;
        lastAmount = amount;
        lastDeadline = deadline;
        lastV = v;
        lastR = r;
        lastS = s;
        lastOperator = operator;
        lastRateAllowance = rateAllowance;
        lastLockupAllowance = lockupAllowance;
        lastMaxLockupPeriod = maxLockupPeriod;
    }

    function createRail(
        IERC20 token,
        address payer,
        address payee,
        address operator,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) external returns (uint256 railId) {
        lastRailToken = token;
        lastRailPayer = payer;
        lastRailPayee = payee;
        lastRailOperator = operator;
        lastCommissionRateBps = commissionRateBps;
        lastServiceFeeRecipient = serviceFeeRecipient;

        railId = nextRailId++;
    }

    function modifyRailLockup(uint256 railId, uint256 newLockupPeriod, uint256 lockupFixed) external {
        lastRailIdForLockup = railId;
        lastNewLockupPeriod = newLockupPeriod;
        lastLockupFixed = lockupFixed;
    }
}

// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.30;

import {IFilecoinPayV1} from "../../src/interfaces/IFilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FilecoinPayV1Mock is IFilecoinPayV1 {
    uint256 public nextRailId = 1;
    mapping(uint256 => bool) public terminated;
    mapping(IERC20 => mapping(address => mapping(address => OperatorApproval))) internal _operatorApprovals;

    struct OperatorApproval {
        bool isApproved;
        uint256 rateAllowance;
        uint256 lockupAllowance;
        uint256 rateUsage;
        uint256 lockupUsage;
        uint256 maxLockupPeriod;
    }

    function setOperatorApproval(
        IERC20 token,
        address client,
        address operator,
        bool isApproved,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 rateUsage,
        uint256 lockupUsage,
        uint256 maxLockupPeriod
    ) external {
        _operatorApprovals[token][client][operator] = OperatorApproval({
            isApproved: isApproved,
            rateAllowance: rateAllowance,
            lockupAllowance: lockupAllowance,
            rateUsage: rateUsage,
            lockupUsage: lockupUsage,
            maxLockupPeriod: maxLockupPeriod
        });
    }

    function operatorApprovals(IERC20 token, address client, address operator)
        external
        view
        override
        returns (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        )
    {
        OperatorApproval storage approval = _operatorApprovals[token][client][operator];
        return (
            approval.isApproved,
            approval.rateAllowance,
            approval.lockupAllowance,
            approval.rateUsage,
            approval.lockupUsage,
            approval.maxLockupPeriod
        );
    }

    struct Rail {
        IERC20 token;
        address payer;
        address payee;
        address operator;
        uint256 commissionRateBps;
        address serviceFeeRecipient;
        uint256 lockupPeriod;
        uint256 lockupFixed;
    }

    mapping(uint256 => Rail) public rails;

    function createRail(
        IERC20 token,
        address payer,
        address payee,
        address operator,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) external override returns (uint256 railId) {
        railId = nextRailId++;
        rails[railId] = Rail({
            token: token,
            payer: payer,
            payee: payee,
            operator: operator,
            commissionRateBps: commissionRateBps,
            serviceFeeRecipient: serviceFeeRecipient,
            lockupPeriod: 0,
            lockupFixed: 0
        });
    }

    function modifyRailLockup(uint256 railId, uint256 newLockupPeriod, uint256 lockupFixed) external override {
        Rail storage r = rails[railId];
        r.lockupPeriod = newLockupPeriod;
        r.lockupFixed = lockupFixed;
    }

    function modifyRailPayment(uint256 railId, uint256 newRate, uint256 oneTimePayment) external override {}

    function terminateRail(uint256 railId) external override {
        terminated[railId] = true;
    }

    function getRailLockup(uint256 railId) external view returns (uint256 lockupPeriod, uint256 lockupFixed) {
        Rail storage r = rails[railId];
        return (r.lockupPeriod, r.lockupFixed);
    }
}

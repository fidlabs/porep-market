// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Validator is AccessControlUpgradeable {
    function initialize(
        address,
        address,
        address,
        CommonTypes.FilActorId,
        address,
        address,
        DepositWithRailParams calldata
    ) external initializer {
        __AccessControl_init();
    }

    constructor() {
        _disableInitializers();
    }

    struct DepositWithRailParams {
        IERC20 token;
        address payer;
        address payee;
        uint256 amount;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 dealId;
    }
}

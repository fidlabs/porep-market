// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity =0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Validator is AccessControlUpgradeable {
    function initialize(
        address, // admin
        address, // _porepService
        address, // _filecoinPay
        address, // _SLIScorer
        address, // _clientSC
        address, // _poRepMarket
        uint256 //_dealId
    )
        external
        initializer
    {
        __AccessControl_init();
    }

    constructor() {
        _disableInitializers();
    }
}

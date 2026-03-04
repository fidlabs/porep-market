// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoRepMarket} from "../../src/PoRepMarket.sol";

contract DemoHelper {
    PoRepMarket public immutable poRepMarket;
    address public immutable admin;

    error OnlyAdmin();

    constructor(address _poRepMarket, address _admin) {
        poRepMarket = PoRepMarket(_poRepMarket);
        admin = _admin;
    }

    function completeDeal(uint256 dealId) external {
        if (msg.sender != admin) revert OnlyAdmin();
        poRepMarket.completeDeal(dealId);
    }
}

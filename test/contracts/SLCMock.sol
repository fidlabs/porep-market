// SPDX-License-Identifier: MIT
// solhint-disable

pragma solidity ^0.8.24;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";

contract SLCMock {
    error ScoreOutOfBounds();

    mapping(CommonTypes.FilActorId provider => uint256 score) public scores;

    function setScore(CommonTypes.FilActorId provider, uint256 score) external {
        if (score != 0 && score != 100) {
            revert ScoreOutOfBounds();
        }
        scores[provider] = score;
    }

    function getScore(CommonTypes.FilActorId provider) external view returns (uint256) {
        return scores[provider];
    }
}

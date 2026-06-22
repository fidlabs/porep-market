// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IPoRepMarket} from "../interfaces/IPoRepMarket.sol";
import {PoRepTypes} from "../types/PoRepTypes.sol";
import {FVMSector, SectorStatus} from "../../lib/fvm-solidity/src/FVMSector.sol";

/**
 * @title PoRepMarketSectorStatusInspector
 * @notice Helper contract to validate sector status for a given deal ID against claimed status
 * @dev Inherits {Multicall} so multiple validateSectorStatus calls can be batched into a single call
 */
contract PoRepMarketSectorStatusInspector is Multicall {
    /**
     * @notice Error indicating that an invalid deal ID was provided
     * @dev 0xb06db32a
     */
    error InvalidDealId();

    /**
     * @notice Error indicating that the PoRepMarket address provided during contract deployment is invalid
     * @dev 0xc9cc4a06
     */
    error InvalidPoRepMarketAddress();

    /**
     * @notice PoRepMarket contract address used to fetch deal details for a given deal ID
     */
    IPoRepMarket public immutable POREPMARKET_CONTRACT;

    /**
     * @notice Initializes the PoRepMarketSectorStatusInspector contract with the PoRepMarket contract address
     * @param _poRepMarketContract Address of the PoRepMarket contract
     */
    constructor(address _poRepMarketContract) {
        if (_poRepMarketContract == address(0)) revert InvalidPoRepMarketAddress();
        POREPMARKET_CONTRACT = IPoRepMarket(_poRepMarketContract);
    }

    /**
     * @notice Validates that a sector's actual status matches the claimed status.
     *         Resolves the miner actor ID from the deal's provider, then calls the
     *         miner actor's ValidateSectorStatus.
     * @param dealId The id of the deal whose provider's sector is being validated
     * @param sector The sector number
     * @param status The claimed sector status
     * @param deadline Claimed deadline index, or NO_DEADLINE if sector is absent from the AMT
     * @param partition Claimed partition index, or NO_PARTITION if sector is absent from the AMT
     * @return valid Whether the claimed status matches the actual status
     */
    function validateSectorStatus(uint256 dealId, uint64 sector, SectorStatus status, int64 deadline, int64 partition)
        external
        returns (bool valid)
    {
        if (dealId == 0) revert InvalidDealId();
        PoRepTypes.Deal memory deal = POREPMARKET_CONTRACT.getDeal(dealId);
        uint64 minerId = CommonTypes.FilActorId.unwrap(deal.provider);
        return FVMSector.validateSectorStatus(minerId, sector, status, deadline, partition);
    }
}

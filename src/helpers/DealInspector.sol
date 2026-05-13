// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";
import {VerifRegAPI} from "filecoin-solidity/v0.8/VerifRegAPI.sol";
import {IClient} from "../interfaces/IClient.sol";
import {IPoRepMarket} from "../interfaces/IPoRepMarket.sol";
import {PoRepTypes} from "../types/PoRepTypes.sol";
import {FVMSector, SectorStatus} from "../../lib/fvm-solidity/src/FVMSector.sol";

/**
 * @title DealInspector
 * @notice Helper contract to fetch claims for a given deal ID and validate sector status against claimed status
 */
contract DealInspector {
    /**
     * @notice Error indicating that the call to VerifReg's GetClaims method failed
     * @dev 0x9359037c
     */
    error GetClaimsCallFailed();

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
     * @notice Error indicating that the client smart contract address provided during contract deployment is invalid
     * @dev 0x4d9c0a3f
     */
    error InvalidClientAddress();

    /**
     * @notice Client smart contract address used to fetch allocation IDs for a given deal ID
     */
    IClient public immutable CLIENT_CONTRACT;

    /**
     * @notice PoRepMarket contract address used to fetch deal proposal details for a given deal ID
     */
    IPoRepMarket public immutable POREPMARKET_CONTRACT;

    /**
     * @notice Initializes the DealInspector contract with the addresses of the client and PoRepMarket contracts
     * @param _clientContract Address of the client smart contract
     * @param _poRepMarketContract Address of the PoRepMarket contract
     */
    constructor(address _clientContract, address _poRepMarketContract) {
        _ensureNonZeroAddresses(_clientContract, _poRepMarketContract);
        CLIENT_CONTRACT = IClient(_clientContract);
        POREPMARKET_CONTRACT = IPoRepMarket(_poRepMarketContract);
    }

    /**
     * @notice Fetches claims for a given deal ID
     * @param dealId The ID of the deal for which to fetch claims
     * @return VerifRegTypes.GetClaimsReturn The claims associated with the deal ID
     */
    function getClaims(uint256 dealId) external view returns (VerifRegTypes.GetClaimsReturn memory) {
        if (dealId == 0) {
            revert InvalidDealId();
        }
        PoRepTypes.DealProposal memory deal = POREPMARKET_CONTRACT.getDealProposal(dealId);
        CommonTypes.FilActorId[] memory ids = CLIENT_CONTRACT.getClientAllocationIdsPerDeal(dealId);
        VerifRegTypes.GetClaimsParams memory getClaimsParams =
            VerifRegTypes.GetClaimsParams({provider: deal.provider, claim_ids: ids});

        (int256 exitCode, VerifRegTypes.GetClaimsReturn memory result) = VerifRegAPI.getClaims(getClaimsParams);
        if (exitCode != 0) {
            revert GetClaimsCallFailed();
        }
        return result;
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
        if (dealId == 0) {
            revert InvalidDealId();
        }
        PoRepTypes.DealProposal memory deal = POREPMARKET_CONTRACT.getDealProposal(dealId);
        uint64 minerId = CommonTypes.FilActorId.unwrap(deal.provider);
        return FVMSector.validateSectorStatus(minerId, sector, status, deadline, partition);
    }

    /**
     * @notice Checks if a sector is fully dead (terminated or never committed)
     *         Works without knowing deadline/partition - uses NO_DEADLINE/NO_PARTITION sentinels (-1, -1)
     *         Returns false for sectors still tracked in the miner's sectors AMT/
     * @param minerId The miner actor ID
     * @param sector The sector number
     * @return Whether the sector is absent from the miner's sectors AMT, and is fully dead
     */
    function isSectorDead(uint64 minerId, uint64 sector) external returns (bool) {
        (bool ok, bool valid) = FVMSector.tryValidateSectorStatus(minerId, sector, SectorStatus.Dead, -1, -1);
        return ok && valid;
    }

    /**
     * @notice Ensures that the provided addresses are non-zero
     * @param _clientSC Address of the client smart contract address
     * @param _poRepMarket Address of the PoRepMarket contract address
     */
    function _ensureNonZeroAddresses(address _clientSC, address _poRepMarket) internal pure {
        if (_clientSC == address(0)) {
            revert InvalidClientAddress();
        }
        if (_poRepMarket == address(0)) {
            revert InvalidPoRepMarketAddress();
        }
    }
}

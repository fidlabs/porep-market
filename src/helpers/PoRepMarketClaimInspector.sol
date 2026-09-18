// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";
import {VerifRegAPI} from "filecoin-solidity/v0.8/VerifRegAPI.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IDataCapEvidenceAdapter} from "../interfaces/IDataCapEvidenceAdapter.sol";
import {IPoRepMarket} from "../interfaces/IPoRepMarket.sol";
import {PoRepTypes} from "../types/PoRepTypes.sol";
import {FVMSector, SectorStatus} from "../../lib/fvm-solidity/src/FVMSector.sol";

/**
 * @title PoRepMarketClaimInspector
 * @notice Helper contract to fetch claims for a given deal ID and validate sector status against claimed status
 * @dev Inherits {Multicall} so multiple validateSectorStatus calls can be batched into a single call
 */
contract PoRepMarketClaimInspector is Multicall {
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
     * @notice Error indicating that the DataCapEvidenceAdapter address provided during contract deployment is invalid
     * @dev 0xd2178646
     */
    error InvalidDataCapEvidenceAdapterAddress();

    /**
     * @notice Error indicating a mismatch between the number of claims returned and the number of claim IDs processed
     * @dev 0xe38fdaac
     */
    error ClaimIdsMismatch(uint256 claimsLength, uint256 claimIdsLength);

    /**
     * @notice DataCapEvidenceAdapter address used to fetch claim IDs for a given deal ID
     */
    IDataCapEvidenceAdapter public immutable DATA_CAP_EVIDENCE_ADAPTER;

    /**
     * @notice PoRepMarket contract address used to fetch deal details for a given deal ID
     */
    IPoRepMarket public immutable POREPMARKET_CONTRACT;

    /**
     * @notice Initializes the DealInspector contract with the addresses of the DataCapEvidenceAdapter and PoRepMarket contracts
     * @param _dataCapEvidenceAdapter Address of the DataCapEvidenceAdapter contract
     * @param _poRepMarketContract Address of the PoRepMarket contract
     */
    constructor(address _dataCapEvidenceAdapter, address _poRepMarketContract) {
        _ensureNonZeroAddresses(_dataCapEvidenceAdapter, _poRepMarketContract);
        DATA_CAP_EVIDENCE_ADAPTER = IDataCapEvidenceAdapter(_dataCapEvidenceAdapter);
        POREPMARKET_CONTRACT = IPoRepMarket(_poRepMarketContract);
    }

    /**
     * @notice Fetches claims for a given deal ID along with their matching claim IDs
     * @dev Claim IDs are read from the DataCapEvidenceAdapter's claim list, i.e. allocations
     *      already confirmed as claimed via submitEvidenceBatch. Pending allocations are not included.
     *      VerifReg returns claims without IDs, in input order, skipping failures.
     *      We re-attach the IDs so claimIds[i] matches claims[i].
     *      The returned claims carry the sector number (claims[i].sector) which, together with
     *      the deal ID, is the input for {validateSectorStatus}.
     * @param dealId The ID of the deal for which to fetch claims
     * @return claimIds The IDs of successfully fetched claims, aligned with claims
     * @return claims The claims associated with the deal ID
     */
    function getClaimForDeal(uint256 dealId)
        external
        view
        returns (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims)
    {
        if (dealId == 0) {
            revert InvalidDealId();
        }
        PoRepTypes.Deal memory deal = POREPMARKET_CONTRACT.getDeal(dealId);
        (CommonTypes.FilActorId[] memory ids,) = DATA_CAP_EVIDENCE_ADAPTER.getClaimIds(dealId, 0, type(uint256).max);
        return _getClaims(deal.provider, ids);
    }

    /**
     * @notice Fetches claims for a given (provider, claim IDs) pair along with their matching claim IDs
     * @dev VerifReg returns claims without IDs, in input order, skipping failures.
     *      We re-attach the IDs so claimIds[i] matches claims[i].
     * @param provider The provider actor ID
     * @param ids The claim IDs to fetch for the provider
     * @return claimIds The IDs of successfully fetched claims, aligned with claims
     * @return claims The claims associated with the (provider, ids) pair
     */
    function getClaimsForProvider(CommonTypes.FilActorId provider, CommonTypes.FilActorId[] calldata ids)
        external
        view
        returns (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims)
    {
        return _getClaims(provider, ids);
    }

    /**
     * @notice Validates that a sector's actual status matches the claimed status.
     *         Resolves the miner actor ID from the deal's provider, then calls the
     *         miner actor's ValidateSectorStatus.
     * @dev The sector number comes from {getClaimForDeal} (claims[i].sector).
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

    /**
     * @notice Fetches claims from VerifReg for a provider and re-attaches the IDs of successful results
     * @param provider The provider actor ID
     * @param ids The claim IDs to fetch for the provider
     * @return claimIds The IDs of successfully fetched claims, aligned with claims
     * @return claims The claims returned by VerifReg
     */
    function _getClaims(CommonTypes.FilActorId provider, CommonTypes.FilActorId[] memory ids)
        internal
        view
        returns (CommonTypes.FilActorId[] memory claimIds, VerifRegTypes.Claim[] memory claims)
    {
        VerifRegTypes.GetClaimsParams memory getClaimsParams =
            VerifRegTypes.GetClaimsParams({provider: provider, claim_ids: ids});

        (int256 exitCode, VerifRegTypes.GetClaimsReturn memory result) = VerifRegAPI.getClaims(getClaimsParams);
        if (exitCode != 0) {
            revert GetClaimsCallFailed();
        }

        claims = result.claims;
        claimIds = new CommonTypes.FilActorId[](claims.length);

        uint256 failIterator = 0;
        uint256 outIdx = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            if (
                result.batch_info.fail_codes.length > failIterator
                    && i == result.batch_info.fail_codes[failIterator].idx
            ) {
                ++failIterator;
                continue;
            }
            claimIds[outIdx++] = ids[i];
        }

        if (outIdx != claims.length) {
            revert ClaimIdsMismatch(claims.length, outIdx);
        }
    }

    /**
     * @notice Ensures that the provided addresses are non-zero
     * @param _dataCapEvidenceAdapter Address of the DataCapEvidenceAdapter contract
     * @param _poRepMarket Address of the PoRepMarket contract address
     */
    function _ensureNonZeroAddresses(address _dataCapEvidenceAdapter, address _poRepMarket) internal pure {
        if (_dataCapEvidenceAdapter == address(0)) {
            revert InvalidDataCapEvidenceAdapterAddress();
        }
        if (_poRepMarket == address(0)) {
            revert InvalidPoRepMarketAddress();
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {DataCapAPI} from "filecoin-solidity/v0.8/DataCapAPI.sol";
import {DataCapTypes} from "filecoin-solidity/v0.8/types/DataCapTypes.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";
import {CBORDecoder} from "filecoin-solidity/v0.8/utils/CborDecode.sol";
import {VerifRegAPI} from "filecoin-solidity/v0.8/VerifRegAPI.sol";
import {UtilsHandlers} from "filecoin-solidity/v0.8/utils/UtilsHandlers.sol";
import {FilAddresses} from "filecoin-solidity/v0.8/utils/FilAddresses.sol";
import {AllocationResponseCbor} from "./lib/AllocationResponseCbor.sol";
import {PoRepMarket} from "./PoRepMarket.sol";
import {IValidator} from "./interfaces/Validator.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Client
 * @notice Upgradeable contract for managing client allowances with role-based access control
 */
contract Client is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using AllocationResponseCbor for DataCapTypes.TransferReturn;

    // @custom:storage-location erc7201:porepmarket.storage.ClientStorage
    struct ClientStorage {
        mapping(uint256 dealId => Deal deal) _deals;
        PoRepMarket _poRepMarketContract;
    }

    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.ClientStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CLIENT_STORAGE_LOCATION =
        0x2b21b193d0cfac9c3a87c7f79dc75824e9816d95224b141c67bae6ec5621ea00;

    // solhint-disable-next-line use-natspec
    function _getClientStorage() private pure returns (ClientStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := CLIENT_STORAGE_LOCATION
        }
    }

    /**
     * @dev Returns the storage struct for the Client contract.
     * @notice function to allow acess to storage for inheriting contracts
     * @return ClientStorage storage struct
     */
    function s() internal pure returns (ClientStorage storage) {
        return _getClientStorage();
    }

    /**
     * @notice Allocator role which allows for increasing and decreasing allowances
     */
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    uint32 private constant _FRC46_TOKEN_TYPE = 2233613279; // method_hash!("FRC46") as u32;
    address private constant _DATACAP_ADDRESS = address(0xfF00000000000000000000000000000000000007);

    /**
     * @notice Upgradable role which allows for contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice The role to set terminated claims.
     */
    bytes32 public constant TERMINATION_ORACLE = keccak256("TERMINATION_ORACLE");

    // solhint-disable gas-indexed-events
    /**
     * @notice Emitted when DataCap is allocated to a SP.
     * @param client The address of the client.
     * @param amount The amount of DataCap allocated.
     */
    event DatacapSpent(address indexed client, uint256 amount);
    // solhint-enable gas-indexed-events

    /**
     * @notice Emited when lockupPeriod is called
     * @param dealId Deal id
     * @param validator Validator address
     */
    event ValidatorLockupPeriodUpdated(uint256 indexed dealId, address indexed validator);

    /**
     * @notice Emitted when a verified client is added
     * @param client Client address
     * @param allowance Allowance amount
     */
    event VerifiedClientAdded(address indexed client, uint256 indexed allowance);

    /**
     * @notice Thrown if sender is not proposed client
     */
    error InvalidClient();

    /**
     * @notice Thrown if alloc provider is not proposed provider
     */
    error InvalidProvider();

    /**
     * @notice Datacap transfer failed
     */
    error TransferFailed(int256 exitCode);

    /**
     * @notice Error thrown when claim extension request length is invalid
     */
    error InvalidClaimExtensionRequest();

    /**
     * @notice Error thrown when allocation request length is invalid
     */
    error InvalidAllocationRequest();

    /**
     * @notice GetClaims call to VerifReg failed
     */
    error GetClaimsCallFailed();

    /**
     * @notice Error thrown when operator_data length is invalid
     */
    error InvalidOperatorData();

    /**
     * @notice Thrown if trying to receive invalid token
     */
    error InvalidTokenReceived();

    /**
     * @notice Thrown if trying to receive unsupported token type
     */
    error UnsupportedType();

    /**
     * @notice Thrown if caller is invalid
     */
    error InvalidCaller(address caller, address expectedCaller);

    /**
     * @notice Error thrown when VerifReg addVerifiedClient call fails
     */
    error VerifRegAddVerifiedClientFailed(int256 exitCode);

    /**
     * @notice Error thrown when deal state is invalid for transfer
     */
    error InvalidDealStateForTransfer();

    struct Deal {
        address client;
        address validator;
        CommonTypes.FilActorId provider;
        uint256 dealId;
        uint256 railId;
        uint256 sizeOfAllocations;
        CommonTypes.ChainEpoch longestDealTerm;
        CommonTypes.FilActorId[] allocationIds;
    }

    struct ProviderAllocation {
        CommonTypes.FilActorId provider;
        uint64 size;
    }

    struct ProviderClaim {
        CommonTypes.FilActorId provider;
        CommonTypes.FilActorId claim;
    }

    struct ClientDataUsage {
        address client;
        uint256 usage;
    }

    /**
     * @notice Disabled constructor (proxy pattern)
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Contract initializator. Should be called during deployment
     * @param admin Contract owner
     * @param allocator Address of the allocator contract that can increase and decrease allowances
     * @param terminationOracle Address of the Termination Oracle
     * @param _poRepMarketContract Address of the PoRepMarket contract
     */
    function initialize(address admin, address allocator, address terminationOracle, address _poRepMarketContract)
        public
        initializer
    {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(ALLOCATOR_ROLE, allocator);
        _grantRole(TERMINATION_ORACLE, terminationOracle);

        ClientStorage storage $ = s();
        $._poRepMarketContract = PoRepMarket(_poRepMarketContract);
    }

    /**
     * @notice This function transfers DataCap tokens from the client to the storage provider
     * @dev This function can only be called by the client
     * @param params The parameters for the transfer
     * @param dealId The id of the deal
     * @param dealCompleted Whether the deal is completed
     */
    function transfer(DataCapTypes.TransferParams calldata params, uint256 dealId, bool dealCompleted)
        external
        nonReentrant
    {
        (ProviderAllocation[] memory allocations, ProviderClaim[] memory claimExtensions, int64 longestDealTerm) =
            _deserializeVerifregOperatorData(params.operator_data);

        _verifyAndRegisterDeal(dealId, dealCompleted);
        _updateValidatorLockupPeriodAndLongestTermForDeal(dealId, longestDealTerm);
        _verifyAndRegisterAllocations(dealId, allocations);
        _verifyAndRegisterClaimExtensions(dealId, claimExtensions);

        ClientStorage storage $ = s();

        VerifRegTypes.AddVerifiedClientParams memory verifregParams = VerifRegTypes.AddVerifiedClientParams({
            addr: FilAddresses.fromEthAddress(address(this)),
            allowance: CommonTypes.BigInt(abi.encodePacked($._deals[dealId].sizeOfAllocations), false)
        });

        {
            emit VerifiedClientAdded(msg.sender, $._deals[dealId].sizeOfAllocations);
            int256 verifgerApiExitCode = VerifRegAPI.addVerifiedClient(verifregParams);
            if (verifgerApiExitCode != 0) {
                revert VerifRegAddVerifiedClientFailed(verifgerApiExitCode);
            }
        }

        emit DatacapSpent(msg.sender, $._deals[dealId].sizeOfAllocations);
        /// @custom:oz-upgrades-unsafe-allow-reachable delegatecall
        (int256 exitCode, DataCapTypes.TransferReturn memory transferReturn) = DataCapAPI.transfer(params);
        if (exitCode != 0) {
            revert TransferFailed(exitCode);
        }

        if (allocations.length != 0) {
            CommonTypes.FilActorId[] memory allocationIds = transferReturn.decodeAllocationResponse();
            for (uint256 i = 0; i < allocationIds.length; i++) {
                CommonTypes.FilActorId allocId = allocationIds[i];
                $._deals[dealId].allocationIds.push(allocId);
            }
        }
    }

    // solhint-disable func-name-mixedcase
    /**
     * @notice The handle_filecoin_method function is a universal entry point for calls
     * coming from built-in Filecoin actors. Datacap is an FRC-46 Token. Receiving FRC46
     * tokens requires implementing a Receiver Hook:
     * https://github.com/filecoin-project/FIPs/blob/master/FRCs/frc-0046.md#receiver-hook.
     * We use handle_filecoin_method to handle the receiver hook and make sure that the token
     * sent to our contract is freshly minted Datacap and reject all other calls and transfers.
     * @param method Method number
     * @param inputCodec Codec of the payload
     * @param params Params of the call
     * @return exitCode The exit code of the operation
     * @return codec The codec used for the response
     * @return data The response data
     * @dev Reverts if trying to send a unsupported token type
     * @dev Reverts if trying to receive invalid token
     */
    function handle_filecoin_method(uint64 method, uint64 inputCodec, bytes calldata params)
        external
        view
        returns (uint32 exitCode, uint64 codec, bytes memory data)
    {
        if (msg.sender != _DATACAP_ADDRESS) {
            revert InvalidCaller(msg.sender, _DATACAP_ADDRESS);
        }
        CommonTypes.UniversalReceiverParams memory receiverParams =
            UtilsHandlers.handleFilecoinMethod(method, inputCodec, params);
        if (receiverParams.type_ != _FRC46_TOKEN_TYPE) revert UnsupportedType();
        (uint256 tokenReceivedLength,) = CBORDecoder.readFixedArray(receiverParams.payload, 0);
        if (tokenReceivedLength != 6) revert InvalidTokenReceived();
        exitCode = 0;
        codec = 0;
        data = "";
    }

    // solhint-disable function-max-lines
    /**
     * @notice Deserialize Verifreg Operator Data.
     * @param cborData The cbor encoded operator data.
     * @return allocations Array of provider allocations.
     * @return claimExtensions Array of provider claims.
     * @return longestDealTerm Allocation with the longest term.
     */
    function _deserializeVerifregOperatorData(bytes memory cborData)
        internal
        pure
        returns (ProviderAllocation[] memory allocations, ProviderClaim[] memory claimExtensions, int64 longestDealTerm)
    {
        uint256 resultLength;
        uint64 provider;
        uint256 byteIdx = 0;

        (resultLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
        if (resultLength != 2) revert InvalidOperatorData();

        {
            uint64 size;
            int64 termMax;
            int64 expiration;
            (resultLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
            allocations = new ProviderAllocation[](resultLength);
            for (uint256 i = 0; i < resultLength; i++) {
                uint256 allocationRequestLength;
                (allocationRequestLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);

                if (allocationRequestLength != 6) {
                    revert InvalidAllocationRequest();
                }

                {
                    (provider, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
                    allocations[i].provider = CommonTypes.FilActorId.wrap(provider);
                }
                // slither-disable-start unused-return
                (, byteIdx) = CBORDecoder.readBytes(cborData, byteIdx); // data (CID)
                {
                    (size, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
                    allocations[i].size = size;
                }
                (, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx); // termMin
                // slither-disable-end unused-return
                {
                    (termMax, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx);
                    (expiration, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx);

                    if (termMax + expiration > longestDealTerm) {
                        longestDealTerm = termMax + expiration;
                    }
                }
            }
        }
        {
            uint64 claimId;
            (resultLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);
            claimExtensions = new ProviderClaim[](resultLength);
            for (uint256 i = 0; i < resultLength; i++) {
                uint256 claimExtensionRequestLength;
                (claimExtensionRequestLength, byteIdx) = CBORDecoder.readFixedArray(cborData, byteIdx);

                if (claimExtensionRequestLength != 3) {
                    revert InvalidClaimExtensionRequest();
                }

                (provider, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
                (claimId, byteIdx) = CBORDecoder.readUInt64(cborData, byteIdx);
                // slither-disable-start unused-return
                (, byteIdx) = CBORDecoder.readInt64(cborData, byteIdx);
                // slither-disable-end unused-return

                claimExtensions[i].provider = CommonTypes.FilActorId.wrap(provider);
                claimExtensions[i].claim = CommonTypes.FilActorId.wrap(claimId);
            }
        }
    }

    /**
     * @notice Verifies and registers a deal.
     * @param dealId The deal id.
     * @param dealCompleted flag to check if deal is completed
     */
    function _verifyAndRegisterDeal(uint256 dealId, bool dealCompleted) internal {
        ClientStorage storage $ = s();

        PoRepMarket.DealProposal memory proposal = $._poRepMarketContract.getDealProposal(dealId);

        if (proposal.client != msg.sender) {
            revert InvalidClient();
        }

        if (proposal.state != PoRepMarket.DealState.Accepted) {
            revert InvalidDealStateForTransfer();
        }

        if (dealCompleted) {
            $._poRepMarketContract.completeDeal(dealId);
        }

        Deal storage deal = $._deals[dealId];
        if (deal.dealId != 0) return;

        deal.client = proposal.client;
        deal.provider = proposal.provider;
        deal.dealId = proposal.dealId;
        deal.validator = proposal.validator;
        deal.railId = proposal.railId;
    }

    /**
     * @notice Updates validator lockup period if needed
     * @param dealId The deal id.
     * @param longestDealTerm The longest allocation.
     */
    function _updateValidatorLockupPeriodAndLongestTermForDeal(uint256 dealId, int64 longestDealTerm) internal {
        Deal storage deal = _getStorageDeal(dealId);

        if (longestDealTerm > CommonTypes.ChainEpoch.unwrap(deal.longestDealTerm)) {
            IValidator validator = IValidator(deal.validator);
            validator.updateLockupPeriod(deal.railId, uint256(uint64(longestDealTerm)));

            emit ValidatorLockupPeriodUpdated(dealId, deal.validator);
            deal.longestDealTerm = CommonTypes.ChainEpoch.wrap(longestDealTerm);
        }
    }

    /**
     * @notice Verifies and registers allocations.
     * @param dealId The deal id.
     * @param allocations The array of provider allocations.
     */
    function _verifyAndRegisterAllocations(uint256 dealId, ProviderAllocation[] memory allocations) internal {
        Deal storage deal = _getStorageDeal(dealId);

        for (uint256 i = 0; i < allocations.length; i++) {
            ProviderAllocation memory alloc = allocations[i];
            if (CommonTypes.FilActorId.unwrap(alloc.provider) != CommonTypes.FilActorId.unwrap(deal.provider)) {
                revert InvalidProvider();
            }

            deal.sizeOfAllocations += alloc.size;
        }
    }

    // solhint-disable function-max-lines
    /**
     * @notice Verifies and registers claim extensions.
     * @param dealId The id of the deal.
     * @param claimExtensions The array of provider claims.
     */
    function _verifyAndRegisterClaimExtensions(uint256 dealId, ProviderClaim[] memory claimExtensions) internal {
        Deal storage deal = _getStorageDeal(dealId);
        CommonTypes.FilActorId[] memory claimIds = new CommonTypes.FilActorId[](claimExtensions.length);
        CommonTypes.FilActorId dealProvider = deal.provider;

        for (uint256 i = 0; i < claimExtensions.length; i++) {
            ProviderClaim memory claim = claimExtensions[i];

            if (CommonTypes.FilActorId.unwrap(claim.provider) != CommonTypes.FilActorId.unwrap(dealProvider)) {
                revert InvalidProvider();
            }

            claimIds[i] = claim.claim;
        }
        {
            int256 exitCode;
            VerifRegTypes.GetClaimsReturn memory claimsDetails;
            VerifRegTypes.GetClaimsParams memory getClaimsParams =
                VerifRegTypes.GetClaimsParams({provider: dealProvider, claim_ids: claimIds});
            (exitCode, claimsDetails) = VerifRegAPI.getClaims(getClaimsParams);
            if (exitCode != 0 || claimsDetails.batch_info.success_count != claimIds.length) {
                revert GetClaimsCallFailed();
            }

            for (uint256 i = 0; i < claimsDetails.claims.length; i++) {
                VerifRegTypes.Claim memory claim = claimsDetails.claims[i];
                deal.sizeOfAllocations += claim.size;
            }
        }
    }

    /**
     * @notice custom getter to retrieve allication ids per client and provider
     * @param dealId the id of the deal
     * @return allocationIds the allocation ids for the client and provider
     */
    function getClientAllocationIdsPerDeal(uint256 dealId) external view returns (CommonTypes.FilActorId[] memory) {
        return s()._deals[dealId].allocationIds;
    }

    /**
     * @notice Internal function used to retrieve a storage deal
     * @param dealId The id of the deal
     * @return deal The storage deal
     */
    function _getStorageDeal(uint256 dealId) internal view returns (Deal storage) {
        return s()._deals[dealId];
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Internal function used to implement new logic and check if upgrade is authorized
     * @dev Will revert (reject upgrade) if upgrade isn't called by UPGRADER_ROLE
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

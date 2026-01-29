// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {DataCapAPI} from "filecoin-solidity/v0.8/DataCapAPI.sol";
import {BigInts} from "filecoin-solidity/v0.8/utils/BigInts.sol";
import {DataCapTypes} from "filecoin-solidity/v0.8/types/DataCapTypes.sol";
import {VerifRegTypes} from "filecoin-solidity/v0.8/types/VerifRegTypes.sol";
import {CBORDecoder} from "filecoin-solidity/v0.8/utils/CborDecode.sol";
import {VerifRegAPI} from "filecoin-solidity/v0.8/VerifRegAPI.sol";
import {UtilsHandlers} from "filecoin-solidity/v0.8/utils/UtilsHandlers.sol";
import {FilAddresses} from "filecoin-solidity/v0.8/utils/FilAddresses.sol";
import {AllocationResponseCbor} from "./lib/AllocationResponseCbor.sol";
import {PoRepMarket} from "./PoRepMarket.sol";
import {IValidator} from "./interfaces/Validator.sol";

/**
 * @title Client
 * @notice Upgradeable contract for managing client allowances with role-based access control
 */
contract Client is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using AllocationResponseCbor for DataCapTypes.TransferReturn;

    // @custom:storage-location erc7201:porepmarket.storage.ClientStorage
    struct ClientStorage {
        mapping(address client => mapping(CommonTypes.FilActorId provider => uint256 amount)) _allowances;
        mapping(uint256 dealId => Deal deal) _deals;
        mapping(
            CommonTypes.FilActorId provider => mapping(address client => CommonTypes.FilActorId[] allocationIds)
        ) _clientAllocationIdsPerProvider;
        mapping(uint64 claim => bool isTerminated) _terminatedClaims;
        mapping(CommonTypes.FilActorId provider => EnumerableMap.AddressToUintMap client) _spClients;
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
    /**
     * @notice Mapping of allowances for clients and providers using FilActorId
     */

    /**
     * @notice  Precision factor for DataCap tokens (1e18)
     */
    uint256 public constant TOKEN_PRECISION = 1e18;

    /**
     * @notice Event emitted when an allowance is changed
     * @param client Client address
     * @param provider Provider fil actor id
     * @param allowanceBefore Allowance before the change
     * @param allowanceAfter Allowance after the change
     */
    event AllowanceChanged(
        address indexed client, CommonTypes.FilActorId indexed provider, uint256 allowanceBefore, uint256 allowanceAfter
    );

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
     */
    event ValidatorLockupPeriodUpdated(uint256 dealId, address validator);

    /**
     * @notice Thrown if sender is not proposed client
     */
    error InvalidClient();

    /**
     * @notice Thrown if alloc provider is not proposed provider
     */
    error InvalidProvider();

    /**
     * @notice Error emitted when the amount is zero
     */
    error AmountEqualsZero();

    /**
     * @notice Error emitted when the allowance is zero
     */
    error AlreadyZero();

    /**
     * @notice Error thrown when amount is invalid
     */
    error InvalidAmount();

    /**
     * @notice Error thrown when senders balance is less than his allowance
     */
    error InsufficientAllowance();

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
     * @notice GetClaims call to VerifReg faile
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
     * @notice Thrown if beneficiary contract address doesn't match the one registered in BeneficiaryFactory
     */
    error InvalidBeneficiary(address beneficiary, address expectedBeneficiary);

    /**
     * @notice Thrown if beneficiary contract address doesn't match the one registered in BeneficiaryFactory
     */
    error AllocationNotFound(CommonTypes.FilActorId provider, address client, uint64 allocationId);

    /**
     * @notice Thrown if beneficiary allocation expiration is insufficient
     */
    error InsufficientBeneficiaryAllocationExpiration(
        CommonTypes.FilActorId provider, int64 beneficiaryExpiration, int64 requiredExpiration
    );

    struct Deal {
        address client;
        CommonTypes.FilActorId provider;
        uint256 dealID;
        uint256 sizeOfAllocations;
        CommonTypes.ChainEpoch longestDealTerm;
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
        ClientStorage storage $ = s();

        __AccessControl_init();
        // __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(ALLOCATOR_ROLE, allocator);
        _grantRole(TERMINATION_ORACLE, terminationOracle);
        $._poRepMarketContract = PoRepMarket(_poRepMarketContract);
    }

    /**
     * @notice Increases the allowance for a given client and provider
     * @param client Address of the client
     * @param provider Address of the provider
     * @param amount Amount to increase the allowance by
     * Emits an AllowanceChanged event
     */
    function increaseAllowance(address client, CommonTypes.FilActorId provider, uint256 amount)
        external
        onlyRole(ALLOCATOR_ROLE)
    {
        if (amount == 0) revert AmountEqualsZero();

        ClientStorage storage $ = s();
        uint256 allowanceBefore = $._allowances[client][provider];
        $._allowances[client][provider] += amount;
        emit AllowanceChanged(client, provider, allowanceBefore, $._allowances[client][provider]);
    }

    /**
     * @notice Decreases the allowance for a given client and provider
     * @param client Address of the client
     * @param provider Address of the provider
     * @param amount Amount to decrease the allowance by
     * @dev If the amount is greater than the allowance, the allowance is set to 0
     * Emits an AllowanceChanged event
     */
    function decreaseAllowance(address client, CommonTypes.FilActorId provider, uint256 amount)
        external
        onlyRole(ALLOCATOR_ROLE)
    {
        if (amount == 0) revert AmountEqualsZero();

        ClientStorage storage $ = s();
        uint256 allowanceBefore = $._allowances[client][provider];
        if (allowanceBefore == 0) revert AlreadyZero();
        if (allowanceBefore < amount) {
            amount = allowanceBefore;
        }
        $._allowances[client][provider] -= amount;
        emit AllowanceChanged(client, provider, allowanceBefore, $._allowances[client][provider]);
    }

    /**
     * @notice This function transfers DataCap tokens from the client to the storage provider
     * @dev This function can only be called by the client
     * @param params The parameters for the transfer
     * @param dealId The id of the deal
     * @param dealCompleted Whether the deal is completed
     */
    function transfer(DataCapTypes.TransferParams calldata params, uint256 dealId, bool dealCompleted) external {
        (uint256 tokenAmount, bool failed) = BigInts.toUint256(params.amount);
        if (failed) revert InvalidAmount();
        uint256 datacapAmount = tokenAmount / TOKEN_PRECISION;

        (ProviderAllocation[] memory allocations, ProviderClaim[] memory claimExtensions, int64 longestDealTerm) =
            _deserializeVerifregOperatorData(params.operator_data);

        ClientStorage storage $ = s();
        PoRepMarket.DealProposal memory proposal = $._poRepMarketContract.getDealProposal(dealId);

        _verifyAndRegisterDeal(proposal, longestDealTerm);
        _verifyAndRegisterAllocations(proposal, allocations);
        _verifyAndRegisterClaimExtensions(dealId, claimExtensions);

        VerifRegTypes.AddVerifiedClientParams memory verifregParams = VerifRegTypes.AddVerifiedClientParams({
            addr: FilAddresses.fromEthAddress($._deals[dealId].client),
            allowance: CommonTypes.BigInt(abi.encodePacked(datacapAmount), false)
        });

        VerifRegAPI.addVerifiedClient(verifregParams);

        emit DatacapSpent(msg.sender, datacapAmount);
        /// @custom:oz-upgrades-unsafe-allow-reachable delegatecall
        (int256 exitCode, DataCapTypes.TransferReturn memory transferReturn) = DataCapAPI.transfer(params);
        if (exitCode != 0) {
            revert TransferFailed(exitCode);
        }

        if (allocations.length != 0) {
            CommonTypes.FilActorId[] memory allocationIds = transferReturn.decodeAllocationResponse();
            for (uint256 i = 0; i < allocationIds.length; i++) {
                CommonTypes.FilActorId allocId = allocationIds[i];
                CommonTypes.FilActorId provider = allocations[i].provider;
                $._clientAllocationIdsPerProvider[provider][msg.sender].push(allocId);
            }
        }

        if (dealCompleted) {
            $._poRepMarketContract.completeDeal(dealId);
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
     * @param proposal The deal proposal.
     * @param longestDealTerm The longest allocation.
     */
    function _verifyAndRegisterDeal(PoRepMarket.DealProposal memory proposal, int64 longestDealTerm) internal {
        ClientStorage storage $ = s();

        if (longestDealTerm > CommonTypes.ChainEpoch.unwrap($._deals[proposal.dealId].longestDealTerm)) {
            IValidator validator = IValidator(proposal.validator);
            validator.updateLockupPeriod(proposal.dealId);

            emit ValidatorLockupPeriodUpdated(proposal.dealId, proposal.validator);
        }

        $._deals[proposal.dealId].client = proposal.client;
        $._deals[proposal.dealId].provider = proposal.provider;
        $._deals[proposal.dealId].dealID = proposal.dealId;
        $._deals[proposal.dealId].longestDealTerm = CommonTypes.ChainEpoch.wrap(longestDealTerm);
    }

    /**
     * @notice Verifies and registers allocations.
     * @param proposal The deal proposal.
     * @param allocations The array of provider allocations.
     */
    function _verifyAndRegisterAllocations(
        PoRepMarket.DealProposal memory proposal,
        ProviderAllocation[] memory allocations
    ) internal {
        if (proposal.client != msg.sender) revert InvalidClient();
        ClientStorage storage $ = s();

        for (uint256 i = 0; i < allocations.length; i++) {
            ProviderAllocation memory alloc = allocations[i];
            if (CommonTypes.FilActorId.unwrap(alloc.provider) != CommonTypes.FilActorId.unwrap(proposal.provider)) {
                revert InvalidProvider();
            }

            uint256 size = alloc.size;
            if ($._allowances[msg.sender][alloc.provider] < size) {
                revert InsufficientAllowance();
            }
            $._allowances[msg.sender][alloc.provider] -= size;
            $._deals[proposal.dealId].sizeOfAllocations += size;
        }
    }

    // solhint-disable function-max-lines
    /**
     * @notice Verifies and registers claim extensions.
     * @param dealId The id of the deal.
     * @param claimExtensions The array of provider claims.
     */
    function _verifyAndRegisterClaimExtensions(uint256 dealId, ProviderClaim[] memory claimExtensions) internal {
        int256 exitCode;
        uint256 claimProvidersCount = 0;
        CommonTypes.FilActorId[] memory claimProviders = new CommonTypes.FilActorId[](claimExtensions.length);

        // get providers list with no duplicates
        for (uint256 i = 0; i < claimExtensions.length; i++) {
            ProviderClaim memory claim = claimExtensions[i];
            bool alreadyExists = false;
            for (uint256 j = 0; j < claimProvidersCount; j++) {
                if (CommonTypes.FilActorId.unwrap(claimProviders[j]) == CommonTypes.FilActorId.unwrap(claim.provider)) {
                    alreadyExists = true;
                    break;
                }
            }
            if (!alreadyExists) {
                claimProviders[claimProvidersCount++] = claim.provider;
            }
        }

        CommonTypes.FilActorId[] memory claims = new CommonTypes.FilActorId[](claimExtensions.length);
        for (uint256 providerIdx = 0; providerIdx < claimProvidersCount; providerIdx++) {
            // for each provider, find all claims for this provider
            uint256 claimCount = 0;
            CommonTypes.FilActorId provider = claimProviders[providerIdx];
            for (uint256 i = 0; i < claimExtensions.length; i++) {
                ProviderClaim memory claim = claimExtensions[i];
                if (CommonTypes.FilActorId.unwrap(claim.provider) == CommonTypes.FilActorId.unwrap(provider)) {
                    claims[claimCount++] = claim.claim;
                }
            }
            // solhint-disable-next-line no-inline-assembly
            assembly {
                mstore(claims, claimCount)
            }

            // get details of claims of this provider
            VerifRegTypes.GetClaimsParams memory getClaimsParams =
                VerifRegTypes.GetClaimsParams({provider: provider, claim_ids: claims});
            VerifRegTypes.GetClaimsReturn memory claimsDetails;
            (exitCode, claimsDetails) = VerifRegAPI.getClaims(getClaimsParams);
            if (exitCode != 0 || claimsDetails.batch_info.success_count != claims.length) {
                revert GetClaimsCallFailed();
            }

            // calculate total size of claims (a.k.a. how much datacap is going to this single SP)
            ClientStorage storage $ = s();
            uint256 size = 0;
            for (uint256 i = 0; i < claimsDetails.claims.length; i++) {
                VerifRegTypes.Claim memory claim = claimsDetails.claims[i];
                size += claim.size;
            }
            if ($._allowances[msg.sender][provider] < size) {
                revert InsufficientAllowance();
            }
            $._allowances[msg.sender][provider] -= size;
            $._deals[dealId].sizeOfAllocations += size;
        }
    }

    function getSPClientsDataUsage(CommonTypes.FilActorId provider)
        external
        view
        returns (ClientDataUsage[] memory clientsDataUsage)
    {
        ClientStorage storage $ = s();
        uint256 clientCount = $._spClients[provider].length();
        clientsDataUsage = new ClientDataUsage[](clientCount);
        for (uint256 i = 0; i < clientCount; ++i) {
            (address client, uint256 usage) = $._spClients[provider].at(i);
            clientsDataUsage[i] = ClientDataUsage({client: client, usage: usage});
        }
    }

    /**
     * @notice Returns the data usage of all clients for a given storage provider
     * @param provider The FilActorId of the storage provider
     * @return clients An array of provider clients
     */
    function getSPClients(CommonTypes.FilActorId provider) external view returns (address[] memory clients) {
        clients = s()._spClients[provider].keys();
    }

    /**
     * @notice Deletes an allocation ID from the client's allocation list for a given provider
     * @dev Removes the allocation ID by swapping it with the last element and popping from the array. Reverts with AllocationNotFound if the allocation ID is not found
     * @param provider The Filecoin actor ID of the provider
     * @param client The Ethereum address of the client
     * @param allocationId The allocation ID to delete
     */
    function _deleteAllocationIdByValue(CommonTypes.FilActorId provider, address client, uint64 allocationId) internal {
        CommonTypes.FilActorId[] storage ids = s()._clientAllocationIdsPerProvider[provider][client];

        uint256 maxIdx = ids.length - 1;
        for (uint256 i = 0; i < maxIdx; i++) {
            if (CommonTypes.FilActorId.unwrap(ids[i]) == allocationId) {
                ids[i] = ids[maxIdx];
                ids.pop();
                return;
            }
        }
        if (CommonTypes.FilActorId.unwrap(ids[maxIdx]) == allocationId) {
            ids.pop();
        } else {
            revert AllocationNotFound(provider, client, allocationId);
        }
    }

    /**
     * @notice Marks the given claims as terminated early.
     * @dev Only callable by TERMINATION_ORACLE role.
     * @param claims An array of claim IDs to mark as terminated.
     */
    function claimsTerminatedEarly(uint64[] calldata claims) external onlyRole(TERMINATION_ORACLE) {
        ClientStorage storage $ = s();

        for (uint256 i = 0; i < claims.length; i++) {
            $._terminatedClaims[claims[i]] = true;
        }
    }

    /**
     * @notice custom getter to retrieve allication ids per client and provider
     * @param provider the FilActorId of provider
     * @param client the client address
     * @return allocationIds the allocation ids for the client and provider
     */
    function getClientAllocationIdsPerProvider(CommonTypes.FilActorId provider, address client)
        external
        view
        returns (CommonTypes.FilActorId[] memory)
    {
        return s()._clientAllocationIdsPerProvider[provider][client];
    }

    /**
     * @notice custom getter to allowances per client and provider
     * @param client the client address
     * @param provider the FilActorId of provider
     * @return amount allocation per client and provider
     */
    function getAllowance(address client, CommonTypes.FilActorId provider) external view returns (uint256 amount) {
        return s()._allowances[client][provider];
    }

    function getTerminatedClaim(uint64 claim) external view returns (bool isTerminated) {
        return s()._terminatedClaims[claim];
    }

        /**
     * @notice Calculates the total active data size for a client with a specific provider
     * @dev Iterates through the client's allocation IDs, retrieves their claims, and sums up the sizes of active claims
     *      Removes allocation IDs associated with expired or terminated claims
     * @param client The Ethereum address of the client
     * @param provider The Filecoin actor ID of the provider
     * @return totalSizePerSp The total active data size for the client with the specified provider
     */
    function getClientSpActiveDataSize(address client, CommonTypes.FilActorId provider) external returns (uint256) {
        ClientStorage storage $ = s();

        CommonTypes.FilActorId[] memory clientAllocationIds = $._clientAllocationIdsPerProvider[provider][client];
        VerifRegTypes.GetClaimsParams memory getClaimsParams =
            VerifRegTypes.GetClaimsParams({provider: provider, claim_ids: clientAllocationIds});
        (int256 getClaimsExitCode, VerifRegTypes.GetClaimsReturn memory getClaimsResult) =
            VerifRegAPI.getClaims(getClaimsParams);
        if (getClaimsExitCode != 0) {
            revert GetClaimsCallFailed();
        }
        uint256 totalSizePerSp = 0;
        uint256 failCodesIterator = 0;
        int64 currentEpoch = int64(uint64(block.number));
        for (uint256 i = 0; i < clientAllocationIds.length; i++) {
            if (
                getClaimsResult.batch_info.fail_codes.length > 0
                    && getClaimsResult.batch_info.fail_codes.length > failCodesIterator
                    && i == getClaimsResult.batch_info.fail_codes[failCodesIterator].idx
            ) {
                failCodesIterator += 1;
                continue;
            }
            if (
                CommonTypes.ChainEpoch.unwrap(getClaimsResult.claims[i - failCodesIterator].term_start)
                            + CommonTypes.ChainEpoch.unwrap(getClaimsResult.claims[i - failCodesIterator].term_max)
                        < currentEpoch
                    || $._terminatedClaims[
                        CommonTypes.FilActorId.unwrap(getClaimsResult.claims[i - failCodesIterator].sector)
                    ]
            ) {
                _deleteAllocationIdByValue(provider, client, CommonTypes.FilActorId.unwrap(clientAllocationIds[i]));
                continue;
            }
            totalSizePerSp += getClaimsResult.claims[i - failCodesIterator].size;
        }
        return totalSizePerSp;
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Internal function used to implement new logic and check if upgrade is authorized
     * @dev Will revert (reject upgrade) if upgrade isn't called by UPGRADER_ROLE
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

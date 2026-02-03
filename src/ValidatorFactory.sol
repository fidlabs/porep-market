// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Validator} from "./Validator.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title ValidatorFactory
 * @notice Beacon factory contract for creating Validator instances
 */
contract ValidatorFactory is UUPSUpgradeable, AccessControlUpgradeable {
    /**
     * @notice Upgradable role which allows for contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // @custom:storage-location erc7201:porepmarket.storage.ValidatorFactoryStorage
    struct ValidatorFactoryStorage {
        mapping(address admin => mapping(CommonTypes.FilActorId provider => uint256 deployCounter)) _nonce;
        mapping(uint256 dealId => address contractAddress) _instances;
        mapping(address => bool) _isValidatorContract;
        address _clientSmartContract;
        address _filecoinPay;
        address _poRepMarket;
        address _beacon;
    }

    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.ValidatorFactoryStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VALIDATOR_FACTORY_STORAGE_LOCATION =
        0x4535768406d1af0f5a262f9968680cf180c0f29a04172a8e056d8f1b4b87ed00;

    // solhint-disable-next-line use-natspec
    function _getValidatorFactoryStorage() private pure returns (ValidatorFactoryStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := VALIDATOR_FACTORY_STORAGE_LOCATION
        }
    }

    /**
     * @dev Returns the storage struct for the ValidatorFactory contract.
     * @notice function to allow acess to storage for inheriting contracts
     * @return ValidatorFactoryStorage storage struct
     */
    function s() internal pure returns (ValidatorFactoryStorage storage) {
        return _getValidatorFactoryStorage();
    }

    error InstanceAlreadyExists();

    /**
     * @notice Emitted when a new proxy is successfully created
     * @param proxy The address of the newly deployed proxy
     * @param provider The provider for which the proxy was created
     */
    event ProxyCreated(address indexed proxy, CommonTypes.FilActorId indexed provider);

    /**
     * @notice Initializes the contract
     * @dev Initializes the contract by setting a default admin role and a UUPS upgradeable role
     * @param admin The address of the admin responsible for the contract
     * @param implementation The address of the implementation contract
     * @param _poRepMarket The address of the PoRepMarket contract
     * @param _clientSmartContract The address of the ClientSmartContract contract
     * @param _filecoinPay The address of the FilecoinPay contract
     */
    function initialize(
        address admin,
        address implementation,
        address _poRepMarket,
        address _clientSmartContract,
        address _filecoinPay
    ) public initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        ValidatorFactoryStorage storage $ = s();
        $._beacon = address(new UpgradeableBeacon(implementation, admin));
        $._poRepMarket = _poRepMarket;
        $._clientSmartContract = _clientSmartContract;
        $._filecoinPay = _filecoinPay;
    }

    /**
     * @notice Creates a new instance of an upgradeable contract.
     * @dev Uses BeaconProxy to create a new proxy instance, pointing to the Beacon for the logic contract.
     * @dev Reverts if an instance for the given provider already exists.
     * @param admin The address of the admin responsible for the contract.
     * @param slcAddress The address of the SLC contract.
     * @param provider The ID of the provider responsible for the contract.
     * @param params The parameters for the deposit with rail.
     */
    function create(
        address admin,
        address slcAddress,
        CommonTypes.FilActorId provider,
        Validator.DepositWithRailParams calldata params
    ) external {
        ValidatorFactoryStorage storage $ = s();

        if ($._instances[params.dealId] != address(0)) {
            revert InstanceAlreadyExists();
        }

        $._nonce[admin][provider]++;

        bytes memory initCode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(
                $._beacon,
                abi.encodeCall(
                    Validator.initialize,
                    (admin, $._filecoinPay, slcAddress, provider, $._clientSmartContract, $._poRepMarket, params)
                )
            )
        );

        address proxy = Create2.deploy(0, keccak256(abi.encode(admin, provider, $._nonce[admin][provider])), initCode);
        $._instances[params.dealId] = proxy;
        $._isValidatorContract[proxy] = true;

        emit ProxyCreated(proxy, provider);
    }

    /**
     * @notice Checks if an address is a validator contract
     * @param contractAddress The address to check
     * @return True if the address is a validator contract, false otherwise
     */
    function isValidatorContract(address contractAddress) external view returns (bool) {
        return s()._isValidatorContract[contractAddress];
    }

    /**
     * @notice Gets the instance for a given deal
     * @param dealId The ID of the deal
     * @return The instance for the given deal
     */
    function getInstance(uint256 dealId) external view returns (address) {
        return s()._instances[dealId];
    }

    /**
     * @notice Gets the beacon for the factory
     * @return The beacon for the factory
     */
    function getBeacon() external view returns (address) {
        return s()._beacon;
    }

    // solhint-disable no-empty-blocks
    /**
     * @notice Internal function used to implement new logic and check if upgrade is authorized
     * @dev Will revert (reject upgrade) if upgrade isn't called by UPGRADER_ROLE
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

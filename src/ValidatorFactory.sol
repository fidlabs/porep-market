// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Validator} from "./Validator.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {IValidatorFactory} from "./interfaces/IValidatorFactory.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";
import {AccessControlledUpgradeable} from "./abstracts/AccessControlledUpgradeable.sol";
import {Roles} from "./lib/Roles.sol";

/**
 * @title ValidatorFactory
 * @notice Beacon factory contract for creating Validator instances
 */
contract ValidatorFactory is IValidatorFactory, UUPSUpgradeable, AccessControlledUpgradeable {
    // @custom:storage-location erc7201:porepmarket.storage.ValidatorFactoryStorage
    struct ValidatorFactoryStorage {
        mapping(uint256 dealId => address contractAddress) _instances;
        mapping(address => bool) _isValidatorContract;
        address _filecoinPay;
        address _poRepMarket;
        address _beacon;
        address _admin;
        address _upgraderRole;
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

    /**
     * @notice Error indicating that an instance for the given dealId already exists
     * @dev 0x1144626f
     */
    error InstanceAlreadyExists();

    /**
     * @notice Error indicating that the provided implementation address is invalid
     * @dev 0x4d9c0a3f
     */
    error InvalidClientAddress();

    /**
     * @notice Error indicating that the provided PoRepMarket address is invalid
     * @dev 0xc9cc4a06
     */
    error InvalidPoRepMarketAddress();

    /**
     * @notice Error indicating that the provided FilecoinPay address is invalid
     * @dev 0x5419d62f
     */
    error InvalidFilecoinPayAddress();

    /**
     * @notice Error indicating that the provided implementation address is invalid
     * @dev 0xc970156c
     */
    error InvalidImplementationAddress();

    /**
     * @notice Emitted when a new proxy is successfully created
     * @param proxy The address of the newly deployed proxy
     * @param dealId The dealId for which the proxy was created
     */
    event ProxyCreated(address indexed proxy, uint256 indexed dealId);

    /**
     * @notice Constructor
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @dev Initializes the contract by setting a default admin role and a UUPS upgradeable role
     * @param _accessManager Protocol AccessManager address
     * @param implementation The address of the implementation contract
     */
    function initialize(address _accessManager, address implementation) public initializer {
        if (implementation == address(0)) {
            revert InvalidImplementationAddress();
        }

        __AccessControlled_init(_accessManager);

        ValidatorFactoryStorage storage $ = s();
        $._beacon = address(new UpgradeableBeacon(implementation, _accessManager));
    }

    /**
     * @notice Initializes the contract with the PoRepMarket, and FilecoinPay addresses
     * @dev This function is called after the contract is initialized with the admin and implementation addresses
     * @param _filecoinPay The address of the FilecoinPay contract
     * @param _poRepMarket The address of the PoRepMarket contract
     */
    function initialize2(address _filecoinPay, address _poRepMarket)
        external
        reinitializer(2)
        onlyRole(Roles.DEFAULT_ADMIN_ROLE)
    {
        if (_poRepMarket == address(0)) revert InvalidPoRepMarketAddress();
        if (_filecoinPay == address(0)) revert InvalidFilecoinPayAddress();

        ValidatorFactoryStorage storage $ = s();
        $._poRepMarket = _poRepMarket;
        $._filecoinPay = _filecoinPay;
    }

    /**
     * @notice Creates a new instance of an upgradeable contract.
     * @dev Uses BeaconProxy to create a new proxy instance, pointing to the Beacon for the logic contract.
     * @dev Reverts if an instance for the given dealId already exists.
     * @param dealId The dealId for which the proxy was created.
     */
    function create(uint256 dealId) external {
        ValidatorFactoryStorage storage $ = s();
        if ($._instances[dealId] != address(0)) revert InstanceAlreadyExists();

        PoRepTypes.Deal memory deal = IPoRepMarket($._poRepMarket).getDeal(dealId);
        if (msg.sender != deal.client) revert InvalidClientAddress();
        bytes memory initCode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(
                $._beacon,
                abi.encodeCall(Validator.initialize, (accessManager(), $._filecoinPay, $._poRepMarket, dealId))
            )
        );
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 salt = keccak256(abi.encode(accessManager(), dealId));
        address proxy = Create2.computeAddress(salt, keccak256(initCode), address(this));
        $._instances[dealId] = proxy;
        $._isValidatorContract[proxy] = true;

        Create2.deploy(0, salt, initCode);
        emit ProxyCreated(proxy, dealId);
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
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}

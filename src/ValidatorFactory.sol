// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Validator} from "./Validator.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IPoRepMarket} from "./interfaces/IPoRepMarket.sol";
import {IValidatorFactory} from "./interfaces/IValidatorFactory.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";

/**
 * @title ValidatorFactory
 * @notice Beacon factory contract for creating Validator instances
 */
contract ValidatorFactory is IValidatorFactory, UUPSUpgradeable, AccessControlUpgradeable {
    /**
     * @notice Upgradable role which allows for contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

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
     * @notice Error indicating that the provided admin address is invalid
     * @dev 0x05bb467c
     */
    error InvalidAdminAddress();

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
     * @notice Error indicating that the provided new admin address is invalid
     * @dev 0xb5aaecfd
     */
    error InvalidNewAdminAddress();

    /**
     * @notice Error indicating that the provided new upgrader role address is invalid
     * @dev 0xe7124f5b
     */
    error InvalidNewUpgraderRoleAddress();

    /**
     * @notice Error indicating that role management functions are disabled
     * @dev This contract has a fixed admin and does not allow for dynamic role management
     * @dev 0xd6758507
     */
    error RoleManagementDisabled();

    /**
     * @notice Emitted when a new proxy is successfully created
     * @param proxy The address of the newly deployed proxy
     * @param dealId The dealId for which the proxy was created
     */
    event ProxyCreated(address indexed proxy, uint256 indexed dealId);

    /**
     * @notice Emitted when the admin is changed
     * @param newAdmin The address of the new admin
     */
    event AdminChanged(address indexed newAdmin);

    /**
     * @notice Emitted when the upgrader role is changed
     * @param newUpgraderRole The address of the new upgrader role
     */
    event UpgraderRoleChanged(address indexed newUpgraderRole);

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
     * @param admin The address of the admin responsible for the contract
     * @param implementation The address of the implementation contract
     */
    function initialize(address admin, address implementation) public initializer {
        if (admin == address(0)) {
            revert InvalidAdminAddress();
        }
        if (implementation == address(0)) {
            revert InvalidImplementationAddress();
        }

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        ValidatorFactoryStorage storage $ = s();
        $._beacon = address(new UpgradeableBeacon(implementation, admin));
        $._admin = admin;
        $._upgraderRole = admin;
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
        onlyRole(DEFAULT_ADMIN_ROLE)
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
                $._beacon, abi.encodeCall(Validator.initialize, ($._admin, $._filecoinPay, $._poRepMarket, dealId))
            )
        );
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 salt = keccak256(abi.encode($._admin, dealId));
        address proxy = Create2.computeAddress(salt, keccak256(initCode), address(this));
        $._instances[dealId] = proxy;
        $._isValidatorContract[proxy] = true;

        Create2.deploy(0, salt, initCode);
        emit ProxyCreated(proxy, dealId);
    }

    /**
     * @notice Sets a new admin for the contract and revoke the role from the old admin
     * @dev Only callable by the current admin. Reverts if the new admin address is the zero address.
     * @param newAdmin The new admin address
     */
    function setAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) {
            revert InvalidNewAdminAddress();
        }
        ValidatorFactoryStorage storage $ = s();

        _revokeRole(DEFAULT_ADMIN_ROLE, $._admin);
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        $._admin = newAdmin;

        emit AdminChanged(newAdmin);
    }

    /**
     * @notice Sets a new upgrader role for the contract
     * @dev Only callable by the current admin. Reverts if the new upgrader role address is the zero address.
     * @param newUpgraderRole The new upgrader role address
     */
    function setUpgraderRole(address newUpgraderRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newUpgraderRole == address(0)) {
            revert InvalidNewUpgraderRoleAddress();
        }
        ValidatorFactoryStorage storage $ = s();

        _revokeRole(UPGRADER_ROLE, $._upgraderRole);
        _grantRole(UPGRADER_ROLE, newUpgraderRole);

        $._upgraderRole = newUpgraderRole;

        emit UpgraderRoleChanged(newUpgraderRole);
    }

    // solhint-disable use-natspec
    /**
     * @notice Disabled role management functions
     * @dev This contract has a fixed admin and does not allow for dynamic role management
     */
    function grantRole(bytes32, address) public pure override {
        revert RoleManagementDisabled();
    }

    /**
     * @notice Disabled role management functions
     * @dev This contract has a fixed admin and does not allow for dynamic role management
     */
    function revokeRole(bytes32, address) public pure override {
        revert RoleManagementDisabled();
    }

    /**
     * @notice Disabled role management functions
     * @dev This contract has a fixed admin and does not allow for dynamic role management
     */
    function renounceRole(bytes32, address) public pure override {
        revert RoleManagementDisabled();
    }

    // solhint-enable use-natspec

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

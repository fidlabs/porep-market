// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Operator} from "./Operator.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title OperatorFactory
 * @notice Beacon factory contract for creating Operator instances
 */
contract OperatorFactory is UUPSUpgradeable, AccessControlUpgradeable {
    /**
     * @notice Upgradable role which allows for contract upgrades
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // @custom:storage-location erc7201:porepmarket.storage.OperatorFactoryStorage
    struct OperatorFactoryStorage {
        mapping(address => bool) _isOperatorContract;
        address _filecoinPay;
        address _beacon;
        address _admin;
        address _upgraderRole;
        IERC20 _token;
    }

    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.OperatorFactoryStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OPERATOR_FACTORY_STORAGE_LOCATION =
        0x7aee5fed1c1bd28675f209a0fba1ff993d27370a28858d7e37b8d0d98f85da00;

    // solhint-disable-next-line use-natspec
    function _getOperatorFactoryStorage() private pure returns (OperatorFactoryStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := OPERATOR_FACTORY_STORAGE_LOCATION
        }
    }

    /**
     * @dev Returns the storage struct for the OperatorFactory contract.
     * @notice function to allow acess to storage for inheriting contracts
     * @return OperatorFactoryStorage storage struct
     */
    function s() internal pure returns (OperatorFactoryStorage storage) {
        return _getOperatorFactoryStorage();
    }

    /**
     * @notice Error indicating that an instance for the given dealId already exists
     * @dev 0x1144626f
     */
    error InstanceAlreadyExists();

    /**
     * @notice Error indicating that the provided token address is invalid
     * @dev 0x5419d62f
     */
    error InvalidTokenAddress();
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
     * @notice Error indicating that the provided ClientSmartContract address is invalid
     * @dev 0x39ee49ba
     */
    error InvalidClientSmartContractAddress();

    /**
     * @notice Error indicating that the provided FilecoinPay address is invalid
     * @dev 0x5419d62f
     */
    error InvalidFilecoinPayAddress();

    /**
     * @notice Error indicating that the provided SLIScorer address is invalid
     * @dev 0x7725d473
     */
    error InvalidPoRepServiceAddress();

    /**
     * @notice Error indicating that the provided SLIScorer address is invalid
     * @dev 0xf234bc02
     */
    error InvalidSliScorerAddress();

    /**
     * @notice Error indicating that the provided SPRegistry address is invalid
     * @dev 0xe6e262d1
     */
    error InvalidSPRegistryAddress();

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
     */
    event ProxyCreated(address indexed proxy);

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
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @dev Initializes the contract by setting a default admin role and a UUPS upgradeable role
     * @param admin The address of the admin responsible for the contract
     * @param implementation The address of the implementation contract
     * @param token The ERC20 token used for payments
     */
    function initialize(address admin, address implementation, IERC20 token) public initializer {
        if (admin == address(0)) {
            revert InvalidAdminAddress();
        }
        if (implementation == address(0)) {
            revert InvalidImplementationAddress();
        }

        if (token == IERC20(address(0))) {
            revert InvalidTokenAddress();
        }

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        OperatorFactoryStorage storage $ = s();
        $._beacon = address(new UpgradeableBeacon(implementation, admin));
        $._admin = admin;
        $._upgraderRole = admin;
        $._token = token;
    }

    /**
     * @notice Creates a new instance of an upgradeable contract.
     * @dev Uses BeaconProxy to create a new proxy instance, pointing to the Beacon for the logic contract.
     * @dev Reverts if an instance for the given dealId already exists.
     */
    function create() external {
        OperatorFactoryStorage storage $ = s();

        bytes memory initCode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode($._beacon, abi.encodeCall(Operator.initialize, ($._admin, $._filecoinPay, $._token)))
        );
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 salt = keccak256(abi.encode($._admin, block.timestamp));
        address proxy = Create2.computeAddress(salt, keccak256(initCode), address(this));
        $._isOperatorContract[proxy] = true;

        Create2.deploy(0, salt, initCode);
        emit ProxyCreated(proxy);
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
        OperatorFactoryStorage storage $ = s();

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
        OperatorFactoryStorage storage $ = s();

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
     * @notice Checks if an address is an operator contract
     * @param contractAddress The address to check
     * @return True if the address is an operator contract, false otherwise
     */
    function isOperatorContract(address contractAddress) external view returns (bool) {
        return s()._isOperatorContract[contractAddress];
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

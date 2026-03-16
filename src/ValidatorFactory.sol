// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity =0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Validator} from "./Validator.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {PoRepMarket} from "./PoRepMarket.sol";
import {PoRepTypes} from "./types/PoRepTypes.sol";

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
        mapping(uint256 dealId => address contractAddress) _instances;
        mapping(address => bool) _isValidatorContract;
        address _clientSmartContract;
        address _poRepService;
        address _filecoinPay;
        address _sliScorer;
        address _poRepMarket;
        address _SPRegistry;
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
    error InvalidAdminAddress();
    error InvalidClientAddress();
    error InvalidSlcAddress();
    error InvalidPoRepMarketAddress();
    error InvalidClientSmartContractAddress();
    error InvalidFilecoinPayAddress();
    error InvalidPoRepServiceAddress();
    error InvalidSliScorerAddress();
    error InvalidSPRegistryAddress();

    /**
     * @notice Emitted when a new proxy is successfully created
     * @param proxy The address of the newly deployed proxy
     * @param dealId The dealId for which the proxy was created
     */
    event ProxyCreated(address indexed proxy, uint256 indexed dealId);

    /**
     * @notice Initializes the contract
     * @dev Initializes the contract by setting a default admin role and a UUPS upgradeable role
     * @param admin The address of the admin responsible for the contract
     * @param implementation The address of the implementation contract
     */
    function initialize(address admin, address implementation) public initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        ValidatorFactoryStorage storage $ = s();
        $._beacon = address(new UpgradeableBeacon(implementation, admin));
    }

    /**
     * @notice Initializes the contract with the PoRepMarket, ClientSmartContract, and FilecoinPay addresses
     * @dev This function is called after the contract is initialized with the admin and implementation addresses
     * @param _poRepService The address of the PoRepService contract
     * @param _filecoinPay The address of the FilecoinPay contract
     * @param _sliScorer The address of the SLIScorer contract
     * @param _clientSmartContract The address of the ClientSmartContract contract
     * @param _poRepMarket The address of the PoRepMarket contract
     * @param _SPRegistry The address of the SPRegistry contract
     */
    function initialize2(
        address _poRepService,
        address _filecoinPay,
        address _sliScorer,
        address _clientSmartContract,
        address _poRepMarket,
        address _SPRegistry
    ) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_poRepService == address(0)) revert InvalidPoRepServiceAddress();
        if (_poRepMarket == address(0)) revert InvalidPoRepMarketAddress();
        if (_clientSmartContract == address(0)) revert InvalidClientSmartContractAddress();
        if (_filecoinPay == address(0)) revert InvalidFilecoinPayAddress();
        if (_sliScorer == address(0)) revert InvalidSliScorerAddress();
        if (_SPRegistry == address(0)) revert InvalidSPRegistryAddress();

        ValidatorFactoryStorage storage $ = s();
        $._poRepMarket = _poRepMarket;
        $._clientSmartContract = _clientSmartContract;
        $._poRepService = _poRepService;
        $._filecoinPay = _filecoinPay;
        $._sliScorer = _sliScorer;
        $._SPRegistry = _SPRegistry;
    }

    /**
     * @notice Creates a new instance of an upgradeable contract.
     * @dev Uses BeaconProxy to create a new proxy instance, pointing to the Beacon for the logic contract.
     * @dev Reverts if an instance for the given dealId already exists.
     * @param admin The address of the admin responsible for the contract.
     * @param dealId The dealId for which the proxy was created.
     */
    function create(address admin, uint256 dealId) external {
        if (admin == address(0)) revert InvalidAdminAddress();

        ValidatorFactoryStorage storage $ = s();
        if ($._instances[dealId] != address(0)) revert InstanceAlreadyExists();

        PoRepTypes.DealProposal memory dp = PoRepMarket($._poRepMarket).getDealProposal(dealId);
        if (msg.sender != dp.client) revert InvalidClientAddress();

        bytes memory initCode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(
                $._beacon,
                abi.encodeCall(
                    Validator.initialize,
                    (
                        admin,
                        $._poRepService,
                        $._filecoinPay,
                        $._sliScorer,
                        $._clientSmartContract,
                        $._poRepMarket,
                        $._SPRegistry,
                        dealId
                    )
                )
            )
        );
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 salt = keccak256(abi.encode(admin, dealId));
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
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}

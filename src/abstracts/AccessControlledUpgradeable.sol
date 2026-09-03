// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessManager} from "../interfaces/IAccessManager.sol";

/**
 * @title AccessControlledUpgradeable
 * @notice Routes role checks to the protocol-wide AccessManager.
 */
abstract contract AccessControlledUpgradeable is Initializable {
    /// @custom:storage-location erc7201:porepmarket.storage.AccessControlledUpgradeableStorage
    struct AccessControlledUpgradeableStorage {
        address _accessManager;
    }

    // keccak256(abi.encode(uint256(keccak256("porepmarket.storage.AccessControlledUpgradeableStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ACCESS_CONTROLLED_UPGRADEABLE_STORAGE_LOCATION =
        0x5fb8a3382c2de59c0ced6c5b31ee681f5bd1a0ad890fb5581ffeccfdb2f2e900;

    /**
     * @dev 0x9a005626
     */
    error InvalidAccessManager(address manager);

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    // solhint-disable-next-line func-name-mixedcase
    function __AccessControlled_init(address manager) internal onlyInitializing {
        if (manager == address(0) || manager.code.length == 0) revert InvalidAccessManager(manager);
        _getAccessControlledUpgradeableStorage()._accessManager = manager;
    }

    /**
     * @notice Returns the protocol-wide AccessManager address.
     * @return manager Protocol AccessManager address.
     */
    function accessManager() public view returns (address) {
        return _getAccessControlledUpgradeableStorage()._accessManager;
    }

    function _hasRole(bytes32 role, address account) internal view returns (bool allowed) {
        address manager = accessManager();
        bytes32 selector = bytes32(IAccessManager.hasRole.selector);
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, selector)
            mstore(add(pointer, 0x04), role)
            mstore(add(pointer, 0x24), account)
            let success := staticcall(gas(), manager, pointer, 0x44, pointer, 0x20)
            allowed := and(and(success, eq(returndatasize(), 0x20)), eq(mload(pointer), 1))
        }
    }

    function _checkRole(bytes32 role) internal view {
        _checkRole(role, msg.sender);
    }

    function _checkRole(bytes32 role, address account) internal view {
        if (!_hasRole(role, account)) revert IAccessControl.AccessControlUnauthorizedAccount(account, role);
    }

    // solhint-disable-next-line use-natspec
    function _getAccessControlledUpgradeableStorage()
        private
        pure
        returns (AccessControlledUpgradeableStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            $.slot := ACCESS_CONTROLLED_UPGRADEABLE_STORAGE_LOCATION
        }
    }
}

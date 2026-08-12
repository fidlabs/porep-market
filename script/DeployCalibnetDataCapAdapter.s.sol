// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, gas-small-strings, quotes
pragma solidity =0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {CalibnetDataCapAdapter} from "../src/CalibnetDataCapAdapter.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";

interface ICalibnetDataCapAdapterProxy {
    function UPGRADER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external;
}

contract DeployCalibnetDataCapAdapter is DeployUtils {
    using stdJson for string;

    uint256 internal constant CALIBNET_CHAIN_ID = 314159;
    address internal constant CALIBNET_ADAPTER_PROXY = 0xfEBd13e0DecCD8B96c2781da32b30BbEB12884Db;
    string internal constant DATA_CAP_ADAPTER_ARTIFACT = "src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter";
    string internal constant CALIBNET_ADAPTER_ARTIFACT = "src/CalibnetDataCapAdapter.sol:CalibnetDataCapAdapter";

    /**
     * @dev 0xa5dab5fe
     */
    error UnsupportedChainId(uint256 chainId);

    /**
     * @dev 0x3acefc45
     */
    error UnexpectedAdapterProxy(address expected, address actual);

    /**
     * @dev 0xfcf16e0e
     */
    error MissingUpgraderRole(address account);

    /**
     * @dev 0xffd5555a
     */
    error UpgradeFailed(address expectedImplementation, address actualImplementation);

    function run() external {
        _run(CALIBNET_ADAPTER_PROXY);
    }

    function _run(address expectedProxy) internal {
        if (block.chainid != CALIBNET_CHAIN_ID) revert UnsupportedChainId(block.chainid);

        string memory manifest = vm.readFile(vm.envString("DEPLOYMENT_MANIFEST"));
        address proxy = _manifestUupsTarget(manifest, "DataCapEvidenceAdapter");
        if (proxy != expectedProxy) revert UnexpectedAdapterProxy(expectedProxy, proxy);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        ICalibnetDataCapAdapterProxy adapter = ICalibnetDataCapAdapterProxy(proxy);
        if (!adapter.hasRole(adapter.UPGRADER_ROLE(), deployer)) revert MissingUpgraderRole(deployer);

        vm.startBroadcast(deployer);
        address implementation = address(new CalibnetDataCapAdapter());
        adapter.upgradeToAndCall(implementation, "");
        vm.stopBroadcast();

        address liveImplementation = _erc1967Implementation(proxy);
        if (liveImplementation != implementation) revert UpgradeFailed(implementation, liveImplementation);

        vm.writeJson(
            string.concat(
                '{"operations":[{"target":"DataCapEvidenceAdapter","kind":"uups","artifact":"',
                DATA_CAP_ADAPTER_ARTIFACT,
                '","newArtifact":"',
                CALIBNET_ADAPTER_ARTIFACT,
                '","newImplementation":"',
                vm.toString(implementation),
                '","newImplementationCodeHash":"',
                vm.toString(implementation.codehash),
                '"}]}'
            ),
            vm.envString("UPGRADE_OUTPUT")
        );
    }
}

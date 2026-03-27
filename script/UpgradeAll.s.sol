// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {DeployUtils, UpgradeParams} from "./utils/DeployUtils.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract UpgradeAll is Script, DeployUtils {
    using stdJson for string;

    address internal admin;
    string internal upgradeArtifact;
    string internal latestArtifact;

    error AllContractsUpToDate();

    function run() external {
        admin = vm.addr(vm.envUint("PRIVATE_KEY"));
        upgradeArtifact = "upgradeArtifact";
        latestArtifact = readLatestDeploymentArtifact();

        UpgradeParams[] memory pendingUpgrades = collectPendingUpgrades();

        if (pendingUpgrades.length == 0) {
            revert AllContractsUpToDate();
        }

        vm.startBroadcast(admin);
        upgradeAll(pendingUpgrades);
        vm.stopBroadcast();

        serializeAndSaveArtifact();
    }

    function upgradeAll(UpgradeParams[] memory pendingUpgrades) internal {
        for (uint256 i = 0; i < pendingUpgrades.length; i++) {
            UpgradeParams memory p = pendingUpgrades[i];
            address impl;

            if (p.isBeacon) {
                impl = upgradeBeacon(p.proxy, p.contractName);
            } else {
                impl = upgrade(p.proxy, p.contractName, p.cd);
            }

            serializeContract(upgradeArtifact, p.contractName, p.proxy, impl);
            updateLatestImpl(p.contractName, impl);
        }
    }

    function collectPendingUpgrades() internal returns (UpgradeParams[] memory pending) {
        UpgradeParams[] memory params = getAllUpgradeableContractsParams();
        pending = new UpgradeParams[](params.length);
        uint256 count;

        for (uint256 i = 0; i < params.length; i++) {
            (address proxyAddr, address prevImpl, bytes32 prevImplCodeHash, bytes32 prevDeployedCodeHash) =
                deserializeContract(latestArtifact, params[i].contractName);

            if (generateContractHash(params[i].contractName) == prevDeployedCodeHash) continue;

            params[i].proxy = proxyAddr;
            pending[count] = params[i];

            serializePreviousVersion(upgradeArtifact, params[i].contractName, prevImpl, prevImplCodeHash);
            count++;
        }

        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(pending, count)
        }
    }

    function serializeAndSaveArtifact() internal {
        upgradeArtifact.serialize("chainId", block.chainid);
        upgradeArtifact.serialize("block", block.number);
        upgradeArtifact.serialize("timestamp", block.timestamp);
        string memory output = upgradeArtifact.serialize("deployer", admin);

        saveUpgradeArtifact(output, "upgradeAll");
    }

    /**
     * @dev fill reinitCalldata if needed
     */
    function getAllUpgradeableContractsParams() internal pure returns (UpgradeParams[] memory params) {
        params = new UpgradeParams[](7);
        params[0] = proxy("PoRepMarket", bytes(""));
        params[1] = proxy("Client", bytes(""));
        params[2] = proxy("ValidatorFactory", bytes(""));
        params[3] = proxy("SLIOracle", bytes(""));
        params[4] = proxy("SLIScorer", bytes(""));
        params[5] = proxy("SPRegistry", bytes(""));
        params[6] = beacon("Validator");
    }
}

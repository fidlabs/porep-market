// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, gas-small-strings
pragma solidity =0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {SectorEvidenceAdapter} from "../src/SectorEvidenceAdapter.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";

contract DeploySectorEvidenceAdapter is DeployUtils {
    using stdJson for string;

    function run() external {
        _run(
            vm.readFile(vm.envString("DEPLOYMENT_MANIFEST")),
            vm.envString("DEPLOYMENT_OUTPUT"),
            vm.envUint("PRIVATE_KEY")
        );
    }

    function _run(string memory manifest, string memory outputPath, uint256 privateKey) internal {
        address market = _manifestUupsTarget(manifest, "PoRepMarket");
        address manager = manifest.readAddress(".contracts.AccessManager.implementation");
        _ensureCode(manager);

        vm.startBroadcast(vm.addr(privateKey));
        address implementation = address(new SectorEvidenceAdapter());
        address proxy = createProxy(abi.encodeCall(SectorEvidenceAdapter.initialize, (manager, market)), implementation);
        // DataCap claims stop working after NV29, so new deals must use sector evidence.
        PoRepMarket(market).setGlobalEvidenceAdapter(proxy);
        vm.stopBroadcast();

        vm.writeJson(
            _serializeUupsContract(
                "missingSectorEvidenceAdapter",
                "src/SectorEvidenceAdapter.sol:SectorEvidenceAdapter",
                proxy,
                implementation
            ),
            outputPath,
            ".contracts.SectorEvidenceAdapter"
        );
    }
}

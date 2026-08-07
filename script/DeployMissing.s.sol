// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, gas-small-strings
pragma solidity =0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {PoRepMarketSectorStatusInspector} from "../src/helpers/PoRepMarketSectorStatusInspector.sol";
import {PoRepMarketViewHelper} from "../src/helpers/PoRepMarketViewHelper.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";

contract DeployMissing is DeployUtils {
    using stdJson for string;

    function run() external {
        string memory manifest = vm.readFile(vm.envString("DEPLOYMENT_MANIFEST"));
        string memory output = vm.envString("DEPLOYMENT_OUTPUT");
        address market = _manifestUupsTarget(manifest, "PoRepMarket");

        vm.startBroadcast(vm.addr(vm.envUint("PRIVATE_KEY")));
        address sectorStatusInspector = address(new PoRepMarketSectorStatusInspector(market));
        address viewHelper = address(new PoRepMarketViewHelper(market));
        vm.stopBroadcast();

        vm.writeJson(
            _serializeStandalone(
                "missingSectorStatusInspector",
                "src/helpers/PoRepMarketSectorStatusInspector.sol:PoRepMarketSectorStatusInspector",
                sectorStatusInspector
            ),
            output,
            ".contracts.PoRepMarketSectorStatusInspector"
        );
        vm.writeJson(
            _serializeStandalone(
                "missingViewHelper", "src/helpers/PoRepMarketViewHelper.sol:PoRepMarketViewHelper", viewHelper
            ),
            output,
            ".contracts.PoRepMarketViewHelper"
        );
    }

    function _serializeStandalone(string memory objectKey, string memory artifact, address implementation)
        private
        returns (string memory)
    {
        objectKey.serialize("kind", string("standalone"));
        objectKey.serialize("artifact", artifact);
        objectKey.serialize("implementation", implementation);
        return objectKey.serialize("implementationCodeHash", implementation.codehash);
    }
}

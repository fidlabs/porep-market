// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, gas-small-strings, quotes
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeploySectorEvidenceAdapter} from "../../script/DeploySectorEvidenceAdapter.s.sol";
import {AccessManager} from "../../src/AccessManager.sol";
import {PoRepMarket} from "../../src/PoRepMarket.sol";
import {SectorEvidenceAdapter} from "../../src/SectorEvidenceAdapter.sol";

contract DeploySectorEvidenceAdapterTestHarness is DeploySectorEvidenceAdapter {
    function runWithInputs(string calldata manifest, string calldata outputPath, uint256 privateKey) external {
        _run(manifest, outputPath, privateKey);
    }
}

contract DeploySectorEvidenceAdapterTest is Test {
    using stdJson for string;

    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function testDeploysAdapterAndMakesItGlobal() public {
        address admin = vm.addr(1);
        address manager = address(new AccessManager(admin, admin));
        address marketImplementation = address(new PoRepMarket());
        address market = address(
            new ERC1967Proxy(
                marketImplementation,
                abi.encodeCall(PoRepMarket.initialize, (manager, vm.addr(2), vm.addr(3), vm.addr(4), vm.addr(5)))
            )
        );
        string memory outputPath = string.concat(vm.projectRoot(), "/.deployment/sector-adapter-output.json");
        vm.createDir(string.concat(vm.projectRoot(), "/.deployment"), true);
        vm.writeFile(outputPath, "{}");

        new DeploySectorEvidenceAdapterTestHarness()
            .runWithInputs(_manifest(manager, market, marketImplementation), outputPath, 1);

        string memory output = vm.readFile(outputPath);
        address proxy = output.readAddress(".contracts.SectorEvidenceAdapter.proxy");
        address implementation = output.readAddress(".contracts.SectorEvidenceAdapter.implementation");
        assertEq(output.readString(".contracts.SectorEvidenceAdapter.kind"), "uups");
        assertEq(
            output.readString(".contracts.SectorEvidenceAdapter.artifact"),
            "src/SectorEvidenceAdapter.sol:SectorEvidenceAdapter"
        );
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), implementation);
        assertEq(SectorEvidenceAdapter(proxy).getPoRepMarketAddress(), market);
        assertEq(SectorEvidenceAdapter(proxy).accessManager(), manager);
        assertEq(PoRepMarket(market).getGlobalEvidenceAdapter(), proxy);
    }

    function _manifest(address manager, address market, address marketImplementation)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"contracts":{"AccessManager":{"implementation":"',
            vm.toString(manager),
            '"},"PoRepMarket":{"proxy":"',
            vm.toString(market),
            '","implementation":"',
            vm.toString(marketImplementation),
            '"}}}'
        );
    }
}

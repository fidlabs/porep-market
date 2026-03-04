// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CommonTypes} from "filecoin-solidity/v0.8/types/CommonTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PoRepMarket} from "../../src/PoRepMarket.sol";
import {SPRegistry} from "../../src/SPRegistry.sol";
import {SLIOracle} from "../../src/SLIOracle.sol";
import {SLIScorer} from "../../src/SLIScorer.sol";
import {ValidatorFactory} from "../../src/ValidatorFactory.sol";
import {Validator} from "../../src/Validator.sol";
import {SLITypes} from "../../src/types/SLITypes.sol";
import {ISPRegistry} from "../../src/interfaces/ISPRegistry.sol";
import {DemoHelper} from "./DemoHelper.sol";

/// @notice Deploy all contracts behind UUPS proxies
contract DeployDemo is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);
        vm.startBroadcast(pk);

        ValidatorFactory vfImpl = new ValidatorFactory();
        Validator validatorImpl = new Validator();
        ERC1967Proxy vfProxy =
            new ERC1967Proxy(address(vfImpl), abi.encodeCall(ValidatorFactory.initialize, (admin, address(validatorImpl))));

        // admin as temporary poRepMarket to satisfy non-zero check
        SPRegistry spImpl = new SPRegistry();
        ERC1967Proxy spProxy = new ERC1967Proxy(address(spImpl), abi.encodeCall(SPRegistry.initialize, (admin, admin)));

        PoRepMarket pmImpl = new PoRepMarket();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl), abi.encodeCall(PoRepMarket.initialize, (admin, address(vfProxy), address(spProxy)))
        );

        SPRegistry(address(spProxy)).grantRole(SPRegistry(address(spProxy)).MARKET_ROLE(), address(pmProxy));

        // admin doubles as oracle for demo purposes
        SLIOracle oracleImpl = new SLIOracle();
        ERC1967Proxy oracleProxy =
            new ERC1967Proxy(address(oracleImpl), abi.encodeCall(SLIOracle.initialize, (admin, admin)));

        SLIScorer scorerImpl = new SLIScorer();
        ERC1967Proxy scorerProxy = new ERC1967Proxy(
            address(scorerImpl), abi.encodeCall(SLIScorer.initialize, (admin, SLIOracle(address(oracleProxy))))
        );

        DemoHelper demoHelper = new DemoHelper(address(pmProxy), admin);
        PoRepMarket(address(pmProxy)).setClientSmartContract(address(demoHelper));

        vm.stopBroadcast();

        console.log("DEPLOYED_SP_REGISTRY=%s", address(spProxy));
        console.log("DEPLOYED_POREP_MARKET=%s", address(pmProxy));
        console.log("DEPLOYED_VALIDATOR_FACTORY=%s", address(vfProxy));
        console.log("DEPLOYED_SLI_ORACLE=%s", address(oracleProxy));
        console.log("DEPLOYED_SLI_SCORER=%s", address(scorerProxy));
        console.log("DEPLOYED_DEMO_HELPER=%s", address(demoHelper));
        console.log("DEPLOYED_ADMIN=%s", admin);
    }
}

/// @notice Register both SPs and set SLI attestations
contract SetupMarketplace is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address spRegistry = vm.envAddress("SP_REGISTRY");
        address sliOracle = vm.envAddress("SLI_ORACLE");

        vm.startBroadcast(pk);

        // Register SP Alpha (actor ID 1001)
        SPRegistry(spRegistry).registerProviderFor(
            CommonTypes.FilActorId.wrap(1001),
            vm.addr(pk),
            SLITypes.SLIThresholds({retrievabilityPct: 95, bandwidthMbps: 500, latencyMs: 50, indexingPct: 90}),
            100 * (1024 ** 4), // 100 TiB
            500000000000000000 // 0.5 FIL
        );

        // Register SP Beta (actor ID 1002)
        SPRegistry(spRegistry).registerProviderFor(
            CommonTypes.FilActorId.wrap(1002),
            vm.addr(pk),
            SLITypes.SLIThresholds({retrievabilityPct: 70, bandwidthMbps: 100, latencyMs: 200, indexingPct: 60}),
            50 * (1024 ** 4), // 50 TiB
            300000000000000000 // 0.3 FIL
        );

        // SLI attestations for Alpha
        SLIOracle(sliOracle).setSLI(
            CommonTypes.FilActorId.wrap(1001),
            SLITypes.SLIThresholds({retrievabilityPct: 98, bandwidthMbps: 520, latencyMs: 45, indexingPct: 92})
        );

        // SLI attestations for Beta
        SLIOracle(sliOracle).setSLI(
            CommonTypes.FilActorId.wrap(1002),
            SLITypes.SLIThresholds({retrievabilityPct: 72, bandwidthMbps: 110, latencyMs: 180, indexingPct: 65})
        );

        vm.stopBroadcast();

        console.log("SETUP_COMPLETE=true");
    }
}

/// @notice Compare SLI scores (read-only)
contract CompareScores is Script {
    function run() external view {
        address sliScorer = vm.envAddress("SLI_SCORER");

        SLITypes.SLIThresholds memory requirements =
            SLITypes.SLIThresholds({retrievabilityPct: 90, bandwidthMbps: 400, latencyMs: 100, indexingPct: 80});

        uint256 scoreAlpha = SLIScorer(sliScorer).calculateScore(CommonTypes.FilActorId.wrap(1001), requirements);
        uint256 scoreBeta = SLIScorer(sliScorer).calculateScore(CommonTypes.FilActorId.wrap(1002), requirements);

        console.log("SCORE_ALPHA=%d", scoreAlpha);
        console.log("SCORE_BETA=%d", scoreBeta);
    }
}

/// @notice Propose a high-requirements deal (matches Alpha)
contract ProposeDealHigh is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address poRepMarket = vm.envAddress("POREP_MARKET");

        vm.startBroadcast(pk);

        PoRepMarket(poRepMarket).proposeDeal(
            SLITypes.SLIThresholds({retrievabilityPct: 90, bandwidthMbps: 400, latencyMs: 100, indexingPct: 80}),
            SLITypes.DealTerms({dealSizeBytes: 34359738368, pricePerSector: 400000000000000000, durationDays: 180})
        );

        vm.stopBroadcast();

        PoRepMarket.DealProposal memory deal = PoRepMarket(poRepMarket).getDealProposal(1);
        console.log("DEAL_1_ID=%d", deal.dealId);
        console.log("DEAL_1_PROVIDER=%d", CommonTypes.FilActorId.unwrap(deal.provider));
        console.log("DEAL_1_STATE=%d", uint256(deal.state));
        console.log("DEAL_1_CLIENT=%s", deal.client);
    }
}

/// @notice Reject deal 1, capacity gets released
contract RejectDeal is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address poRepMarket = vm.envAddress("POREP_MARKET");
        address spRegistry = vm.envAddress("SP_REGISTRY");

        vm.startBroadcast(pk);

        PoRepMarket(poRepMarket).rejectDeal(1);

        vm.stopBroadcast();

        PoRepMarket.DealProposal memory deal = PoRepMarket(poRepMarket).getDealProposal(1);
        console.log("DEAL_1_STATE=%d", uint256(deal.state));

        ISPRegistry.ProviderInfo memory alpha =
            ISPRegistry(spRegistry).getProviderInfo(CommonTypes.FilActorId.wrap(1001));
        console.log("ALPHA_PENDING_AFTER=%d", alpha.pendingBytes);
        console.log("ALPHA_AVAILABLE=%d", alpha.availableBytes);
    }
}

/// @notice Propose a relaxed deal (triggers auto-approve)
contract ProposeDealAutoApprove is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address poRepMarket = vm.envAddress("POREP_MARKET");

        vm.startBroadcast(pk);

        PoRepMarket(poRepMarket).proposeDeal(
            SLITypes.SLIThresholds({retrievabilityPct: 60, bandwidthMbps: 50, latencyMs: 300, indexingPct: 50}),
            SLITypes.DealTerms({dealSizeBytes: 34359738368, pricePerSector: 500000000000000000, durationDays: 365})
        );

        vm.stopBroadcast();

        PoRepMarket.DealProposal memory deal = PoRepMarket(poRepMarket).getDealProposal(2);
        console.log("DEAL_2_ID=%d", deal.dealId);
        console.log("DEAL_2_PROVIDER=%d", CommonTypes.FilActorId.unwrap(deal.provider));
        console.log("DEAL_2_STATE=%d", uint256(deal.state));
    }
}

/// @notice Fallback: accept deal 2 manually if auto-approve didn't trigger
contract AcceptDealFallback is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address poRepMarket = vm.envAddress("POREP_MARKET");

        PoRepMarket.DealProposal memory deal = PoRepMarket(poRepMarket).getDealProposal(2);

        if (uint256(deal.state) == 0) {
            vm.startBroadcast(pk);
            PoRepMarket(poRepMarket).acceptDeal(2);
            vm.stopBroadcast();
        }

        deal = PoRepMarket(poRepMarket).getDealProposal(2);
        console.log("DEAL_2_STATE=%d", uint256(deal.state));
    }
}

/// @notice Complete deal 2 via DemoHelper
contract CompleteDeal is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address demoHelper = vm.envAddress("DEMO_HELPER");
        address poRepMarket = vm.envAddress("POREP_MARKET");
        address spRegistry = vm.envAddress("SP_REGISTRY");

        vm.startBroadcast(pk);

        DemoHelper(demoHelper).completeDeal(2);

        vm.stopBroadcast();

        PoRepMarket.DealProposal memory deal = PoRepMarket(poRepMarket).getDealProposal(2);
        console.log("DEAL_2_STATE=%d", uint256(deal.state));

        uint64 providerId = CommonTypes.FilActorId.unwrap(deal.provider);
        ISPRegistry.ProviderInfo memory info =
            ISPRegistry(spRegistry).getProviderInfo(CommonTypes.FilActorId.wrap(providerId));
        console.log("PROVIDER_COMMITTED=%d", info.committedBytes);
        console.log("PROVIDER_PENDING=%d", info.pendingBytes);
        console.log("PROVIDER_ID=%d", providerId);
    }
}

/// @notice Final summary (read-only)
contract DemoSummary is Script {
    function run() external view {
        address poRepMarket = vm.envAddress("POREP_MARKET");
        address spRegistry = vm.envAddress("SP_REGISTRY");
        address sliScorer = vm.envAddress("SLI_SCORER");

        // Deal states
        PoRepMarket.DealProposal memory deal1 = PoRepMarket(poRepMarket).getDealProposal(1);
        console.log("SUMMARY_DEAL_1_STATE=%d", uint256(deal1.state));
        console.log("SUMMARY_DEAL_1_PROVIDER=%d", CommonTypes.FilActorId.unwrap(deal1.provider));

        PoRepMarket.DealProposal memory deal2 = PoRepMarket(poRepMarket).getDealProposal(2);
        console.log("SUMMARY_DEAL_2_STATE=%d", uint256(deal2.state));
        console.log("SUMMARY_DEAL_2_PROVIDER=%d", CommonTypes.FilActorId.unwrap(deal2.provider));

        // Provider capacity
        ISPRegistry.ProviderInfo memory alpha =
            ISPRegistry(spRegistry).getProviderInfo(CommonTypes.FilActorId.wrap(1001));
        console.log("ALPHA_AVAILABLE=%d", alpha.availableBytes);
        console.log("ALPHA_COMMITTED=%d", alpha.committedBytes);
        console.log("ALPHA_PENDING=%d", alpha.pendingBytes);

        ISPRegistry.ProviderInfo memory beta =
            ISPRegistry(spRegistry).getProviderInfo(CommonTypes.FilActorId.wrap(1002));
        console.log("BETA_AVAILABLE=%d", beta.availableBytes);
        console.log("BETA_COMMITTED=%d", beta.committedBytes);
        console.log("BETA_PENDING=%d", beta.pendingBytes);

        // Scores against standard requirements
        SLITypes.SLIThresholds memory requirements =
            SLITypes.SLIThresholds({retrievabilityPct: 90, bandwidthMbps: 400, latencyMs: 100, indexingPct: 80});

        uint256 alphaScore = SLIScorer(sliScorer).calculateScore(CommonTypes.FilActorId.wrap(1001), requirements);
        uint256 betaScore = SLIScorer(sliScorer).calculateScore(CommonTypes.FilActorId.wrap(1002), requirements);
        console.log("ALPHA_SCORE=%d", alphaScore);
        console.log("BETA_SCORE=%d", betaScore);
    }
}

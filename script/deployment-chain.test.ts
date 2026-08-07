import assert from "node:assert/strict";
import { test } from "node:test";
import {
  extractBroadcastTransactionHashes,
  loadTransactionReceipts,
  verifyLiveDeployment,
  verifyManifestContracts,
  waitForFilecoinFinality,
  type CommandRunner,
} from "./deployment-chain.ts";
import type { DeploymentManifest, DeploymentTransaction, ManifestContract } from "./deployment-state.ts";

const hashA = `0x${"a".repeat(64)}`;
const hashB = `0x${"b".repeat(64)}`;
const codeHash = `0x${"c".repeat(64)}`;
const addresses = Array.from({ length: 9 }, (_, index) => `0x${String(index + 1).repeat(40)}`);
const [a1, a2, a3, a4, a5, a6, a7, a8, a9] = addresses as [string, string, string, string, string, string, string, string, string];

test("accepts every unique Foundry transaction and rejects malformed entries", () => {
  assert.deepEqual(
    extractBroadcastTransactionHashes(JSON.stringify({ transactions: [{ hash: hashA }, { hash: hashB }] })),
    [hashA, hashB],
  );
  assert.throws(
    () => extractBroadcastTransactionHashes(JSON.stringify({ transactions: [{ hash: hashA }, { transactionHash: hashB }] })),
    /transactions\[1\]\.hash/,
  );
  assert.throws(
    () => extractBroadcastTransactionHashes(JSON.stringify({ transactions: [{ hash: hashA }, { hash: hashA }] })),
    /duplicate transaction hash/,
  );
});

test("loads successful receipts including Filecoin transaction-hash aliases", async () => {
  const valid = JSON.stringify({
    transactionHash: hashA,
    status: "0x1",
    blockNumber: "0xa",
    blockHash: hashB,
    contractAddress: null,
  });
  const run = async (output: string): Promise<DeploymentTransaction[]> =>
    loadTransactionReceipts(async () => output, "rpc", [hashA]);

  assert.deepEqual(await run(valid), [{ hash: hashA, status: 1, blockNumber: 10, blockHash: hashB, contractAddress: null }]);
  assert.deepEqual(await run(valid.replace(hashA, hashB)), [{ hash: hashB, status: 1, blockNumber: 10, blockHash: hashB, contractAddress: null }]);
  await assert.rejects(run("null"), /receipt is missing/);
  await assert.rejects(run(valid.replace('"0x1"', '"0x0"')), /failed with status/);
  await assert.rejects(
    loadTransactionReceipts(async () => valid, "rpc", [hashA, hashB]),
    /duplicate canonical receipt hash/,
  );
});

function receipt(blockNumber = 10, blockHash = hashB): DeploymentTransaction {
  return { hash: hashA, status: 1, blockNumber, blockHash, contractAddress: null };
}

test("waits for Filecoin finality and then verifies the canonical receipt block", async () => {
  const heights = [9, 10];
  const calls: string[][] = [];
  const run: CommandRunner = async (_command, args) => {
    calls.push([...args]);
    return args.includes("Filecoin.ChainGetFinalizedTipSet")
      ? JSON.stringify({ Height: heights.shift() })
      : JSON.stringify({ number: "0xa", hash: hashB });
  };
  await waitForFilecoinFinality(run, "rpc", [receipt()], { sleep: async () => {}, progress: () => {} });
  assert.equal(calls.filter((args) => args.includes("eth_getBlockByNumber")).length, 1);
});

test("rejects a non-canonical receipt block and supports cancellation", async () => {
  const nonCanonical: CommandRunner = async (_command, args) =>
    args.includes("Filecoin.ChainGetFinalizedTipSet")
      ? JSON.stringify({ Height: 10 })
      : JSON.stringify({ number: "0xa", hash: hashA });
  await assert.rejects(waitForFilecoinFinality(nonCanonical, "rpc", [receipt()], { progress: () => {} }), /not canonical/);

  const controller = new AbortController();
  const waiting: CommandRunner = async () => JSON.stringify({ Height: 9 });
  await assert.rejects(
    waitForFilecoinFinality(waiting, "rpc", [receipt()], {
      signal: controller.signal,
      progress: () => {},
      sleep: async () => controller.abort(),
    }),
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );
});

test("verifies runtime hashes and UUPS implementation slots", async () => {
  const manifest = manifestWith({ Example: uups(a1, a2) });
  await verifyManifestContracts(basicRunner(), "rpc", manifest);
  await assert.rejects(verifyManifestContracts(basicRunner({ implementation: a3 }), "rpc", manifest), /implementation slot/);
  await assert.rejects(verifyManifestContracts(basicRunner({ runtimeHash: hashA }), "rpc", manifest), /code hash/);
});

test("uses recorded replacement implementations during upgrade verification", async () => {
  const manifest = manifestWith({ Example: uups(a1, a2) });
  const operation = {
    target: "Example",
    kind: "uups" as const,
    artifact: "src/Contract.sol:Contract",
    newImplementation: a3,
    newImplementationCodeHash: hashB,
  };
  const seen: string[] = [];
  const run: CommandRunner = async (_command, args) => {
    if (args.includes("eth_getCode")) {
      seen.push(args.at(-2)!);
      return JSON.stringify(args.at(-2) === a3 ? "0x6002" : "0x6001");
    }
    if (args[0] === "keccak") return args[1] === "0x6002" ? hashB : codeHash;
    if (args.includes("eth_getStorageAt")) return JSON.stringify(padded(a3));
    throw new Error(`unexpected cast arguments: ${args.join(" ")}`);
  };
  await verifyManifestContracts(run, "rpc", manifest, [operation]);
  assert.ok(seen.includes(a3));
  assert.ok(!seen.includes(a2));
});

test("verifies the complete deployment topology", async () => {
  const manifest = completeManifest();
  const selectors = new Set<string>();
  await verifyLiveDeployment(fullRunner(manifest, selectors), "rpc", manifest);
  assert.ok(selectors.has("getBeacon()(address)"));
  assert.ok(selectors.has("getValidatorFactoryContract()(address)"));
  assert.ok(selectors.has("getGlobalEvidenceAdapter()(address)"));
  assert.ok(selectors.has("hasRole(bytes32,address)(bool)"));
  assert.ok(selectors.has("POREPMARKET_CONTRACT()(address)"));
});

test("rejects a stale Validator beacon-to-factory binding", async () => {
  const manifest = completeManifest();
  const beacon = manifest.contracts.ValidatorBeacon!;
  assert.equal(beacon.kind, "beacon");
  manifest.contracts.ValidatorBeacon = { ...beacon, factoryProxy: a2 };
  await assert.rejects(verifyLiveDeployment(fullRunner(manifest), "rpc", manifest), /factoryProxy/);
});

function manifestWith(contracts: Record<string, ManifestContract>): DeploymentManifest {
  return {
    status: "finalized",
    deployer: a1,
    release: { buildInfoSha256: hashA },
    contracts,
    externalDependencies: {
      FilecoinPay: a8,
      MetaAllocator: a9,
      PoRepService: a5,
      Oracle: a6,
      TerminationOracle: a7,
      Operator: a4,
    },
  };
}

function uups(proxy: string, implementation: string): ManifestContract {
  return {
    kind: "uups",
    artifact: "src/Contract.sol:Contract",
    proxy,
    implementation,
    proxyCodeHash: codeHash,
    implementationCodeHash: codeHash,
  };
}

function basicRunner(overrides: { implementation?: string; runtimeHash?: string } = {}): CommandRunner {
  return async (_command, args) => {
    if (args.includes("eth_getCode")) return JSON.stringify("0x6001");
    if (args[0] === "keccak") return overrides.runtimeHash ?? codeHash;
    if (args.includes("eth_getStorageAt")) return JSON.stringify(padded(overrides.implementation ?? a2));
    throw new Error(`unexpected cast arguments: ${args.join(" ")}`);
  };
}

function completeManifest(): DeploymentManifest {
  return manifestWith({
    PoRepMarket: uups(a1, a2),
    ValidatorFactory: uups(a3, a4),
    DataCapEvidenceAdapter: uups(a5, a6),
    SPRegistry: uups(a7, a8),
    SLIOracle: uups(a9, a2),
    SLIScorer: uups(a4, a6),
    Validator: { kind: "implementation", artifact: "src/Validator.sol:Validator", implementation: a8, implementationCodeHash: codeHash },
    ValidatorBeacon: { kind: "beacon", artifact: "UpgradeableBeacon", address: a9, implementation: a8, factoryProxy: a3 },
    PoRepMarketClaimInspector: { kind: "standalone", artifact: "ClaimInspector", implementation: a7, implementationCodeHash: codeHash },
    PoRepMarketSectorStatusInspector: { kind: "standalone", artifact: "SectorStatusInspector", implementation: a5, implementationCodeHash: codeHash },
    PoRepMarketViewHelper: { kind: "standalone", artifact: "ViewHelper", implementation: a6, implementationCodeHash: codeHash },
  });
}

function fullRunner(manifest: DeploymentManifest, selectors = new Set<string>()): CommandRunner {
  return async (_command, args) => {
    if (args.includes("eth_getCode")) return JSON.stringify("0x6001");
    if (args[0] === "keccak") return codeHash;
    if (args.includes("eth_getStorageAt")) {
      const proxy = args.at(-3)!;
      const contract = Object.values(manifest.contracts).find((item) => item.kind === "uups" && item.proxy === proxy);
      assert.ok(contract?.kind === "uups");
      return JSON.stringify(padded(contract.implementation));
    }
    if (args[0] === "call") {
      const target = args[1]!;
      const signature = args[2]!;
      selectors.add(signature);
      if (signature.endsWith("_ROLE()(bytes32)") || signature === "TERMINATION_ORACLE()(bytes32)") return hashA;
      if (signature === "hasRole(bytes32,address)(bool)") return "true\n";
      return padded(addressResult(manifest, target, signature));
    }
    throw new Error(`unexpected cast arguments: ${args.join(" ")}`);
  };
}

function addressResult(manifest: DeploymentManifest, target: string, signature: string): string {
  const c = manifest.contracts;
  if (signature === "implementation()(address)") return implementation(c.Validator!);
  if (signature === "owner()(address)") return manifest.deployer;
  if (signature === "getBeacon()(address)") return beaconAddress(c.ValidatorBeacon!);
  if (signature === "getValidatorFactoryContract()(address)") return proxy(c.ValidatorFactory!);
  if (signature === "getSPRegistryContract()(address)") return proxy(c.SPRegistry!);
  if (signature === "getGlobalEvidenceAdapter()(address)") return proxy(c.DataCapEvidenceAdapter!);
  if (signature === "getPoRepMarketAddress()(address)") return proxy(c.PoRepMarket!);
  if (signature === "POREPMARKET_CONTRACT()(address)") return proxy(c.PoRepMarket!);
  if (signature === "DATA_CAP_EVIDENCE_ADAPTER()(address)") return proxy(c.DataCapEvidenceAdapter!);
  throw new Error(`unexpected address call ${target} ${signature}`);
}

function proxy(contract: ManifestContract): string {
  assert.equal(contract.kind, "uups");
  return (contract as Extract<ManifestContract, { kind: "uups" }>).proxy;
}
function implementation(contract: ManifestContract): string {
  assert.notEqual(contract.kind, "beacon");
  return (contract as Exclude<ManifestContract, { kind: "beacon" }>).implementation;
}
function beaconAddress(contract: ManifestContract): string {
  assert.equal(contract.kind, "beacon");
  return (contract as Extract<ManifestContract, { kind: "beacon" }>).address;
}
function padded(address: string): string {
  return `0x${"0".repeat(24)}${address.slice(2)}`;
}

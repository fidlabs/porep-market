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
import type {
  DeploymentManifest,
  DeploymentTransaction,
  ManifestContract,
  UpgradeOperation,
} from "./deployment-state.ts";

const hashA = `0x${"a".repeat(64)}`;
const hashB = `0x${"b".repeat(64)}`;

test("extracts and normalizes every Foundry broadcast transaction hash", () => {
  const broadcast = JSON.stringify({
    transactions: [{ hash: hashA.toUpperCase().replace("0X", "0x") }, { hash: hashB }],
  });

  assert.deepEqual(extractBroadcastTransactionHashes(broadcast), [hashA, hashB]);
});

test("rejects a malformed Foundry entry instead of filtering it out", () => {
  const broadcast = JSON.stringify({ transactions: [{ hash: hashA }, { transactionHash: hashB }] });

  assert.throws(() => extractBroadcastTransactionHashes(broadcast), /transactions\[1\]\.hash/);
});

for (const [name, transactions] of [
  ["missing transactions", undefined],
  ["empty transactions", []],
  ["non-object entry", [{ hash: hashA }, null]],
  ["non-string hash", [{ hash: 12 }]],
  ["short hash", [{ hash: "0x12" }]],
] as const) {
  test(`rejects ${name} in a Foundry broadcast`, () => {
    assert.throws(() => extractBroadcastTransactionHashes(JSON.stringify({ transactions })), /broadcast\.transactions/);
  });
}

test("rejects duplicate Foundry transaction hashes case-insensitively", () => {
  const uppercaseHash = hashA.toUpperCase().replace("0X", "0x");
  const broadcast = JSON.stringify({ transactions: [{ hash: hashA }, { hash: uppercaseHash }] });

  assert.throws(() => extractBroadcastTransactionHashes(broadcast), /duplicate transaction hash/);
});

function receipt(overrides: Record<string, unknown> = {}) {
  return JSON.stringify({
    transactionHash: hashA,
    status: "0x1",
    blockNumber: "0xA",
    blockHash: hashB,
    contractAddress: null,
    ...overrides,
  });
}

function runnerForReceipt(output: string | Error): CommandRunner {
  return async (command, args) => {
    assert.equal(command, "cast");
    assert.deepEqual(args, ["rpc", "--rpc-url", "rpc", "eth_getTransactionReceipt", hashA]);
    if (output instanceof Error) {
      throw output;
    }
    return output;
  };
}

test("loads an exact successful receipt using JSON-RPC hex quantities", async () => {
  const uppercaseTransactionHash = hashA.toUpperCase().replace("0X", "0x");
  const uppercaseBlockHash = hashB.toUpperCase().replace("0X", "0x");
  const output = receipt({ transactionHash: uppercaseTransactionHash, blockNumber: "0xA", blockHash: uppercaseBlockHash });

  const receipts = await loadTransactionReceipts(runnerForReceipt(output), "rpc", [hashA]);

  assert.deepEqual(receipts, [
    { hash: hashA, status: 1, blockNumber: 10, blockHash: hashB, contractAddress: null },
  ]);
});

for (const [name, output, expected] of [
  ["missing receipt", "null", /receipt is missing.*transaction/],
  ["mismatched receipt hash", receipt({ transactionHash: hashB }), /receipt hash.*does not match/],
  ["failed receipt status", receipt({ status: "0x0" }), /transaction.*failed with status/],
  ["zero block number", receipt({ blockNumber: "0x0" }), /transaction.*positive block number/],
  ["missing block hash", receipt({ blockHash: null }), /transaction.*blockHash/],
  ["malformed receipt JSON", "{", /receipt JSON.*transaction/],
] as const) {
  test(`rejects ${name}`, async () => {
    await assert.rejects(loadTransactionReceipts(runnerForReceipt(output), "rpc", [hashA]), expected);
  });
}

for (const [field, value] of [
  ["status", "0x"],
  ["status", "0x01"],
  ["status", "1"],
  ["status", 1],
  ["blockNumber", "0X1"],
  ["blockNumber", "0xg"],
  ["blockNumber", "0x20000000000000"],
] as const) {
  test(`rejects malformed JSON-RPC quantity ${field}=${String(value)}`, async () => {
    await assert.rejects(
      loadTransactionReceipts(runnerForReceipt(receipt({ [field]: value })), "rpc", [hashA]),
      new RegExp(`transaction.*${field}`),
    );
  });
}

test("rejects duplicate requested receipt hashes case-insensitively", async () => {
  const uppercaseHash = hashA.toUpperCase().replace("0X", "0x");

  await assert.rejects(
    loadTransactionReceipts(runnerForReceipt(receipt()), "rpc", [hashA, uppercaseHash]),
    /duplicate transaction hash/,
  );
});

test("names the transaction when receipt RPC fails", async () => {
  await assert.rejects(
    loadTransactionReceipts(runnerForReceipt(new Error("offline")), "rpc", [hashA]),
    new RegExp(`could not read receipt for transaction ${hashA}`),
  );
});

function minedReceipt(blockNumber = 10, blockHash = hashB): DeploymentTransaction {
  return { hash: hashA, status: 1, blockNumber, blockHash, contractAddress: null };
}

test("waits indefinitely with progress until every receipt block is finalized and canonical", async () => {
  const finalizedHeights = [8, 9, 10];
  const progress: string[] = [];
  const sleeps: number[] = [];
  let canonicalReads = 0;
  const run: CommandRunner = async (command, args, options) => {
    assert.equal(command, "cast");
    assert.equal(options.signal, undefined);
    if (args.includes("Filecoin.ChainGetFinalizedTipSet")) {
      return JSON.stringify({ Height: finalizedHeights.shift() });
    }
    canonicalReads += 1;
    assert.deepEqual(args, ["rpc", "--rpc-url", "rpc", "eth_getBlockByNumber", "0xa", "false"]);
    return JSON.stringify({ number: "0xA", hash: hashB.toUpperCase().replace("0X", "0x") });
  };

  await waitForFilecoinFinality(run, "rpc", [minedReceipt()], {
    pollIntervalMs: 25,
    progress: (message) => progress.push(message),
    sleep: async (milliseconds) => {
      sleeps.push(milliseconds);
    },
  });

  assert.deepEqual(sleeps, [25, 25]);
  assert.equal(canonicalReads, 1);
  assert.deepEqual(progress, [
    "Filecoin finalized height 8; waiting for receipt block 10",
    "Filecoin finalized height 9; waiting for receipt block 10",
    "Filecoin finalized height 10 covers all receipt blocks",
  ]);
});

test("checks each distinct receipt height once after finality", async () => {
  const calls: string[][] = [];
  const run: CommandRunner = async (_command, args) => {
    calls.push([...args]);
    if (args.includes("Filecoin.ChainGetFinalizedTipSet")) {
      return JSON.stringify({ Height: 11 });
    }
    const requestedHeight = args.at(-2);
    return requestedHeight === "0xa"
      ? JSON.stringify({ number: "0xa", hash: hashA })
      : JSON.stringify({ number: "0xb", hash: hashB });
  };

  await waitForFilecoinFinality(
    run,
    "rpc",
    [minedReceipt(10, hashA), minedReceipt(10, hashA), minedReceipt(11, hashB)],
    { sleep: async () => {}, progress: () => {} },
  );

  assert.equal(calls.filter((args) => args.includes("eth_getBlockByNumber")).length, 2);
});

test("rejects conflicting receipt block hashes at one height", async () => {
  const run: CommandRunner = async () => JSON.stringify({ Height: 10 });

  await assert.rejects(
    waitForFilecoinFinality(run, "rpc", [minedReceipt(10, hashA), minedReceipt(10, hashB)]),
    /receipt block 10 has conflicting hashes/,
  );
});

test("rejects a canonical block hash mismatch", async () => {
  const run: CommandRunner = async (_command, args) =>
    args.includes("Filecoin.ChainGetFinalizedTipSet")
      ? JSON.stringify({ Height: 10 })
      : JSON.stringify({ number: "0xa", hash: hashA });

  await assert.rejects(
    waitForFilecoinFinality(run, "rpc", [minedReceipt()], { progress: () => {} }),
    /receipt block 10 is not canonical/,
  );
});

test("rejects a canonical block height mismatch", async () => {
  const run: CommandRunner = async (_command, args) =>
    args.includes("Filecoin.ChainGetFinalizedTipSet")
      ? JSON.stringify({ Height: 10 })
      : JSON.stringify({ number: "0xb", hash: hashB });

  await assert.rejects(
    waitForFilecoinFinality(run, "rpc", [minedReceipt()], { progress: () => {} }),
    /canonical block height mismatch.*10/,
  );
});

test("names finality RPC failures", async () => {
  const run: CommandRunner = async () => {
    throw new Error("offline");
  };

  await assert.rejects(waitForFilecoinFinality(run, "rpc", [minedReceipt()]), /could not read Filecoin finalized height/);
});

test("cancellation during sleep stops before another finality RPC", async () => {
  const controller = new AbortController();
  let calls = 0;
  const run: CommandRunner = async (_command, _args, options) => {
    calls += 1;
    assert.equal(options.signal, controller.signal);
    return JSON.stringify({ Height: 9 });
  };

  await assert.rejects(
    waitForFilecoinFinality(run, "rpc", [minedReceipt()], {
      signal: controller.signal,
      progress: () => {},
      sleep: async () => controller.abort(),
    }),
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );
  assert.equal(calls, 1);
});

const address1 = `0x${"1".repeat(40)}`;
const address2 = `0x${"2".repeat(40)}`;
const address3 = `0x${"3".repeat(40)}`;
const address4 = `0x${"4".repeat(40)}`;
const address5 = `0x${"5".repeat(40)}`;
const address6 = `0x${"6".repeat(40)}`;
const address7 = `0x${"7".repeat(40)}`;
const address8 = `0x${"8".repeat(40)}`;
const address9 = `0x${"9".repeat(40)}`;
const codeHash = `0x${"c".repeat(64)}`;
const replacementCodeHash = `0x${"d".repeat(64)}`;
const runtimeCode = "0x6001";

function manifestWith(contracts: Record<string, ManifestContract>): DeploymentManifest {
  return {
    status: "pending",
    deployer: address1,
    release: { buildInfoSha256: hashA },
    contracts,
    externalDependencies: {
      FilecoinPay: address8,
      MetaAllocator: address9,
      PoRepService: address5,
      Oracle: address6,
      TerminationOracle: address7,
      Operator: address4,
    },
  };
}

function simpleChainRunner(overrides: {
  runtime?: string;
  codeHash?: string;
  storageAddress?: string;
  beaconImplementation?: string;
  beaconOwner?: string;
} = {}): CommandRunner {
  return async (_command, args) => {
    if (args.includes("eth_getCode")) {
      return JSON.stringify(overrides.runtime ?? runtimeCode);
    }
    if (args[0] === "keccak") {
      return `${overrides.codeHash ?? codeHash}\n`;
    }
    if (args.includes("eth_getStorageAt")) {
      return JSON.stringify(paddedAddress(overrides.storageAddress ?? address2));
    }
    if (args.includes("implementation()(address)")) {
      return paddedAddress(overrides.beaconImplementation ?? address2);
    }
    if (args.includes("owner()(address)")) {
      return paddedAddress(overrides.beaconOwner ?? address1);
    }
    throw new Error(`unexpected cast arguments: ${args.join(" ")}`);
  };
}

function paddedAddress(address: string): string {
  return `0x${"0".repeat(24)}${address.slice(2)}`;
}

const contractKindCases: Array<[string, Record<string, ManifestContract>]> = [
  [
    "uups",
    {
      Example: {
        kind: "uups",
        artifact: "src/Example.sol:Example",
        proxy: address1,
        implementation: address2,
        proxyCodeHash: codeHash,
        implementationCodeHash: codeHash,
      },
    },
  ],
  [
    "implementation",
    {
      Example: {
        kind: "implementation",
        artifact: "src/Example.sol:Example",
        implementation: address2,
        implementationCodeHash: codeHash,
      },
    },
  ],
  [
    "standalone",
    {
      Example: {
        kind: "standalone",
        artifact: "src/Example.sol:Example",
        implementation: address2,
        implementationCodeHash: codeHash,
      },
    },
  ],
  [
    "beacon",
    {
      Validator: {
        kind: "implementation",
        artifact: "src/Validator.sol:Validator",
        implementation: address2,
        implementationCodeHash: codeHash,
      },
      ValidatorBeacon: {
        kind: "beacon",
        artifact: "UpgradeableBeacon.sol:UpgradeableBeacon",
        address: address3,
        implementation: address2,
        factoryProxy: address1,
      },
    },
  ],
];

for (const [kind, contracts] of contractKindCases) {
  test(`checks manifest contract kind ${kind}`, async () => {
    await verifyManifestContracts(simpleChainRunner(), "rpc", manifestWith(contracts));
  });
}

test("rejects an unknown manifest contract kind", async () => {
  const manifest = manifestWith({
    Broken: { kind: "proxy", artifact: "src/Broken.sol:Broken" } as unknown as ManifestContract,
  });

  await assert.rejects(verifyManifestContracts(simpleChainRunner(), "rpc", manifest), /Broken.*unsupported kind proxy/);
});

test("rejects empty runtime bytecode", async () => {
  const manifest = manifestWith(contractKindCases[1]![1]);

  await assert.rejects(
    verifyManifestContracts(simpleChainRunner({ runtime: "0x" }), "rpc", manifest),
    /Example implementation has no runtime bytecode/,
  );
});

test("rejects a recorded runtime code hash mismatch", async () => {
  const manifest = manifestWith(contractKindCases[1]![1]);

  await assert.rejects(
    verifyManifestContracts(simpleChainRunner({ codeHash: hashA }), "rpc", manifest),
    /Example implementation code hash does not match manifest/,
  );
});

test("rejects a UUPS implementation slot mismatch", async () => {
  const manifest = manifestWith(contractKindCases[0]![1]);

  await assert.rejects(
    verifyManifestContracts(simpleChainRunner({ storageAddress: address3 }), "rpc", manifest),
    /Example implementation slot does not match/,
  );
});

test("uses recorded UUPS and Validator upgrade replacements", async () => {
  const contracts: Record<string, ManifestContract> = {
    Example: contractKindCases[0]![1].Example!,
    Validator: {
      kind: "implementation",
      artifact: "src/Validator.sol:Validator",
      implementation: address2,
      implementationCodeHash: codeHash,
    },
    ValidatorBeacon: {
      kind: "beacon",
      artifact: "UpgradeableBeacon.sol:UpgradeableBeacon",
      address: address3,
      implementation: address2,
      factoryProxy: address1,
    },
  };
  const operations: UpgradeOperation[] = [
    {
      target: "Example",
      kind: "uups",
      artifact: "src/Example.sol:Example",
      newImplementation: address4,
      newImplementationCodeHash: replacementCodeHash,
    },
    {
      target: "Validator",
      kind: "beacon",
      artifact: "src/Validator.sol:Validator",
      newImplementation: address4,
      newImplementationCodeHash: replacementCodeHash,
    },
  ];
  const seenCodeAddresses: string[] = [];
  const run: CommandRunner = async (_command, args) => {
    if (args.includes("eth_getCode")) {
      const address = args.at(-2)!;
      seenCodeAddresses.push(address);
      return JSON.stringify(address === address4 ? "0x6002" : runtimeCode);
    }
    if (args[0] === "keccak") {
      return args[1] === "0x6002" ? replacementCodeHash : codeHash;
    }
    if (args.includes("eth_getStorageAt")) {
      return JSON.stringify(paddedAddress(address4));
    }
    if (args.includes("implementation()(address)")) {
      return paddedAddress(address4);
    }
    if (args.includes("owner()(address)")) {
      return paddedAddress(address1);
    }
    throw new Error(`unexpected cast arguments: ${args.join(" ")}`);
  };

  await verifyManifestContracts(run, "rpc", manifestWith(contracts), operations);

  assert.equal(seenCodeAddresses.filter((address) => address === address4).length, 2);
  assert.equal(seenCodeAddresses.includes(address2), false);
});

test("rejects a UUPS replacement whose runtime hash differs from the recorded upgrade operation", async () => {
  const operation: UpgradeOperation = {
    target: "Example",
    kind: "uups",
    artifact: "src/Example.sol:Example",
    newImplementation: address4,
    newImplementationCodeHash: replacementCodeHash,
  };
  const run: CommandRunner = async (_command, args) => {
    if (args.includes("eth_getCode")) {
      return JSON.stringify(args.at(-2) === address4 ? "0x6002" : runtimeCode);
    }
    if (args[0] === "keccak") {
      return args[1] === "0x6002" ? hashA : codeHash;
    }
    if (args.includes("eth_getStorageAt")) {
      return JSON.stringify(paddedAddress(address4));
    }
    throw new Error(`unexpected cast arguments: ${args.join(" ")}`);
  };

  await assert.rejects(
    verifyManifestContracts(run, "rpc", manifestWith(contractKindCases[0]![1]), [operation]),
    /Example replacement code hash does not match recorded upgrade operation/,
  );
});

function completeManifest(): DeploymentManifest {
  return manifestWith({
    PoRepMarket: uupsContract(address1, address2),
    ValidatorFactory: uupsContract(address3, address4),
    DataCapEvidenceAdapter: uupsContract(address5, address6),
    SPRegistry: uupsContract(address7, address8),
    SLIOracle: uupsContract(address9, address2),
    SLIScorer: uupsContract(address4, address6),
    Validator: {
      kind: "implementation",
      artifact: "src/Validator.sol:Validator",
      implementation: address8,
      implementationCodeHash: codeHash,
    },
    ValidatorBeacon: {
      kind: "beacon",
      artifact: "UpgradeableBeacon.sol:UpgradeableBeacon",
      address: address9,
      implementation: address8,
      factoryProxy: address3,
    },
    PoRepMarketClaimInspector: {
      kind: "standalone",
      artifact: "src/helpers/PoRepMarketClaimInspector.sol:PoRepMarketClaimInspector",
      implementation: address7,
      implementationCodeHash: codeHash,
    },
  });
}

function uupsContract(proxy: string, implementation: string): ManifestContract {
  return {
    kind: "uups",
    artifact: "src/Contract.sol:Contract",
    proxy,
    implementation,
    proxyCodeHash: codeHash,
    implementationCodeHash: codeHash,
  };
}

test("checks every explicit role, wiring, dependency, beacon, and ClaimInspector binding", async () => {
  const manifest = completeManifest();
  const checkedSelectors = new Set<string>();
  const roleChecks: Array<[string, string]> = [];
  const run: CommandRunner = async (_command, args) => {
    if (args.includes("eth_getCode")) {
      return JSON.stringify(runtimeCode);
    }
    if (args[0] === "keccak") {
      return codeHash;
    }
    if (args.includes("eth_getStorageAt")) {
      const proxy = args.at(-3)!;
      const contract = Object.values(manifest.contracts).find((entry) => entry.kind === "uups" && entry.proxy === proxy);
      assert.ok(contract?.kind === "uups");
      return JSON.stringify(paddedAddress(contract.implementation));
    }
    if (args[0] === "call") {
      const target = args[1]!;
      const signature = args[2]!;
      checkedSelectors.add(signature);
      if (signature.endsWith("_ROLE()(bytes32)") || signature === "TERMINATION_ORACLE()(bytes32)") {
        return hashA;
      }
      if (signature === "hasRole(bytes32,address)(bool)") {
        roleChecks.push([target, args[4]!]);
        return "true\n";
      }
      const expectedAddress = explicitAddressResult(manifest, target, signature);
      return paddedAddress(expectedAddress);
    }
    throw new Error(`unexpected cast arguments: ${args.join(" ")}`);
  };

  await verifyLiveDeployment(run, "rpc", manifest);

  assert.deepEqual(roleChecks, [
    [address1, address1],
    [address3, address1],
    [address5, address1],
    [address7, address1],
    [address9, address1],
    [address4, address1],
    [address1, address5],
    [address9, address6],
    [address5, address7],
    [address7, address1],
    [address7, address4],
  ]);
  assert.deepEqual(
    [...checkedSelectors].sort(),
    [
      "DATA_CAP_EVIDENCE_ADAPTER()(address)",
      "DEFAULT_ADMIN_ROLE()(bytes32)",
      "MARKET_ROLE()(bytes32)",
      "OPERATOR_ROLE()(bytes32)",
      "ORACLE_ROLE()(bytes32)",
      "POREPMARKET_CONTRACT()(address)",
      "POREP_SERVICE_ROLE()(bytes32)",
      "TERMINATION_ORACLE()(bytes32)",
      "getBeacon()(address)",
      "getPoRepMarketAddress()(address)",
      "getSPRegistryContract()(address)",
      "getValidatorFactoryContract()(address)",
      "hasRole(bytes32,address)(bool)",
      "implementation()(address)",
      "owner()(address)",
    ].sort(),
  );
});

test("rejects a stale ValidatorBeacon factoryProxy when all live calls are valid", async () => {
  const manifest = completeManifest();
  const beacon = manifest.contracts.ValidatorBeacon!;
  assert.equal(beacon.kind, "beacon");
  manifest.contracts.ValidatorBeacon = { ...beacon, factoryProxy: address2 };

  const run: CommandRunner = async (_command, args) => {
    if (args.includes("eth_getCode")) {
      return JSON.stringify(runtimeCode);
    }
    if (args[0] === "keccak") {
      return codeHash;
    }
    if (args.includes("eth_getStorageAt")) {
      const proxy = args.at(-3)!;
      const contract = Object.values(manifest.contracts).find((entry) => entry.kind === "uups" && entry.proxy === proxy);
      assert.ok(contract?.kind === "uups");
      return JSON.stringify(paddedAddress(contract.implementation));
    }
    if (args[0] === "call") {
      const target = args[1]!;
      const signature = args[2]!;
      if (signature.endsWith("_ROLE()(bytes32)") || signature === "TERMINATION_ORACLE()(bytes32)") {
        return hashA;
      }
      if (signature === "hasRole(bytes32,address)(bool)") {
        return "true\n";
      }
      return paddedAddress(explicitAddressResult(manifest, target, signature));
    }
    throw new Error(`unexpected cast arguments: ${args.join(" ")}`);
  };

  await assert.rejects(
    verifyLiveDeployment(run, "rpc", manifest),
    /ValidatorBeacon factoryProxy does not match ValidatorFactory proxy/,
  );
});

function explicitAddressResult(manifest: DeploymentManifest, target: string, signature: string): string {
  const contracts = manifest.contracts;
  if (signature === "implementation()(address)" || signature === "owner()(address)") {
    assert.equal(target, getBeaconAddress(contracts.ValidatorBeacon!));
    return signature === "owner()(address)" ? manifest.deployer : getImplementation(contracts.Validator!);
  }
  if (signature === "getBeacon()(address)") {
    assert.equal(target, getProxy(contracts.ValidatorFactory!));
    return getBeaconAddress(contracts.ValidatorBeacon!);
  }
  if (signature === "getValidatorFactoryContract()(address)" || signature === "getSPRegistryContract()(address)") {
    assert.equal(target, getProxy(contracts.PoRepMarket!));
    return signature === "getValidatorFactoryContract()(address)"
      ? getProxy(contracts.ValidatorFactory!)
      : getProxy(contracts.SPRegistry!);
  }
  if (signature === "getPoRepMarketAddress()(address)") {
    assert.equal(target, getProxy(contracts.DataCapEvidenceAdapter!));
    return getProxy(contracts.PoRepMarket!);
  }
  if (signature === "POREPMARKET_CONTRACT()(address)" || signature === "DATA_CAP_EVIDENCE_ADAPTER()(address)") {
    assert.equal(target, getImplementation(contracts.PoRepMarketClaimInspector!));
    return signature === "POREPMARKET_CONTRACT()(address)"
      ? getProxy(contracts.PoRepMarket!)
      : getProxy(contracts.DataCapEvidenceAdapter!);
  }
  throw new Error(`unexpected address call ${target} ${signature}`);
}

function getProxy(contract: ManifestContract): string {
  assert.equal(contract.kind, "uups");
  return (contract as Extract<ManifestContract, { kind: "uups" }>).proxy;
}

function getImplementation(contract: ManifestContract): string {
  assert.notEqual(contract.kind, "beacon");
  return (contract as Exclude<ManifestContract, { kind: "beacon" }>).implementation;
}

function getBeaconAddress(contract: ManifestContract): string {
  assert.equal(contract.kind, "beacon");
  return (contract as Extract<ManifestContract, { kind: "beacon" }>).address;
}

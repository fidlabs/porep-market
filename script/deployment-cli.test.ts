import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, fstatSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import {
  applyPaymentTokenPolicy,
  installSignalHandling,
  mergeMissingHelpers,
  mergeTransactions,
  networkConfigs,
  runProcess,
  writeAtomicFile,
} from "./deployment.ts";
import { hashRawBytes, parseDeploymentManifest } from "./deployment-state.ts";
import { confirmBlockscoutSource, verifyContractSources } from "./deployment-sources.ts";

const script = fileURLToPath(new URL("./deployment.ts", import.meta.url));

function temporaryDirectory(): string {
  return mkdtempSync(join(tmpdir(), "porep-deployment-cli-"));
}

function executable(directory: string, name: string, body: string): string {
  const path = join(directory, name);
  writeFileSync(path, `#!${process.execPath}\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
}

function environment(directory: string): NodeJS.ProcessEnv {
  return {
    DEPLOYMENTS_ROOT: join(directory, "deployments"),
    PENDING_ROOT_TS: join(directory, "pending-ts"),
    PENDING_ROOT: join(directory, "pending-bash"),
    RPC_DEVNET: "http://devnet.example",
    PRIVATE_KEY_DEVNET: "devnet-key",
    FILECOIN_PAY_DEVNET: `0x${"1".repeat(40)}`,
    TERMINATION_ORACLE_DEVNET: `0x${"2".repeat(40)}`,
    ORACLE_DEVNET: `0x${"3".repeat(40)}`,
    POREP_SERVICE_DEVNET: `0x${"4".repeat(40)}`,
    META_ALLOCATOR_DEVNET: `0x${"5".repeat(40)}`,
    OPERATOR_ADDR_DEVNET: `0x${"6".repeat(40)}`,
  };
}

function run(args: readonly string[], env: NodeJS.ProcessEnv = {}) {
  return spawnSync(process.execPath, [script, ...args], { encoding: "utf8", env: { ...process.env, ...env } });
}

test("rejects invalid command lines", () => {
  assert.match(run([]).stderr, /Usage: deployment.ts/);
  assert.match(run(["remove", "devnet"]).stderr, /unsupported command/);
  assert.match(run(["deploy", "localnet"]).stderr, /unsupported network/);
  assert.match(run(["deploy", "devnet", "bad"]).stderr, /unsupported deploy arguments/);
  assert.match(run(["deploy-missing", "devnet", "bad"]).stderr, /does not accept arguments/);
  assert.match(run(["configure-payment-tokens", "devnet", "bad"]).stderr, /does not accept arguments/);
  assert.match(run(["deploy-calibnet-adapter", "calibnet", "bad"]).stderr, /does not accept arguments/);
  assert.match(run(["deploy-calibnet-adapter", "devnet"]).stderr, /only be deployed on calibnet/);
  assert.match(run(["deploy-calibnet-adapter", "mainnet"]).stderr, /only be deployed on calibnet/);
  assert.match(run(["upgrade", "devnet"]).stderr, /requires at least one target/);
  assert.match(run(["check-live", "devnet", "bad"]).stderr, /does not accept arguments/);
});

test("maps the three Filecoin networks explicitly", () => {
  assert.equal(networkConfigs.devnet.chainId, 31415926);
  assert.equal(networkConfigs.calibnet.chainId, 314159);
  assert.equal(networkConfigs.mainnet.chainId, 314);
  assert.equal(networkConfigs.mainnet.rpcVariable, "RPC_MAINNET");
  assert.deepEqual(networkConfigs.calibnet.paymentTokens, [
    { name: "USDFC", address: "0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0" },
  ]);
  assert.deepEqual(networkConfigs.mainnet.paymentTokens, [
    { name: "USDFC", address: "0x80B98d3aa09ffff255c3ba4A241111Ff1262F045" },
    { name: "AxlUSDC", address: "0xEB466342C4d449BC9f53A865D5Cb90586f405215" },
  ]);
});

test("allows the Calibnet adapter switch within the deployed build while rejecting unchanged standard upgrades", () => {
  const directory = temporaryDirectory();
  try {
    const build = Buffer.from("{}");
    const source = parseDeploymentManifest(readFileSync("deployments/calibnet/latest.json", "utf8"));
    source.contracts.DataCapEvidenceAdapter.artifact = "src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter";
    source.release.buildInfoSha256 = hashRawBytes(build);
    const deploymentDirectory = join(directory, "deployments", "calibnet");
    mkdirSync(join(deploymentDirectory, "build-info"), { recursive: true });
    writeFileSync(join(deploymentDirectory, "latest.json"), JSON.stringify(source));
    writeFileSync(
      join(deploymentDirectory, "build-info", `${source.release.buildInfoSha256.slice(2)}.json.gz`),
      gzipSync(build),
    );
    const marker = join(directory, "storage-checked");
    const env: NodeJS.ProcessEnv = {
      ...environment(directory),
      RPC_CALIBNET: "http://calibnet.example",
      PRIVATE_KEY_CALIBNET: "calibnet-key",
      CAST_BIN: executable(directory, "cast", "process.stdout.write('314159')"),
      GIT_BIN: executable(directory, "git", ""),
      FORGE_BIN: executable(directory, "forge", `
        const fs = require('node:fs');
        const path = require('node:path');
        const args = process.argv.slice(2);
        if (args[0] !== 'build') throw new Error('unexpected broadcast');
        const output = args[args.indexOf('--out') + 1];
        fs.mkdirSync(path.join(output, 'build-info'), { recursive: true });
        fs.writeFileSync(path.join(output, 'build-info', 'build.json'), '{}');
      `),
      STORAGE_VALIDATOR: executable(directory, "storage-validator", `
        require('node:fs').writeFileSync(${JSON.stringify(marker)}, '');
        process.exitCode = 77;
      `),
    };

    const standard = run(["upgrade", "calibnet", "DataCapEvidenceAdapter"], env);
    assert.match(standard.stderr, /current build matches the deployed release/);
    assert.equal(existsSync(marker), false);

    const relaxed = run(["deploy-calibnet-adapter", "calibnet"], env);
    assert.equal(existsSync(marker), true);
    assert.match(relaxed.stderr, /storage-validator exited with code 77/);
    assert.equal(existsSync(join(env.PENDING_ROOT_TS!, "calibnet", "pending-upgrade.json")), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("adds the configured payment tokens without replacing deployment state", () => {
  const source = parseDeploymentManifest(readFileSync("deployments/mainnet/latest.json", "utf8"));
  const result = applyPaymentTokenPolicy(source, networkConfigs.mainnet.paymentTokens, []);

  assert.deepEqual(result.contracts, source.contracts);
  assert.deepEqual(result.transactions, source.transactions);
  assert.equal(result.externalDependencies.USDFC, networkConfigs.mainnet.paymentTokens[0].address);
  assert.equal(result.externalDependencies.AxlUSDC, networkConfigs.mainnet.paymentTokens[1].address);
});

test("adds the two missing release helpers without replacing existing contracts", () => {
  const source = parseDeploymentManifest(readFileSync("deployments/calibnet/latest.json", "utf8"));
  delete source.contracts.PoRepMarketSectorStatusInspector;
  delete source.contracts.PoRepMarketViewHelper;
  const deployed = structuredClone(source);
  deployed.contracts.PoRepMarketSectorStatusInspector = {
    kind: "standalone",
    artifact: "src/helpers/PoRepMarketSectorStatusInspector.sol:PoRepMarketSectorStatusInspector",
    implementation: `0x${"a".repeat(40)}`,
    implementationCodeHash: `0x${"b".repeat(64)}`,
  };
  deployed.contracts.PoRepMarketViewHelper = {
    kind: "standalone",
    artifact: "src/helpers/PoRepMarketViewHelper.sol:PoRepMarketViewHelper",
    implementation: `0x${"c".repeat(40)}`,
    implementationCodeHash: `0x${"d".repeat(64)}`,
  };

  const result = mergeMissingHelpers(source, deployed, `0x${"e".repeat(64)}`);

  assert.equal(source.contracts.PoRepMarketViewHelper, undefined);
  assert.deepEqual(result.contracts.PoRepMarketViewHelper, deployed.contracts.PoRepMarketViewHelper);
  assert.deepEqual(result.contracts.PoRepMarketSectorStatusInspector, deployed.contracts.PoRepMarketSectorStatusInspector);
  assert.deepEqual(result.transactions, source.transactions);
  assert.throws(() => mergeMissingHelpers(result, deployed, result.release.buildInfoSha256), /already exists/);
});

test("appends new receipts to the receipts already recorded for the deployment", () => {
  const prior = [
    { hash: `0x${"1".repeat(64)}`, status: 1, blockNumber: 1, blockHash: `0x${"2".repeat(64)}`, contractAddress: `0x${"3".repeat(40)}` },
    { hash: `0x${"4".repeat(64)}`, status: 1, blockNumber: 2, blockHash: `0x${"5".repeat(64)}`, contractAddress: `0x${"6".repeat(40)}` },
  ];
  const receipts = [
    { hash: `0x${"7".repeat(64)}`, status: 1, blockNumber: 3, blockHash: `0x${"8".repeat(64)}`, contractAddress: `0x${"9".repeat(40)}` },
  ];

  assert.deepEqual(mergeTransactions(prior, receipts), [...prior, ...receipts]);
  assert.deepEqual(mergeTransactions(undefined, receipts), receipts);
  assert.deepEqual(mergeTransactions([...prior, ...receipts], receipts), [...prior, ...receipts]);
});

test("runs subprocesses without shell interpolation and reports failures", async () => {
  const directory = temporaryDirectory();
  try {
    const command = executable(directory, "command", "process.stdout.write(JSON.stringify(process.argv.slice(2)))");
    assert.deepEqual(JSON.parse(await runProcess(command, ["a b", "$HOME"])), ["a b", "$HOME"]);
    const failure = executable(directory, "failure", "process.stderr.write('failed'); process.exitCode = 2");
    await assert.rejects(runProcess(failure, []), /exited with code 2: failed/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("gives interactive subprocesses the operator terminal", async () => {
  const directory = temporaryDirectory();
  try {
    const marker = join(directory, "stdout-inode");
    const command = executable(
      directory,
      "interactive",
      `require('node:fs').writeFileSync(${JSON.stringify(marker)}, String(require('node:fs').fstatSync(1).ino))`,
    );

    await runProcess(command, [], { terminal: true });

    assert.equal(readFileSync(marker, "utf8"), String(fstatSync(1).ino));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("writes files atomically", () => {
  const directory = temporaryDirectory();
  try {
    const path = join(directory, "nested", "pending.json");
    writeAtomicFile(path, "{}\n");
    assert.equal(readFileSync(path, "utf8"), "{}\n");
    assert.deepEqual(readdirSync(dirname(path)), ["pending.json"]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("checks chain ID and mainnet confirmation before operating", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('314')");
    let result = run(["deploy", "devnet"], { ...environment(directory), CAST_BIN: cast });
    assert.match(result.stderr, /devnet RPC chain ID must be 31415926, got 314/);

    result = run(["finalize-deploy", "mainnet"], {
      CAST_BIN: cast,
      RPC_MAINNET: "http://mainnet.example",
      CONFIRM_MAINNET: "",
      DEPLOYMENTS_ROOT: join(directory, "deployments"),
    });
    assert.match(result.stderr, /set CONFIRM_MAINNET=yes/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("requires explicit confirmation before replacing the mainnet manifest", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('314')");
    const git = executable(directory, "git", "");
    const marker = join(directory, "forge-ran");
    const forge = executable(directory, "forge", `
      const fs = require('node:fs');
      const path = require('node:path');
      const args = process.argv.slice(2);
      if (args[0] === 'build') {
        const output = args[args.indexOf('--out') + 1];
        fs.mkdirSync(path.join(output, 'build-info'), { recursive: true });
        fs.writeFileSync(path.join(output, 'build-info', 'build.json'), '{}');
      } else {
        fs.writeFileSync(${JSON.stringify(marker)}, '');
        process.exitCode = 99;
      }
    `);
    const deploymentsRoot = join(directory, "deployments");
    const deploymentDirectory = join(deploymentsRoot, "mainnet");
    mkdirSync(deploymentDirectory, { recursive: true });
    writeFileSync(join(deploymentDirectory, "latest.json"), "{}\n");
    const env: NodeJS.ProcessEnv = {
      CAST_BIN: cast,
      GIT_BIN: git,
      FORGE_BIN: forge,
      RPC_MAINNET: "http://mainnet.example",
      PRIVATE_KEY_MAINNET: "mainnet-key",
      FILECOIN_PAY_MAINNET: `0x${"1".repeat(40)}`,
      TERMINATION_ORACLE_MAINNET: `0x${"2".repeat(40)}`,
      ORACLE_MAINNET: `0x${"3".repeat(40)}`,
      POREP_SERVICE_MAINNET: `0x${"4".repeat(40)}`,
      META_ALLOCATOR_MAINNET: `0x${"5".repeat(40)}`,
      OPERATOR_ADDR_MAINNET: `0x${"6".repeat(40)}`,
      CONFIRM_MAINNET: "yes",
      DEPLOYMENTS_ROOT: deploymentsRoot,
      PENDING_ROOT_TS: join(directory, "pending-ts"),
      PENDING_ROOT: join(directory, "pending-bash"),
    };

    let result = run(["deploy", "mainnet", "--fresh"], env);
    assert.match(result.stderr, /pass --confirm-replace-mainnet-manifest/);
    assert.equal(existsSync(marker), false);

    result = run(["deploy", "mainnet", "--fresh", "--confirm-replace-mainnet-manifest"], env);
    assert.doesNotMatch(result.stderr, /pass --confirm-replace-mainnet-manifest/);
    assert.equal(existsSync(marker), true);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("checks live mainnet state without write confirmation or a clean manifest", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('314')");
    const git = executable(directory, "git", "process.stdout.write(' M deployments/mainnet/latest.json')");
    const deploymentDirectory = join(directory, "deployments", "mainnet");
    mkdirSync(deploymentDirectory, { recursive: true });
    writeFileSync(join(deploymentDirectory, "latest.json"), "{");

    const result = run(["check-live", "mainnet"], {
      CAST_BIN: cast,
      GIT_BIN: git,
      RPC_MAINNET: "http://mainnet.example",
      CONFIRM_MAINNET: "",
      DEPLOYMENTS_ROOT: join(directory, "deployments"),
    });

    assert.match(result.stderr, /manifest JSON is invalid/);
    assert.doesNotMatch(result.stderr, /CONFIRM_MAINNET|not clean/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("rejects standard upgrades from manager-less legacy manifests before Forge runs", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('31415926')");
    const git = executable(directory, "git", "");
    const marker = join(directory, "forge-ran");
    const forge = executable(directory, "forge", `require('node:fs').writeFileSync(${JSON.stringify(marker)}, '')`);
    const deploymentDirectory = join(directory, "deployments", "devnet");
    mkdirSync(deploymentDirectory, { recursive: true });
    const source = parseDeploymentManifest(readFileSync("deployments/mainnet/latest.json", "utf8"));
    delete source.contracts.AccessManager;
    writeFileSync(join(deploymentDirectory, "latest.json"), JSON.stringify(source));

    const result = run(["upgrade", "devnet", "PoRepMarket"], {
      ...environment(directory),
      CAST_BIN: cast,
      GIT_BIN: git,
      FORGE_BIN: forge,
    });

    assert.match(result.stderr, /V2 upgrades require a fresh AccessManager deployment/);
    assert.equal(existsSync(marker), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("submits every deployed Calibnet address that Blockscout does not already hold", async () => {
  const manifest = parseDeploymentManifest(readFileSync("deployments/calibnet/latest.json", "utf8"));
  const calls: string[][] = [];
  const confirmed: string[] = [];
  const submitted = new Set<string>();
  await verifyContractSources(manifest, {
    chainId: 314159,
    root: process.cwd(),
    rpcUrl: "http://calibnet.example",
    verifierUrl: "https://filecoin-testnet.blockscout.com/api/",
    runForge: async (args) => { calls.push([...args]); submitted.add(args[1]!); },
    confirmVerified: async (target) => {
      if (!submitted.has(target.address)) throw new Error("not verified yet");
      confirmed.push(target.address);
    },
    progress: () => {},
  });

  assert.equal(calls.length, 18);
  assert.equal(confirmed.length, 18);
  assert.equal(calls.filter((args) => args.includes("--guess-constructor-args")).length, 10);
  assert.equal(calls.filter((args) => args.includes("--constructor-args")).length, 0);
  assert.equal(calls.filter((args) => args.includes("--skip-is-verified-check")).length, 17);
  assert.equal(calls.filter((args) => args.includes("blockscout")).length, 17);
  assert.equal(calls.filter((args) => args.includes("sourcify")).length, 1);
  assert.ok(calls.every((args) => args.includes("--verifier") && args.includes("--watch")));
});

test("skips Forge for earlier-release contracts Blockscout already holds", async () => {
  const manifest = parseDeploymentManifest(readFileSync("deployments/calibnet/latest.json", "utf8"));
  manifest.transactions = [];
  const calls: string[][] = [];
  await verifyContractSources(manifest, {
    chainId: 314159,
    root: process.cwd(),
    rpcUrl: "http://calibnet.example",
    verifierUrl: "https://filecoin-testnet.blockscout.com/api/",
    runForge: async (args) => { calls.push([...args]); },
    confirmVerified: async () => {},
    progress: () => {},
  });

  assert.equal(calls.length, 0);
});

test("always submits addresses the current operation deployed", async () => {
  const manifest = parseDeploymentManifest(readFileSync("deployments/calibnet/latest.json", "utf8"));
  const deployed = (manifest.transactions ?? [])
    .map((transaction) => transaction.contractAddress)
    .filter((address) => address !== null);
  assert.ok(deployed.length > 0);
  const calls: string[][] = [];

  await verifyContractSources(manifest, {
    chainId: 314159,
    root: process.cwd(),
    rpcUrl: "http://calibnet.example",
    verifierUrl: "https://filecoin-testnet.blockscout.com/api/",
    runForge: async (args) => { calls.push([...args]); },
    confirmVerified: async () => {},
    progress: () => {},
  });

  const submitted = calls.map((args) => args[1]!.toLowerCase());
  for (const address of deployed) assert.ok(submitted.includes(address.toLowerCase()));
});

test("verifies every remaining contract after one fails and reports them together", async () => {
  const manifest = parseDeploymentManifest(readFileSync("deployments/calibnet/latest.json", "utf8"));
  const failing = manifest.contracts.PoRepMarketClaimInspector;
  assert.equal(failing.kind, "standalone");
  const attempted: string[] = [];
  const submitted = new Set<string>();

  await assert.rejects(
    verifyContractSources(manifest, {
      chainId: 314159,
      root: process.cwd(),
      rpcUrl: "http://calibnet.example",
      verifierUrl: "https://filecoin-testnet.blockscout.com/api/",
      runForge: async (args) => {
        const address = args[1]!;
        attempted.push(address);
        if (address === failing.implementation) throw new Error("Local bytecode doesn't match on-chain bytecode");
        submitted.add(address);
      },
      confirmVerified: async (target) => {
        if (!submitted.has(target.address)) throw new Error("not verified yet");
      },
      progress: () => {},
    }),
    (error: Error) => {
      assert.match(error.message, /1 of 18 contracts failed source verification/);
      assert.match(error.message, /PoRepMarketClaimInspector/);
      assert.match(error.message, /Local bytecode doesn't match on-chain bytecode/);
      return true;
    },
  );

  assert.equal(attempted.length, 18);
});

test("rejects a Blockscout record that is not fully verified", async () => {
  const target = {
    label: "ValidatorBeacon",
    address: `0x${"1".repeat(40)}`,
    artifact: "lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon",
    verifier: "blockscout" as const,
    guessConstructorArguments: false,
  };

  // A name alone does not mean verified: Blockscout derives it from bytecode similarity.
  const partial = new Response(JSON.stringify({ name: "UpgradeableBeacon", is_fully_verified: false }));
  await assert.rejects(
    confirmBlockscoutSource("https://blockscout.example/api/", target, async () => partial),
    /did not fully verify .* is_fully_verified=false/,
  );

  const missing = new Response("", { status: 404 });
  await assert.rejects(
    confirmBlockscoutSource("https://blockscout.example/api/", target, async () => missing),
    /holds no verified source/,
  );

  const verified = new Response(JSON.stringify({ name: "UpgradeableBeacon", is_fully_verified: true }));
  await confirmBlockscoutSource("https://blockscout.example/api/", target, async (input) => {
    assert.match(String(input), /\/api\/v2\/smart-contracts\/0x1{40}$/);
    return verified;
  });
});

test("refuses an unfinished TypeScript or Bash operation", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('31415926')");
    const git = executable(directory, "git", "");
    const forge = executable(directory, "forge", "process.exitCode = 99");
    const env: NodeJS.ProcessEnv = { ...environment(directory), CAST_BIN: cast, GIT_BIN: git, FORGE_BIN: forge };

    for (const pendingRoot of [env.PENDING_ROOT_TS!, env.PENDING_ROOT!]) {
      const pending = join(pendingRoot, "devnet", "pending-upgrade.json");
      mkdirSync(dirname(pending), { recursive: true });
      writeFileSync(pending, '{"status":"pending"}\n');
      const result = run(["deploy", "devnet"], env);
      assert.match(result.stderr, /pending operation already exists/);
      rmSync(pending);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("fresh deployment preserves unfinished recovery evidence", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('31415926')");
    const git = executable(directory, "git", "");
    const forge = executable(directory, "forge", "process.exitCode = 99");
    const env: NodeJS.ProcessEnv = { ...environment(directory), CAST_BIN: cast, GIT_BIN: git, FORGE_BIN: forge };
    const deploymentDirectory = join(env.DEPLOYMENTS_ROOT!, "devnet");
    const pendingDirectory = join(env.PENDING_ROOT_TS!, "devnet");
    mkdirSync(deploymentDirectory, { recursive: true });
    mkdirSync(pendingDirectory, { recursive: true });
    writeFileSync(join(deploymentDirectory, "latest.json"), "{}\n");
    writeFileSync(join(pendingDirectory, "pending-deploy.json"), '{"status":"pending"}\n');
    writeFileSync(join(pendingDirectory, "pending-deploy.build-info.json.gz"), "build evidence");
    writeFileSync(join(pendingDirectory, "pending-deploy.broadcast.json"), "broadcast evidence");

    const result = run(["deploy", "devnet", "--fresh"], env);

    assert.match(result.stderr, /pending operation already exists/);
    assert.equal(readFileSync(join(pendingDirectory, "pending-deploy.json"), "utf8"), '{"status":"pending"}\n');
    assert.equal(readFileSync(join(pendingDirectory, "pending-deploy.build-info.json.gz"), "utf8"), "build evidence");
    assert.equal(readFileSync(join(pendingDirectory, "pending-deploy.broadcast.json"), "utf8"), "broadcast evidence");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("retains the pending journal and build-info before Forge broadcasts", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('31415926')");
    const git = executable(directory, "git", "");
    const marker = join(directory, "broadcast-preconditions");
    const pendingDirectory = join(directory, "pending-ts", "devnet");
    const forge = executable(directory, "forge", `
      const fs = require('node:fs');
      const path = require('node:path');
      const args = process.argv.slice(2);
      if (args[0] === 'build') {
        const output = args[args.indexOf('--out') + 1];
        fs.mkdirSync(path.join(output, 'build-info'), { recursive: true });
        fs.writeFileSync(path.join(output, 'build-info', 'build.json'), '{}');
      } else {
        const pending = path.join(${JSON.stringify(pendingDirectory)}, 'pending-deploy.json');
        const build = path.join(${JSON.stringify(pendingDirectory)}, 'pending-deploy.build-info.json.gz');
        fs.writeFileSync(${JSON.stringify(marker)}, String(fs.existsSync(pending) && fs.existsSync(build)));
        process.exitCode = 99;
      }
    `);

    const result = run(["deploy", "devnet"], {
      ...environment(directory),
      CAST_BIN: cast,
      GIT_BIN: git,
      FORGE_BIN: forge,
    });

    assert.equal(result.status, 1);
    assert.equal(readFileSync(marker, "utf8"), "true");
    assert.match(result.stderr, /Build contracts[\s\S]*Broadcast deployment/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("checks clean source before invoking Forge", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('31415926')");
    const git = executable(directory, "git", "process.stdout.write(' M src/PoRepMarket.sol')");
    const marker = join(directory, "forge-ran");
    const forge = executable(directory, "forge", `require('node:fs').writeFileSync(${JSON.stringify(marker)}, '')`);
    const result = run(["deploy", "devnet"], {
      ...environment(directory),
      CAST_BIN: cast,
      GIT_BIN: git,
      FORGE_BIN: forge,
    });
    assert.match(result.stderr, /deployment source is dirty/);
    assert.equal(readdirSync(directory).includes("forge-ran"), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("SIGINT and SIGTERM share one abort signal and clean up listeners", () => {
  const before = [process.listenerCount("SIGINT"), process.listenerCount("SIGTERM")];
  const handling = installSignalHandling();
  process.emit("SIGINT");
  assert.equal(handling.signal.aborted, true);
  handling.dispose();
  assert.deepEqual([process.listenerCount("SIGINT"), process.listenerCount("SIGTERM")], before);
});

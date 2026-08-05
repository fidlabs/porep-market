import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { installSignalHandling, networkConfigs, runProcess, writeAtomicFile } from "./deployment.ts";

const scriptPath = fileURLToPath(new URL("./deployment.ts", import.meta.url));
const repositoryRoot = dirname(dirname(scriptPath));

function runDeploymentCommand(args: readonly string[], environment: NodeJS.ProcessEnv = {}, cwd?: string) {
  return spawnSync(process.execPath, [scriptPath, ...args], {
    cwd,
    encoding: "utf8",
    env: { ...process.env, ...environment },
  });
}

function runDeploymentCommandAsync(args: readonly string[], environment: NodeJS.ProcessEnv = {}) {
  return new Promise<{ code: number | null; signal: NodeJS.Signals | null; stderr: string }>((resolve, reject) => {
    const child = spawn(process.execPath, [scriptPath, ...args], {
      env: { ...process.env, ...environment },
      stdio: ["ignore", "ignore", "pipe"],
    });
    const stderr: Buffer[] = [];
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.once("error", reject);
    child.once("close", (code, signal) => {
      resolve({ code, signal, stderr: Buffer.concat(stderr).toString("utf8") });
    });
  });
}

function createTemporaryDirectory(): string {
  return mkdtempSync(join(tmpdir(), "porep-deployment-cli-"));
}

function createFakeExecutable(directory: string, name: string, output = ""): string {
  const path = join(directory, name);
  writeFileSync(
    path,
    `#!${process.execPath}\n` +
      "import { appendFileSync } from 'node:fs';\n" +
      "if (process.env.FAKE_COMMAND_LOG) appendFileSync(process.env.FAKE_COMMAND_LOG, JSON.stringify(process.argv.slice(2)) + '\\n');\n" +
      "const dirtyPath = process.env.FAKE_DIRTY_PATH;\n" +
      "if (dirtyPath && process.argv.includes(dirtyPath)) process.stdout.write(' M latest.json\\n');\n" +
      `else process.stdout.write(${JSON.stringify(output)});\n`,
  );
  chmodSync(path, 0o755);
  return path;
}

function deploymentEnvironment(directory: string): NodeJS.ProcessEnv {
  return {
    PATH: `${directory}${delimiter}${process.env.PATH ?? ""}`,
    DEPLOYMENTS_ROOT: join(directory, "deployments"),
    PENDING_ROOT_TS: join(directory, "pending-ts"),
    PENDING_ROOT: join(directory, "pending-bash"),
    RPC_DEVNET: "http://devnet.example",
    PRIVATE_KEY_DEVNET: "devnet-key",
    FILECOIN_PAY_DEVNET: "0x0000000000000000000000000000000000000001",
    TERMINATION_ORACLE_DEVNET: "0x0000000000000000000000000000000000000002",
    ORACLE_DEVNET: "0x0000000000000000000000000000000000000003",
    POREP_SERVICE_DEVNET: "0x0000000000000000000000000000000000000004",
    META_ALLOCATOR_DEVNET: "0x0000000000000000000000000000000000000005",
    OPERATOR_ADDR_DEVNET: "0x0000000000000000000000000000000000000006",
  };
}

const testAddress = `0x${"1".repeat(40)}`;
const testTransactionHash = `0x${"a".repeat(64)}`;
const testBlockHash = `0x${"b".repeat(64)}`;
const testCodeHash = `0x${"c".repeat(64)}`;

function deployTestEnvironment(directory: string): NodeJS.ProcessEnv {
  const environment = deploymentEnvironment(directory);
  const forgeLog = join(directory, "forge.jsonl");
  const castLog = join(directory, "cast.jsonl");
  const pendingRoot = join(directory, "pending-ts");
  const bashPendingRoot = join(directory, "pending-bash");

  createDeployFakeCast(directory);
  createDeployFakeForge(directory);
  createFakeExecutable(directory, "git");
  writeFileSync(forgeLog, "");
  writeFileSync(castLog, "");

  return {
    ...environment,
    CAST_BIN: join(directory, "cast"),
    FORGE_BIN: join(directory, "forge"),
    GIT_BIN: join(directory, "git"),
    PENDING_ROOT_TS: pendingRoot,
    PENDING_ROOT: bashPendingRoot,
    FAKE_CAST_LOG: castLog,
    FAKE_FORGE_LOG: forgeLog,
    TEST_ADDRESS: testAddress,
    TEST_TRANSACTION_HASH: testTransactionHash,
    TEST_BLOCK_HASH: testBlockHash,
    TEST_CODE_HASH: testCodeHash,
    FILECOIN_PAY_DEVNET: testAddress,
    TERMINATION_ORACLE_DEVNET: testAddress,
    ORACLE_DEVNET: testAddress,
    POREP_SERVICE_DEVNET: testAddress,
    META_ALLOCATOR_DEVNET: testAddress,
    OPERATOR_ADDR_DEVNET: testAddress,
  };
}

function createDeployFakeCast(directory: string): void {
  const path = join(directory, "cast");
  writeFileSync(
    path,
    `#!${process.execPath}\n` +
      "import { appendFileSync } from 'node:fs';\n" +
      "const args = process.argv.slice(2);\n" +
      "if (process.env.FAKE_CAST_LOG) appendFileSync(process.env.FAKE_CAST_LOG, JSON.stringify(args) + '\\n');\n" +
      "const address = process.env.TEST_ADDRESS;\n" +
      "const txHash = process.env.TEST_TRANSACTION_HASH;\n" +
      "const blockHash = process.env.TEST_BLOCK_HASH;\n" +
      "const codeHash = process.env.TEST_CODE_HASH;\n" +
      "if (args[0] === 'chain-id') process.stdout.write((process.env.FAKE_CHAIN_ID ?? '31415926') + '\\n');\n" +
      "else if (args[0] === 'keccak') process.stdout.write(codeHash + '\\n');\n" +
      "else if (args[0] === 'call' && args[2] === 'hasRole(bytes32,address)(bool)') process.stdout.write('true\\n');\n" +
      "else if (args[0] === 'call' && (args[2].includes('ROLE') || args[2] === 'TERMINATION_ORACLE()(bytes32)')) process.stdout.write(codeHash + '\\n');\n" +
      "else if (args[0] === 'call') process.stdout.write(address + '\\n');\n" +
      "else if (args[0] === 'rpc' && args[3] === 'eth_getTransactionReceipt') process.stdout.write(JSON.stringify({transactionHash:txHash,status:'0x1',blockNumber:'0xa',blockHash,contractAddress:null}));\n" +
      "else if (args[0] === 'rpc' && args[3] === 'Filecoin.ChainGetFinalizedTipSet') {\n" +
      "  if (process.env.FAKE_INTERRUPT_FINALITY === 'yes') { process.stderr.write('finality wait interrupted'); process.exit(2); }\n" +
      "  process.stdout.write(JSON.stringify({Height:10}));\n" +
      "}\n" +
      "else if (args[0] === 'rpc' && args[3] === 'eth_getBlockByNumber') process.stdout.write(JSON.stringify({number:'0xa',hash:blockHash}));\n" +
      "else if (args[0] === 'rpc' && args[3] === 'eth_getCode') process.stdout.write(JSON.stringify('0x01'));\n" +
      "else if (args[0] === 'rpc' && args[3] === 'eth_getStorageAt') process.stdout.write(JSON.stringify('0x' + '0'.repeat(24) + address.slice(2)));\n" +
      "else { process.stderr.write('unexpected cast arguments: ' + JSON.stringify(args)); process.exitCode = 2; }\n",
  );
  chmodSync(path, 0o755);
}

function createDeployFakeForge(directory: string): void {
  const path = join(directory, "forge");
  const manifestResult = {
    status: "pending",
    deployer: testAddress,
    release: { buildInfoSha256: "replaced-by-fake" },
    contracts: {
      PoRepMarket: uupsContract("src/PoRepMarket.sol:PoRepMarket"),
      ValidatorFactory: uupsContract("src/ValidatorFactory.sol:ValidatorFactory"),
      DataCapEvidenceAdapter: uupsContract("src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter"),
      SPRegistry: uupsContract("src/SPRegistry.sol:SPRegistry"),
      SLIOracle: uupsContract("src/SLIOracle.sol:SLIOracle"),
      SLIScorer: uupsContract("src/SLIScorer.sol:SLIScorer"),
      Validator: {
        kind: "implementation",
        artifact: "src/Validator.sol:Validator",
        implementation: testAddress,
        implementationCodeHash: testCodeHash,
      },
      ValidatorBeacon: {
        kind: "beacon",
        artifact: "lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon",
        address: testAddress,
        implementation: testAddress,
        factoryProxy: testAddress,
      },
      PoRepMarketClaimInspector: {
        kind: "standalone",
        artifact: "src/helpers/PoRepMarketClaimInspector.sol:PoRepMarketClaimInspector",
        implementation: testAddress,
        implementationCodeHash: testCodeHash,
      },
    },
    externalDependencies: {
      FilecoinPay: testAddress,
      TerminationOracle: testAddress,
      Oracle: testAddress,
      PoRepService: testAddress,
      MetaAllocator: testAddress,
      Operator: testAddress,
    },
  };

  writeFileSync(
    path,
    `#!${process.execPath}\n` +
      "import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';\n" +
      "import { join } from 'node:path';\n" +
      "const args = process.argv.slice(2);\n" +
      "const claim = process.env.PENDING_ROOT_TS && join(process.env.PENDING_ROOT_TS, 'devnet', 'operation.claim');\n" +
      "const record = {args,claimExists:Boolean(claim && existsSync(claim)),environment:{RPC_URL:process.env.RPC_URL,PRIVATE_KEY_SET:Boolean(process.env.PRIVATE_KEY),FILECOIN_PAY:process.env.FILECOIN_PAY,TERMINATION_ORACLE:process.env.TERMINATION_ORACLE,ORACLE:process.env.ORACLE,POREP_SERVICE:process.env.POREP_SERVICE,META_ALLOCATOR:process.env.META_ALLOCATOR,OPERATOR_ADDR:process.env.OPERATOR_ADDR,BUILD_INFO_SHA256:process.env.BUILD_INFO_SHA256,DEPLOYMENT_OUTPUT:process.env.DEPLOYMENT_OUTPUT,FOUNDRY_BROADCAST:process.env.FOUNDRY_BROADCAST}};\n" +
      "appendFileSync(process.env.FAKE_FORGE_LOG, JSON.stringify(record) + '\\n');\n" +
      "if (args[0] === 'build') {\n" +
      "  if (process.env.FAKE_BUILD_DELAY_MS) await new Promise(resolve => setTimeout(resolve, Number(process.env.FAKE_BUILD_DELAY_MS)));\n" +
      "  const out = args[args.indexOf('--out') + 1]; const buildDir = join(out, 'build-info'); mkdirSync(buildDir, {recursive:true});\n" +
      "  writeFileSync(join(buildDir, 'build.json'), '{\\\"build\\\":1}\\n');\n" +
      "  if (process.env.FAKE_EXTRA_BUILD_INFO === 'yes') writeFileSync(join(buildDir, 'extra.json'), '{}\\n');\n" +
      "} else if (args[0] === 'script') {\n" +
      "  if (process.env.FAKE_FAIL_BEFORE_BROADCAST === 'yes') { process.stderr.write('failed before broadcast'); process.exit(2); }\n" +
      "  const runDir = join(process.env.FOUNDRY_BROADCAST, 'Deploy.s.sol', '31415926'); mkdirSync(runDir, {recursive:true});\n" +
      "  const broadcast = JSON.stringify({transactions:[{hash:process.env.TEST_TRANSACTION_HASH}]}) + '\\n';\n" +
      "  writeFileSync(join(runDir, 'run-latest.json'), '{}\\n');\n" +
      "  if (process.env.FAKE_LATEST_ONLY !== 'yes') writeFileSync(join(runDir, 'run-100.json'), broadcast);\n" +
      "  const pending = JSON.parse(readFileSync(process.env.DEPLOYMENT_OUTPUT, 'utf8'));\n" +
      `  const result = ${JSON.stringify(manifestResult)};\n` +
      "  result.release.buildInfoSha256 = process.env.BUILD_INFO_SHA256; pending.result = result;\n" +
      "  if (process.env.FAKE_BAD_DEPENDENCY === 'yes') result.externalDependencies.FilecoinPay = '0x' + '2'.repeat(40);\n" +
      "  writeFileSync(process.env.DEPLOYMENT_OUTPUT, JSON.stringify(pending, null, 2) + '\\n');\n" +
      "  if (process.env.FAKE_FORGE_SIGNAL) { process.kill(process.ppid, process.env.FAKE_FORGE_SIGNAL); await new Promise(resolve => setTimeout(resolve, 10000)); }\n" +
      "  if (process.env.FAKE_FAIL_AFTER_BROADCAST === 'yes') { process.stderr.write('failed after broadcast'); process.exit(2); }\n" +
      "} else { process.stderr.write('unexpected forge arguments'); process.exitCode = 2; }\n",
  );
  chmodSync(path, 0o755);
}

function uupsContract(artifact: string) {
  return {
    kind: "uups",
    artifact,
    proxy: testAddress,
    implementation: testAddress,
    proxyCodeHash: testCodeHash,
    implementationCodeHash: testCodeHash,
  };
}

function readJson(path: string): Record<string, unknown> {
  return JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
}

function readJsonLines(path: string): Record<string, unknown>[] {
  return readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

function createCanonicalManifest(directory: string): string {
  const manifest = join(directory, "deployments", "devnet", "latest.json");
  mkdirSync(dirname(manifest), { recursive: true });
  writeFileSync(manifest, "{}\n");
  return manifest;
}

test("prints usage without a command", () => {
  const result = runDeploymentCommand([]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /^Usage: deployment.ts <command> <network> \[args\.\.\.\]$/m);
});

test("rejects unsupported commands", () => {
  const result = runDeploymentCommand(["remove", "devnet"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported command: remove/);
});

test("rejects unsupported networks", () => {
  const result = runDeploymentCommand(["deploy", "localnet"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported network: localnet/);
});

test("deploy accepts only its optional --fresh argument", () => {
  const result = runDeploymentCommand(["deploy", "devnet", "unexpected"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported deploy arguments: unexpected/);
});

test("upgrade requires at least one target", () => {
  const result = runDeploymentCommand(["upgrade", "devnet"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /upgrade requires at least one target/);
});

for (const command of ["finalize-deploy", "finalize-upgrade", "verify"] as const) {
  test(`${command} rejects extra arguments`, () => {
    const result = runDeploymentCommand([command, "devnet", "unexpected"]);

    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`${command} does not accept arguments`));
  });
}

test("maps Filecoin networks to their chain IDs", () => {
  assert.deepEqual(networkConfigs, {
    devnet: {
      chainId: 31415926,
      rpcVariable: "RPC_DEVNET",
      privateKeyVariable: "PRIVATE_KEY_DEVNET",
      environmentSuffix: "DEVNET",
    },
    calibnet: {
      chainId: 314159,
      rpcVariable: "RPC_CALIBNET",
      privateKeyVariable: "PRIVATE_KEY_CALIBNET",
      environmentSuffix: "CALIBNET",
    },
    mainnet: {
      chainId: 314,
      rpcVariable: "RPC_MAINNET",
      privateKeyVariable: "PRIVATE_KEY_MAINNET",
      environmentSuffix: "MAINNET",
    },
  });
});

test("runs an executable with an exact argument array", async () => {
  const directory = createTemporaryDirectory();
  const commandLog = join(directory, "commands.jsonl");
  const forge = createFakeExecutable(directory, "forge", "forge output");
  const previousLog = process.env.FAKE_COMMAND_LOG;
  process.env.FAKE_COMMAND_LOG = commandLog;

  try {
    const output = await runProcess(forge, ["build", "--root", "/release", "--build-info"]);

    assert.equal(output, "forge output");
    assert.deepEqual(JSON.parse(readFileSync(commandLog, "utf8")), ["build", "--root", "/release", "--build-info"]);
  } finally {
    if (previousLog === undefined) delete process.env.FAKE_COMMAND_LOG;
    else process.env.FAKE_COMMAND_LOG = previousLog;
    rmSync(directory, { force: true, recursive: true });
  }
});

test("reports the executable exit code and stderr", async () => {
  const directory = createTemporaryDirectory();
  const forge = join(directory, "forge");
  writeFileSync(forge, `#!${process.execPath}\nprocess.stderr.write("forge failed"); process.exitCode = 2;\n`);
  chmodSync(forge, 0o755);

  try {
    await assert.rejects(runProcess(forge, ["build"]), /forge exited with code 2: forge failed/);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("deploy preflight checks the RPC chain before tracked release paths", () => {
  const directory = createTemporaryDirectory();
  const commandLog = join(directory, "commands.jsonl");
  createFakeExecutable(directory, "cast", "31415926\n");
  createFakeExecutable(directory, "git");
  const forge = join(directory, "forge");
  writeFileSync(forge, `#!${process.execPath}\nprocess.stderr.write("stop after preflight"); process.exitCode = 2;\n`);
  chmodSync(forge, 0o755);

  try {
    const result = runDeploymentCommand(["deploy", "devnet"], {
      ...deploymentEnvironment(directory),
      FAKE_COMMAND_LOG: commandLog,
    }, directory);

    assert.equal(result.status, 1);
    assert.match(result.stderr, /forge exited with code 2: stop after preflight/);
    assert.deepEqual(
      readFileSync(commandLog, "utf8")
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line)),
      [
        ["chain-id", "--rpc-url", "http://devnet.example"],
        [
          "-C",
          repositoryRoot,
          "status",
          "--porcelain",
          "--untracked-files=all",
          "--",
          "src",
          "script",
          "foundry.toml",
          "foundry.lock",
          "remappings.txt",
          "package.json",
          "package-lock.json",
          "lib",
        ],
      ],
    );
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("deploy rejects dirty release source before building", () => {
  const directory = createTemporaryDirectory();
  const commandLog = join(directory, "commands.jsonl");
  createFakeExecutable(directory, "cast", "31415926\n");
  createFakeExecutable(directory, "git");

  try {
    const result = runDeploymentCommand(["deploy", "devnet"], {
      ...deploymentEnvironment(directory),
      FAKE_COMMAND_LOG: commandLog,
      FAKE_DIRTY_PATH: "src",
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /deployment source is dirty/);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("deploy completes build, broadcast, finality, live checks, and atomic publication in one command", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");
  const broadcast = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.broadcast.json");
  const latest = join(environment.DEPLOYMENTS_ROOT!, "devnet", "latest.json");

  try {
    const obsoleteBuildInfo = join(environment.DEPLOYMENTS_ROOT!, "devnet", "build-info", `${"d".repeat(64)}.json.gz`);
    mkdirSync(dirname(obsoleteBuildInfo), { recursive: true });
    writeFileSync(obsoleteBuildInfo, "obsolete");
    const result = runDeploymentCommand(["deploy", "devnet"], environment);

    assert.equal(result.status, 0, result.stderr);
    assert.equal(readJson(pending).status, "finalized");
    assert.equal(readJson(latest).status, "finalized");
    assert.equal(readFileSync(broadcast, "utf8"), `${JSON.stringify({ transactions: [{ hash: testTransactionHash }] })}\n`);
    assert.match(readFileSync(latest, "utf8"), /\n$/);
    const retainedBuildInfoDirectory = join(environment.DEPLOYMENTS_ROOT!, "devnet", "build-info");
    const retainedBuildInfoFiles = readdirSync(retainedBuildInfoDirectory);
    assert.deepEqual(retainedBuildInfoFiles.length, 1);
    const retainedBuildInfo = readFileSync(join(retainedBuildInfoDirectory, retainedBuildInfoFiles[0]));
    assert.equal(gunzipSync(retainedBuildInfo).toString("utf8"), '{"build":1}\n');
    const expectedBuildHash = `0x${createHash("sha256").update('{"build":1}\n').digest("hex")}`;
    assert.equal((readJson(latest).release as Record<string, unknown>).buildInfoSha256, expectedBuildHash);

    const forgeCalls = readJsonLines(environment.FAKE_FORGE_LOG!);
    assert.equal(forgeCalls.length, 2);
    assert.deepEqual((forgeCalls[0].args as string[]).slice(0, 2), ["build", "--root"]);
    assert.deepEqual((forgeCalls[1].args as string[]).slice(0, 2), ["script", "script/Deploy.s.sol:Deploy"]);
    assert.equal(forgeCalls[0].claimExists, false);
    assert.equal(forgeCalls[1].claimExists, true);
    assert.ok((forgeCalls[1].args as string[]).includes("--private-key"));
    assert.deepEqual(forgeCalls[1].environment, {
      RPC_URL: "http://devnet.example",
      PRIVATE_KEY_SET: true,
      FILECOIN_PAY: testAddress,
      TERMINATION_ORACLE: testAddress,
      ORACLE: testAddress,
      POREP_SERVICE: testAddress,
      META_ALLOCATOR: testAddress,
      OPERATOR_ADDR: testAddress,
      BUILD_INFO_SHA256: (readJson(latest).release as Record<string, unknown>).buildInfoSha256,
      DEPLOYMENT_OUTPUT: pending,
      FOUNDRY_BROADCAST: forgeCalls[1].environment && (forgeCalls[1].environment as Record<string, unknown>).FOUNDRY_BROADCAST,
    });

    const castCalls = readJsonLines(environment.FAKE_CAST_LOG!).map((entry) => entry as unknown as string[]);
    assert.ok(castCalls.some((args) => args.includes("eth_getTransactionReceipt")));
    assert.ok(castCalls.some((args) => args.includes("Filecoin.ChainGetFinalizedTipSet")));
    assert.ok(castCalls.some((args) => args.includes("eth_getBlockByNumber")));
    assert.ok(castCalls.some((args) => args[0] === "call"));
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("--fresh replaces an existing non-mainnet manifest and records its exact raw hash", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const latest = join(environment.DEPLOYMENTS_ROOT!, "devnet", "latest.json");
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");
  const previousBytes = '{"previous":true}\n';
  mkdirSync(dirname(latest), { recursive: true });
  writeFileSync(latest, previousBytes);

  try {
    const withoutFresh = runDeploymentCommand(["deploy", "devnet"], environment);
    assert.equal(withoutFresh.status, 1);
    assert.match(withoutFresh.stderr, /already exists; pass --fresh/);

    const fresh = runDeploymentCommand(["deploy", "devnet", "--fresh"], environment);

    assert.equal(fresh.status, 0, fresh.stderr);
    const expectedPreviousHash = `0x${createHash("sha256").update(previousBytes).digest("hex")}`;
    assert.equal(readJson(pending).previousManifestSha256, expectedPreviousHash);
    assert.equal(readJson(latest).status, "finalized");
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("--fresh remains unsupported for mainnet", () => {
  const result = runDeploymentCommand(["deploy", "mainnet", "--fresh"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /fresh mainnet deployment is not supported/);
});

test("interrupted finality wait preserves deploy evidence and finalize-deploy resumes without Forge", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");
  const pendingDirectory = dirname(pending);

  try {
    const interrupted = runDeploymentCommand(["deploy", "devnet"], {
      ...environment,
      FAKE_INTERRUPT_FINALITY: "yes",
    });

    assert.equal(interrupted.status, 1);
    assert.equal(readJson(pending).status, "pending");
    assert.ok(readdirSync(pendingDirectory).includes("pending-deploy.broadcast.json"));
    assert.ok(readdirSync(pendingDirectory).includes("pending-deploy.build-info.json.gz"));
    assert.equal(existsSync(join(environment.DEPLOYMENTS_ROOT!, "devnet", "latest.json")), false);
    const forgeCallsBeforeRecovery = readFileSync(environment.FAKE_FORGE_LOG!, "utf8");

    const recovered = runDeploymentCommand(["finalize-deploy", "devnet"], environment);

    assert.equal(recovered.status, 0, recovered.stderr);
    assert.equal(readJson(pending).status, "finalized");
    assert.equal(readFileSync(environment.FAKE_FORGE_LOG!, "utf8"), forgeCallsBeforeRecovery);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  test(`${signal} during Forge preserves and binds a completed broadcast for finalize-deploy`, () => {
    const directory = createTemporaryDirectory();
    const environment = deployTestEnvironment(directory);
    const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");
    const broadcast = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.broadcast.json");
    const claim = join(environment.PENDING_ROOT_TS!, "devnet", "operation.claim");

    try {
      const interrupted = runDeploymentCommand(["deploy", "devnet"], {
        ...environment,
        FAKE_FORGE_SIGNAL: signal,
      });

      assert.equal(interrupted.status, 1);
      const pendingAfterSignal = readJson(pending);
      assert.equal(pendingAfterSignal.status, "pending");
      assert.match(String(pendingAfterSignal.broadcastSha256), /^0x[0-9a-f]{64}$/);
      assert.equal(existsSync(broadcast), true);
      assert.equal(existsSync(claim), false);
      const forgeLog = readFileSync(environment.FAKE_FORGE_LOG!, "utf8");

      const recovered = runDeploymentCommand(["finalize-deploy", "devnet"], environment);

      assert.equal(recovered.status, 0, recovered.stderr);
      assert.equal(readJson(pending).status, "finalized");
      assert.equal(readFileSync(environment.FAKE_FORGE_LOG!, "utf8"), forgeLog);
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  });
}

test("a nonzero Forge exit after broadcast preserves evidence for finalize-deploy", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");

  try {
    const failed = runDeploymentCommand(["deploy", "devnet"], {
      ...environment,
      FAKE_FAIL_AFTER_BROADCAST: "yes",
    });

    assert.equal(failed.status, 1);
    assert.match(String(readJson(pending).broadcastSha256), /^0x[0-9a-f]{64}$/);
    const forgeLog = readFileSync(environment.FAKE_FORGE_LOG!, "utf8");

    const recovered = runDeploymentCommand(["finalize-deploy", "devnet"], environment);

    assert.equal(recovered.status, 0, recovered.stderr);
    assert.equal(readFileSync(environment.FAKE_FORGE_LOG!, "utf8"), forgeLog);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("invalid Forge result is discarded while its broadcast evidence remains bound", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");

  try {
    const failed = runDeploymentCommand(["deploy", "devnet"], {
      ...environment,
      FAKE_BAD_DEPENDENCY: "yes",
    });

    assert.equal(failed.status, 1);
    assert.match(String(readJson(pending).broadcastSha256), /^0x[0-9a-f]{64}$/);

    const finalize = runDeploymentCommand(["finalize-deploy", "devnet"], environment);
    assert.equal(finalize.status, 1);
    assert.match(finalize.stderr, /pending\.result is missing post-broadcast evidence/);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("an exclusive same-network claim allows only one concurrent deploy to broadcast", async () => {
  const directory = createTemporaryDirectory();
  const environment: NodeJS.ProcessEnv = {
    ...deployTestEnvironment(directory),
    FAKE_BUILD_DELAY_MS: "300",
  };

  try {
    const [first, second] = await Promise.all([
      runDeploymentCommandAsync(["deploy", "devnet"], environment),
      runDeploymentCommandAsync(["deploy", "devnet"], environment),
    ]);

    assert.deepEqual([first.code, second.code].sort(), [0, 1]);
    const forgeCalls = readJsonLines(environment.FAKE_FORGE_LOG!);
    const broadcasts = forgeCalls.filter((call) => (call.args as string[])[0] === "script");
    assert.equal(broadcasts.length, 1);
    assert.ok([first.stderr, second.stderr].some((stderr) => /operation claim|operation already exists/.test(stderr)));
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("--fresh discards only an authenticated pre-broadcast deploy journal", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");

  try {
    const failed = runDeploymentCommand(["deploy", "devnet"], {
      ...environment,
      FAKE_FAIL_BEFORE_BROADCAST: "yes",
    });
    assert.equal(failed.status, 1);
    assert.equal(readJson(pending).broadcastSha256, null);

    const withoutFresh = runDeploymentCommand(["deploy", "devnet"], environment);
    assert.equal(withoutFresh.status, 1);
    assert.match(withoutFresh.stderr, /operation already exists/);

    const fresh = runDeploymentCommand(["deploy", "devnet", "--fresh"], environment);

    assert.equal(fresh.status, 0, fresh.stderr);
    assert.equal(readJson(pending).status, "finalized");
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("finalize-deploy recovers the post-publication interruption without rewriting latest or calling chain tools", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");
  const latest = join(environment.DEPLOYMENTS_ROOT!, "devnet", "latest.json");

  try {
    const deployed = runDeploymentCommand(["deploy", "devnet"], environment);
    assert.equal(deployed.status, 0, deployed.stderr);
    const pendingValue = readJson(pending);
    pendingValue.status = "pending";
    writeFileSync(pending, `${JSON.stringify(pendingValue, null, 2)}\n`);
    const latestBytes = readFileSync(latest);
    const latestModified = statSync(latest).mtimeMs;
    const forgeLog = readFileSync(environment.FAKE_FORGE_LOG!, "utf8");
    const castLog = readFileSync(environment.FAKE_CAST_LOG!, "utf8");

    const recovered = runDeploymentCommand(["finalize-deploy", "devnet"], environment);

    assert.equal(recovered.status, 0, recovered.stderr);
    assert.deepEqual(readFileSync(latest), latestBytes);
    assert.equal(statSync(latest).mtimeMs, latestModified);
    assert.equal(readFileSync(environment.FAKE_FORGE_LOG!, "utf8"), forgeLog);
    assert.equal(readFileSync(environment.FAKE_CAST_LOG!, "utf8").slice(castLog.length).trim().split("\n").length, 1);
    assert.match(readFileSync(environment.FAKE_CAST_LOG!, "utf8").slice(castLog.length), /chain-id/);
    assert.equal(readJson(pending).status, "finalized");
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("finalize-deploy refuses an unexpected latest.json without rewriting it", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");
  const latest = join(environment.DEPLOYMENTS_ROOT!, "devnet", "latest.json");

  try {
    const deployed = runDeploymentCommand(["deploy", "devnet"], environment);
    assert.equal(deployed.status, 0, deployed.stderr);
    const pendingValue = readJson(pending);
    pendingValue.status = "pending";
    writeFileSync(pending, `${JSON.stringify(pendingValue, null, 2)}\n`);
    writeFileSync(latest, '{"unexpected":true}\n');
    const unexpectedBytes = readFileSync(latest);

    const recovered = runDeploymentCommand(["finalize-deploy", "devnet"], environment);

    assert.equal(recovered.status, 1);
    assert.match(recovered.stderr, /canonical devnet deployment is unexpected/);
    assert.deepEqual(readFileSync(latest), unexpectedBytes);
    assert.equal(readJson(pending).status, "pending");
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("finalized deploy recovery is idempotent and does not rewrite or rebroadcast", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const latest = join(environment.DEPLOYMENTS_ROOT!, "devnet", "latest.json");

  try {
    const deployed = runDeploymentCommand(["deploy", "devnet"], environment);
    assert.equal(deployed.status, 0, deployed.stderr);
    const latestBytes = readFileSync(latest);
    const forgeLog = readFileSync(environment.FAKE_FORGE_LOG!, "utf8");

    const retried = runDeploymentCommand(["finalize-deploy", "devnet"], environment);

    assert.equal(retried.status, 0, retried.stderr);
    assert.deepEqual(readFileSync(latest), latestBytes);
    assert.equal(readFileSync(environment.FAKE_FORGE_LOG!, "utf8"), forgeLog);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("deploy refuses pending TypeScript and Bash operations before Forge", () => {
  for (const [rootVariable, filename] of [
    ["PENDING_ROOT_TS", "pending-upgrade.json"],
    ["PENDING_ROOT", "pending-deploy.json"],
  ] as const) {
    const directory = createTemporaryDirectory();
    const environment = deployTestEnvironment(directory);
    const pending = join(environment[rootVariable]!, "devnet", filename);
    mkdirSync(dirname(pending), { recursive: true });
    writeFileSync(pending, '{"status":"pending"}\n');

    try {
      const result = runDeploymentCommand(["deploy", "devnet"], environment);

      assert.equal(result.status, 1);
      assert.match(result.stderr, /pending devnet (TypeScript|Bash) operation already exists/);
      assert.equal(readFileSync(environment.FAKE_FORGE_LOG!, "utf8"), "");
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  }
});

test("deploy fails closed on journals with missing, unknown, or unauthenticated finalized status", () => {
  for (const [rootVariable, filename, journal] of [
    ["PENDING_ROOT_TS", "pending-deploy.json", {}],
    ["PENDING_ROOT_TS", "pending-upgrade.json", { status: "unknown" }],
    ["PENDING_ROOT", "pending-deploy.json", { status: "finalized" }],
  ] as const) {
    const directory = createTemporaryDirectory();
    const environment = deployTestEnvironment(directory);
    const pending = join(environment[rootVariable]!, "devnet", filename);
    mkdirSync(dirname(pending), { recursive: true });
    writeFileSync(pending, `${JSON.stringify(journal)}\n`);

    try {
      const result = runDeploymentCommand(["deploy", "devnet"], environment);

      assert.equal(result.status, 1);
      assert.match(result.stderr, /journal is not an authenticated terminal state/);
      assert.equal(readFileSync(environment.FAKE_FORGE_LOG!, "utf8"), "");
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  }
});

test("--fresh can replace an authenticated finalized deploy journal", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");

  try {
    const first = runDeploymentCommand(["deploy", "devnet"], environment);
    assert.equal(first.status, 0, first.stderr);

    const fresh = runDeploymentCommand(["deploy", "devnet", "--fresh"], environment);

    assert.equal(fresh.status, 0, fresh.stderr);
    assert.equal(readJson(pending).status, "finalized");
    const forgeCalls = readJsonLines(environment.FAKE_FORGE_LOG!);
    assert.equal(forgeCalls.filter((call) => (call.args as string[])[0] === "script").length, 2);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("deploy rejects multiple build-info files before writing pending state", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pending = join(environment.PENDING_ROOT_TS!, "devnet", "pending-deploy.json");

  try {
    const result = runDeploymentCommand(["deploy", "devnet"], {
      ...environment,
      FAKE_EXTRA_BUILD_INFO: "yes",
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /exactly one build-info JSON/);
    assert.equal(existsSync(pending), false);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("deploy ignores run-latest.json as broadcast evidence", () => {
  const directory = createTemporaryDirectory();
  const environment = deployTestEnvironment(directory);
  const pendingDirectory = join(environment.PENDING_ROOT_TS!, "devnet");

  try {
    const result = runDeploymentCommand(["deploy", "devnet"], {
      ...environment,
      FAKE_LATEST_ONLY: "yes",
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /exactly one timestamped Forge broadcast/);
    assert.equal(readJson(join(pendingDirectory, "pending-deploy.json")).status, "pending");
    assert.equal(existsSync(join(pendingDirectory, "pending-deploy.broadcast.json")), false);

    const finalize = runDeploymentCommand(["finalize-deploy", "devnet"], environment);
    assert.equal(finalize.status, 1);
    assert.match(finalize.stderr, /pending\.broadcastSha256 is missing post-broadcast evidence/);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("rejects an RPC chain mismatch before checking release paths", () => {
  const directory = createTemporaryDirectory();
  const commandLog = join(directory, "commands.jsonl");
  createFakeExecutable(directory, "cast", "314\n");
  createFakeExecutable(directory, "git");

  try {
    const result = runDeploymentCommand(["deploy", "devnet"], {
      ...deploymentEnvironment(directory),
      FAKE_COMMAND_LOG: commandLog,
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /devnet RPC chain ID must be 31415926, got 314/);
    assert.deepEqual(JSON.parse(readFileSync(commandLog, "utf8")), ["chain-id", "--rpc-url", "http://devnet.example"]);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("mainnet requires CONFIRM_MAINNET=yes after confirming its RPC chain", () => {
  const directory = createTemporaryDirectory();
  const commandLog = join(directory, "commands.jsonl");
  createFakeExecutable(directory, "cast", "314\n");

  try {
    const result = runDeploymentCommand(["verify", "mainnet"], {
      PATH: `${directory}${delimiter}${process.env.PATH ?? ""}`,
      FAKE_COMMAND_LOG: commandLog,
      RPC_MAINNET: "http://mainnet.example",
      DEPLOYMENTS_ROOT: join(directory, "deployments"),
      CONFIRM_MAINNET: "",
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /set CONFIRM_MAINNET=yes before operating on mainnet/);
    assert.deepEqual(JSON.parse(readFileSync(commandLog, "utf8")), ["chain-id", "--rpc-url", "http://mainnet.example"]);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

for (const [command, arguments_] of [
  ["upgrade", ["PoRepMarket"]],
  ["finalize-upgrade", []],
  ["verify", []],
] as const) {
  test(`${command} waits for the canonical manifest cleanliness check`, () => {
    const directory = createTemporaryDirectory();
    const commandLog = join(directory, "commands.jsonl");
    const manifest = createCanonicalManifest(directory);
    createFakeExecutable(directory, "cast", "31415926\n");
    createFakeExecutable(directory, "git");

    try {
      const result = runDeploymentCommand([command, "devnet", ...arguments_], {
        ...deploymentEnvironment(directory),
        FAKE_COMMAND_LOG: commandLog,
        FAKE_DIRTY_PATH: manifest,
      });

      assert.equal(result.status, 1);
      assert.match(result.stderr, new RegExp(`canonical deployment manifest is not clean: ${manifest}`));
      assert.doesNotMatch(result.stderr, /phase is not implemented/);
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  });
}

test("writes a file atomically without leaving its temporary file behind", () => {
  const directory = createTemporaryDirectory();
  const file = join(directory, "pending.json");

  try {
    writeAtomicFile(file, '{"status":"pending"}\n');

    assert.equal(readFileSync(file, "utf8"), '{"status":"pending"}\n');
    assert.deepEqual(readdirSync(directory), ["pending.json"]);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("SIGINT aborts the shared deployment signal and cleanup removes listeners", () => {
  const sigintListeners = process.listenerCount("SIGINT");
  const sigtermListeners = process.listenerCount("SIGTERM");
  const signalHandling = installSignalHandling();

  try {
    process.emit("SIGINT");
    assert.equal(signalHandling.signal.aborted, true);
  } finally {
    signalHandling.dispose();
  }

  assert.equal(process.listenerCount("SIGINT"), sigintListeners);
  assert.equal(process.listenerCount("SIGTERM"), sigtermListeners);
});

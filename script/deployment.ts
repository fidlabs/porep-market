import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, gzipSync } from "node:zlib";
import {
  classifyDeployCanonicalState,
  classifyUpgradeCanonicalState,
  hashRawBytes,
  parseDeploymentManifest,
  parsePendingOperation,
  parseUpgradeOperations,
  renderPrepublicationUpgradedManifest,
  type DeploymentManifest,
  type PendingDeploy,
  type PendingUpgrade,
} from "./deployment-state.ts";
import {
  extractBroadcastTransactionHashes,
  loadTransactionReceipts,
  verifyLiveDeployment,
  waitForFilecoinFinality,
  type CommandRunner,
} from "./deployment-chain.ts";

const commands = ["deploy", "finalize-deploy", "upgrade", "finalize-upgrade", "verify"] as const;
const releasePaths = [
  "src",
  "script",
  "foundry.toml",
  "foundry.lock",
  "remappings.txt",
  "package.json",
  "package-lock.json",
  "lib",
] as const;

export const networkConfigs = {
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
} as const;

type Network = keyof typeof networkConfigs;
type Command = (typeof commands)[number];
type Context = {
  network: Network;
  root: string;
  deploymentsRoot: string;
  pendingRoot: string;
  bashPendingRoot: string;
  environment: NodeJS.ProcessEnv;
  cast: string;
  forge: string;
  git: string;
  signal?: AbortSignal;
};
type Paths = {
  directory: string;
  pending: string;
  buildInfo: string;
  broadcast: string;
  latest: string;
};
type Build = {
  hash: string;
  raw: Buffer;
  gzip: Buffer;
  outputDirectory: string;
  cacheDirectory: string;
};

export type SignalHandling = { signal: AbortSignal; dispose: () => void };

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const networks = Object.keys(networkConfigs) as Network[];
const usage = `Usage: deployment.ts <command> <network> [args...]\nCommands: ${commands.join(", ")}\nNetworks: ${networks.join(", ")}`;
const upgradeArtifacts: Record<string, string> = {
  PoRepMarket: "src/PoRepMarket.sol:PoRepMarket",
  ValidatorFactory: "src/ValidatorFactory.sol:ValidatorFactory",
  DataCapEvidenceAdapter: "src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter",
  SPRegistry: "src/SPRegistry.sol:SPRegistry",
  SLIOracle: "src/SLIOracle.sol:SLIOracle",
  SLIScorer: "src/SLIScorer.sol:SLIScorer",
  Validator: "src/Validator.sol:Validator",
};

async function deploy(context: Context, fresh: boolean): Promise<void> {
  if (fresh && context.network === "mainnet") throw new Error("fresh mainnet deployment is not supported");
  const privateKey = required(context, networkConfigs[context.network].privateKeyVariable);
  const dependencies = deploymentDependencies(context);

  await broadcastPreflight(context);
  const previousHash = prepareDeploy(context, fresh);
  ensureNoPendingOperation(context);

  const workspace = mkdtempSync(join(tmpdir(), "porep-deploy-ts-"));
  try {
    const build = await buildContracts(context, workspace);
    ensureNoPendingOperation(context);
    const pending = newPendingDeploy(context, previousHash, build.hash);
    const output = join(workspace, "deploy-output.json");
    writeAtomicFile(output, json(pending));

    let forgeError: unknown;
    try {
      await runDeployScript(context, workspace, output, build, privateKey, dependencies);
    } catch (error) {
      forgeError = error;
    }

    const recorded = recordDeploy(context, workspace, output, build, pending, dependencies);
    if (forgeError !== undefined) throw forgeError;
    if (!recorded) throw new Error("Forge did not produce complete deployment evidence");
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }

  await finalizeDeploy(context, true);
}

async function finalizeDeploy(context: Context, preflightDone = false): Promise<void> {
  if (!preflightDone) await finalizePreflight(context);
  const paths = operationPaths(context, "deploy");
  let pending = readDeployPending(context, paths);
  authenticateEvidence(paths, pending.release.buildInfoSha256, pending.broadcastSha256);

  const state = classifyDeployCanonicalState(hashFile(paths.latest), pending);
  if (state === "unexpected") throw new Error("canonical manifest does not match pending deployment");
  if (state === "result") {
    finishPending(paths.pending, pending);
    pruneBuildInfo(context, pending.release.buildInfoSha256);
    return;
  }
  if (pending.status === "finalized") throw new Error("finalized deployment manifest is missing");

  const rpcUrl = rpc(context);
  const receipts = await finalizedReceipts(context, paths.broadcast, rpcUrl);
  const manifest: DeploymentManifest = {
    ...pending.result!,
    status: "finalized",
    finalizedAt: pending.finalizedAt ?? new Date().toISOString(),
    transactions: receipts,
  };
  await verifyLiveDeployment(commandRunner(context), rpcUrl, manifest);

  const manifestBytes = json(manifest);
  pending = {
    ...pending,
    result: manifest,
    finalizedAt: manifest.finalizedAt!,
    resultManifestSha256: hashRawBytes(Buffer.from(manifestBytes)),
  };
  writeAtomicFile(paths.pending, json(pending));
  publish(context, paths, pending.release.buildInfoSha256, manifestBytes);
  finishPending(paths.pending, pending);
}

async function upgrade(context: Context, targets: readonly string[]): Promise<void> {
  const privateKey = required(context, networkConfigs[context.network].privateKeyVariable);
  await broadcastPreflight(context);
  ensureNoPendingOperation(context);

  const paths = operationPaths(context, "upgrade");
  ensureFile(paths.latest, `canonical ${context.network} deployment`);
  await ensureCleanCanonicalManifest(context);
  const sourceBytes = readFileSync(paths.latest);
  const source = parseDeploymentManifest(sourceBytes.toString("utf8"));
  const sourceHash = hashRawBytes(sourceBytes);
  validateTargets(source, targets);

  const workspace = mkdtempSync(join(tmpdir(), "porep-upgrade-ts-"));
  try {
    const build = await buildContracts(context, workspace);
    await validateStorage(context, source, build, workspace);
    const codeHashes = await compiledCodeHashes(context, source, targets, build.raw);
    rejectUnchangedTargets(source, codeHashes);

    await ensureCleanReleaseSource(context);
    if (hashFile(paths.latest) !== sourceHash) throw new Error("canonical manifest changed during upgrade preflight");
    ensureNoPendingOperation(context);

    const pending = newPendingUpgrade(context, targets, sourceHash, build.hash);
    const sourcePath = join(workspace, "source.json");
    const output = join(workspace, "upgrade-output.json");
    writeAtomicFile(sourcePath, sourceBytes);
    writeAtomicFile(output, json(pending));

    let forgeError: unknown;
    try {
      await runUpgradeScript(context, workspace, sourcePath, output, build, privateKey, targets);
    } catch (error) {
      forgeError = error;
    }

    const recorded = recordUpgrade(context, workspace, output, build, pending, source, codeHashes);
    if (forgeError !== undefined) throw forgeError;
    if (!recorded) throw new Error("Forge did not produce complete upgrade evidence");
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }

  await finalizeUpgrade(context, true);
}

async function finalizeUpgrade(context: Context, preflightDone = false): Promise<void> {
  if (!preflightDone) await finalizePreflight(context);
  const paths = operationPaths(context, "upgrade");
  const pending = readUpgradePending(context, paths);
  authenticateEvidence(paths, pending.release.buildInfoSha256, pending.broadcastSha256);

  const state = classifyUpgradeCanonicalState(hashFile(paths.latest), pending);
  if (state === "unexpected") throw new Error("canonical manifest does not match pending upgrade");
  if (state === "result") {
    finishPending(paths.pending, pending);
    pruneBuildInfo(context, pending.release.buildInfoSha256);
    return;
  }
  if (pending.status === "finalized") throw new Error("finalized upgrade manifest is missing");

  const source = parseDeploymentManifest(readFileSync(paths.latest, "utf8"));
  const rpcUrl = rpc(context);
  await finalizedReceipts(context, paths.broadcast, rpcUrl);
  await verifyLiveDeployment(commandRunner(context), rpcUrl, source, pending.operations);

  const manifestBytes = json(renderPrepublicationUpgradedManifest(source, pending));
  if (hashRawBytes(Buffer.from(manifestBytes)) !== pending.resultManifestSha256) {
    throw new Error("pending upgrade result hash is invalid");
  }
  publish(context, paths, pending.release.buildInfoSha256, manifestBytes);
  finishPending(paths.pending, pending);
}

async function verify(context: Context): Promise<void> {
  await finalizePreflight(context);
  const path = canonicalManifestPath(context);
  ensureFile(path, `canonical ${context.network} deployment`);
  await ensureCleanCanonicalManifest(context);
  const manifest = parseDeploymentManifest(readFileSync(path, "utf8"));
  await verifyLiveDeployment(commandRunner(context), rpc(context), manifest);
}

async function runCli(args: readonly string[], signal?: AbortSignal): Promise<void> {
  const [commandValue, networkValue, ...rest] = args;
  const command = parseCommand(commandValue);
  const network = parseNetwork(networkValue);
  const context = createContext(network, signal);

  switch (command) {
    case "deploy":
      await deploy(context, parseFresh(rest));
      return;
    case "finalize-deploy":
      noArguments(command, rest);
      await finalizeDeploy(context);
      return;
    case "upgrade":
      if (rest.length === 0) throw new Error("upgrade requires at least one target");
      await upgrade(context, rest);
      return;
    case "finalize-upgrade":
      noArguments(command, rest);
      await finalizeUpgrade(context);
      return;
    case "verify":
      noArguments(command, rest);
      await verify(context);
  }
}

function createContext(network: Network, signal?: AbortSignal): Context {
  return {
    network,
    root,
    deploymentsRoot: process.env.DEPLOYMENTS_ROOT ?? join(root, "deployments"),
    pendingRoot: process.env.PENDING_ROOT_TS ?? join(root, ".deployment-ts"),
    bashPendingRoot: process.env.PENDING_ROOT ?? join(root, ".deployment"),
    environment: process.env,
    cast: process.env.CAST_BIN ?? "cast",
    forge: process.env.FORGE_BIN ?? "forge",
    git: process.env.GIT_BIN ?? "git",
    signal,
  };
}

function operationPaths(context: Context, operation: "deploy" | "upgrade"): Paths {
  const directory = join(context.pendingRoot, context.network);
  return {
    directory,
    pending: join(directory, `pending-${operation}.json`),
    buildInfo: join(directory, `pending-${operation}.build-info.json.gz`),
    broadcast: join(directory, `pending-${operation}.broadcast.json`),
    latest: canonicalManifestPath(context),
  };
}

function parseCommand(value: string | undefined): Command {
  if (value === undefined) throw new Error(usage);
  if (!commands.includes(value as Command)) throw new Error(`unsupported command: ${value}`);
  return value as Command;
}

function parseNetwork(value: string | undefined): Network {
  if (value === undefined) throw new Error(usage);
  if (!networks.includes(value as Network)) throw new Error(`unsupported network: ${value}`);
  return value as Network;
}

function parseFresh(args: readonly string[]): boolean {
  if (args.length === 0) return false;
  if (args.length === 1 && args[0] === "--fresh") return true;
  throw new Error(`unsupported deploy arguments: ${args.join(" ")}`);
}

function noArguments(command: Command, args: readonly string[]): void {
  if (args.length !== 0) throw new Error(`${command} does not accept arguments`);
}

async function broadcastPreflight(context: Context): Promise<void> {
  await ensureChainId(context);
  confirmMainnet(context);
  await ensureCleanReleaseSource(context);
}

async function finalizePreflight(context: Context): Promise<void> {
  await ensureChainId(context);
  confirmMainnet(context);
}

async function ensureChainId(context: Context): Promise<void> {
  const actual = (await runProcess(context.cast, ["chain-id", "--rpc-url", rpc(context)], { signal: context.signal })).trim();
  const expected = networkConfigs[context.network].chainId;
  if (actual !== String(expected)) throw new Error(`${context.network} RPC chain ID must be ${expected}, got ${actual}`);
}

function confirmMainnet(context: Context): void {
  if (context.network === "mainnet" && context.environment.CONFIRM_MAINNET !== "yes") {
    throw new Error("set CONFIRM_MAINNET=yes before operating on mainnet");
  }
}

async function ensureCleanReleaseSource(context: Context): Promise<void> {
  const output = await runProcess(
    context.git,
    ["-C", context.root, "status", "--porcelain", "--untracked-files=all", "--", ...releasePaths],
    { signal: context.signal },
  );
  if (output.length !== 0) throw new Error(`deployment source is dirty under ${context.root}`);
}

function prepareDeploy(context: Context, fresh: boolean): string | null {
  const paths = operationPaths(context, "deploy");
  if (!existsSync(paths.latest)) return null;
  if (!fresh) throw new Error(`canonical ${context.network} deployment already exists; pass --fresh`);
  rmSync(paths.pending, { force: true });
  rmSync(paths.buildInfo, { force: true });
  rmSync(paths.broadcast, { force: true });
  return hashFile(paths.latest) ?? null;
}

function ensureNoPendingOperation(context: Context): void {
  const paths = [
    join(context.pendingRoot, context.network, "pending-deploy.json"),
    join(context.pendingRoot, context.network, "pending-upgrade.json"),
    join(context.bashPendingRoot, context.network, "pending-deploy.json"),
    join(context.bashPendingRoot, context.network, "pending-upgrade.json"),
  ];
  for (const path of paths) {
    if (!existsSync(path)) continue;
    let status: unknown;
    try {
      status = (JSON.parse(readFileSync(path, "utf8")) as { status?: unknown }).status;
    } catch {
      throw new Error(`pending operation file is invalid: ${path}`);
    }
    if (status !== "finalized") throw new Error(`pending operation already exists: ${path}`);
  }
}

async function buildContracts(context: Context, workspace: string): Promise<Build> {
  const outputDirectory = join(workspace, "out");
  const cacheDirectory = join(workspace, "cache");
  await runProcess(
    context.forge,
    ["build", "--root", context.root, "--out", outputDirectory, "--cache-path", cacheDirectory, "--build-info", "--extra-output", "storageLayout"],
    { signal: context.signal },
  );
  const directory = join(outputDirectory, "build-info");
  const files = existsSync(directory) ? readdirSync(directory).filter((name) => name.endsWith(".json")) : [];
  if (files.length !== 1) throw new Error("Forge build must produce exactly one build-info JSON");
  const raw = readFileSync(join(directory, files[0]));
  return {
    hash: hashRawBytes(raw),
    raw,
    gzip: gzipSync(raw, { level: 9 }),
    outputDirectory,
    cacheDirectory,
  };
}

function newPendingDeploy(context: Context, previousHash: string | null, buildHash: string): PendingDeploy {
  return {
    status: "pending",
    operation: "deploy",
    network: context.network,
    chainId: networkConfigs[context.network].chainId,
    previousManifestSha256: previousHash,
    release: { buildInfoSha256: buildHash },
    broadcastSha256: null,
    result: null,
    finalizedAt: null,
    resultManifestSha256: null,
  };
}

function newPendingUpgrade(context: Context, targets: readonly string[], sourceHash: string, buildHash: string): PendingUpgrade {
  return {
    status: "pending",
    operation: "upgrade",
    network: context.network,
    chainId: networkConfigs[context.network].chainId,
    targets: [...targets],
    operations: [],
    sourceManifestSha256: sourceHash,
    resultManifestSha256: null,
    release: { buildInfoSha256: buildHash },
    broadcastSha256: null,
  };
}

async function runDeployScript(
  context: Context,
  workspace: string,
  output: string,
  build: Build,
  privateKey: string,
  dependencies: ReturnType<typeof deploymentDependencies>,
): Promise<void> {
  const environment = {
    ...context.environment,
    PRIVATE_KEY: privateKey,
    RPC_URL: rpc(context),
    FILECOIN_PAY: dependencies.FilecoinPay,
    TERMINATION_ORACLE: dependencies.TerminationOracle,
    ORACLE: dependencies.Oracle,
    POREP_SERVICE: dependencies.PoRepService,
    META_ALLOCATOR: dependencies.MetaAllocator,
    OPERATOR_ADDR: dependencies.Operator,
    BUILD_INFO_SHA256: build.hash,
    DEPLOYMENT_OUTPUT: output,
    FOUNDRY_BROADCAST: join(workspace, "broadcast"),
  };
  await runForgeScript(context, "script/Deploy.s.sol:Deploy", workspace, build, privateKey, environment);
}

async function runUpgradeScript(
  context: Context,
  workspace: string,
  source: string,
  output: string,
  build: Build,
  privateKey: string,
  targets: readonly string[],
): Promise<void> {
  const environment = {
    ...context.environment,
    PRIVATE_KEY: privateKey,
    RPC_URL: rpc(context),
    DEPLOYMENT_MANIFEST: source,
    UPGRADE_OUTPUT: output,
    UPGRADE_CONTRACT_NAMES: targets.join(","),
    FOUNDRY_BROADCAST: join(workspace, "broadcast"),
  };
  await runForgeScript(context, "script/Upgrade.s.sol:Upgrade", workspace, build, privateKey, environment);
}

async function runForgeScript(
  context: Context,
  script: string,
  workspace: string,
  build: Build,
  privateKey: string,
  environment: NodeJS.ProcessEnv,
): Promise<void> {
  void workspace;
  await runProcess(
    context.forge,
    [
      "script", script, "--root", context.root,
      "--out", build.outputDirectory, "--cache-path", build.cacheDirectory,
      "--broadcast", "--rpc-url", rpc(context), "--private-key", privateKey,
      "--gas-estimate-multiplier", "100000", "--slow",
    ],
    { environment, signal: context.signal },
  );
}

function recordDeploy(
  context: Context,
  workspace: string,
  output: string,
  build: Build,
  expected: PendingDeploy,
  dependencies: ReturnType<typeof deploymentDependencies>,
): boolean {
  const broadcast = findBroadcast(context, workspace, "Deploy.s.sol");
  if (!broadcast || !existsSync(output)) return false;
  const parsed = parsePendingOperation(readFileSync(output, "utf8"));
  if (parsed.operation !== "deploy" || parsed.result === null) throw new Error("Forge deployment output is incomplete");
  if (parsed.result.release.buildInfoSha256 !== build.hash) throw new Error("Forge deployment used unexpected build-info");
  for (const [name, value] of Object.entries(dependencies)) {
    if (parsed.result.externalDependencies[name]?.toLowerCase() !== value.toLowerCase()) {
      throw new Error(`Forge deployment dependency ${name} is unexpected`);
    }
  }
  const paths = operationPaths(context, "deploy");
  const broadcastBytes = readFileSync(broadcast);
  const pending: PendingDeploy = { ...expected, result: parsed.result, broadcastSha256: hashRawBytes(broadcastBytes) };
  retainPendingEvidence(paths, build.gzip, broadcastBytes, pending);
  return true;
}

function recordUpgrade(
  context: Context,
  workspace: string,
  output: string,
  build: Build,
  expected: PendingUpgrade,
  source: DeploymentManifest,
  codeHashes: ReadonlyMap<string, string>,
): boolean {
  const broadcast = findBroadcast(context, workspace, "Upgrade.s.sol");
  if (!broadcast || !existsSync(output)) return false;
  const operations = parseUpgradeOperations(JSON.stringify((JSON.parse(readFileSync(output, "utf8")) as { operations: unknown }).operations));
  validateOperations(expected.targets, operations, codeHashes);
  const broadcastBytes = readFileSync(broadcast);
  let pending: PendingUpgrade = {
    ...expected,
    operations,
    broadcastSha256: hashRawBytes(broadcastBytes),
  };
  const resultBytes = json(renderPrepublicationUpgradedManifest(source, pending));
  pending = { ...pending, resultManifestSha256: hashRawBytes(Buffer.from(resultBytes)) };
  retainPendingEvidence(operationPaths(context, "upgrade"), build.gzip, broadcastBytes, pending);
  return true;
}

function retainPendingEvidence(paths: Paths, buildInfo: Buffer, broadcast: Buffer, pending: PendingDeploy | PendingUpgrade): void {
  mkdirSync(paths.directory, { recursive: true });
  writeAtomicFile(paths.buildInfo, buildInfo);
  writeAtomicFile(paths.broadcast, broadcast);
  writeAtomicFile(paths.pending, json(pending));
}

function findBroadcast(context: Context, workspace: string, script: string): string | undefined {
  const directory = join(workspace, "broadcast", script, String(networkConfigs[context.network].chainId));
  const files = existsSync(directory) ? readdirSync(directory).filter((name) => /^run-[0-9]+\.json$/.test(name)) : [];
  if (files.length > 1) throw new Error("Forge produced multiple timestamped broadcast files");
  return files.length === 1 ? join(directory, files[0]) : undefined;
}

function validateTargets(source: DeploymentManifest, targets: readonly string[]): void {
  if (source.status !== "finalized") throw new Error("canonical manifest must be finalized before upgrade");
  if (new Set(targets).size !== targets.length) throw new Error("upgrade targets contain duplicates");
  for (const target of targets) {
    const artifact = upgradeArtifacts[target];
    const contract = source.contracts[target];
    if (!artifact || !contract) throw new Error(`unsupported upgrade target: ${target}`);
    const expectedKind = target === "Validator" ? "implementation" : "uups";
    if (contract.kind !== expectedKind || contract.artifact !== artifact) {
      throw new Error(`manifest entry for ${target} is not upgradeable by this command`);
    }
  }
}

async function validateStorage(context: Context, source: DeploymentManifest, build: Build, workspace: string): Promise<void> {
  const previous = retainedBuildInfoPath(context, source.release.buildInfoSha256);
  authenticateBuildInfo(previous, source.release.buildInfoSha256);
  const current = join(workspace, "current-build-info.json.gz");
  writeAtomicFile(current, build.gzip);
  const targets = Object.entries(source.contracts)
    .filter(([name, contract]) => contract.kind === "uups" || (name === "Validator" && contract.kind === "implementation"))
    .map(([name]) => name);
  const args = ["--manifest", canonicalManifestPath(context)];
  for (const target of targets) args.push("--target", target);
  args.push(
    "--reference-build-info", previous,
    "--reference-sha256", source.release.buildInfoSha256,
    "--current-build-info", current,
    "--current-sha256", build.hash,
  );
  const validator = context.environment.STORAGE_VALIDATOR ?? join(context.root, "script", "validate-storage-layout.sh");
  await runProcess(validator, args, { environment: context.environment, signal: context.signal });
}

async function compiledCodeHashes(
  context: Context,
  source: DeploymentManifest,
  targets: readonly string[],
  buildInfo: Buffer,
): Promise<Map<string, string>> {
  const root = record(JSON.parse(buildInfo.toString("utf8")), "build-info");
  const output = record(root.output, "build-info.output");
  const contracts = record(output.contracts, "build-info.output.contracts");
  const hashes = new Map<string, string>();
  for (const target of targets) {
    const artifact = source.contracts[target]!.artifact;
    const [sourceName, contractName] = artifact.split(":");
    const contract = record(record(contracts[sourceName], sourceName)[contractName], artifact);
    const evm = record(contract.evm, `${artifact}.evm`);
    const deployed = record(evm.deployedBytecode, `${artifact}.deployedBytecode`);
    if (typeof deployed.object !== "string" || !/^[0-9a-fA-F]+$/.test(deployed.object)) {
      throw new Error(`compiled bytecode for ${target} is missing`);
    }
    hashes.set(target, (await runProcess(context.cast, ["keccak", `0x${deployed.object}`], { signal: context.signal })).trim());
  }
  return hashes;
}

function rejectUnchangedTargets(source: DeploymentManifest, hashes: ReadonlyMap<string, string>): void {
  for (const [target, hash] of hashes) {
    const contract = source.contracts[target]!;
    if ("implementationCodeHash" in contract && contract.implementationCodeHash === hash) {
      throw new Error(`compiled implementation for ${target} is unchanged`);
    }
  }
}

function validateOperations(targets: readonly string[], operations: PendingUpgrade["operations"], hashes: ReadonlyMap<string, string>): void {
  if (operations.length !== targets.length) throw new Error("Forge upgrade operations do not match requested targets");
  operations.forEach((operation, index) => {
    const target = targets[index];
    const kind = target === "Validator" ? "beacon" : "uups";
    if (operation.target !== target || operation.kind !== kind || operation.artifact !== upgradeArtifacts[target]) {
      throw new Error(`Forge upgrade operation ${index} does not match ${target}`);
    }
    if (operation.newImplementationCodeHash !== hashes.get(target)) {
      throw new Error(`Forge upgrade bytecode for ${target} does not match the validated build`);
    }
  });
}

function readDeployPending(context: Context, paths: Paths): PendingDeploy {
  const pending = readPending(paths.pending);
  if (pending.operation !== "deploy" || pending.network !== context.network) throw new Error("pending deployment does not match command");
  if (!pending.result || !pending.broadcastSha256) throw new Error("pending deployment evidence is incomplete");
  return pending;
}

function readUpgradePending(context: Context, paths: Paths): PendingUpgrade {
  const pending = readPending(paths.pending);
  if (pending.operation !== "upgrade" || pending.network !== context.network) throw new Error("pending upgrade does not match command");
  if (pending.operations.length === 0 || !pending.broadcastSha256 || !pending.resultManifestSha256) {
    throw new Error("pending upgrade evidence is incomplete");
  }
  return pending;
}

function readPending(path: string): ReturnType<typeof parsePendingOperation> {
  if (!existsSync(path)) throw new Error(`pending operation does not exist: ${path}`);
  return parsePendingOperation(readFileSync(path, "utf8"));
}

function authenticateEvidence(paths: Paths, buildHash: string, broadcastHash: string | null): void {
  authenticateBuildInfo(paths.buildInfo, buildHash);
  if (!broadcastHash || hashFile(paths.broadcast) !== broadcastHash) throw new Error("pending broadcast hash does not match");
}

function authenticateBuildInfo(path: string, expectedHash: string): Buffer {
  const raw = gunzipSync(readFileSync(path));
  if (hashRawBytes(raw) !== expectedHash) throw new Error(`build-info hash does not match: ${path}`);
  return raw;
}

async function finalizedReceipts(context: Context, broadcast: string, rpcUrl: string) {
  const hashes = extractBroadcastTransactionHashes(readFileSync(broadcast, "utf8"));
  const receipts = await loadTransactionReceipts(commandRunner(context), rpcUrl, hashes);
  await waitForFilecoinFinality(commandRunner(context), rpcUrl, receipts, { signal: context.signal });
  return receipts;
}

function commandRunner(context: Context): CommandRunner {
  return (command, args, options) => {
    if (command !== "cast") throw new Error(`unsupported command: ${command}`);
    return runProcess(context.cast, args, { signal: options.signal ?? context.signal });
  };
}

function publish(context: Context, paths: Paths, buildHash: string, manifest: string): void {
  const destination = retainedBuildInfoPath(context, buildHash);
  mkdirSync(dirname(destination), { recursive: true });
  if (!existsSync(destination)) writeAtomicFile(destination, readFileSync(paths.buildInfo));
  writeAtomicFile(paths.latest, manifest);
  pruneBuildInfo(context, buildHash);
}

function finishPending(path: string, pending: PendingDeploy | PendingUpgrade): void {
  if (pending.status !== "finalized") writeAtomicFile(path, json({ ...pending, status: "finalized" }));
}

function retainedBuildInfoPath(context: Context, hash: string): string {
  return join(context.deploymentsRoot, context.network, "build-info", `${hash.slice(2)}.json.gz`);
}

function pruneBuildInfo(context: Context, retainedHash: string): void {
  const directory = dirname(retainedBuildInfoPath(context, retainedHash));
  if (!existsSync(directory)) return;
  const retained = `${retainedHash.slice(2)}.json.gz`;
  for (const file of readdirSync(directory)) {
    if (file.endsWith(".json.gz") && file !== retained) rmSync(join(directory, file), { force: true });
  }
}

function deploymentDependencies(context: Context): Record<string, string> & {
  FilecoinPay: string;
  TerminationOracle: string;
  Oracle: string;
  PoRepService: string;
  MetaAllocator: string;
  Operator: string;
} {
  const suffix = networkConfigs[context.network].environmentSuffix;
  return {
    FilecoinPay: required(context, `FILECOIN_PAY_${suffix}`),
    TerminationOracle: required(context, `TERMINATION_ORACLE_${suffix}`),
    Oracle: required(context, `ORACLE_${suffix}`),
    PoRepService: required(context, `POREP_SERVICE_${suffix}`),
    MetaAllocator: required(context, `META_ALLOCATOR_${suffix}`),
    Operator: required(context, `OPERATOR_ADDR_${suffix}`),
  };
}

function required(context: Context, name: string): string {
  const value = context.environment[name];
  if (!value) throw new Error(`required environment variable is unset for ${context.network}: ${name}`);
  return value;
}

function rpc(context: Context): string {
  return required(context, networkConfigs[context.network].rpcVariable);
}

function canonicalManifestPath(context: Context): string {
  return join(context.deploymentsRoot, context.network, "latest.json");
}

function ensureFile(path: string, label: string): void {
  if (!existsSync(path)) throw new Error(`${label} does not exist: ${path}`);
}

async function ensureCleanCanonicalManifest(context: Context): Promise<void> {
  const path = canonicalManifestPath(context);
  const output = await runProcess(
    context.git,
    ["-C", context.root, "status", "--porcelain", "--untracked-files=all", "--", path],
    { signal: context.signal },
  );
  if (output.length !== 0) throw new Error(`canonical deployment manifest is not clean: ${path}`);
}

function hashFile(path: string): string | undefined {
  return existsSync(path) ? hashRawBytes(readFileSync(path)) : undefined;
}

function record(value: unknown, name: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${name} must be an object`);
  return value as Record<string, unknown>;
}

function json(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

export async function runProcess(
  command: string,
  args: readonly string[],
  options: { environment?: NodeJS.ProcessEnv; signal?: AbortSignal } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env: options.environment, shell: false, signal: options.signal });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let processError: Error | undefined;
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.once("error", (error) => {
      processError = new Error(`could not run ${command}: ${error.message}`, { cause: error });
      if (child.pid === undefined) reject(processError);
    });
    child.once("close", (code, signal) => {
      if (processError) {
        reject(processError);
        return;
      }
      if (code !== 0) {
        const details = Buffer.concat(stderr).toString("utf8").trim();
        reject(new Error(`${command} exited with code ${code ?? "unknown"}${signal ? ` (${signal})` : ""}${details ? `: ${details}` : ""}`));
        return;
      }
      resolve(Buffer.concat(stdout).toString("utf8"));
    });
  });
}

export function writeAtomicFile(path: string, content: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = join(dirname(path), `.${randomUUID()}.tmp`);
  let descriptor: number | undefined;
  try {
    descriptor = openSync(temporary, "wx", 0o600);
    writeFileSync(descriptor, content);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporary, path);
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    rmSync(temporary, { force: true });
    throw error;
  }
}

export function installSignalHandling(): SignalHandling {
  const controller = new AbortController();
  const abort = (): void => controller.abort();
  process.on("SIGINT", abort);
  process.on("SIGTERM", abort);
  return {
    signal: controller.signal,
    dispose: () => {
      process.off("SIGINT", abort);
      process.off("SIGTERM", abort);
    },
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const signals = installSignalHandling();
  void runCli(process.argv.slice(2), signals.signal)
    .catch((error: unknown) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    })
    .finally(signals.dispose);
}

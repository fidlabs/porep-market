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
  writeSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, gzipSync } from "node:zlib";
import {
  classifyDeployCanonicalState,
  hashRawBytes,
  parsePendingOperation,
  renderDeployManifest,
  type DeploymentManifest,
  type PendingDeploy,
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
type Executables = { cast: string; forge: string; git: string };
type DeploymentContext = {
  network: Network;
  root: string;
  deploymentsRoot: string;
  pendingRoot: string;
  bashPendingRoot: string;
  environment: NodeJS.ProcessEnv;
  executables: Executables;
  signal?: AbortSignal;
};

type DeploymentDependencies = ReturnType<typeof loadDeploymentDependencies>;

type DeployPaths = {
  pendingDirectory: string;
  pending: string;
  buildInfo: string;
  broadcast: string;
  latest: string;
};

export type SignalHandling = {
  signal: AbortSignal;
  dispose: () => void;
};

const networks = Object.keys(networkConfigs) as Network[];
const usage = `Usage: deployment.ts <command> <network> [args...]\nCommands: ${commands.join(", ")}\nNetworks: ${networks.join(", ")}`;
const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));

async function deploy(context: DeploymentContext, fresh: boolean): Promise<void> {
  if (fresh && context.network === "mainnet") {
    throw new Error("fresh mainnet deployment is not supported");
  }
  const privateKey = requireEnvironment(context, networkConfigs[context.network].privateKeyVariable);
  const dependencies = loadDeploymentDependencies(context);
  const paths = deployPaths(context);

  await preflightBroadcast(context);
  const previousManifestSha256 = prepareDeployDestination(context, fresh);
  refusePendingOperations(context);

  const workspace = mkdtempSync(join(tmpdir(), "porep-deploy-ts-"));
  try {
    const buildInfoSha256 = await buildDeployment(context, workspace, paths);
    const pending = createPendingDeploy(context, previousManifestSha256, buildInfoSha256);
    writePendingDeploy(paths.pending, pending);

    await broadcastDeployment(context, workspace, paths, privateKey, dependencies, buildInfoSha256);
    recordDeploymentBroadcast(context, workspace, paths, pending, dependencies);
  } finally {
    rmSync(workspace, { force: true, recursive: true });
  }

  await finalizeDeploy(context, true);
}

async function finalizeDeploy(context: DeploymentContext, preflightCompleted = false): Promise<void> {
  if (!preflightCompleted) {
    await preflightFinalize(context);
  }
  const paths = deployPaths(context);
  let pending = loadPendingDeploy(context, paths);

  authenticatePendingBuildInfo(paths.buildInfo, pending.release.buildInfoSha256);
  authenticatePendingBroadcast(paths.broadcast, pending.broadcastSha256);

  const canonicalHash = hashFileIfPresent(paths.latest);
  const canonicalState = classifyDeployCanonicalState(canonicalHash, pending);
  if (canonicalState === "unexpected" || canonicalState === "source" && pending.status === "finalized") {
    throw new Error(`canonical ${context.network} deployment is unexpected during deploy recovery`);
  }

  if (canonicalState === "result") {
    authenticateRenderedDeployManifest(pending);
    authenticateRetainedBuildInfo(context, pending.release.buildInfoSha256);
    markDeployFinalized(paths.pending, pending);
    pruneBuildInfo(context, pending.release.buildInfoSha256);
    return;
  }
  if (pending.status === "finalized") {
    throw new Error(`finalized ${context.network} deployment manifest is missing`);
  }

  let manifestBytes: string;
  if (pending.resultManifestSha256 === null) {
    pending = await collectDeployFinalizationEvidence(context, paths, pending);
    manifestBytes = renderDeployManifestBytes(pending);
  } else {
    manifestBytes = authenticateRenderedDeployManifest(pending);
  }

  const preparedCanonicalHash = hashFileIfPresent(paths.latest);
  const preparedCanonicalState = classifyDeployCanonicalState(preparedCanonicalHash, pending);
  if (preparedCanonicalState === "unexpected") {
    throw new Error(`canonical ${context.network} deployment is unexpected during deploy publication`);
  }
  if (preparedCanonicalState === "result") {
    authenticateRetainedBuildInfo(context, pending.release.buildInfoSha256);
  } else {
    retainBuildInfo(context, paths.buildInfo, pending.release.buildInfoSha256);
    writeAtomicFile(paths.latest, manifestBytes);
  }

  markDeployFinalized(paths.pending, pending);
  pruneBuildInfo(context, pending.release.buildInfoSha256);
}

async function upgrade(context: DeploymentContext, targets: readonly string[]): Promise<void> {
  requireEnvironment(context, networkConfigs[context.network].privateKeyVariable);
  await preflightBroadcast(context);
  ensureCanonicalManifest(context);
  await ensureCleanCanonicalManifest(context);
  void targets;
  throw new Error("upgrade phase is not implemented");
}

async function finalizeUpgrade(context: DeploymentContext): Promise<void> {
  await preflightFinalize(context);
  ensureCanonicalManifest(context);
  await ensureCleanCanonicalManifest(context);
  throw new Error("finalize-upgrade phase is not implemented");
}

async function verify(context: DeploymentContext): Promise<void> {
  await preflightFinalize(context);
  ensureCanonicalManifest(context);
  await ensureCleanCanonicalManifest(context);
  throw new Error("verify phase is not implemented");
}

async function runDeploymentCli(arguments_: readonly string[], signal?: AbortSignal): Promise<void> {
  const [commandArgument, networkArgument, ...commandArguments] = arguments_;
  const command = parseCommand(commandArgument);
  const network = parseNetwork(networkArgument);
  const context = createContext(network, signal);

  switch (command) {
    case "deploy":
      await deploy(context, parseDeployArguments(commandArguments));
      return;
    case "finalize-deploy":
      ensureNoArguments(command, commandArguments);
      await finalizeDeploy(context);
      return;
    case "upgrade":
      await upgrade(context, parseUpgradeArguments(commandArguments));
      return;
    case "finalize-upgrade":
      ensureNoArguments(command, commandArguments);
      await finalizeUpgrade(context);
      return;
    case "verify":
      ensureNoArguments(command, commandArguments);
      await verify(context);
  }
}

function createContext(network: Network, signal?: AbortSignal): DeploymentContext {
  const root = repositoryRoot;
  return {
    root,
    deploymentsRoot: process.env.DEPLOYMENTS_ROOT ?? join(root, "deployments"),
    pendingRoot: process.env.PENDING_ROOT_TS ?? join(root, ".deployment-ts"),
    bashPendingRoot: process.env.PENDING_ROOT ?? join(root, ".deployment"),
    environment: process.env,
    executables: {
      cast: process.env.CAST_BIN ?? "cast",
      forge: process.env.FORGE_BIN ?? "forge",
      git: process.env.GIT_BIN ?? "git",
    },
    signal,
    network,
  };
}

function deployPaths(context: DeploymentContext): DeployPaths {
  const pendingDirectory = join(context.pendingRoot, context.network);
  return {
    pendingDirectory,
    pending: join(pendingDirectory, "pending-deploy.json"),
    buildInfo: join(pendingDirectory, "pending-deploy.build-info.json.gz"),
    broadcast: join(pendingDirectory, "pending-deploy.broadcast.json"),
    latest: canonicalManifestPath(context),
  };
}

function parseCommand(command: string | undefined): Command {
  if (command === undefined) {
    throw new Error(usage);
  }
  if (!commands.includes(command as Command)) {
    throw new Error(`unsupported command: ${command}`);
  }
  return command as Command;
}

function parseNetwork(network: string | undefined): Network {
  if (network === undefined) {
    throw new Error(usage);
  }
  if (!networks.includes(network as Network)) {
    throw new Error(`unsupported network: ${network}`);
  }
  return network as Network;
}

function parseDeployArguments(arguments_: readonly string[]): boolean {
  if (arguments_.length === 0) {
    return false;
  }
  if (arguments_.length === 1 && arguments_[0] === "--fresh") {
    return true;
  }
  throw new Error(`unsupported deploy arguments: ${arguments_.join(" ")}`);
}

function parseUpgradeArguments(arguments_: readonly string[]): readonly string[] {
  if (arguments_.length === 0) {
    throw new Error("upgrade requires at least one target");
  }
  return arguments_;
}

function ensureNoArguments(command: Command, arguments_: readonly string[]): void {
  if (arguments_.length !== 0) {
    throw new Error(`${command} does not accept arguments: ${arguments_.join(" ")}`);
  }
}

function loadDeploymentDependencies(context: DeploymentContext): {
  filecoinPay: string;
  terminationOracle: string;
  oracle: string;
  porepService: string;
  metaAllocator: string;
  operatorAddress: string;
} {
  const suffix = networkConfigs[context.network].environmentSuffix;
  return {
    filecoinPay: requireEnvironment(context, `FILECOIN_PAY_${suffix}`),
    terminationOracle: requireEnvironment(context, `TERMINATION_ORACLE_${suffix}`),
    oracle: requireEnvironment(context, `ORACLE_${suffix}`),
    porepService: requireEnvironment(context, `POREP_SERVICE_${suffix}`),
    metaAllocator: requireEnvironment(context, `META_ALLOCATOR_${suffix}`),
    operatorAddress: requireEnvironment(context, `OPERATOR_ADDR_${suffix}`),
  };
}

function requireEnvironment(context: DeploymentContext, variable: string): string {
  const value = context.environment[variable];
  if (value === undefined || value.length === 0) {
    throw new Error(`required environment variable is unset for ${context.network}: ${variable}`);
  }
  return value;
}

async function preflightBroadcast(context: DeploymentContext): Promise<void> {
  await ensureChainId(context);
  ensureMainnetConfirmed(context);
  await ensureCleanReleaseSource(context);
}

async function preflightFinalize(context: DeploymentContext): Promise<void> {
  await ensureChainId(context);
  ensureMainnetConfirmed(context);
}

async function ensureChainId(context: DeploymentContext): Promise<void> {
  const config = networkConfigs[context.network];
  const rpcUrl = requireEnvironment(context, config.rpcVariable);
  const actual = (await runProcess(context.executables.cast, ["chain-id", "--rpc-url", rpcUrl], {
    signal: context.signal,
  })).trim();
  if (actual !== String(config.chainId)) {
    throw new Error(`${context.network} RPC chain ID must be ${config.chainId}, got ${actual}`);
  }
}

function ensureMainnetConfirmed(context: DeploymentContext): void {
  if (context.network === "mainnet" && context.environment.CONFIRM_MAINNET !== "yes") {
    throw new Error("set CONFIRM_MAINNET=yes before operating on mainnet");
  }
}

async function ensureCleanReleaseSource(context: DeploymentContext): Promise<void> {
  const output = await runProcess(
    context.executables.git,
    ["-C", context.root, "status", "--porcelain", "--untracked-files=all", "--", ...releasePaths],
    { signal: context.signal },
  );
  if (output.length !== 0) {
    throw new Error(`deployment source is dirty under ${context.root}`);
  }
}

function canonicalManifestPath(context: DeploymentContext): string {
  return join(context.deploymentsRoot, context.network, "latest.json");
}

function prepareDeployDestination(context: DeploymentContext, fresh: boolean): string | null {
  const path = canonicalManifestPath(context);
  if (!fileExists(path)) {
    return null;
  }
  if (!fresh) {
    throw new Error(`canonical ${context.network} deployment already exists; pass --fresh`);
  }
  return hashRawBytes(readFileSync(path));
}

function refusePendingOperations(context: DeploymentContext): void {
  const pendingFiles = [
    { kind: "TypeScript", path: join(context.pendingRoot, context.network, "pending-deploy.json") },
    { kind: "TypeScript", path: join(context.pendingRoot, context.network, "pending-upgrade.json") },
    { kind: "Bash", path: join(context.bashPendingRoot, context.network, "pending-deploy.json") },
    { kind: "Bash", path: join(context.bashPendingRoot, context.network, "pending-upgrade.json") },
  ] as const;

  for (const pendingFile of pendingFiles) {
    if (readPendingStatus(pendingFile.path) === "pending") {
      throw new Error(`pending ${context.network} ${pendingFile.kind} operation already exists: ${pendingFile.path}`);
    }
  }
}

function readPendingStatus(path: string): unknown {
  if (!fileExists(path)) {
    return undefined;
  }
  let value: unknown;
  try {
    value = JSON.parse(readFileSync(path, "utf8")) as unknown;
  } catch {
    throw new Error(`pending operation JSON is invalid: ${path}`);
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`pending operation must be an object: ${path}`);
  }
  return (value as Record<string, unknown>).status;
}

async function buildDeployment(context: DeploymentContext, workspace: string, paths: DeployPaths): Promise<string> {
  const outputDirectory = join(workspace, "out");
  await runProcess(
    context.executables.forge,
    [
      "build",
      "--root",
      context.root,
      "--out",
      outputDirectory,
      "--cache-path",
      join(workspace, "cache"),
      "--build-info",
      "--extra-output",
      "storageLayout",
    ],
    { signal: context.signal },
  );

  const buildInfoDirectory = join(outputDirectory, "build-info");
  const buildInfoFiles = fileExists(buildInfoDirectory)
    ? readdirSync(buildInfoDirectory).filter((name) => name.endsWith(".json"))
    : [];
  if (buildInfoFiles.length !== 1) {
    throw new Error("Forge build must produce exactly one build-info JSON");
  }

  const buildInfoBytes = readFileSync(join(buildInfoDirectory, buildInfoFiles[0]));
  const buildInfoSha256 = hashRawBytes(buildInfoBytes);
  const compressedBuildInfo = gzipSync(buildInfoBytes, { level: 9 });
  mkdirSync(paths.pendingDirectory, { recursive: true });
  writeAtomicFile(paths.buildInfo, compressedBuildInfo);
  return buildInfoSha256;
}

function createPendingDeploy(
  context: DeploymentContext,
  previousManifestSha256: string | null,
  buildInfoSha256: string,
): PendingDeploy {
  return {
    status: "pending",
    operation: "deploy",
    network: context.network,
    chainId: networkConfigs[context.network].chainId,
    previousManifestSha256,
    release: { buildInfoSha256 },
    broadcastSha256: null,
    result: null,
    finalizedAt: null,
    resultManifestSha256: null,
  };
}

async function broadcastDeployment(
  context: DeploymentContext,
  workspace: string,
  paths: DeployPaths,
  privateKey: string,
  dependencies: DeploymentDependencies,
  buildInfoSha256: string,
): Promise<void> {
  const rpcUrl = requireEnvironment(context, networkConfigs[context.network].rpcVariable);
  const environment: NodeJS.ProcessEnv = {
    ...context.environment,
    RPC_URL: rpcUrl,
    PRIVATE_KEY: privateKey,
    FILECOIN_PAY: dependencies.filecoinPay,
    TERMINATION_ORACLE: dependencies.terminationOracle,
    ORACLE: dependencies.oracle,
    POREP_SERVICE: dependencies.porepService,
    META_ALLOCATOR: dependencies.metaAllocator,
    OPERATOR_ADDR: dependencies.operatorAddress,
    BUILD_INFO_SHA256: buildInfoSha256,
    DEPLOYMENT_OUTPUT: paths.pending,
    FOUNDRY_BROADCAST: join(workspace, "broadcast"),
  };

  await runProcess(
    context.executables.forge,
    [
      "script",
      "script/Deploy.s.sol:Deploy",
      "--root",
      context.root,
      "--broadcast",
      "--rpc-url",
      rpcUrl,
      "--private-key",
      privateKey,
      "--gas-estimate-multiplier",
      "100000",
      "--slow",
    ],
    { environment, signal: context.signal },
  );
}

function recordDeploymentBroadcast(
  context: DeploymentContext,
  workspace: string,
  paths: DeployPaths,
  expectedPending: PendingDeploy,
  dependencies: DeploymentDependencies,
): void {
  const source = locateDeploymentBroadcast(context, workspace);
  const broadcastBytes = readFileSync(source);
  writeAtomicFile(paths.broadcast, broadcastBytes);
  const broadcastSha256 = hashRawBytes(broadcastBytes);

  const mutatedPending = parsePendingOperation(readFileSync(paths.pending, "utf8"));
  if (mutatedPending.operation !== "deploy") {
    throw new Error("Forge deployment output changed pending.operation");
  }
  validateForgeDeployOutput(mutatedPending, expectedPending, dependencies);

  writePendingDeploy(paths.pending, { ...mutatedPending, broadcastSha256 });
}

function locateDeploymentBroadcast(context: DeploymentContext, workspace: string): string {
  const directory = join(
    workspace,
    "broadcast",
    "Deploy.s.sol",
    String(networkConfigs[context.network].chainId),
  );
  const candidates = fileExists(directory)
    ? readdirSync(directory).filter((name) => /^run-[0-9]+\.json$/.test(name))
    : [];
  if (candidates.length !== 1) {
    throw new Error("Forge must produce exactly one timestamped Forge broadcast file");
  }
  return join(directory, candidates[0]);
}

function validateForgeDeployOutput(
  actual: PendingDeploy,
  expected: PendingDeploy,
  dependencies: DeploymentDependencies,
): void {
  if (
    actual.status !== "pending" ||
    actual.network !== expected.network ||
    actual.chainId !== expected.chainId ||
    actual.previousManifestSha256 !== expected.previousManifestSha256 ||
    actual.release.buildInfoSha256 !== expected.release.buildInfoSha256 ||
    actual.broadcastSha256 !== null ||
    actual.finalizedAt !== null ||
    actual.resultManifestSha256 !== null
  ) {
    throw new Error("Forge deployment output changed pending recovery fields");
  }
  if (actual.result === null || actual.result.status !== "pending") {
    throw new Error("Forge did not write pending.result");
  }
  if (actual.result.release.buildInfoSha256 !== expected.release.buildInfoSha256) {
    throw new Error("Forge deployment output release differs from pending release");
  }

  const expectedDependencies: Record<string, string> = {
    FilecoinPay: dependencies.filecoinPay,
    TerminationOracle: dependencies.terminationOracle,
    Oracle: dependencies.oracle,
    PoRepService: dependencies.porepService,
    MetaAllocator: dependencies.metaAllocator,
    Operator: dependencies.operatorAddress,
  };
  for (const [name, address] of Object.entries(expectedDependencies)) {
    if (actual.result.externalDependencies[name]?.toLowerCase() !== address.toLowerCase()) {
      throw new Error(`Forge deployment output external dependency ${name} differs from the command environment`);
    }
  }
}

function loadPendingDeploy(context: DeploymentContext, paths: DeployPaths): PendingDeploy {
  if (!fileExists(paths.pending)) {
    throw new Error(`pending ${context.network} deployment does not exist: ${paths.pending}`);
  }
  const pending = parsePendingOperation(readFileSync(paths.pending, "utf8"));
  if (pending.operation !== "deploy") {
    throw new Error(`pending operation is not a deploy: ${paths.pending}`);
  }
  if (pending.network !== context.network || pending.chainId !== networkConfigs[context.network].chainId) {
    throw new Error(`pending deployment does not match ${context.network}`);
  }
  if (pending.broadcastSha256 === null) {
    throw new Error("pending.broadcastSha256 is missing post-broadcast evidence");
  }
  if (pending.result === null) {
    throw new Error("pending.result is missing post-broadcast evidence");
  }
  if (pending.result.release.buildInfoSha256 !== pending.release.buildInfoSha256) {
    throw new Error("pending.result.release differs from pending.release");
  }
  if (pending.status === "finalized" && (pending.finalizedAt === null || pending.resultManifestSha256 === null)) {
    throw new Error("finalized pending deployment is missing publication evidence");
  }
  if (pending.resultManifestSha256 === null) {
    if (pending.finalizedAt !== null || pending.result.transactions !== undefined) {
      throw new Error("pending deployment has incomplete publication evidence");
    }
  } else if (pending.finalizedAt === null || pending.result.transactions === undefined || pending.result.transactions.length === 0) {
    throw new Error("pending deployment is missing finalizedAt or transaction receipts");
  }
  return pending;
}

function authenticatePendingBuildInfo(path: string, expectedHash: string): void {
  if (!fileExists(path)) {
    throw new Error(`pending deployment build-info does not exist: ${path}`);
  }
  let rawBytes: Buffer;
  try {
    rawBytes = gunzipSync(readFileSync(path));
  } catch (error) {
    throw new Error(`pending deployment build-info is not valid gzip: ${path}`, { cause: error });
  }
  if (hashRawBytes(rawBytes) !== expectedHash) {
    throw new Error("pending deployment build-info hash does not match pending.release.buildInfoSha256");
  }
}

function authenticatePendingBroadcast(path: string, expectedHash: string | null): void {
  if (expectedHash === null) {
    throw new Error("pending.broadcastSha256 is missing post-broadcast evidence");
  }
  if (!fileExists(path)) {
    throw new Error(`pending deployment broadcast does not exist: ${path}`);
  }
  if (hashRawBytes(readFileSync(path)) !== expectedHash) {
    throw new Error("pending deployment broadcast hash does not match pending.broadcastSha256");
  }
}

async function collectDeployFinalizationEvidence(
  context: DeploymentContext,
  paths: DeployPaths,
  pending: PendingDeploy,
): Promise<PendingDeploy> {
  if (pending.result === null || pending.broadcastSha256 === null) {
    throw new Error("pending deployment is missing post-broadcast evidence");
  }
  const rpcUrl = requireEnvironment(context, networkConfigs[context.network].rpcVariable);
  const run = deploymentCommandRunner(context);
  const broadcastText = readFileSync(paths.broadcast, "utf8");
  const transactionHashes = extractBroadcastTransactionHashes(broadcastText);
  const receipts = await loadTransactionReceipts(run, rpcUrl, transactionHashes);
  await waitForFilecoinFinality(run, rpcUrl, receipts, { signal: context.signal });

  const result: DeploymentManifest = { ...pending.result, transactions: receipts };
  await verifyLiveDeployment(run, rpcUrl, result);

  const finalizedAt = pending.finalizedAt ?? new Date().toISOString();
  const pendingWithEvidence: PendingDeploy = {
    ...pending,
    result,
    finalizedAt,
    resultManifestSha256: pending.broadcastSha256,
  };
  const manifestBytes = renderDeployManifestBytes(pendingWithEvidence);
  const resultManifestSha256 = hashRawBytes(Buffer.from(manifestBytes));
  const completedPending = { ...pendingWithEvidence, resultManifestSha256 };
  writePendingDeploy(paths.pending, completedPending);
  return completedPending;
}

function deploymentCommandRunner(context: DeploymentContext): CommandRunner {
  return async (command, arguments_, options) => {
    if (command !== "cast") {
      throw new Error(`unsupported deployment command: ${command}`);
    }
    return runProcess(context.executables.cast, arguments_, {
      signal: options.signal ?? context.signal,
    });
  };
}

function renderDeployManifestBytes(pending: PendingDeploy): string {
  if (pending.finalizedAt === null) {
    throw new Error("pending.finalizedAt is missing publication evidence");
  }
  const manifest = renderDeployManifest(pending, pending.finalizedAt);
  return `${JSON.stringify(manifest, null, 2)}\n`;
}

function authenticateRenderedDeployManifest(pending: PendingDeploy): string {
  if (pending.resultManifestSha256 === null) {
    throw new Error("pending.resultManifestSha256 is missing publication evidence");
  }
  const manifestBytes = renderDeployManifestBytes(pending);
  if (hashRawBytes(Buffer.from(manifestBytes)) !== pending.resultManifestSha256) {
    throw new Error("rendered deployment manifest hash does not match pending.resultManifestSha256");
  }
  return manifestBytes;
}

function retainedBuildInfoPath(context: DeploymentContext, buildInfoSha256: string): string {
  return join(context.deploymentsRoot, context.network, "build-info", `${buildInfoSha256.slice(2)}.json.gz`);
}

function retainBuildInfo(context: DeploymentContext, source: string, buildInfoSha256: string): void {
  authenticatePendingBuildInfo(source, buildInfoSha256);
  const destination = retainedBuildInfoPath(context, buildInfoSha256);
  mkdirSync(dirname(destination), { recursive: true });
  if (fileExists(destination)) {
    authenticatePendingBuildInfo(destination, buildInfoSha256);
    return;
  }
  writeAtomicFile(destination, readFileSync(source));
}

function authenticateRetainedBuildInfo(context: DeploymentContext, buildInfoSha256: string): void {
  const path = retainedBuildInfoPath(context, buildInfoSha256);
  if (!fileExists(path)) {
    throw new Error(`published deployment build-info does not exist: ${path}`);
  }
  authenticatePendingBuildInfo(path, buildInfoSha256);
}

function markDeployFinalized(path: string, pending: PendingDeploy): void {
  if (pending.status === "finalized") {
    return;
  }
  writePendingDeploy(path, { ...pending, status: "finalized" });
}

function pruneBuildInfo(context: DeploymentContext, retainedHash: string): void {
  const directory = join(context.deploymentsRoot, context.network, "build-info");
  if (!fileExists(directory)) {
    return;
  }
  const retainedFilename = `${retainedHash.slice(2)}.json.gz`;
  for (const filename of readdirSync(directory)) {
    if (filename.endsWith(".json.gz") && filename !== retainedFilename) {
      rmSync(join(directory, filename), { force: true });
    }
  }
}

function hashFileIfPresent(path: string): string | undefined {
  return fileExists(path) ? hashRawBytes(readFileSync(path)) : undefined;
}

function writePendingDeploy(path: string, pending: PendingDeploy): void {
  writeAtomicFile(path, `${JSON.stringify(pending, null, 2)}\n`);
}

function ensureCanonicalManifest(context: DeploymentContext): void {
  const path = canonicalManifestPath(context);
  if (!fileExists(path)) {
    throw new Error(`canonical ${context.network} deployment does not exist: ${path}`);
  }
}

async function ensureCleanCanonicalManifest(context: DeploymentContext): Promise<void> {
  const path = canonicalManifestPath(context);
  const output = await runProcess(
    context.executables.git,
    ["-C", context.root, "status", "--porcelain", "--untracked-files=all", "--", path],
    { signal: context.signal },
  );
  if (output.length !== 0) {
    throw new Error(`canonical deployment manifest is not clean: ${path}`);
  }
}

function fileExists(path: string): boolean {
  return existsSync(path);
}

export async function runProcess(
  command: string,
  arguments_: readonly string[],
  options: { environment?: NodeJS.ProcessEnv; signal?: AbortSignal } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, arguments_, {
      env: options.environment,
      shell: false,
      signal: options.signal,
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let settled = false;

    const fail = (error: Error): void => {
      if (!settled) {
        settled = true;
        reject(error);
      }
    };

    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.once("error", (error) => fail(new Error(`could not run ${command}: ${error.message}`, { cause: error })));
    child.once("close", (code, signal) => {
      if (settled) return;
      if (code !== 0) {
        const details = Buffer.concat(stderr).toString("utf8").trim();
        fail(new Error(`${command} exited with code ${code ?? "unknown"}${signal === null ? "" : ` (${signal})`}${details === "" ? "" : `: ${details}`}`));
        return;
      }
      settled = true;
      resolve(Buffer.concat(stdout).toString("utf8"));
    });
  });
}

export function writeAtomicFile(path: string, content: string | Uint8Array): void {
  const temporaryPath = join(dirname(path), `.${randomUUID()}.tmp`);
  let fileDescriptor: number | undefined;
  try {
    fileDescriptor = openSync(temporaryPath, "wx", 0o600);
    if (typeof content === "string") {
      writeSync(fileDescriptor, content);
    } else {
      writeSync(fileDescriptor, content);
    }
    fsyncSync(fileDescriptor);
    closeSync(fileDescriptor);
    fileDescriptor = undefined;
    renameSync(temporaryPath, path);
  } catch (error) {
    try {
      if (fileDescriptor !== undefined) closeSync(fileDescriptor);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
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

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const signalHandling = installSignalHandling();
  void runDeploymentCli(process.argv.slice(2), signalHandling.signal)
    .catch((error: unknown) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    })
    .finally(signalHandling.dispose);
}

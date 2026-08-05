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
  classifyUpgradeCanonicalState,
  hashRawBytes,
  parseDeploymentManifest,
  parsePendingOperation,
  renderDeployManifest,
  renderPrepublicationUpgradedManifest,
  renderUpgradedManifest,
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
  claim: string;
  latest: string;
};

type UpgradePaths = DeployPaths;

type PreparedBuildInfo = {
  sha256: string;
  raw: Buffer;
  compressed: Buffer;
};

type OperationClaim = {
  path: string;
  fileDescriptor: number;
};

export type SignalHandling = {
  signal: AbortSignal;
  dispose: () => void;
};

const networks = Object.keys(networkConfigs) as Network[];
const usage = `Usage: deployment.ts <command> <network> [args...]\nCommands: ${commands.join(", ")}\nNetworks: ${networks.join(", ")}`;
const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const uupsUpgradeArtifacts: Record<string, string> = {
  PoRepMarket: "src/PoRepMarket.sol:PoRepMarket",
  ValidatorFactory: "src/ValidatorFactory.sol:ValidatorFactory",
  DataCapEvidenceAdapter: "src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter",
  SPRegistry: "src/SPRegistry.sol:SPRegistry",
  SLIOracle: "src/SLIOracle.sol:SLIOracle",
  SLIScorer: "src/SLIScorer.sol:SLIScorer",
};
const validatorArtifact = "src/Validator.sol:Validator";

async function deploy(context: DeploymentContext, fresh: boolean): Promise<void> {
  if (fresh && context.network === "mainnet") {
    throw new Error("fresh mainnet deployment is not supported");
  }
  const privateKey = requireEnvironment(context, networkConfigs[context.network].privateKeyVariable);
  const dependencies = loadDeploymentDependencies(context);
  const paths = deployPaths(context);

  await preflightBroadcast(context);
  const previousManifestSha256 = prepareDeployDestination(context, fresh);
  preparePendingOperations(context, paths, fresh);

  const workspace = mkdtempSync(join(tmpdir(), "porep-deploy-ts-"));
  let claim: OperationClaim | undefined;
  try {
    const buildInfo = await buildDeployment(context, workspace);
    const pending = createPendingDeploy(context, previousManifestSha256, buildInfo.sha256);
    claim = claimDeployOperation(context, paths, buildInfo, pending);

    let broadcastFailure: unknown;
    try {
      await broadcastDeployment(context, workspace, paths, privateKey, dependencies, buildInfo.sha256);
    } catch (error) {
      broadcastFailure = error;
    }

    let recordedPending: PendingDeploy | undefined;
    let evidenceFailure: unknown;
    try {
      recordedPending = preserveDeploymentBroadcast(context, workspace, paths, pending, dependencies);
      if (broadcastFailure === undefined && recordedPending === undefined) {
        throw new Error("Forge must produce exactly one timestamped Forge broadcast file");
      }
      if (broadcastFailure === undefined && recordedPending !== undefined) {
        validateForgeDeployResult(recordedPending, pending, dependencies);
      }
    } catch (error) {
      evidenceFailure = error;
    }

    if (broadcastFailure !== undefined) {
      if (evidenceFailure !== undefined) {
        throw new AggregateError(
          [broadcastFailure, evidenceFailure],
          "Forge failed and deployment broadcast evidence could not be recorded safely",
        );
      }
      throw broadcastFailure;
    }
    if (evidenceFailure !== undefined) {
      throw evidenceFailure;
    }
  } finally {
    if (claim !== undefined) {
      releaseOperationClaim(claim);
    }
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
  const privateKey = requireEnvironment(context, networkConfigs[context.network].privateKeyVariable);
  await preflightBroadcast(context);
  ensureCanonicalManifest(context);
  await ensureCleanCanonicalManifest(context);
  const paths = upgradePaths(context);
  const sourceBytes = readFileSync(paths.latest);
  const source = parseDeploymentManifest(sourceBytes.toString("utf8"));
  const sourceManifestSha256 = hashRawBytes(sourceBytes);
  validateUpgradeTargets(source, targets);
  prepareUpgradeOperation(context, paths);

  const previousBuildInfoPath = retainedBuildInfoPath(context, source.release.buildInfoSha256);
  authenticatePendingBuildInfo(previousBuildInfoPath, source.release.buildInfoSha256);

  const workspace = mkdtempSync(join(tmpdir(), "porep-upgrade-ts-"));
  const forgeIoDirectory = join(context.root, ".deployment", `.typescript-upgrade-${randomUUID()}`);
  let claim: OperationClaim | undefined;
  try {
    mkdirSync(forgeIoDirectory, { recursive: true });
    const exactSourceManifestPath = join(forgeIoDirectory, "source-manifest.json");
    const forgeOutputPath = join(forgeIoDirectory, "upgrade-output.json");
    writeAtomicFile(exactSourceManifestPath, sourceBytes);
    const buildInfo = await buildDeployment(context, workspace);
    await validateUpgradeStorageLayouts(
      context,
      paths.latest,
      source,
      previousBuildInfoPath,
      buildInfo,
      workspace,
    );
    const compiledCodeHashes = await loadCompiledUpgradeCodeHashes(context, buildInfo.raw, source, targets);
    await validateUpgradeAuthorization(context, source, targets, privateKey);
    rejectUnchangedUpgradeBytecode(source, compiledCodeHashes);
    if (hashFileIfPresent(paths.latest) !== sourceManifestSha256) {
      throw new Error(`canonical ${context.network} deployment changed during upgrade preflight`);
    }

    const pending = createPendingUpgrade(context, targets, sourceManifestSha256, buildInfo.sha256);
    claim = claimUpgradeOperation(context, paths, buildInfo, pending);
    writeAtomicFile(forgeOutputPath, `${JSON.stringify(pending, null, 2)}\n`);

    let broadcastFailure: unknown;
    try {
      await broadcastUpgrade(
        context,
        workspace,
        forgeOutputPath,
        exactSourceManifestPath,
        privateKey,
        targets,
      );
    } catch (error) {
      broadcastFailure = error;
    }

    let recordedPending: PendingUpgrade | undefined;
    let evidenceFailure: unknown;
    try {
      recordedPending = preserveUpgradeBroadcast(
        context,
        workspace,
        paths,
        forgeOutputPath,
        pending,
        source,
        compiledCodeHashes,
      );
      if (broadcastFailure === undefined && recordedPending === undefined) {
        throw new Error("Forge must produce exactly one timestamped Forge upgrade broadcast file");
      }
      if (recordedPending !== undefined && hashFileIfPresent(paths.latest) !== sourceManifestSha256) {
        throw new Error(`canonical ${context.network} deployment changed during upgrade broadcast`);
      }
    } catch (error) {
      evidenceFailure = error;
    }

    if (broadcastFailure !== undefined) {
      if (evidenceFailure !== undefined) {
        throw new AggregateError(
          [broadcastFailure, evidenceFailure],
          "Forge failed and upgrade broadcast evidence could not be recorded safely",
        );
      }
      throw broadcastFailure;
    }
    if (evidenceFailure !== undefined) {
      throw evidenceFailure;
    }
  } finally {
    if (claim !== undefined) {
      releaseOperationClaim(claim);
    }
    rmSync(workspace, { force: true, recursive: true });
    rmSync(forgeIoDirectory, { force: true, recursive: true });
  }

  await finalizeUpgrade(context, true);
}

async function finalizeUpgrade(context: DeploymentContext, preflightCompleted = false): Promise<void> {
  if (!preflightCompleted) {
    await preflightFinalize(context);
  }
  const paths = upgradePaths(context);
  let pending = loadPendingUpgrade(context, paths);

  authenticatePendingBuildInfo(paths.buildInfo, pending.release.buildInfoSha256);
  authenticatePendingBroadcast(paths.broadcast, pending.broadcastSha256);

  const canonicalHash = hashFileIfPresent(paths.latest);
  const canonicalState = classifyUpgradeCanonicalState(canonicalHash, pending);
  if (canonicalState === "unexpected") {
    throw new Error(`canonical ${context.network} deployment is unexpected during upgrade recovery`);
  }
  if (canonicalState === "result") {
    authenticateRetainedBuildInfo(context, pending.release.buildInfoSha256);
    markUpgradeFinalized(paths.pending, pending);
    return;
  }
  if (pending.status === "finalized") {
    throw new Error(`finalized ${context.network} upgrade manifest is missing`);
  }

  const sourceBytes = readFileSync(paths.latest);
  if (hashRawBytes(sourceBytes) !== pending.sourceManifestSha256) {
    throw new Error(`canonical ${context.network} deployment no longer matches pending upgrade source`);
  }
  const source = parseDeploymentManifest(sourceBytes.toString("utf8"));
  const previousBuildInfoPath = retainedBuildInfoPath(context, source.release.buildInfoSha256);
  authenticatePendingBuildInfo(previousBuildInfoPath, source.release.buildInfoSha256);
  const currentBuildInfo = loadAuthenticatedBuildInfo(paths.buildInfo, pending.release.buildInfoSha256);
  const compiledCodeHashes = await loadCompiledUpgradeCodeHashes(
    context,
    currentBuildInfo,
    source,
    pending.targets,
  );
  validateRecordedUpgradeOperations(source, pending, compiledCodeHashes);
  const manifestBytes = authenticateRenderedUpgradeManifest(source, pending);

  const rpcUrl = requireEnvironment(context, networkConfigs[context.network].rpcVariable);
  const run = deploymentCommandRunner(context);
  const transactionHashes = extractBroadcastTransactionHashes(readFileSync(paths.broadcast, "utf8"));
  const receipts = await loadTransactionReceipts(run, rpcUrl, transactionHashes);
  await waitForFilecoinFinality(run, rpcUrl, receipts, { signal: context.signal });
  await verifyLiveDeployment(run, rpcUrl, source, pending.operations);

  const preparedCanonicalHash = hashFileIfPresent(paths.latest);
  const preparedCanonicalState = classifyUpgradeCanonicalState(preparedCanonicalHash, pending);
  if (preparedCanonicalState === "unexpected") {
    throw new Error(`canonical ${context.network} deployment is unexpected during upgrade publication`);
  }
  if (preparedCanonicalState === "result") {
    authenticateRetainedBuildInfo(context, pending.release.buildInfoSha256);
  } else {
    retainBuildInfo(context, paths.buildInfo, pending.release.buildInfoSha256);
    writeAtomicFile(paths.latest, manifestBytes);
  }

  pending = { ...pending, status: "finalized" };
  writePendingUpgrade(paths.pending, pending);
  pruneBuildInfoExcept(context, [source.release.buildInfoSha256, pending.release.buildInfoSha256]);
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
    claim: join(pendingDirectory, "operation.claim"),
    latest: canonicalManifestPath(context),
  };
}

function upgradePaths(context: DeploymentContext): UpgradePaths {
  const pendingDirectory = join(context.pendingRoot, context.network);
  return {
    pendingDirectory,
    pending: join(pendingDirectory, "pending-upgrade.json"),
    buildInfo: join(pendingDirectory, "pending-upgrade.build-info.json.gz"),
    broadcast: join(pendingDirectory, "pending-upgrade.broadcast.json"),
    claim: join(pendingDirectory, "operation.claim"),
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

function preparePendingOperations(context: DeploymentContext, paths: DeployPaths, fresh: boolean): void {
  if (fileExists(paths.claim)) {
    throw new Error(`same-network operation claim already exists: ${paths.claim}`);
  }

  if (fresh && fileExists(paths.pending)) {
    if (isAuthenticatedTerminalJournal(context, "TypeScript", paths.pending)) {
      removeDeployRecoveryFiles(paths);
    } else if (isDiscardablePreBroadcastDeploy(context, paths)) {
      removeDeployRecoveryFiles(paths);
    }
  }

  assertNoBlockingOperationJournals(context);
}

function assertNoBlockingOperationJournals(context: DeploymentContext): void {
  const journals = [
    { kind: "TypeScript", path: join(context.pendingRoot, context.network, "pending-deploy.json") },
    { kind: "TypeScript", path: join(context.pendingRoot, context.network, "pending-upgrade.json") },
    { kind: "Bash", path: join(context.bashPendingRoot, context.network, "pending-deploy.json") },
    { kind: "Bash", path: join(context.bashPendingRoot, context.network, "pending-upgrade.json") },
  ] as const;

  for (const journal of journals) {
    if (fileExists(journal.path) && !isAuthenticatedTerminalJournal(context, journal.kind, journal.path)) {
      throw new Error(
        `pending ${context.network} ${journal.kind} operation already exists; ` +
          `journal is not an authenticated terminal state: ${journal.path}`,
      );
    }
  }
}

function isAuthenticatedTerminalJournal(
  context: DeploymentContext,
  kind: "TypeScript" | "Bash",
  path: string,
): boolean {
  try {
    if (kind === "Bash") {
      return isAuthenticatedBashTerminalJournal(context, path);
    }

    const pending = parsePendingOperation(readFileSync(path, "utf8"));
    if (
      pending.status !== "finalized" ||
      pending.network !== context.network ||
      pending.chainId !== networkConfigs[context.network].chainId ||
      pending.resultManifestSha256 === null ||
      hashFileIfPresent(canonicalManifestPath(context)) !== pending.resultManifestSha256
    ) {
      return false;
    }

    const evidence = journalEvidencePaths(path);
    authenticatePendingBuildInfo(evidence.buildInfo, pending.release.buildInfoSha256);
    authenticatePendingBroadcast(evidence.broadcast, pending.broadcastSha256);
    if (pending.operation === "deploy") {
      authenticateRenderedDeployManifest(pending);
    }
    return true;
  } catch {
    return false;
  }
}

function isAuthenticatedBashTerminalJournal(context: DeploymentContext, path: string): boolean {
  const value = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const journal = value as Record<string, unknown>;
  const resultHash = journal.resultManifestSha256;
  return (
    journal.status === "finalized" &&
    journal.network === context.network &&
    journal.chainId === networkConfigs[context.network].chainId &&
    typeof resultHash === "string" &&
    /^0x[0-9a-f]{64}$/.test(resultHash) &&
    hashFileIfPresent(canonicalManifestPath(context)) === resultHash
  );
}

function isDiscardablePreBroadcastDeploy(context: DeploymentContext, paths: DeployPaths): boolean {
  try {
    const pending = parsePendingOperation(readFileSync(paths.pending, "utf8"));
    if (
      pending.operation !== "deploy" ||
      pending.status !== "pending" ||
      pending.network !== context.network ||
      pending.chainId !== networkConfigs[context.network].chainId ||
      pending.broadcastSha256 !== null ||
      pending.result !== null ||
      pending.finalizedAt !== null ||
      pending.resultManifestSha256 !== null ||
      fileExists(paths.broadcast)
    ) {
      return false;
    }
    authenticatePendingBuildInfo(paths.buildInfo, pending.release.buildInfoSha256);
    return true;
  } catch {
    return false;
  }
}

function removeDeployRecoveryFiles(paths: DeployPaths): void {
  rmSync(paths.pending, { force: true });
  rmSync(paths.buildInfo, { force: true });
  rmSync(paths.broadcast, { force: true });
}

function journalEvidencePaths(path: string): { buildInfo: string; broadcast: string } {
  const prefix = path.slice(0, -".json".length);
  return {
    buildInfo: `${prefix}.build-info.json.gz`,
    broadcast: `${prefix}.broadcast.json`,
  };
}

async function buildDeployment(context: DeploymentContext, workspace: string): Promise<PreparedBuildInfo> {
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
  return {
    sha256: hashRawBytes(buildInfoBytes),
    raw: buildInfoBytes,
    compressed: gzipSync(buildInfoBytes, { level: 9 }),
  };
}

function validateUpgradeTargets(source: DeploymentManifest, targets: readonly string[]): void {
  if (source.status !== "finalized") {
    throw new Error("canonical deployment manifest must be finalized before upgrade");
  }
  const uniqueTargets = new Set<string>();
  for (const target of targets) {
    if (uniqueTargets.has(target)) {
      throw new Error(`duplicate upgrade target: ${target}`);
    }
    uniqueTargets.add(target);

    if (target === "Validator") {
      const validator = source.contracts.Validator;
      if (validator === undefined || validator.kind !== "implementation") {
        throw new Error("upgrade target Validator must have kind implementation");
      }
      if (validator.artifact !== validatorArtifact) {
        throw new Error(`upgrade target Validator artifact must be ${validatorArtifact}`);
      }
      const beacon = source.contracts.ValidatorBeacon;
      if (beacon === undefined || beacon.kind !== "beacon") {
        throw new Error("upgrade target Validator requires ValidatorBeacon with kind beacon");
      }
      continue;
    }

    const expectedArtifact = uupsUpgradeArtifacts[target];
    if (expectedArtifact === undefined) {
      throw new Error(`unsupported upgrade target: ${target}`);
    }
    const contract = source.contracts[target];
    if (contract === undefined || contract.kind !== "uups") {
      throw new Error(`upgrade target ${target} must have kind uups`);
    }
    if (contract.artifact !== expectedArtifact) {
      throw new Error(`upgrade target ${target} artifact must be ${expectedArtifact}`);
    }
  }
}

function prepareUpgradeOperation(context: DeploymentContext, paths: UpgradePaths): void {
  if (fileExists(paths.claim)) {
    throw new Error(`same-network operation claim already exists: ${paths.claim}`);
  }
  if (fileExists(paths.pending) && isAuthenticatedTerminalJournal(context, "TypeScript", paths.pending)) {
    removeUpgradeRecoveryFiles(paths);
  }
  assertNoBlockingOperationJournals(context);
}

function removeUpgradeRecoveryFiles(paths: UpgradePaths): void {
  rmSync(paths.pending, { force: true });
  rmSync(paths.buildInfo, { force: true });
  rmSync(paths.broadcast, { force: true });
}

async function validateUpgradeStorageLayouts(
  context: DeploymentContext,
  manifestPath: string,
  source: DeploymentManifest,
  previousBuildInfoPath: string,
  buildInfo: PreparedBuildInfo,
  workspace: string,
): Promise<void> {
  const currentBuildInfoPath = join(workspace, "current-build-info.json.gz");
  writeAtomicFile(currentBuildInfoPath, buildInfo.compressed);
  const storageTargets = Object.entries(source.contracts).flatMap(([name, contract]) => {
    if (contract.kind === "uups" || name === "Validator" && contract.kind === "implementation") {
      return [name];
    }
    return [];
  });
  if (storageTargets.length === 0) {
    throw new Error("canonical deployment has no upgradeable implementations for storage validation");
  }

  const arguments_ = ["--manifest", manifestPath];
  for (const target of storageTargets) {
    arguments_.push("--target", target);
  }
  arguments_.push(
    "--reference-build-info",
    previousBuildInfoPath,
    "--reference-sha256",
    source.release.buildInfoSha256,
    "--current-build-info",
    currentBuildInfoPath,
    "--current-sha256",
    buildInfo.sha256,
  );

  const executable = context.environment.STORAGE_VALIDATOR ?? join(context.root, "script", "validate-storage-layout.sh");
  try {
    await runProcess(executable, arguments_, { environment: context.environment, signal: context.signal });
  } catch (error) {
    throw new Error("storage validation failed", { cause: error });
  }
}

async function loadCompiledUpgradeCodeHashes(
  context: DeploymentContext,
  buildInfoBytes: Buffer,
  source: DeploymentManifest,
  targets: readonly string[],
): Promise<Map<string, string>> {
  let value: unknown;
  try {
    value = JSON.parse(buildInfoBytes.toString("utf8")) as unknown;
  } catch {
    throw new Error("current build-info JSON is invalid");
  }
  const hashes = new Map<string, string>();
  for (const target of targets) {
    const contract = source.contracts[target];
    if (contract === undefined) {
      throw new Error(`upgrade target ${target} is missing from source manifest`);
    }
    const bytecode = readBuildInfoDeployedBytecode(value, contract.artifact, target);
    const output = (await runProcess(context.executables.cast, ["keccak", bytecode], {
      signal: context.signal,
    })).trim();
    if (!/^0x[0-9a-f]{64}$/.test(output)) {
      throw new Error(`compiled implementation code hash for ${target} is invalid`);
    }
    hashes.set(target, output);
  }
  return hashes;
}

function readBuildInfoDeployedBytecode(value: unknown, artifact: string, target: string): string {
  const separator = artifact.lastIndexOf(":");
  if (separator <= 0 || separator === artifact.length - 1) {
    throw new Error(`manifest artifact for ${target} is invalid: ${artifact}`);
  }
  const sourceName = artifact.slice(0, separator);
  const contractName = artifact.slice(separator + 1);
  const buildInfo = readRecord(value, "build-info");
  const output = readRecord(buildInfo.output, "build-info.output");
  const contracts = readRecord(output.contracts, "build-info.output.contracts");
  const sourceContracts = readRecord(contracts[sourceName], `build-info output for ${sourceName}`);
  const contract = readRecord(sourceContracts[contractName], `build-info output for ${artifact}`);
  const evm = readRecord(contract.evm, `build-info output for ${artifact}.evm`);
  const deployedBytecode = readRecord(
    evm.deployedBytecode,
    `build-info output for ${artifact}.evm.deployedBytecode`,
  );
  const object = deployedBytecode.object;
  if (typeof object !== "string" || object.length === 0 || object.length % 2 !== 0 || !/^[0-9a-fA-F]+$/.test(object)) {
    throw new Error(`build-info deployed bytecode for ${target} is invalid`);
  }
  return `0x${object}`;
}

function readRecord(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${path} must be an object`);
  }
  return value as Record<string, unknown>;
}

async function validateUpgradeAuthorization(
  context: DeploymentContext,
  source: DeploymentManifest,
  targets: readonly string[],
  privateKey: string,
): Promise<void> {
  const rpcUrl = requireEnvironment(context, networkConfigs[context.network].rpcVariable);
  const deployer = readCommandAddress(
    await runProcess(context.executables.cast, ["wallet", "address", "--private-key", privateKey], {
      signal: context.signal,
    }),
    "upgrade deployer",
  );

  for (const target of targets) {
    if (target === "Validator") {
      const beacon = source.contracts.ValidatorBeacon;
      if (beacon === undefined || beacon.kind !== "beacon") {
        throw new Error("upgrade target Validator requires ValidatorBeacon with kind beacon");
      }
      const owner = readCommandAddress(
        await runProcess(
          context.executables.cast,
          ["call", beacon.address, "owner()(address)", "--rpc-url", rpcUrl],
          { signal: context.signal },
        ),
        "ValidatorBeacon owner",
      );
      if (owner !== deployer) {
        throw new Error(`${deployer} is not authorized to upgrade Validator`);
      }
      continue;
    }

    const contract = source.contracts[target];
    if (contract === undefined || contract.kind !== "uups") {
      throw new Error(`upgrade target ${target} must have kind uups`);
    }
    const role = (await runProcess(
      context.executables.cast,
      ["call", contract.proxy, "UPGRADER_ROLE()(bytes32)", "--rpc-url", rpcUrl],
      { signal: context.signal },
    )).trim();
    if (!/^0x[0-9a-fA-F]{64}$/.test(role)) {
      throw new Error(`${target} UPGRADER_ROLE is invalid`);
    }
    const authorized = (await runProcess(
      context.executables.cast,
      ["call", contract.proxy, "hasRole(bytes32,address)(bool)", role, deployer, "--rpc-url", rpcUrl],
      { signal: context.signal },
    )).trim();
    if (authorized !== "true") {
      throw new Error(`${deployer} is not authorized to upgrade ${target}`);
    }
  }
}

function readCommandAddress(output: string, label: string): string {
  const value = output.trim().toLowerCase();
  if (!/^0x[0-9a-f]{40}$/.test(value)) {
    throw new Error(`${label} is not an address`);
  }
  return value;
}

function rejectUnchangedUpgradeBytecode(
  source: DeploymentManifest,
  compiledCodeHashes: ReadonlyMap<string, string>,
): void {
  for (const [target, compiledCodeHash] of compiledCodeHashes) {
    const contract = source.contracts[target];
    if (contract === undefined || !("implementationCodeHash" in contract)) {
      throw new Error(`upgrade target ${target} has no implementation code hash`);
    }
    if (contract.implementationCodeHash === compiledCodeHash) {
      throw new Error(`compiled implementation for ${target} is unchanged`);
    }
  }
}

function createPendingUpgrade(
  context: DeploymentContext,
  targets: readonly string[],
  sourceManifestSha256: string,
  buildInfoSha256: string,
): PendingUpgrade {
  return {
    status: "pending",
    operation: "upgrade",
    network: context.network,
    chainId: networkConfigs[context.network].chainId,
    targets: [...targets],
    operations: [],
    sourceManifestSha256,
    resultManifestSha256: null,
    release: { buildInfoSha256 },
    broadcastSha256: null,
  };
}

function claimUpgradeOperation(
  context: DeploymentContext,
  paths: UpgradePaths,
  buildInfo: PreparedBuildInfo,
  pending: PendingUpgrade,
): OperationClaim {
  mkdirSync(paths.pendingDirectory, { recursive: true });
  let fileDescriptor: number;
  try {
    fileDescriptor = openSync(paths.claim, "wx", 0o600);
  } catch (error) {
    throw new Error(`could not acquire same-network operation claim: ${paths.claim}`, { cause: error });
  }

  const claim = { path: paths.claim, fileDescriptor };
  try {
    writeSync(fileDescriptor, `upgrade ${process.pid}\n`);
    fsyncSync(fileDescriptor);
    assertNoBlockingOperationJournals(context);
    writeAtomicFile(paths.buildInfo, buildInfo.compressed);
    writeExclusiveFile(paths.pending, `${JSON.stringify(pending, null, 2)}\n`);
    return claim;
  } catch (error) {
    releaseOperationClaim(claim);
    throw error;
  }
}

async function broadcastUpgrade(
  context: DeploymentContext,
  workspace: string,
  forgeOutputPath: string,
  sourceManifestPath: string,
  privateKey: string,
  targets: readonly string[],
): Promise<void> {
  const rpcUrl = requireEnvironment(context, networkConfigs[context.network].rpcVariable);
  const environment: NodeJS.ProcessEnv = {
    ...context.environment,
    RPC_URL: rpcUrl,
    PRIVATE_KEY: privateKey,
    UPGRADE_OUTPUT: forgeOutputPath,
    DEPLOYMENT_MANIFEST: sourceManifestPath,
    UPGRADE_CONTRACT_NAMES: targets.join(","),
    FOUNDRY_BROADCAST: join(workspace, "broadcast"),
  };
  await runProcess(
    context.executables.forge,
    [
      "script",
      "script/Upgrade.s.sol:Upgrade",
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

function preserveUpgradeBroadcast(
  context: DeploymentContext,
  workspace: string,
  paths: UpgradePaths,
  forgeOutputPath: string,
  expectedPending: PendingUpgrade,
  source: DeploymentManifest,
  compiledCodeHashes: ReadonlyMap<string, string>,
): PendingUpgrade | undefined {
  const broadcastSource = locateUpgradeBroadcast(context, workspace);
  if (broadcastSource === undefined) {
    return undefined;
  }
  const broadcastBytes = readFileSync(broadcastSource);
  writeAtomicFile(paths.broadcast, broadcastBytes);
  const broadcastSha256 = hashRawBytes(broadcastBytes);

  let mutatedPending: PendingUpgrade;
  try {
    const parsedPending = parsePendingOperation(readFileSync(forgeOutputPath, "utf8"));
    if (parsedPending.operation !== "upgrade") {
      throw new Error("Forge upgrade output changed pending.operation");
    }
    validateForgeUpgradeRecoveryFields(parsedPending, expectedPending);
    mutatedPending = { ...parsedPending, broadcastSha256 };
    validateRecordedUpgradeOperations(source, mutatedPending, compiledCodeHashes);
  } catch (error) {
    writePendingUpgrade(paths.pending, { ...expectedPending, broadcastSha256 });
    throw new Error("Forge upgrade output is invalid; broadcast evidence was preserved", { cause: error });
  }

  const manifest = renderPrepublicationUpgradedManifest(source, mutatedPending);
  const manifestBytes = `${JSON.stringify(manifest, null, 2)}\n`;
  const recordedPending = {
    ...mutatedPending,
    resultManifestSha256: hashRawBytes(Buffer.from(manifestBytes)),
  };
  writePendingUpgrade(paths.pending, recordedPending);
  return recordedPending;
}

function locateUpgradeBroadcast(context: DeploymentContext, workspace: string): string | undefined {
  const directory = join(
    workspace,
    "broadcast",
    "Upgrade.s.sol",
    String(networkConfigs[context.network].chainId),
  );
  const candidates = fileExists(directory)
    ? readdirSync(directory).filter((name) => /^run-[0-9]+\.json$/.test(name))
    : [];
  if (candidates.length === 0) {
    return undefined;
  }
  if (candidates.length !== 1) {
    throw new Error("Forge must produce exactly one timestamped Forge upgrade broadcast file");
  }
  return join(directory, candidates[0]);
}

function validateForgeUpgradeRecoveryFields(actual: PendingUpgrade, expected: PendingUpgrade): void {
  if (
    actual.status !== "pending" ||
    actual.network !== expected.network ||
    actual.chainId !== expected.chainId ||
    actual.sourceManifestSha256 !== expected.sourceManifestSha256 ||
    actual.release.buildInfoSha256 !== expected.release.buildInfoSha256 ||
    actual.broadcastSha256 !== null ||
    actual.resultManifestSha256 !== null ||
    actual.targets.length !== expected.targets.length ||
    actual.targets.some((target, index) => target !== expected.targets[index])
  ) {
    throw new Error("Forge upgrade output changed pending recovery fields");
  }
}

function validateRecordedUpgradeOperations(
  source: DeploymentManifest,
  pending: PendingUpgrade,
  compiledCodeHashes: ReadonlyMap<string, string>,
): void {
  if (pending.operations.length === 0) {
    throw new Error("pending upgrade has no completed operations");
  }
  if (pending.operations.length !== pending.targets.length) {
    throw new Error("pending upgrade operations do not match requested targets");
  }
  for (const [index, operation] of pending.operations.entries()) {
    const target = pending.targets[index];
    if (operation.target !== target) {
      throw new Error(`pending upgrade operation ${index} does not match requested target ${target}`);
    }
    const expectedKind = target === "Validator" ? "beacon" : "uups";
    if (operation.kind !== expectedKind) {
      throw new Error(`pending upgrade operation for ${target} must have kind ${expectedKind}`);
    }
    const expectedHash = compiledCodeHashes.get(target);
    if (expectedHash === undefined || operation.newImplementationCodeHash !== expectedHash) {
      throw new Error(`pending upgrade operation code hash for ${target} does not match current build-info`);
    }
  }
  renderPrepublicationUpgradedManifest(source, pending);
}

function claimDeployOperation(
  context: DeploymentContext,
  paths: DeployPaths,
  buildInfo: PreparedBuildInfo,
  pending: PendingDeploy,
): OperationClaim {
  mkdirSync(paths.pendingDirectory, { recursive: true });
  let fileDescriptor: number;
  try {
    fileDescriptor = openSync(paths.claim, "wx", 0o600);
  } catch (error) {
    throw new Error(`could not acquire same-network operation claim: ${paths.claim}`, { cause: error });
  }

  const claim = { path: paths.claim, fileDescriptor };
  try {
    writeSync(fileDescriptor, `deploy ${process.pid}\n`);
    fsyncSync(fileDescriptor);
    assertNoBlockingOperationJournals(context);
    writeAtomicFile(paths.buildInfo, buildInfo.compressed);
    writeExclusiveFile(paths.pending, `${JSON.stringify(pending, null, 2)}\n`);
    return claim;
  } catch (error) {
    releaseOperationClaim(claim);
    throw error;
  }
}

function releaseOperationClaim(claim: OperationClaim): void {
  closeSync(claim.fileDescriptor);
  rmSync(claim.path, { force: true });
}

function writeExclusiveFile(path: string, content: string): void {
  let fileDescriptor: number | undefined;
  try {
    fileDescriptor = openSync(path, "wx", 0o600);
    writeSync(fileDescriptor, content);
    fsyncSync(fileDescriptor);
    closeSync(fileDescriptor);
    fileDescriptor = undefined;
  } catch (error) {
    if (fileDescriptor !== undefined) {
      closeSync(fileDescriptor);
    }
    throw new Error(`could not create deployment operation journal exclusively: ${path}`, { cause: error });
  }
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

function preserveDeploymentBroadcast(
  context: DeploymentContext,
  workspace: string,
  paths: DeployPaths,
  expectedPending: PendingDeploy,
  dependencies: DeploymentDependencies,
): PendingDeploy | undefined {
  const source = locateDeploymentBroadcast(context, workspace);
  if (source === undefined) {
    return undefined;
  }
  const broadcastBytes = readFileSync(source);
  writeAtomicFile(paths.broadcast, broadcastBytes);
  const broadcastSha256 = hashRawBytes(broadcastBytes);

  let mutatedPending: PendingDeploy;
  try {
    const parsedPending = parsePendingOperation(readFileSync(paths.pending, "utf8"));
    if (parsedPending.operation !== "deploy") {
      throw new Error("Forge deployment output changed pending.operation");
    }
    validateForgeRecoveryFields(parsedPending, expectedPending);
    if (parsedPending.result !== null) {
      validateForgeDeployResult(parsedPending, expectedPending, dependencies);
    }
    mutatedPending = parsedPending;
  } catch (error) {
    writePendingDeploy(paths.pending, { ...expectedPending, broadcastSha256 });
    throw new Error("Forge deployment output is invalid; broadcast evidence was preserved", { cause: error });
  }

  const recordedPending = { ...mutatedPending, broadcastSha256 };
  writePendingDeploy(paths.pending, recordedPending);
  return recordedPending;
}

function locateDeploymentBroadcast(context: DeploymentContext, workspace: string): string | undefined {
  const directory = join(
    workspace,
    "broadcast",
    "Deploy.s.sol",
    String(networkConfigs[context.network].chainId),
  );
  const candidates = fileExists(directory)
    ? readdirSync(directory).filter((name) => /^run-[0-9]+\.json$/.test(name))
    : [];
  if (candidates.length === 0) {
    return undefined;
  }
  if (candidates.length !== 1) {
    throw new Error("Forge must produce exactly one timestamped Forge broadcast file");
  }
  return join(directory, candidates[0]);
}

function validateForgeRecoveryFields(actual: PendingDeploy, expected: PendingDeploy): void {
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
}

function validateForgeDeployResult(
  actual: PendingDeploy,
  expected: PendingDeploy,
  dependencies: DeploymentDependencies,
): void {
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

function loadPendingUpgrade(context: DeploymentContext, paths: UpgradePaths): PendingUpgrade {
  if (!fileExists(paths.pending)) {
    throw new Error(`pending ${context.network} upgrade does not exist: ${paths.pending}`);
  }
  const pending = parsePendingOperation(readFileSync(paths.pending, "utf8"));
  if (pending.operation !== "upgrade") {
    throw new Error(`pending operation is not an upgrade: ${paths.pending}`);
  }
  if (pending.network !== context.network || pending.chainId !== networkConfigs[context.network].chainId) {
    throw new Error(`pending upgrade does not match ${context.network}`);
  }
  if (pending.broadcastSha256 === null) {
    throw new Error("pending.broadcastSha256 is missing post-broadcast evidence");
  }
  if (pending.operations.length === 0) {
    throw new Error("pending upgrade has no completed operations");
  }
  if (pending.resultManifestSha256 === null) {
    throw new Error("pending.resultManifestSha256 is missing post-broadcast evidence");
  }
  return pending;
}

function authenticatePendingBuildInfo(path: string, expectedHash: string): void {
  void loadAuthenticatedBuildInfo(path, expectedHash);
}

function loadAuthenticatedBuildInfo(path: string, expectedHash: string): Buffer {
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
  return rawBytes;
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
  };
  const manifestBytes = renderPrepublicationDeployManifestBytes(pendingWithEvidence);
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

function renderPrepublicationDeployManifestBytes(pending: PendingDeploy): string {
  if (pending.broadcastSha256 === null || pending.result === null || pending.finalizedAt === null) {
    throw new Error("pending deployment is missing pre-publication evidence");
  }
  const result = structuredClone(pending.result);
  const manifest: DeploymentManifest = {
    ...result,
    status: "finalized",
    finalizedAt: pending.finalizedAt,
    transactions: result.transactions ?? [],
  };
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

function authenticateRenderedUpgradeManifest(source: DeploymentManifest, pending: PendingUpgrade): string {
  if (pending.resultManifestSha256 === null) {
    throw new Error("pending.resultManifestSha256 is missing publication evidence");
  }
  const manifest = renderUpgradedManifest(source, pending);
  const manifestBytes = `${JSON.stringify(manifest, null, 2)}\n`;
  if (hashRawBytes(Buffer.from(manifestBytes)) !== pending.resultManifestSha256) {
    throw new Error("rendered upgrade manifest hash does not match pending.resultManifestSha256");
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
  pruneBuildInfoExcept(context, [retainedHash]);
}

function pruneBuildInfoExcept(context: DeploymentContext, retainedHashes: readonly string[]): void {
  const directory = join(context.deploymentsRoot, context.network, "build-info");
  if (!fileExists(directory)) {
    return;
  }
  const retainedFilenames = new Set(retainedHashes.map((hash) => `${hash.slice(2)}.json.gz`));
  for (const filename of readdirSync(directory)) {
    if (filename.endsWith(".json.gz") && !retainedFilenames.has(filename)) {
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

function writePendingUpgrade(path: string, pending: PendingUpgrade): void {
  writeAtomicFile(path, `${JSON.stringify(pending, null, 2)}\n`);
}

function markUpgradeFinalized(path: string, pending: PendingUpgrade): void {
  if (pending.status === "finalized") {
    return;
  }
  writePendingUpgrade(path, { ...pending, status: "finalized" });
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
    let pendingError: Error | undefined;

    const fail = (error: Error): void => {
      if (!settled) {
        settled = true;
        reject(error);
      }
    };

    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.once("error", (error) => {
      const processError = new Error(`could not run ${command}: ${error.message}`, { cause: error });
      if (child.pid === undefined) {
        fail(processError);
        return;
      }
      pendingError = processError;
    });
    child.once("close", (code, signal) => {
      if (settled) return;
      if (pendingError !== undefined) {
        fail(pendingError);
        return;
      }
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

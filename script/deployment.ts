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
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, gzipSync } from "node:zlib";
import {
  classifyDeployCanonicalState,
  classifyUpgradeCanonicalState,
  hashRawBytes,
  parseDeploymentManifest,
  parsePendingOperation,
  parseUpgradeOperations,
  renderUpgradedManifest,
  type DeploymentManifest,
  type DeploymentTransaction,
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
import { confirmBlockscoutSource, confirmSourcifySource, verifyContractSources } from "./deployment-sources.ts";

const commands = [
  "deploy",
  "finalize-deploy",
  "deploy-missing",
  "configure-payment-tokens",
  "deploy-calibnet-adapter",
  "upgrade",
  "finalize-upgrade",
  "check-live",
  "verify-sources",
] as const;
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
    paymentTokens: [],
  },
  calibnet: {
    chainId: 314159,
    rpcVariable: "RPC_CALIBNET",
    privateKeyVariable: "PRIVATE_KEY_CALIBNET",
    environmentSuffix: "CALIBNET",
    verifierUrl: "https://filecoin-testnet.blockscout.com/api/",
    paymentTokens: [{ name: "USDFC", address: "0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0" }],
  },
  mainnet: {
    chainId: 314,
    rpcVariable: "RPC_MAINNET",
    privateKeyVariable: "PRIVATE_KEY_MAINNET",
    environmentSuffix: "MAINNET",
    verifierUrl: "https://filecoin.blockscout.com/api/",
    paymentTokens: [
      { name: "USDFC", address: "0x80B98d3aa09ffff255c3ba4A241111Ff1262F045" },
      { name: "AxlUSDC", address: "0xEB466342C4d449BC9f53A865D5Cb90586f405215" },
    ],
  },
} as const;

type Network = keyof typeof networkConfigs;
type Command = (typeof commands)[number];
type PaymentToken = { name: "USDFC" | "AxlUSDC"; address: string };
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
  gzip: Buffer;
  outputDirectory: string;
  cacheDirectory: string;
};
type DeployOptions = {
  fresh: boolean;
  confirmMainnetReplacement: boolean;
};
type UpgradeVariant = "standard" | "calibnet-adapter";

type DeploymentDependencies = Record<string, string> & {
  FilecoinPay: string;
  TerminationOracle: string;
  Oracle: string;
  PoRepService: string;
  MetaAllocator: string;
  Operator: string;
  USDFC?: string;
  AxlUSDC?: string;
};

export type SignalHandling = { signal: AbortSignal; dispose: () => void };

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const zeroAddress = `0x${"0".repeat(40)}`;
const calibnetAdapterArtifact = "src/CalibnetDataCapAdapter.sol:CalibnetDataCapAdapter";
const networks = Object.keys(networkConfigs) as Network[];
const usage = `Usage: deployment.ts <command> <network> [args...]\nCommands: ${commands.join(", ")}\nNetworks: ${networks.join(", ")}`;
const upgradeTargets: Record<
  string,
  {
    artifact: string;
    manifestKind: "uups" | "implementation";
    operationKind: "uups" | "beacon";
  }
> = {
  PoRepMarket: { artifact: "src/PoRepMarket.sol:PoRepMarket", manifestKind: "uups", operationKind: "uups" },
  ValidatorFactory: {
    artifact: "src/ValidatorFactory.sol:ValidatorFactory",
    manifestKind: "uups",
    operationKind: "uups",
  },
  DataCapEvidenceAdapter: {
    artifact: "src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter",
    manifestKind: "uups",
    operationKind: "uups",
  },
  SPRegistry: { artifact: "src/SPRegistry.sol:SPRegistry", manifestKind: "uups", operationKind: "uups" },
  SLIOracle: { artifact: "src/SLIOracle.sol:SLIOracle", manifestKind: "uups", operationKind: "uups" },
  SLIScorer: { artifact: "src/SLIScorer.sol:SLIScorer", manifestKind: "uups", operationKind: "uups" },
  Validator: { artifact: "src/Validator.sol:Validator", manifestKind: "implementation", operationKind: "beacon" },
};
const missingHelperArtifacts = {
  PoRepMarketSectorStatusInspector: "src/helpers/PoRepMarketSectorStatusInspector.sol:PoRepMarketSectorStatusInspector",
  PoRepMarketViewHelper: "src/helpers/PoRepMarketViewHelper.sol:PoRepMarketViewHelper",
} as const;
async function deploy(context: Context, options: DeployOptions): Promise<void> {
  if (
    context.network === "mainnet" &&
    options.fresh &&
    existsSync(canonicalManifestPath(context)) &&
    !options.confirmMainnetReplacement
  ) {
    throw new Error("pass --confirm-replace-mainnet-manifest to replace the mainnet deployment manifest");
  }
  const privateKey = required(context, networkConfigs[context.network].privateKeyVariable);
  const dependencies = deploymentDependencies(context);

  phase("Deployment preflight");
  await broadcastPreflight(context);
  ensureNoPendingOperation(context);
  const previousHash = prepareDeploy(context, options.fresh);

  const workspace = mkdtempSync(join(tmpdir(), "porep-deploy-ts-"));
  const forgeIoDirectory = join(context.root, ".deployment", `.typescript-deploy-${randomUUID()}`);
  try {
    mkdirSync(forgeIoDirectory, { recursive: true });
    phase("Build contracts");
    const build = await buildContracts(context, workspace);
    ensureNoPendingOperation(context);
    const pending = newPendingDeploy(context, previousHash, build.hash);
    const output = join(forgeIoDirectory, "deploy-output.json");
    writeAtomicFile(output, json(pending));
    retainPendingStart(operationPaths(context, "deploy"), build.gzip, pending);

    let forgeError: unknown;
    try {
      phase("Broadcast deployment");
      await runDeployScript(context, workspace, output, build, privateKey, dependencies);
    } catch (error) {
      forgeError = error;
    }

    const recorded = recordDeploy(context, workspace, output, build, pending, dependencies);
    if (forgeError !== undefined) throw forgeError;
    if (!recorded) throw new Error("Forge did not produce complete deployment evidence");
  } finally {
    rmSync(workspace, { recursive: true, force: true });
    rmSync(forgeIoDirectory, { recursive: true, force: true });
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
    await verifyPublishedSources(context);
    return;
  }
  if (pending.status === "finalized") throw new Error("finalized deployment manifest is missing");

  const rpcUrl = rpc(context);
  phase("Confirm transactions and Filecoin finality");
  const receipts = await finalizedReceipts(context, paths.broadcast, rpcUrl);
  const manifest: DeploymentManifest = {
    ...pending.result!,
    status: "finalized",
    finalizedAt: pending.finalizedAt ?? new Date().toISOString(),
    transactions: mergeTransactions(pending.result!.transactions, receipts),
  };
  phase("Check live deployment");
  await verifyLiveDeployment(
    commandRunner(context),
    rpcUrl,
    manifest,
    [],
    pending.expectedManagerRoles ?? undefined,
  );

  const manifestBytes = json(manifest);
  pending = {
    ...pending,
    result: manifest,
    finalizedAt: manifest.finalizedAt!,
    resultManifestSha256: hashRawBytes(Buffer.from(manifestBytes)),
  };
  writeAtomicFile(paths.pending, json(pending));
  phase("Publish deployment manifest");
  publish(context, paths, pending.release.buildInfoSha256, manifestBytes);
  finishPending(paths.pending, pending);
  await verifyPublishedSources(context);
}

async function deployMissing(context: Context): Promise<void> {
  const privateKey = required(context, networkConfigs[context.network].privateKeyVariable);
  phase("Missing-contract deployment preflight");
  await broadcastPreflight(context);
  ensureNoPendingOperation(context);

  const paths = operationPaths(context, "deploy");
  ensureFile(paths.latest, `canonical ${context.network} deployment`);
  await ensureCleanCanonicalManifest(context);
  const sourceBytes = readFileSync(paths.latest);
  const source = parseDeploymentManifest(sourceBytes.toString("utf8"));
  ensureHelpersAreMissing(source);
  const sourceHash = hashRawBytes(sourceBytes);

  const workspace = mkdtempSync(join(tmpdir(), "porep-deploy-missing-ts-"));
  const forgeIoDirectory = join(context.root, ".deployment", `.typescript-deploy-missing-${randomUUID()}`);
  try {
    mkdirSync(forgeIoDirectory, { recursive: true });
    phase("Build contracts");
    const build = await buildContracts(context, workspace);

    phase("Validate storage layouts");
    await validateStorage(context, source, build, workspace);
    await ensureCleanReleaseSource(context);
    if (hashFile(paths.latest) !== sourceHash) {
      throw new Error("canonical manifest changed during missing-contract preflight");
    }
    ensureNoPendingOperation(context);

    const pending = newPendingDeploy(context, sourceHash, build.hash);
    const sourcePath = join(forgeIoDirectory, "source.json");
    const output = join(forgeIoDirectory, "deploy-missing-output.json");
    writeAtomicFile(sourcePath, sourceBytes);
    writeAtomicFile(output, sourceBytes);
    retainPendingStart(paths, build.gzip, pending);

    let forgeError: unknown;
    try {
      phase("Broadcast missing contracts");
      await runDeployMissingScript(context, workspace, sourcePath, output, build, privateKey);
    } catch (error) {
      forgeError = error;
    }

    const recorded = recordDeployMissing(context, workspace, output, build, pending, source);
    if (forgeError !== undefined) throw forgeError;
    if (!recorded) throw new Error("Forge did not produce complete missing-contract deployment evidence");
  } finally {
    rmSync(workspace, { recursive: true, force: true });
    rmSync(forgeIoDirectory, { recursive: true, force: true });
  }

  await finalizeDeploy(context, true);
}

async function configurePaymentTokens(context: Context): Promise<void> {
  const policy = paymentTokenPolicy(context);
  if (policy.length === 0) throw new Error(`no payment tokens are defined for ${context.network}`);

  const privateKey = required(context, networkConfigs[context.network].privateKeyVariable);
  phase("Payment-token configuration preflight");
  await broadcastPreflight(context);
  ensureNoPendingOperation(context);

  const path = canonicalManifestPath(context);
  ensureFile(path, `canonical ${context.network} deployment`);
  await ensureCleanCanonicalManifest(context);
  const sourceBytes = readFileSync(path);
  const source = parseDeploymentManifest(sourceBytes.toString("utf8"));
  if (source.status !== "finalized") throw new Error("canonical manifest must be finalized");
  const registry = spRegistryProxy(source);

  for (const token of policy) await ensureTokenHasCode(context, token);
  const needsBroadcast = (
    await Promise.all(policy.map((token) => paymentTokenIsConfigured(context, registry, token.address)))
  ).some((configured) => !configured);

  let receipts: DeploymentTransaction[] = [];
  if (needsBroadcast) {
    console.error(`SPRegistry: ${registry}`);
    for (const token of policy) console.error(`  ${token.name}: ${token.address}, allowed=true, minimum=1`);

    const workspace = mkdtempSync(join(tmpdir(), "porep-configure-payment-tokens-"));
    try {
      phase("Broadcast payment-token configuration");
      await runConfigurePaymentTokensScript(context, workspace, registry, privateKey, policy);
      const broadcast = findBroadcast(context, workspace, "ConfigurePaymentTokens.s.sol");
      if (broadcast === undefined) throw new Error("Forge did not produce payment-token broadcast evidence");
      phase("Confirm transactions and Filecoin finality");
      receipts = await finalizedReceipts(context, broadcast, rpc(context));
    } finally {
      rmSync(workspace, { recursive: true, force: true });
    }
  }

  for (const token of policy) {
    if (!(await paymentTokenIsConfigured(context, registry, token.address))) {
      throw new Error(`${token.name} payment-token configuration did not match after broadcast`);
    }
  }

  const result = applyPaymentTokenPolicy(source, policy, receipts);
  const resultBytes = json(result);
  if (resultBytes !== sourceBytes.toString("utf8")) {
    phase("Update deployment manifest");
    writeAtomicFile(path, resultBytes);
  }
  console.error(needsBroadcast ? "Payment tokens configured" : "Payment tokens already configured");
}

async function upgrade(
  context: Context,
  targets: readonly string[],
  variant: UpgradeVariant = "standard",
): Promise<void> {
  if (variant === "calibnet-adapter" && context.network !== "calibnet") {
    throw new Error("CalibnetDataCapAdapter can only be deployed on calibnet");
  }
  const privateKey = required(context, networkConfigs[context.network].privateKeyVariable);
  phase("Upgrade preflight");
  await broadcastPreflight(context);
  ensureNoPendingOperation(context);

  const paths = operationPaths(context, "upgrade");
  ensureFile(paths.latest, `canonical ${context.network} deployment`);
  await ensureCleanCanonicalManifest(context);
  const sourceBytes = readFileSync(paths.latest);
  const source = parseDeploymentManifest(sourceBytes.toString("utf8"));
  const sourceHash = hashRawBytes(sourceBytes);
  validateTargets(source, targets);
  if (variant === "calibnet-adapter") validateCalibnetAdapterTarget(source, targets);

  const workspace = mkdtempSync(join(tmpdir(), "porep-upgrade-ts-"));
  const forgeIoDirectory = join(context.root, ".deployment", `.typescript-upgrade-${randomUUID()}`);
  try {
    mkdirSync(forgeIoDirectory, { recursive: true });
    phase("Build contracts");
    const build = await buildContracts(context, workspace);
    if (build.hash === source.release.buildInfoSha256) {
      throw new Error("current build matches the deployed release; nothing to upgrade");
    }
    phase("Validate storage layouts");
    await validateStorage(context, source, build, workspace);

    await ensureCleanReleaseSource(context);
    if (hashFile(paths.latest) !== sourceHash) throw new Error("canonical manifest changed during upgrade preflight");
    ensureNoPendingOperation(context);

    const pending = newPendingUpgrade(context, targets, sourceHash, build.hash);
    const sourcePath = join(forgeIoDirectory, "source.json");
    const output = join(forgeIoDirectory, "upgrade-output.json");
    writeAtomicFile(sourcePath, sourceBytes);
    writeAtomicFile(output, json(pending));
    retainPendingStart(operationPaths(context, "upgrade"), build.gzip, pending);

    let forgeError: unknown;
    try {
      phase("Broadcast upgrade");
      if (variant === "calibnet-adapter") {
        await runCalibnetAdapterScript(context, workspace, sourcePath, output, build, privateKey);
      } else {
        await runUpgradeScript(context, workspace, sourcePath, output, build, privateKey, targets);
      }
    } catch (error) {
      forgeError = error;
    }

    const recorded = recordUpgrade(context, workspace, output, build, pending, variant);
    if (forgeError !== undefined) throw forgeError;
    if (!recorded) throw new Error("Forge did not produce complete upgrade evidence");
  } finally {
    rmSync(workspace, { recursive: true, force: true });
    rmSync(forgeIoDirectory, { recursive: true, force: true });
  }

  await finalizeUpgrade(context, true);
}

async function finalizeUpgrade(context: Context, preflightDone = false): Promise<void> {
  if (!preflightDone) await finalizePreflight(context);
  const paths = operationPaths(context, "upgrade");
  let pending = readUpgradePending(context, paths);
  authenticateEvidence(paths, pending.release.buildInfoSha256, pending.broadcastSha256);

  const state = classifyUpgradeCanonicalState(hashFile(paths.latest), pending);
  if (state === "unexpected") throw new Error("canonical manifest does not match pending upgrade");
  if (state === "result") {
    finishPending(paths.pending, pending);
    pruneBuildInfo(context, pending.release.buildInfoSha256);
    await verifyPublishedSources(context);
    return;
  }
  if (pending.status === "finalized") throw new Error("finalized upgrade manifest is missing");

  const source = parseDeploymentManifest(readFileSync(paths.latest, "utf8"));
  const rpcUrl = rpc(context);
  phase("Confirm transactions and Filecoin finality");
  const receipts = await finalizedReceipts(context, paths.broadcast, rpcUrl);
  phase("Check live deployment");
  await verifyLiveDeployment(commandRunner(context), rpcUrl, source, pending.operations);

  const finalizedAt = pending.finalizedAt ?? new Date().toISOString();
  const manifestBytes = json(renderUpgradedManifest(source, pending, receipts, finalizedAt));
  pending = {
    ...pending,
    finalizedAt,
    resultManifestSha256: hashRawBytes(Buffer.from(manifestBytes)),
  };
  writeAtomicFile(paths.pending, json(pending));
  phase("Publish upgrade manifest");
  publish(context, paths, pending.release.buildInfoSha256, manifestBytes);
  finishPending(paths.pending, pending);
  await verifyPublishedSources(context);
}

async function checkLive(context: Context): Promise<void> {
  await ensureChainId(context);
  const path = canonicalManifestPath(context);
  ensureFile(path, `canonical ${context.network} deployment`);
  const manifest = parseDeploymentManifest(readFileSync(path, "utf8"));
  await verifyLiveDeployment(commandRunner(context), rpc(context), manifest);
}

async function verifySources(context: Context): Promise<void> {
  await ensureChainId(context);
  const config = networkConfigs[context.network];
  if (!("verifierUrl" in config)) {
    console.error("DevNet has no Blockscout verifier; skipping source verification");
    return;
  }
  const path = canonicalManifestPath(context);
  ensureFile(path, `canonical ${context.network} deployment`);
  const manifest = parseDeploymentManifest(readFileSync(path, "utf8"));
  phase("Verify contract sources");
  await verifyContractSources(manifest, {
    chainId: config.chainId,
    root: context.root,
    rpcUrl: rpc(context),
    verifierUrl: config.verifierUrl,
    confirmVerified: (target) =>
      target.verifier === "blockscout"
        ? confirmBlockscoutSource(config.verifierUrl, target)
        : confirmSourcifySource(config.chainId, target),
    runForge: async (args) => {
      await runProcess(context.forge, args, {
        environment: context.environment,
        signal: context.signal,
        terminal: true,
      });
    },
  });
  printContractAddresses(manifest);
}

async function verifyPublishedSources(context: Context): Promise<void> {
  try {
    await verifySources(context);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(
      `deployment is finalized and published, but source verification failed: ${message}\n` +
        `Retry with: just verify ${context.network}`,
      { cause: error },
    );
  }
}

function phase(message: string): void {
  console.error(`\n== ${message} ==`);
}

function printContractAddresses(manifest: DeploymentManifest): void {
  console.error("Deployed contract addresses:");
  for (const [name, contract] of Object.entries(manifest.contracts)) {
    if (contract.kind === "uups") {
      console.error(`  ${name}: proxy ${contract.proxy}, implementation ${contract.implementation}`);
    } else if (contract.kind === "beacon") {
      console.error(`  ${name}: ${contract.address}`);
    } else {
      console.error(`  ${name}: ${contract.implementation}`);
    }
  }
}

async function runCli(args: readonly string[], signal?: AbortSignal): Promise<void> {
  const [commandValue, networkValue, ...rest] = args;
  const command = parseCommand(commandValue);
  const network = parseNetwork(networkValue);
  const context = createContext(network, signal);

  switch (command) {
    case "deploy":
      await deploy(context, parseDeployOptions(rest));
      return;
    case "finalize-deploy":
      noArguments(command, rest);
      await finalizeDeploy(context);
      return;
    case "deploy-missing":
      noArguments(command, rest);
      await deployMissing(context);
      return;
    case "configure-payment-tokens":
      noArguments(command, rest);
      await configurePaymentTokens(context);
      return;
    case "deploy-calibnet-adapter":
      noArguments(command, rest);
      await upgrade(context, ["DataCapEvidenceAdapter"], "calibnet-adapter");
      return;
    case "upgrade":
      if (rest.length === 0) throw new Error("upgrade requires at least one target");
      await upgrade(context, rest);
      return;
    case "finalize-upgrade":
      noArguments(command, rest);
      await finalizeUpgrade(context);
      return;
    case "check-live":
      noArguments(command, rest);
      await checkLive(context);
      return;
    case "verify-sources":
      noArguments(command, rest);
      await verifySources(context);
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

function parseDeployOptions(args: readonly string[]): DeployOptions {
  if (args.length === 0) return { fresh: false, confirmMainnetReplacement: false };
  if (args.length === 1 && args[0] === "--fresh") {
    return { fresh: true, confirmMainnetReplacement: false };
  }
  if (args.length === 2 && args[0] === "--fresh" && args[1] === "--confirm-replace-mainnet-manifest") {
    return { fresh: true, confirmMainnetReplacement: true };
  }
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
  const actual = (
    await runProcess(context.cast, ["chain-id", "--rpc-url", rpc(context)], { signal: context.signal })
  ).trim();
  const expected = networkConfigs[context.network].chainId;
  if (actual !== String(expected))
    throw new Error(`${context.network} RPC chain ID must be ${expected}, got ${actual}`);
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
    [
      "build",
      "--root",
      context.root,
      "--out",
      outputDirectory,
      "--cache-path",
      cacheDirectory,
      "--build-info",
      "--extra-output",
      "storageLayout",
    ],
    { signal: context.signal, terminal: true },
  );
  const directory = join(outputDirectory, "build-info");
  const files = existsSync(directory) ? readdirSync(directory).filter((name) => name.endsWith(".json")) : [];
  if (files.length !== 1) throw new Error("Forge build must produce exactly one build-info JSON");
  const raw = readFileSync(join(directory, files[0]));
  return {
    hash: hashRawBytes(raw),
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
    expectedManagerRoles: null,
    finalizedAt: null,
    resultManifestSha256: null,
  };
}

function newPendingUpgrade(
  context: Context,
  targets: readonly string[],
  sourceHash: string,
  buildHash: string,
): PendingUpgrade {
  return {
    status: "pending",
    operation: "upgrade",
    network: context.network,
    chainId: networkConfigs[context.network].chainId,
    targets: [...targets],
    operations: [],
    sourceManifestSha256: sourceHash,
    resultManifestSha256: null,
    finalizedAt: null,
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
    USDFC: dependencies.USDFC ?? zeroAddress,
    AXL_USDC: dependencies.AxlUSDC ?? zeroAddress,
    BUILD_INFO_SHA256: build.hash,
    DEPLOYMENT_OUTPUT: output,
    FOUNDRY_BROADCAST: join(workspace, "broadcast"),
  };
  await runForgeScript(context, "script/Deploy.s.sol:Deploy", build, privateKey, environment);
}

async function runConfigurePaymentTokensScript(
  context: Context,
  workspace: string,
  registry: string,
  privateKey: string,
  policy: readonly PaymentToken[],
): Promise<void> {
  const dependencies = Object.fromEntries(policy.map((token) => [token.name, token.address]));
  await runProcess(
    context.forge,
    [
      "script",
      "script/ConfigurePaymentTokens.s.sol:ConfigurePaymentTokens",
      "--root",
      context.root,
      "--broadcast",
      "--rpc-url",
      rpc(context),
      "--private-key",
      privateKey,
      "--gas-estimate-multiplier",
      "100000",
      "--slow",
    ],
    {
      environment: {
        ...context.environment,
        PRIVATE_KEY: privateKey,
        RPC_URL: rpc(context),
        SP_REGISTRY: registry,
        USDFC: dependencies.USDFC ?? zeroAddress,
        AXL_USDC: dependencies.AxlUSDC ?? zeroAddress,
        FOUNDRY_BROADCAST: join(workspace, "broadcast"),
      },
      signal: context.signal,
      terminal: true,
    },
  );
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
  await runForgeScript(context, "script/Upgrade.s.sol:Upgrade", build, privateKey, environment);
}

async function runCalibnetAdapterScript(
  context: Context,
  workspace: string,
  source: string,
  output: string,
  build: Build,
  privateKey: string,
): Promise<void> {
  await runForgeScript(
    context,
    "script/DeployCalibnetDataCapAdapter.s.sol:DeployCalibnetDataCapAdapter",
    build,
    privateKey,
    {
      ...context.environment,
      PRIVATE_KEY: privateKey,
      DEPLOYMENT_MANIFEST: source,
      UPGRADE_OUTPUT: output,
      FOUNDRY_BROADCAST: join(workspace, "broadcast"),
    },
  );
}

async function runDeployMissingScript(
  context: Context,
  workspace: string,
  source: string,
  output: string,
  build: Build,
  privateKey: string,
): Promise<void> {
  await runForgeScript(context, "script/DeployMissing.s.sol:DeployMissing", build, privateKey, {
    ...context.environment,
    PRIVATE_KEY: privateKey,
    RPC_URL: rpc(context),
    DEPLOYMENT_MANIFEST: source,
    DEPLOYMENT_OUTPUT: output,
    FOUNDRY_BROADCAST: join(workspace, "broadcast"),
  });
}

async function runForgeScript(
  context: Context,
  script: string,
  build: Build,
  privateKey: string,
  environment: NodeJS.ProcessEnv,
): Promise<void> {
  await runProcess(
    context.forge,
    [
      "script",
      script,
      "--root",
      context.root,
      "--out",
      build.outputDirectory,
      "--cache-path",
      build.cacheDirectory,
      "--broadcast",
      "--rpc-url",
      rpc(context),
      "--private-key",
      privateKey,
      "--gas-estimate-multiplier",
      "100000",
      "--slow",
    ],
    { environment, signal: context.signal, terminal: true },
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
  if (parsed.result.release.buildInfoSha256 !== build.hash)
    throw new Error("Forge deployment used unexpected build-info");
  for (const [name, value] of Object.entries(dependencies)) {
    if (parsed.result.externalDependencies[name]?.toLowerCase() !== value.toLowerCase()) {
      throw new Error(`Forge deployment dependency ${name} is unexpected`);
    }
  }
  const paths = operationPaths(context, "deploy");
  const broadcastBytes = readFileSync(broadcast);
  const expectedManagerRoles =
    parsed.result.contracts.AccessManager === undefined
      ? null
      : { defaultAdmin: parsed.result.deployer, upgrader: parsed.result.deployer };
  const pending: PendingDeploy = {
    ...expected,
    result: parsed.result,
    expectedManagerRoles,
    broadcastSha256: hashRawBytes(broadcastBytes),
  };
  retainPendingEvidence(paths, build.gzip, broadcastBytes, pending);
  return true;
}

function recordDeployMissing(
  context: Context,
  workspace: string,
  output: string,
  build: Build,
  expected: PendingDeploy,
  source: DeploymentManifest,
): boolean {
  const broadcast = findBroadcast(context, workspace, "DeployMissing.s.sol");
  if (!broadcast || !existsSync(output)) return false;

  const deployed = parseDeploymentManifest(readFileSync(output, "utf8"));
  const result = mergeMissingHelpers(source, deployed, build.hash);
  const broadcastBytes = readFileSync(broadcast);
  const pending: PendingDeploy = {
    ...expected,
    result,
    broadcastSha256: hashRawBytes(broadcastBytes),
  };
  retainPendingEvidence(operationPaths(context, "deploy"), build.gzip, broadcastBytes, pending);
  return true;
}

export function mergeMissingHelpers(
  source: DeploymentManifest,
  deployed: DeploymentManifest,
  buildHash: string,
): DeploymentManifest {
  ensureHelpersAreMissing(source);
  const contracts = structuredClone(source.contracts);

  for (const [name, artifact] of Object.entries(missingHelperArtifacts)) {
    const contract = deployed.contracts[name];
    if (contract?.kind !== "standalone" || contract.artifact !== artifact) {
      throw new Error(`Forge output for ${name} is invalid`);
    }
    contracts[name] = structuredClone(contract);
  }

  return {
    status: "pending",
    deployer: source.deployer,
    release: { buildInfoSha256: buildHash },
    contracts,
    externalDependencies: structuredClone(source.externalDependencies),
    ...(source.transactions === undefined ? {} : { transactions: structuredClone(source.transactions) }),
  };
}

// Deduplicated because a finalize retry that got past the journal write but not the
// publish re-appends the same broadcast receipts.
export function mergeTransactions(
  prior: readonly DeploymentTransaction[] | undefined,
  receipts: readonly DeploymentTransaction[],
): DeploymentTransaction[] {
  const hashes = new Set(receipts.map((receipt) => receipt.hash));
  return [...(prior ?? []).filter((transaction) => !hashes.has(transaction.hash)), ...receipts];
}

export function applyPaymentTokenPolicy(
  source: DeploymentManifest,
  policy: readonly PaymentToken[],
  receipts: readonly DeploymentTransaction[],
): DeploymentManifest {
  const externalDependencies = structuredClone(source.externalDependencies);
  for (const token of policy) externalDependencies[token.name] = token.address;
  return {
    ...source,
    externalDependencies,
    transactions: mergeTransactions(source.transactions, receipts),
  };
}

function ensureHelpersAreMissing(manifest: DeploymentManifest): void {
  for (const name of Object.keys(missingHelperArtifacts)) {
    if (manifest.contracts[name] !== undefined) {
      throw new Error(`${name} already exists in the canonical deployment manifest`);
    }
  }
}

function recordUpgrade(
  context: Context,
  workspace: string,
  output: string,
  build: Build,
  expected: PendingUpgrade,
  variant: UpgradeVariant,
): boolean {
  const script = variant === "calibnet-adapter" ? "DeployCalibnetDataCapAdapter.s.sol" : "Upgrade.s.sol";
  const broadcast = findBroadcast(context, workspace, script);
  if (!broadcast || !existsSync(output)) return false;
  const operations = parseUpgradeOperations(
    JSON.stringify((JSON.parse(readFileSync(output, "utf8")) as { operations: unknown }).operations),
  );
  validateOperations(expected.targets, operations, variant);
  const broadcastBytes = readFileSync(broadcast);
  const pending: PendingUpgrade = {
    ...expected,
    operations,
    broadcastSha256: hashRawBytes(broadcastBytes),
  };
  retainPendingEvidence(operationPaths(context, "upgrade"), build.gzip, broadcastBytes, pending);
  return true;
}

function retainPendingEvidence(
  paths: Paths,
  buildInfo: Buffer,
  broadcast: Buffer,
  pending: PendingDeploy | PendingUpgrade,
): void {
  mkdirSync(paths.directory, { recursive: true });
  writeAtomicFile(paths.buildInfo, buildInfo);
  writeAtomicFile(paths.broadcast, broadcast);
  writeAtomicFile(paths.pending, json(pending));
}

function retainPendingStart(paths: Paths, buildInfo: Buffer, pending: PendingDeploy | PendingUpgrade): void {
  mkdirSync(paths.directory, { recursive: true });
  writeAtomicFile(paths.buildInfo, buildInfo);
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
    const definition = upgradeTargets[target];
    const contract = source.contracts[target];
    if (!definition || !contract) throw new Error(`unsupported upgrade target: ${target}`);
    if (contract.kind !== definition.manifestKind || contract.artifact !== definition.artifact) {
      throw new Error(`manifest entry for ${target} is not upgradeable by this command`);
    }
  }
}

function validateCalibnetAdapterTarget(source: DeploymentManifest, targets: readonly string[]): void {
  if (targets.length !== 1 || targets[0] !== "DataCapEvidenceAdapter") {
    throw new Error("CalibnetDataCapAdapter upgrade target is invalid");
  }
  const adapter = source.contracts.DataCapEvidenceAdapter;
  const manager = source.contracts.AccessManager;
  if (adapter?.kind !== "uups" || manager?.kind !== "standalone") {
    throw new Error("CalibnetDataCapAdapter requires a fresh AccessManager deployment");
  }
}

async function validateStorage(
  context: Context,
  source: DeploymentManifest,
  build: Build,
  workspace: string,
): Promise<void> {
  const previous = retainedBuildInfoPath(context, source.release.buildInfoSha256);
  authenticateBuildInfo(previous, source.release.buildInfoSha256);
  const current = join(workspace, "current-build-info.json.gz");
  writeAtomicFile(current, build.gzip);
  const targets = Object.entries(source.contracts)
    .filter(
      ([name, contract]) => contract.kind === "uups" || (name === "Validator" && contract.kind === "implementation"),
    )
    .map(([name]) => name);
  const args = ["--manifest", canonicalManifestPath(context)];
  for (const target of targets) args.push("--target", target);
  args.push(
    "--reference-build-info",
    previous,
    "--reference-sha256",
    source.release.buildInfoSha256,
    "--current-build-info",
    current,
    "--current-sha256",
    build.hash,
  );
  const validator = context.environment.STORAGE_VALIDATOR ?? join(context.root, "script", "validate-storage-layout.sh");
  await runProcess(validator, args, { environment: context.environment, signal: context.signal, terminal: true });
}

function validateOperations(
  targets: readonly string[],
  operations: PendingUpgrade["operations"],
  variant: UpgradeVariant,
): void {
  if (operations.length !== targets.length) throw new Error("Forge upgrade operations do not match requested targets");
  operations.forEach((operation, index) => {
    const target = targets[index];
    const definition = upgradeTargets[target]!;
    if (
      operation.target !== target ||
      operation.kind !== definition.operationKind ||
      operation.artifact !== definition.artifact ||
      (variant === "standard" && operation.newArtifact !== undefined) ||
      (variant === "calibnet-adapter" && operation.newArtifact !== calibnetAdapterArtifact)
    ) {
      throw new Error(`Forge upgrade operation ${index} does not match ${target}`);
    }
  });
}

function readDeployPending(context: Context, paths: Paths): PendingDeploy {
  const pending = readPending(paths.pending);
  if (pending.operation !== "deploy" || pending.network !== context.network)
    throw new Error("pending deployment does not match command");
  if (!pending.result || !pending.broadcastSha256) throw new Error("pending deployment evidence is incomplete");
  return pending;
}

function readUpgradePending(context: Context, paths: Paths): PendingUpgrade {
  const pending = readPending(paths.pending);
  if (pending.operation !== "upgrade" || pending.network !== context.network)
    throw new Error("pending upgrade does not match command");
  if (pending.operations.length === 0 || !pending.broadcastSha256) {
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
  if (!broadcastHash || hashFile(paths.broadcast) !== broadcastHash)
    throw new Error("pending broadcast hash does not match");
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
  if (existsSync(destination)) authenticateBuildInfo(destination, buildHash);
  else writeAtomicFile(destination, readFileSync(paths.buildInfo));
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

function deploymentDependencies(context: Context): DeploymentDependencies {
  const suffix = networkConfigs[context.network].environmentSuffix;
  const dependencies: DeploymentDependencies = {
    FilecoinPay: requiredNonZeroAddress(context, `FILECOIN_PAY_${suffix}`),
    TerminationOracle: requiredNonZeroAddress(context, `TERMINATION_ORACLE_${suffix}`),
    Oracle: requiredNonZeroAddress(context, `ORACLE_${suffix}`),
    PoRepService: requiredNonZeroAddress(context, `POREP_SERVICE_${suffix}`),
    MetaAllocator: requiredNonZeroAddress(context, `META_ALLOCATOR_${suffix}`),
    Operator: required(context, `OPERATOR_ADDR_${suffix}`),
  };
  for (const token of paymentTokenPolicy(context)) dependencies[token.name] = token.address;
  return dependencies;
}

function paymentTokenPolicy(context: Context): readonly PaymentToken[] {
  return networkConfigs[context.network].paymentTokens;
}

function spRegistryProxy(manifest: DeploymentManifest): string {
  const registry = manifest.contracts.SPRegistry;
  if (registry === undefined || registry.kind !== "uups") {
    throw new Error("manifest SPRegistry must be a uups contract");
  }
  return registry.proxy;
}

async function ensureTokenHasCode(context: Context, token: PaymentToken): Promise<void> {
  const code = (
    await runProcess(context.cast, ["code", token.address, "--rpc-url", rpc(context)], { signal: context.signal })
  ).trim();
  if (!/^0x(?:[0-9a-fA-F]{2})+$/.test(code)) {
    throw new Error(`${token.name} has no runtime bytecode at ${token.address}`);
  }
}

async function paymentTokenIsConfigured(context: Context, registry: string, token: string): Promise<boolean> {
  const output = (
    await runProcess(
      context.cast,
      ["call", registry, "getPaymentTokenConfig(address)(bool,uint256)", token, "--rpc-url", rpc(context)],
      { signal: context.signal },
    )
  )
    .trim()
    .split(/\s+/);
  if (output.length !== 2 || !["true", "false"].includes(output[0]!) || !/^\d+$/.test(output[1]!)) {
    throw new Error(`SPRegistry returned an invalid payment-token configuration for ${token}`);
  }
  return output[0] === "true" && output[1] === "1";
}

function required(context: Context, name: string): string {
  const value = context.environment[name];
  if (!value) throw new Error(`required environment variable is unset for ${context.network}: ${name}`);
  return value;
}

function requiredNonZeroAddress(context: Context, name: string): string {
  const value = required(context, name);
  if (!/^0x[0-9a-fA-F]{40}$/.test(value) || value.toLowerCase() === zeroAddress) {
    throw new Error(`required environment variable must be a non-zero address for ${context.network}: ${name}`);
  }
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
  if (relative(context.root, path).startsWith("..")) return;
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

function json(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

export async function runProcess(
  command: string,
  args: readonly string[],
  options: { environment?: NodeJS.ProcessEnv; signal?: AbortSignal; terminal?: boolean } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: options.environment,
      shell: false,
      signal: options.signal,
      stdio: options.terminal ? "inherit" : "pipe",
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let processError: Error | undefined;
    child.stdout?.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr?.on("data", (chunk: Buffer) => stderr.push(chunk));
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
        reject(
          new Error(
            `${command} exited with code ${code ?? "unknown"}${signal ? ` (${signal})` : ""}${details ? `: ${details}` : ""}`,
          ),
        );
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

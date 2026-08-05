import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, existsSync, fsyncSync, openSync, renameSync, rmSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";

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
type Executables = { cast: string; git: string };
type DeploymentContext = {
  network: Network;
  root: string;
  deploymentsRoot: string;
  environment: NodeJS.ProcessEnv;
  executables: Executables;
  signal?: AbortSignal;
};

export type DeploymentCliOptions = {
  root?: string;
  deploymentsRoot?: string;
  environment?: NodeJS.ProcessEnv;
  executables?: Partial<Executables>;
  signal?: AbortSignal;
};

export type SignalHandling = {
  signal: AbortSignal;
  dispose: () => void;
};

const networks = Object.keys(networkConfigs) as Network[];
const usage = `Usage: deployment.ts <command> <network> [args...]\nCommands: ${commands.join(", ")}\nNetworks: ${networks.join(", ")}`;

async function deploy(context: DeploymentContext, fresh: boolean): Promise<void> {
  requireEnvironment(context, networkConfigs[context.network].privateKeyVariable);
  loadDeploymentDependencies(context);
  await preflightBroadcast(context);
  ensureDeployDestination(context, fresh);
  throw new Error("deploy phase is not implemented");
}

async function finalizeDeploy(context: DeploymentContext): Promise<void> {
  await preflightFinalize(context);
  throw new Error("finalize-deploy phase is not implemented");
}

async function upgrade(context: DeploymentContext, targets: readonly string[]): Promise<void> {
  requireEnvironment(context, networkConfigs[context.network].privateKeyVariable);
  await preflightBroadcast(context);
  ensureCanonicalManifest(context);
  ensureCleanCanonicalManifest(context);
  void targets;
  throw new Error("upgrade phase is not implemented");
}

async function finalizeUpgrade(context: DeploymentContext): Promise<void> {
  await preflightFinalize(context);
  ensureCanonicalManifest(context);
  ensureCleanCanonicalManifest(context);
  throw new Error("finalize-upgrade phase is not implemented");
}

async function verify(context: DeploymentContext): Promise<void> {
  await preflightFinalize(context);
  ensureCanonicalManifest(context);
  ensureCleanCanonicalManifest(context);
  throw new Error("verify phase is not implemented");
}

export async function runDeploymentCli(
  arguments_: readonly string[],
  options: DeploymentCliOptions = {},
): Promise<void> {
  const [commandArgument, networkArgument, ...commandArguments] = arguments_;
  const command = parseCommand(commandArgument);
  const network = parseNetwork(networkArgument);
  const context = createContext(network, options);

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

function createContext(network: Network, options: DeploymentCliOptions): DeploymentContext {
  const root = options.root ?? process.cwd();
  return {
    root,
    deploymentsRoot: options.deploymentsRoot ?? join(root, "deployments"),
    environment: options.environment ?? process.env,
    executables: { cast: options.executables?.cast ?? "cast", git: options.executables?.git ?? "git" },
    signal: options.signal,
    network,
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

function ensureDeployDestination(context: DeploymentContext, fresh: boolean): void {
  if (!fresh && fileExists(canonicalManifestPath(context))) {
    throw new Error(`canonical ${context.network} deployment already exists; pass --fresh`);
  }
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
  options: { signal?: AbortSignal } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, arguments_, { shell: false, signal: options.signal });
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

export function writeAtomicFile(path: string, content: string): void {
  const temporaryPath = join(dirname(path), `.${randomUUID()}.tmp`);
  let fileDescriptor: number | undefined;
  try {
    fileDescriptor = openSync(temporaryPath, "wx", 0o600);
    writeSync(fileDescriptor, content);
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
  void runDeploymentCli(process.argv.slice(2), { signal: signalHandling.signal })
    .catch((error: unknown) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    })
    .finally(signalHandling.dispose);
}

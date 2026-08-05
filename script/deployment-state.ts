import { createHash } from "node:crypto";

export type UupsContract = {
  kind: "uups";
  artifact: string;
  proxy: string;
  implementation: string;
  proxyCodeHash: string;
  implementationCodeHash: string;
};
export type ImplementationContract = {
  kind: "implementation";
  artifact: string;
  implementation: string;
  implementationCodeHash: string;
};
export type StandaloneContract = {
  kind: "standalone";
  artifact: string;
  implementation: string;
  implementationCodeHash: string;
};
export type BeaconContract = {
  kind: "beacon";
  artifact: string;
  address: string;
  implementation: string;
  factoryProxy: string;
};
export type ManifestContract = UupsContract | ImplementationContract | StandaloneContract | BeaconContract;

export type DeploymentTransaction = {
  hash: string;
  status: number;
  blockNumber: number;
  blockHash: string;
  contractAddress: string | null;
};
export type DeploymentManifest = {
  status: "pending" | "finalized";
  finalizedAt?: string;
  deployer: string;
  release: { buildInfoSha256: string };
  contracts: Record<string, ManifestContract>;
  externalDependencies: Record<string, string>;
  transactions?: DeploymentTransaction[];
};
export type UpgradeOperation = {
  target: string;
  kind: "uups" | "beacon";
  artifact: string;
  newImplementation: string;
  newImplementationCodeHash: string;
};
export type PendingDeploy = {
  status: "pending" | "finalized";
  operation: "deploy";
  network: string;
  chainId: number;
  previousManifestSha256: string | null;
  release: { buildInfoSha256: string };
  broadcastSha256: string | null;
  result: DeploymentManifest | null;
  finalizedAt: string | null;
  resultManifestSha256: string | null;
};
export type PendingUpgrade = {
  status: "pending" | "finalized";
  operation: "upgrade";
  network: string;
  chainId: number;
  targets: string[];
  operations: UpgradeOperation[];
  sourceManifestSha256: string;
  resultManifestSha256: string | null;
  release: { buildInfoSha256: string };
  broadcastSha256: string | null;
};
export type PendingOperation = PendingDeploy | PendingUpgrade;
export type CanonicalManifestState = "absent" | "source" | "result" | "unexpected";

const addressPattern = /^0x[0-9a-fA-F]{40}$/;
const hashPattern = /^0x[0-9a-fA-F]{64}$/;

export function parseDeploymentManifest(text: string): DeploymentManifest {
  return manifest(parseJson(text, "manifest"), "manifest");
}

export function parsePendingOperation(text: string): PendingOperation {
  const value = object(parseJson(text, "pending"), "pending");
  const common = {
    status: status(value.status, "pending.status"),
    network: string(value.network, "pending.network"),
    chainId: integer(value.chainId, "pending.chainId"),
    release: release(value.release, "pending.release"),
    broadcastSha256: nullableHash(value.broadcastSha256, "pending.broadcastSha256"),
  };

  if (value.operation === "deploy") {
    return {
      ...common,
      operation: "deploy",
      previousManifestSha256: nullableHash(value.previousManifestSha256, "pending.previousManifestSha256"),
      result: value.result === null ? null : manifest(value.result, "pending.result"),
      finalizedAt: nullableString(value.finalizedAt, "pending.finalizedAt"),
      resultManifestSha256: nullableHash(value.resultManifestSha256, "pending.resultManifestSha256"),
    };
  }
  if (value.operation === "upgrade") {
    const targets = array(value.targets, "pending.targets").map((item, index) => string(item, `pending.targets[${index}]`));
    const operations = array(value.operations, "pending.operations").map((item, index) => operation(item, `pending.operations[${index}]`));
    if (targets.length === 0 || new Set(targets).size !== targets.length) throw new Error("pending.targets are invalid");
    return {
      ...common,
      operation: "upgrade",
      targets,
      operations,
      sourceManifestSha256: hash(value.sourceManifestSha256, "pending.sourceManifestSha256"),
      resultManifestSha256: nullableHash(value.resultManifestSha256, "pending.resultManifestSha256"),
    };
  }
  throw new Error("pending.operation must be deploy or upgrade");
}

export function parseUpgradeOperations(text: string): UpgradeOperation[] {
  return array(parseJson(text, "operations"), "operations").map((item, index) => operation(item, `operations[${index}]`));
}

export function hashRawBytes(bytes: Uint8Array): string {
  return `0x${createHash("sha256").update(bytes).digest("hex")}`;
}

export function renderDeployManifest(pending: PendingDeploy, finalizedAt: string): DeploymentManifest {
  if (!pending.broadcastSha256 || !pending.resultManifestSha256 || !pending.result) {
    throw new Error("pending deployment is missing finalization evidence");
  }
  return { ...structuredClone(pending.result), status: "finalized", finalizedAt, transactions: pending.result.transactions ?? [] };
}

export function renderUpgradedManifest(source: DeploymentManifest, pending: PendingUpgrade): DeploymentManifest {
  if (!pending.resultManifestSha256) throw new Error("pending upgrade is missing result evidence");
  return renderPrepublicationUpgradedManifest(source, pending);
}

export function renderPrepublicationUpgradedManifest(source: DeploymentManifest, pending: PendingUpgrade): DeploymentManifest {
  if (!pending.broadcastSha256) throw new Error("pending upgrade is missing broadcast evidence");
  const contracts = structuredClone(source.contracts);
  for (const item of pending.operations) applyUpgrade(contracts, item);
  return { ...source, release: { buildInfoSha256: pending.release.buildInfoSha256 }, contracts };
}

export function classifyDeployCanonicalState(current: string | undefined, pending: PendingDeploy): CanonicalManifestState {
  if (current === undefined) return pending.previousManifestSha256 === null ? "absent" : "unexpected";
  if (pending.resultManifestSha256 === current) return "result";
  if (pending.previousManifestSha256 === current) return "source";
  return "unexpected";
}

export function classifyUpgradeCanonicalState(current: string | undefined, pending: PendingUpgrade): CanonicalManifestState {
  if (pending.resultManifestSha256 === current) return "result";
  if (pending.sourceManifestSha256 === current) return "source";
  return "unexpected";
}

function manifest(input: unknown, path: string): DeploymentManifest {
  const value = object(input, path);
  const contractsValue = object(value.contracts, `${path}.contracts`);
  const contracts: Record<string, ManifestContract> = {};
  for (const [name, item] of Object.entries(contractsValue)) {
    if (["__proto__", "constructor", "prototype"].includes(name)) throw new Error(`${path}.contracts.${name} is reserved`);
    contracts[name] = contract(item, `${path}.contracts.${name}`);
  }
  const dependencies: Record<string, string> = {};
  for (const [name, item] of Object.entries(object(value.externalDependencies, `${path}.externalDependencies`))) {
    dependencies[name] = address(item, `${path}.externalDependencies.${name}`);
  }
  const transactions = value.transactions === undefined
    ? undefined
    : array(value.transactions, `${path}.transactions`).map((item, index) => transaction(item, `${path}.transactions[${index}]`));
  return {
    status: status(value.status, `${path}.status`),
    ...(value.finalizedAt === undefined ? {} : { finalizedAt: string(value.finalizedAt, `${path}.finalizedAt`) }),
    deployer: address(value.deployer, `${path}.deployer`),
    release: release(value.release, `${path}.release`),
    contracts,
    externalDependencies: dependencies,
    ...(transactions === undefined ? {} : { transactions }),
  };
}

function contract(input: unknown, path: string): ManifestContract {
  const value = object(input, path);
  const artifact = string(value.artifact, `${path}.artifact`);
  switch (value.kind) {
    case "uups":
      return {
        kind: "uups", artifact,
        proxy: address(value.proxy, `${path}.proxy`),
        implementation: address(value.implementation, `${path}.implementation`),
        proxyCodeHash: hash(value.proxyCodeHash, `${path}.proxyCodeHash`),
        implementationCodeHash: hash(value.implementationCodeHash, `${path}.implementationCodeHash`),
      };
    case "implementation":
    case "standalone":
      return {
        kind: value.kind, artifact,
        implementation: address(value.implementation, `${path}.implementation`),
        implementationCodeHash: hash(value.implementationCodeHash, `${path}.implementationCodeHash`),
      };
    case "beacon":
      return {
        kind: "beacon", artifact,
        address: address(value.address, `${path}.address`),
        implementation: address(value.implementation, `${path}.implementation`),
        factoryProxy: address(value.factoryProxy, `${path}.factoryProxy`),
      };
    default:
      throw new Error(`${path}.kind is unsupported`);
  }
}

function operation(input: unknown, path: string): UpgradeOperation {
  const value = object(input, path);
  if (value.kind !== "uups" && value.kind !== "beacon") throw new Error(`${path}.kind is invalid`);
  return {
    target: string(value.target, `${path}.target`),
    kind: value.kind,
    artifact: string(value.artifact, `${path}.artifact`),
    newImplementation: address(value.newImplementation, `${path}.newImplementation`),
    newImplementationCodeHash: hash(value.newImplementationCodeHash, `${path}.newImplementationCodeHash`),
  };
}

function transaction(input: unknown, path: string): DeploymentTransaction {
  const value = object(input, path);
  return {
    hash: hash(value.hash, `${path}.hash`),
    status: integer(value.status, `${path}.status`, 0),
    blockNumber: integer(value.blockNumber, `${path}.blockNumber`, 0),
    blockHash: hash(value.blockHash, `${path}.blockHash`),
    contractAddress: value.contractAddress === null ? null : address(value.contractAddress, `${path}.contractAddress`),
  };
}

function applyUpgrade(contracts: Record<string, ManifestContract>, item: UpgradeOperation): void {
  const target = contracts[item.target];
  if (!target || target.artifact !== item.artifact || !("implementation" in target)) {
    throw new Error(`upgrade operation for ${item.target} does not match the manifest`);
  }
  if (target.implementation.toLowerCase() === item.newImplementation.toLowerCase()) {
    throw new Error(`upgrade operation for ${item.target} did not replace the implementation`);
  }
  if (item.kind === "uups" && target.kind === "uups") {
    contracts[item.target] = { ...target, implementation: item.newImplementation, implementationCodeHash: item.newImplementationCodeHash };
    return;
  }
  const beacon = contracts.ValidatorBeacon;
  if (item.target !== "Validator" || item.kind !== "beacon" || target.kind !== "implementation" || beacon?.kind !== "beacon") {
    throw new Error(`upgrade operation kind does not match ${item.target}`);
  }
  contracts.Validator = { ...target, implementation: item.newImplementation, implementationCodeHash: item.newImplementationCodeHash };
  contracts.ValidatorBeacon = { ...beacon, implementation: item.newImplementation };
}

function parseJson(text: string, path: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new Error(`${path} JSON is invalid`);
  }
}

function object(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${path} must be an object`);
  return value as Record<string, unknown>;
}

function array(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${path} must be an array`);
  return value;
}

function string(value: unknown, path: string): string {
  if (typeof value !== "string" || value.length === 0) throw new Error(`${path} must be a non-empty string`);
  return value;
}

function nullableString(value: unknown, path: string): string | null {
  return value === null ? null : string(value, path);
}

function address(value: unknown, path: string): string {
  const result = string(value, path);
  if (!addressPattern.test(result)) throw new Error(`${path} must be an address`);
  return result;
}

function hash(value: unknown, path: string): string {
  const result = string(value, path);
  if (!hashPattern.test(result)) throw new Error(`${path} must be a 32-byte hash`);
  return result;
}

function nullableHash(value: unknown, path: string): string | null {
  return value === null ? null : hash(value, path);
}

function integer(value: unknown, path: string, minimum = 1): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum) throw new Error(`${path} must be an integer`);
  return value as number;
}

function status(value: unknown, path: string): "pending" | "finalized" {
  if (value !== "pending" && value !== "finalized") throw new Error(`${path} must be pending or finalized`);
  return value;
}

function release(value: unknown, path: string): { buildInfoSha256: string } {
  return { buildInfoSha256: hash(object(value, path).buildInfoSha256, `${path}.buildInfoSha256`) };
}

import { createHash } from "node:crypto";

export type ManifestContract = UupsContract | ImplementationContract | StandaloneContract | BeaconContract;

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

type JsonObject = Record<string, unknown>;

const addressPattern = /^0x[0-9a-fA-F]{40}$/;
const hashPattern = /^0x[0-9a-f]{64}$/;

export function parseDeploymentManifest(text: string): DeploymentManifest {
  const value = parseJson(text, "manifest");
  return parseDeploymentManifestValue(value, "manifest");
}

export function parsePendingOperation(text: string): PendingOperation {
  const value = parseJson(text, "pending");
  const pending = readObject(value, "pending");
  const operation = readString(readField(pending, "operation", "pending"), "pending.operation");

  if (operation === "deploy") {
    return parsePendingDeploy(pending);
  }
  if (operation === "upgrade") {
    return parsePendingUpgrade(pending);
  }
  throw new Error("pending.operation must be deploy or upgrade");
}

export function parseUpgradeOperations(text: string): UpgradeOperation[] {
  const value = parseJson(text, "operations");
  return readArray(value, "operations").map((entry, index) => parseUpgradeOperation(entry, `operations[${index}]`));
}

export function hashRawBytes(bytes: Uint8Array): string {
  const hash = createHash("sha256");
  hash.update(bytes);
  return `0x${hash.digest("hex")}`;
}

export function renderDeployManifest(pending: PendingDeploy, finalizedAt: string): DeploymentManifest {
  const timestamp = readNonEmptyString(finalizedAt, "finalizedAt");
  if (pending.result === null) {
    throw new Error("pending.result is missing broadcast output");
  }
  const result = structuredClone(pending.result);

  return {
    ...result,
    status: "finalized",
    finalizedAt: timestamp,
    transactions: result.transactions ?? [],
  };
}

export function renderUpgradedManifest(source: DeploymentManifest, pending: PendingUpgrade): DeploymentManifest {
  const contracts = structuredClone(source.contracts);

  for (const operation of pending.operations) {
    applyUpgradeOperation(contracts, operation);
  }

  return {
    ...source,
    release: { buildInfoSha256: pending.release.buildInfoSha256 },
    contracts,
  };
}

export function classifyDeployCanonicalState(
  canonicalManifestSha256: string | undefined,
  pending: PendingDeploy,
): CanonicalManifestState {
  if (canonicalManifestSha256 === undefined) {
    return pending.previousManifestSha256 === null ? "absent" : "unexpected";
  }
  if (pending.resultManifestSha256 !== null && canonicalManifestSha256 === pending.resultManifestSha256) {
    return "result";
  }
  if (pending.previousManifestSha256 !== null && canonicalManifestSha256 === pending.previousManifestSha256) {
    return "source";
  }
  return "unexpected";
}

export function classifyUpgradeCanonicalState(
  canonicalManifestSha256: string | undefined,
  pending: PendingUpgrade,
): CanonicalManifestState {
  if (pending.resultManifestSha256 !== null && canonicalManifestSha256 === pending.resultManifestSha256) {
    return "result";
  }
  if (canonicalManifestSha256 === pending.sourceManifestSha256) {
    return "source";
  }
  return "unexpected";
}

function parseJson(text: string, path: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new Error(`${path} JSON is invalid`);
  }
}

function parseDeploymentManifestValue(value: unknown, path: string): DeploymentManifest {
  const manifest = readObject(value, path);
  const status = readStatus(readField(manifest, "status", path), `${path}.status`);
  const release = parseRelease(readField(manifest, "release", path), `${path}.release`);
  const contracts = parseContracts(readField(manifest, "contracts", path), `${path}.contracts`);
  const dependencies = parseExternalDependencies(
    readField(manifest, "externalDependencies", path),
    `${path}.externalDependencies`,
  );
  const deployer = readAddress(readField(manifest, "deployer", path), `${path}.deployer`);
  const finalizedAt = readOptionalNonEmptyString(manifest, "finalizedAt", path);
  const transactions = readOptionalTransactions(manifest, path);

  return {
    status,
    ...(finalizedAt === undefined ? {} : { finalizedAt }),
    deployer,
    release,
    contracts,
    externalDependencies: dependencies,
    ...(transactions === undefined ? {} : { transactions }),
  };
}

function parsePendingDeploy(pending: JsonObject): PendingDeploy {
  const common = parsePendingCommon(pending);
  const result = parseNullableManifest(readField(pending, "result", "pending"), "pending.result");

  return {
    ...common,
    operation: "deploy",
    previousManifestSha256: readNullableHash(
      readField(pending, "previousManifestSha256", "pending"),
      "pending.previousManifestSha256",
    ),
    result,
    finalizedAt: readNullableNonEmptyString(
      readField(pending, "finalizedAt", "pending"),
      "pending.finalizedAt",
    ),
    resultManifestSha256: readNullableHash(
      readField(pending, "resultManifestSha256", "pending"),
      "pending.resultManifestSha256",
    ),
  };
}

function parsePendingUpgrade(pending: JsonObject): PendingUpgrade {
  const common = parsePendingCommon(pending);
  const targets = readArray(readField(pending, "targets", "pending"), "pending.targets").map((target, index) =>
    readNonEmptyString(target, `pending.targets[${index}]`),
  );
  const operations = readArray(readField(pending, "operations", "pending"), "pending.operations").map(
    (operation, index) => parseUpgradeOperation(operation, `pending.operations[${index}]`),
  );

  if (targets.length === 0) {
    throw new Error("pending.targets must not be empty");
  }
  if (new Set(targets).size !== targets.length) {
    throw new Error("pending.targets must not contain duplicates");
  }
  if (operations.length !== 0 && operations.length !== targets.length) {
    throw new Error("pending.operations must match pending.targets");
  }
  for (const [index, operation] of operations.entries()) {
    if (operation.target !== targets[index]) {
      throw new Error(`pending.operations[${index}].target must match pending.targets[${index}]`);
    }
  }

  return {
    ...common,
    operation: "upgrade",
    targets,
    operations,
    sourceManifestSha256: readHash(
      readField(pending, "sourceManifestSha256", "pending"),
      "pending.sourceManifestSha256",
    ),
    resultManifestSha256: readNullableHash(
      readField(pending, "resultManifestSha256", "pending"),
      "pending.resultManifestSha256",
    ),
  };
}

function parsePendingCommon(pending: JsonObject) {
  return {
    status: readStatus(readField(pending, "status", "pending"), "pending.status"),
    network: readNonEmptyString(readField(pending, "network", "pending"), "pending.network"),
    chainId: readInteger(readField(pending, "chainId", "pending"), "pending.chainId", 1),
    release: parseRelease(readField(pending, "release", "pending"), "pending.release"),
    broadcastSha256: readNullableHash(
      readField(pending, "broadcastSha256", "pending"),
      "pending.broadcastSha256",
    ),
  };
}

function parseRelease(value: unknown, path: string) {
  const release = readObject(value, path);
  return {
    buildInfoSha256: readHash(readField(release, "buildInfoSha256", path), `${path}.buildInfoSha256`),
  };
}

function parseNullableManifest(value: unknown, path: string): DeploymentManifest | null {
  if (value === null) {
    return null;
  }
  return parseDeploymentManifestValue(value, path);
}

function parseContracts(value: unknown, path: string): Record<string, ManifestContract> {
  const contracts = readObject(value, path);
  const parsed: Record<string, ManifestContract> = {};

  for (const [name, contract] of Object.entries(contracts)) {
    parsed[name] = parseManifestContract(contract, `${path}.${name}`);
  }
  return parsed;
}

function parseManifestContract(value: unknown, path: string): ManifestContract {
  const contract = readObject(value, path);
  const kind = readString(readField(contract, "kind", path), `${path}.kind`);
  const artifact = readNonEmptyString(readField(contract, "artifact", path), `${path}.artifact`);

  switch (kind) {
    case "uups":
      return {
        kind,
        artifact,
        proxy: readAddress(readField(contract, "proxy", path), `${path}.proxy`),
        implementation: readAddress(readField(contract, "implementation", path), `${path}.implementation`),
        proxyCodeHash: readHash(readField(contract, "proxyCodeHash", path), `${path}.proxyCodeHash`),
        implementationCodeHash: readHash(
          readField(contract, "implementationCodeHash", path),
          `${path}.implementationCodeHash`,
        ),
      };
    case "implementation":
      return parseImplementationContract(contract, path, kind, artifact);
    case "standalone":
      return parseImplementationContract(contract, path, kind, artifact);
    case "beacon":
      return {
        kind,
        artifact,
        address: readAddress(readField(contract, "address", path), `${path}.address`),
        implementation: readAddress(readField(contract, "implementation", path), `${path}.implementation`),
        factoryProxy: readAddress(readField(contract, "factoryProxy", path), `${path}.factoryProxy`),
      };
    default:
      throw new Error(`${path}.kind is unsupported: ${kind}`);
  }
}

function parseImplementationContract(
  contract: JsonObject,
  path: string,
  kind: "implementation" | "standalone",
  artifact: string,
): ImplementationContract | StandaloneContract {
  return {
    kind,
    artifact,
    implementation: readAddress(readField(contract, "implementation", path), `${path}.implementation`),
    implementationCodeHash: readHash(
      readField(contract, "implementationCodeHash", path),
      `${path}.implementationCodeHash`,
    ),
  };
}

function parseExternalDependencies(value: unknown, path: string): Record<string, string> {
  const dependencies = readObject(value, path);
  const expectedNames = ["FilecoinPay", "PoRepService", "MetaAllocator", "TerminationOracle", "Oracle", "Operator"];
  const parsed: Record<string, string> = {};

  for (const name of expectedNames) {
    parsed[name] = readAddress(readField(dependencies, name, path), `${path}.${name}`);
  }
  return parsed;
}

function readOptionalTransactions(manifest: JsonObject, path: string): DeploymentTransaction[] | undefined {
  const value = manifest.transactions;
  if (value === undefined) {
    return undefined;
  }
  return readArray(value, `${path}.transactions`).map((transaction, index) =>
    parseTransaction(transaction, `${path}.transactions[${index}]`),
  );
}

function parseTransaction(value: unknown, path: string): DeploymentTransaction {
  const transaction = readObject(value, path);
  return {
    hash: readHash(readField(transaction, "hash", path), `${path}.hash`),
    status: readInteger(readField(transaction, "status", path), `${path}.status`, 0),
    blockNumber: readInteger(readField(transaction, "blockNumber", path), `${path}.blockNumber`, 0),
    blockHash: readHash(readField(transaction, "blockHash", path), `${path}.blockHash`),
    contractAddress: readNullableAddress(
      readField(transaction, "contractAddress", path),
      `${path}.contractAddress`,
    ),
  };
}

function parseUpgradeOperation(value: unknown, path: string): UpgradeOperation {
  const operation = readObject(value, path);
  const target = readNonEmptyString(readField(operation, "target", path), `${path}.target`);
  const kind = readUpgradeKind(readField(operation, "kind", path), `${path}.kind`);

  if ((target === "Validator") !== (kind === "beacon")) {
    throw new Error(`${path}.kind does not match ${path}.target`);
  }

  return {
    target,
    kind,
    artifact: readNonEmptyString(readField(operation, "artifact", path), `${path}.artifact`),
    newImplementation: readAddress(
      readField(operation, "newImplementation", path),
      `${path}.newImplementation`,
    ),
    newImplementationCodeHash: readHash(
      readField(operation, "newImplementationCodeHash", path),
      `${path}.newImplementationCodeHash`,
    ),
  };
}

function applyUpgradeOperation(contracts: Record<string, ManifestContract>, operation: UpgradeOperation) {
  const target = contracts[operation.target];
  if (target === undefined) {
    throw new Error(`manifest.contracts.${operation.target} is missing`);
  }

  if (operation.kind === "uups") {
    if (target.kind !== "uups") {
      throw new Error(`manifest.contracts.${operation.target}.kind must be uups`);
    }
    contracts[operation.target] = {
      ...target,
      implementation: operation.newImplementation,
      implementationCodeHash: operation.newImplementationCodeHash,
    };
    return;
  }

  if (operation.target !== "Validator" || target.kind !== "implementation") {
    throw new Error(`manifest.contracts.${operation.target}.kind must be implementation for a beacon upgrade`);
  }
  const beacon = contracts.ValidatorBeacon;
  if (beacon === undefined || beacon.kind !== "beacon") {
    throw new Error("manifest.contracts.ValidatorBeacon.kind must be beacon");
  }
  contracts.Validator = {
    ...target,
    implementation: operation.newImplementation,
    implementationCodeHash: operation.newImplementationCodeHash,
  };
  contracts.ValidatorBeacon = {
    ...beacon,
    implementation: operation.newImplementation,
  };
}

function readObject(value: unknown, path: string): JsonObject {
  if (!isObject(value)) {
    throw new Error(`${path} must be an object`);
  }
  return value;
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readField(object: JsonObject, field: string, path: string): unknown {
  const value = object[field];
  if (value === undefined) {
    throw new Error(`${path}.${field} is required`);
  }
  return value;
}

function readString(value: unknown, path: string): string {
  if (typeof value !== "string") {
    throw new Error(`${path} must be a string`);
  }
  return value;
}

function readNonEmptyString(value: unknown, path: string): string {
  const text = readString(value, path);
  if (text.length === 0) {
    throw new Error(`${path} must not be empty`);
  }
  return text;
}

function readAddress(value: unknown, path: string): string {
  const address = readString(value, path);
  if (!addressPattern.test(address)) {
    throw new Error(`${path} must be an address`);
  }
  return address;
}

function readNullableAddress(value: unknown, path: string): string | null {
  if (value === null) {
    return null;
  }
  return readAddress(value, path);
}

function readHash(value: unknown, path: string): string {
  const hash = readString(value, path);
  if (!hashPattern.test(hash)) {
    throw new Error(`${path} must be a lowercase 0x SHA-256 hash`);
  }
  return hash;
}

function readNullableHash(value: unknown, path: string): string | null {
  if (value === null) {
    return null;
  }
  return readHash(value, path);
}

function readInteger(value: unknown, path: string, minimum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum) {
    throw new Error(`${path} must be an integer greater than or equal to ${minimum}`);
  }
  return value;
}

function readArray(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`${path} must be an array`);
  }
  return value;
}

function readStatus(value: unknown, path: string): "pending" | "finalized" {
  const status = readString(value, path);
  if (status !== "pending" && status !== "finalized") {
    throw new Error(`${path} must be pending or finalized`);
  }
  return status;
}

function readUpgradeKind(value: unknown, path: string): "uups" | "beacon" {
  const kind = readString(value, path);
  if (kind !== "uups" && kind !== "beacon") {
    throw new Error(`${path} must be uups or beacon`);
  }
  return kind;
}

function readOptionalNonEmptyString(object: JsonObject, field: string, path: string): string | undefined {
  const value = object[field];
  if (value === undefined) {
    return undefined;
  }
  return readNonEmptyString(value, `${path}.${field}`);
}

function readNullableNonEmptyString(value: unknown, path: string): string | null {
  if (value === null) {
    return null;
  }
  return readNonEmptyString(value, path);
}

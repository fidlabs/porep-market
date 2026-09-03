import type {
  DeploymentManifest,
  DeploymentTransaction,
  ManagerRoleExpectations,
  ManifestContract,
  UpgradeOperation,
} from "./deployment-state.ts";

const transactionHashPattern = /^0x[0-9a-fA-F]{64}$/;
const addressPattern = /^0x[0-9a-fA-F]{40}$/;
const quantityPattern = /^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/;
const runtimeCodePattern = /^0x(?:[0-9a-fA-F]{2})*$/;
const implementationSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const zeroAddress = `0x${"0".repeat(40)}`;

export type CommandOptions = {
  signal?: AbortSignal;
};

export type CommandRunner = (command: string, args: readonly string[], options: CommandOptions) => Promise<string>;

export type FinalityOptions = {
  signal?: AbortSignal;
  pollIntervalMs?: number;
  sleep?: (milliseconds: number, signal?: AbortSignal) => Promise<void>;
  progress?: (message: string) => void;
};

export function extractBroadcastTransactionHashes(text: string): string[] {
  let value: unknown;
  try {
    value = JSON.parse(text) as unknown;
  } catch {
    throw new Error("broadcast JSON is invalid");
  }

  if (!isObject(value) || !Array.isArray(value.transactions) || value.transactions.length === 0) {
    throw new Error("broadcast.transactions must be a non-empty array");
  }

  const hashes: string[] = [];
  const uniqueHashes = new Set<string>();
  for (const [index, transaction] of value.transactions.entries()) {
    if (
      !isObject(transaction) ||
      typeof transaction.hash !== "string" ||
      !transactionHashPattern.test(transaction.hash)
    ) {
      throw new Error(`broadcast.transactions[${index}].hash must be a 32-byte transaction hash`);
    }
    const hash = transaction.hash.toLowerCase();
    if (uniqueHashes.has(hash)) {
      throw new Error(`broadcast.transactions[${index}] has duplicate transaction hash ${hash}`);
    }
    uniqueHashes.add(hash);
    hashes.push(hash);
  }
  return hashes;
}

export async function loadTransactionReceipts(
  run: CommandRunner,
  rpcUrl: string,
  hashes: readonly string[],
): Promise<DeploymentTransaction[]> {
  const requestedHashes = validateRequestedHashes(hashes);
  const receipts: DeploymentTransaction[] = [];
  const receiptHashes = new Set<string>();

  for (const requestedHash of requestedHashes) {
    let output: string;
    try {
      output = await run("cast", ["rpc", "--rpc-url", rpcUrl, "eth_getTransactionReceipt", requestedHash], {});
    } catch (error) {
      throw new Error(`could not read receipt for transaction ${requestedHash}`, { cause: error });
    }
    const receipt = parseTransactionReceipt(output, requestedHash);
    if (receiptHashes.has(receipt.hash)) {
      throw new Error(`duplicate canonical receipt hash ${receipt.hash}`);
    }
    receiptHashes.add(receipt.hash);
    receipts.push(receipt);
  }

  return receipts;
}

export async function waitForFilecoinFinality(
  run: CommandRunner,
  rpcUrl: string,
  receipts: readonly DeploymentTransaction[],
  options: FinalityOptions = {},
): Promise<void> {
  const receiptBlocks = collectReceiptBlocks(receipts);
  const highestReceiptBlock = Math.max(...receiptBlocks.keys());
  const pollIntervalMs = options.pollIntervalMs ?? 30_000;
  if (!Number.isInteger(pollIntervalMs) || pollIntervalMs < 0) {
    throw new Error("Filecoin finality poll interval must be a non-negative integer");
  }
  const sleep = options.sleep ?? abortableSleep;
  const progress = options.progress ?? ((message: string) => console.error(message));

  while (true) {
    throwIfCancelled(options.signal);
    const finalizedHeight = await loadFinalizedHeight(run, rpcUrl, options.signal);
    throwIfCancelled(options.signal);
    if (finalizedHeight >= highestReceiptBlock) {
      progress(`Filecoin finalized height ${finalizedHeight} covers all receipt blocks`);
      break;
    }
    progress(`Filecoin finalized height ${finalizedHeight}; waiting for receipt block ${highestReceiptBlock}`);
    await sleep(pollIntervalMs, options.signal);
    throwIfCancelled(options.signal);
  }

  for (const [height, expectedHash] of receiptBlocks) {
    throwIfCancelled(options.signal);
    await verifyCanonicalBlock(run, rpcUrl, height, expectedHash, options.signal);
  }
}

export async function verifyManifestContracts(
  run: CommandRunner,
  rpcUrl: string,
  manifest: DeploymentManifest,
  operations: readonly UpgradeOperation[] = [],
): Promise<void> {
  const replacements = collectUpgradeReplacements(manifest, operations);

  for (const [name, contract] of Object.entries(manifest.contracts)) {
    switch (contract.kind) {
      case "uups": {
        const replacement = replacements.get(name);
        const implementation = replacement?.newImplementation ?? contract.implementation;
        const implementationCodeHash = replacement?.newImplementationCodeHash ?? contract.implementationCodeHash;
        await verifyRuntimeHash(run, rpcUrl, contract.proxy, contract.proxyCodeHash, `${name} proxy`);
        await verifyRuntimeHash(
          run,
          rpcUrl,
          implementation,
          implementationCodeHash,
          replacement === undefined ? `${name} implementation` : `${name} replacement`,
          replacement === undefined ? "manifest" : "recorded upgrade operation",
        );
        await verifyImplementationSlot(run, rpcUrl, contract.proxy, implementation, name);
        break;
      }
      case "implementation": {
        const replacement = name === "Validator" ? replacements.get(name) : undefined;
        const implementation = replacement?.newImplementation ?? contract.implementation;
        const codeHash = replacement?.newImplementationCodeHash ?? contract.implementationCodeHash;
        await verifyRuntimeHash(
          run,
          rpcUrl,
          implementation,
          codeHash,
          replacement === undefined ? `${name} implementation` : `${name} replacement`,
          replacement === undefined ? "manifest" : "recorded upgrade operation",
        );
        break;
      }
      case "standalone":
        await verifyRuntimeHash(
          run,
          rpcUrl,
          contract.implementation,
          contract.implementationCodeHash,
          `${name} implementation`,
        );
        break;
      case "beacon":
        await verifyBeacon(run, rpcUrl, name, contract, manifest, replacements);
        break;
      default: {
        const unknownContract = contract as ManifestContract & { kind: string };
        throw new Error(`manifest contract ${name} has unsupported kind ${unknownContract.kind}`);
      }
    }
  }
}

export async function verifyLiveDeployment(
  run: CommandRunner,
  rpcUrl: string,
  manifest: DeploymentManifest,
  operations: readonly UpgradeOperation[] = [],
  expectedManagerRoles?: ManagerRoleExpectations,
): Promise<void> {
  await verifyManifestContracts(run, rpcUrl, manifest, operations);

  const market = requireUupsContract(manifest, "PoRepMarket");
  const validatorFactory = requireUupsContract(manifest, "ValidatorFactory");
  const adapter = requireUupsContract(manifest, "DataCapEvidenceAdapter");
  const registry = requireUupsContract(manifest, "SPRegistry");
  const sliOracle = requireUupsContract(manifest, "SLIOracle");
  const sliScorer = requireUupsContract(manifest, "SLIScorer");
  const managerContract =
    manifest.contracts.AccessManager === undefined ? undefined : requireStandaloneContract(manifest, "AccessManager");
  const manager =
    managerContract === undefined
      ? undefined
      : readManifestAddress(managerContract.implementation, "manifest AccessManager implementation");
  const beacon = requireBeaconContract(manifest, "ValidatorBeacon");
  const claimInspector = requireStandaloneContract(manifest, "PoRepMarketClaimInspector");
  const sectorStatusInspector = requireStandaloneContract(manifest, "PoRepMarketSectorStatusInspector");
  const viewHelper = requireStandaloneContract(manifest, "PoRepMarketViewHelper");
  const recordedBeaconFactory = readManifestAddress(beacon.factoryProxy, "manifest ValidatorBeacon factoryProxy");
  const validatorFactoryProxy = readManifestAddress(validatorFactory.proxy, "manifest ValidatorFactory proxy");
  if (recordedBeaconFactory !== validatorFactoryProxy) {
    throw new Error(
      `ValidatorBeacon factoryProxy does not match ValidatorFactory proxy: expected ${validatorFactoryProxy}, got ${recordedBeaconFactory}`,
    );
  }

  const roleContract = manager ?? market.proxy;
  if (manager === undefined) {
    for (const [name, contract] of [
      ["PoRepMarket", market],
      ["ValidatorFactory", validatorFactory],
      ["DataCapEvidenceAdapter", adapter],
      ["SPRegistry", registry],
      ["SLIOracle", sliOracle],
      ["SLIScorer", sliScorer],
    ] as const) {
      await verifyRole(
        run,
        rpcUrl,
        contract.proxy,
        "DEFAULT_ADMIN_ROLE()(bytes32)",
        manifest.deployer,
        `${name} admin`,
      );
    }
  } else {
    for (const [name, contract] of [
      ["PoRepMarket", market],
      ["ValidatorFactory", validatorFactory],
      ["DataCapEvidenceAdapter", adapter],
      ["SPRegistry", registry],
      ["SLIOracle", sliOracle],
      ["SLIScorer", sliScorer],
    ] as const) {
      await verifyAddressCall(
        run,
        rpcUrl,
        contract.proxy,
        "accessManager()(address)",
        manager,
        `${name} AccessManager`,
      );
    }
    const currentAdmin = await readAddressCall(run, rpcUrl, manager, "defaultAdmin()(address)", "protocol admin");
    if (expectedManagerRoles !== undefined && currentAdmin !== expectedManagerRoles.defaultAdmin.toLowerCase()) {
      throw new Error(
        `protocol admin does not match expected initial admin: expected ${expectedManagerRoles.defaultAdmin.toLowerCase()}, got ${currentAdmin}`,
      );
    }
    await verifyRole(run, rpcUrl, manager, "DEFAULT_ADMIN_ROLE()(bytes32)", currentAdmin, "protocol admin");
    if (expectedManagerRoles !== undefined) {
      await verifyRole(
        run,
        rpcUrl,
        manager,
        "UPGRADER_ROLE()(bytes32)",
        expectedManagerRoles.upgrader,
        "protocol upgrader",
      );
    }
  }

  await verifyRole(
    run,
    rpcUrl,
    roleContract,
    "POREP_SERVICE_ROLE()(bytes32)",
    requireNonZeroDependency(manifest, "PoRepService"),
    "PoRep service",
  );
  await verifyRole(
    run,
    rpcUrl,
    manager ?? sliOracle.proxy,
    "ORACLE_ROLE()(bytes32)",
    requireNonZeroDependency(manifest, "Oracle"),
    "SLI oracle",
  );
  await verifyRole(
    run,
    rpcUrl,
    manager ?? adapter.proxy,
    "TERMINATION_ORACLE()(bytes32)",
    requireNonZeroDependency(manifest, "TerminationOracle"),
    "termination oracle",
  );
  await verifyRole(run, rpcUrl, manager ?? registry.proxy, "MARKET_ROLE()(bytes32)", market.proxy, "registry market");

  const operator = requireDependency(manifest, "Operator");
  if (operator !== zeroAddress) {
    await verifyRole(run, rpcUrl, manager ?? registry.proxy, "OPERATOR_ROLE()(bytes32)", operator, "SP operator");
  }

  await verifyAddressCall(
    run,
    rpcUrl,
    market.proxy,
    "getValidatorFactoryContract()(address)",
    validatorFactory.proxy,
    "market validator factory",
  );
  await verifyAddressCall(
    run,
    rpcUrl,
    market.proxy,
    "getSPRegistryContract()(address)",
    registry.proxy,
    "market SP registry",
  );
  await verifyAddressCall(
    run,
    rpcUrl,
    market.proxy,
    "getGlobalEvidenceAdapter()(address)",
    adapter.proxy,
    "market evidence adapter",
  );
  await verifyAddressCall(
    run,
    rpcUrl,
    adapter.proxy,
    "getPoRepMarketAddress()(address)",
    market.proxy,
    "adapter market",
  );
  await verifyAddressCall(
    run,
    rpcUrl,
    validatorFactory.proxy,
    "getBeacon()(address)",
    beacon.address,
    "ValidatorFactory beacon",
  );

  await loadRuntimeCode(run, rpcUrl, requireNonZeroDependency(manifest, "FilecoinPay"), "FilecoinPay");
  await loadRuntimeCode(run, rpcUrl, requireNonZeroDependency(manifest, "MetaAllocator"), "MetaAllocator");

  for (const name of ["USDFC", "AxlUSDC"]) {
    const token = manifest.externalDependencies[name];
    if (token === undefined) continue;
    const address = readManifestAddress(token, `manifest external dependency ${name}`);
    await loadRuntimeCode(run, rpcUrl, address, name);
    await verifyPaymentTokenConfiguration(run, rpcUrl, registry.proxy, address, name);
  }

  await verifyAddressCall(
    run,
    rpcUrl,
    claimInspector.implementation,
    "POREPMARKET_CONTRACT()(address)",
    market.proxy,
    "ClaimInspector market",
  );
  await verifyAddressCall(
    run,
    rpcUrl,
    claimInspector.implementation,
    "DATA_CAP_EVIDENCE_ADAPTER()(address)",
    adapter.proxy,
    "ClaimInspector adapter",
  );
  await verifyAddressCall(
    run,
    rpcUrl,
    sectorStatusInspector.implementation,
    "POREPMARKET_CONTRACT()(address)",
    market.proxy,
    "SectorStatusInspector market",
  );
  await verifyAddressCall(
    run,
    rpcUrl,
    viewHelper.implementation,
    "POREPMARKET_CONTRACT()(address)",
    market.proxy,
    "ViewHelper market",
  );
}

async function verifyPaymentTokenConfiguration(
  run: CommandRunner,
  rpcUrl: string,
  registry: string,
  token: string,
  name: string,
): Promise<void> {
  let output: string;
  try {
    output = await run(
      "cast",
      ["call", registry, "getPaymentTokenConfig(address)(bool,uint256)", token, "--rpc-url", rpcUrl],
      {},
    );
  } catch (error) {
    throw new Error(`could not read ${name} payment-token configuration`, {
      cause: error,
    });
  }
  const values = output.trim().split(/\s+/);
  if (values.length !== 2 || values[0] !== "true" || values[1] !== "1") {
    throw new Error(`${name} payment token must be allowed with minimum 1`);
  }
}

function collectUpgradeReplacements(
  manifest: DeploymentManifest,
  operations: readonly UpgradeOperation[],
): Map<string, UpgradeOperation> {
  const replacements = new Map<string, UpgradeOperation>();
  for (const operation of operations) {
    if (replacements.has(operation.target)) {
      throw new Error(`duplicate upgrade operation for ${operation.target}`);
    }
    const contract = manifest.contracts[operation.target];
    if (contract === undefined) {
      throw new Error(`upgrade operation target ${operation.target} is missing from manifest`);
    }
    if (operation.kind === "uups" && contract.kind !== "uups") {
      throw new Error(`upgrade operation ${operation.target} requires a uups manifest contract`);
    }
    if (operation.kind === "beacon" && (operation.target !== "Validator" || contract.kind !== "implementation")) {
      throw new Error("beacon upgrade operation must target Validator implementation");
    }
    replacements.set(operation.target, operation);
  }
  return replacements;
}

async function verifyRuntimeHash(
  run: CommandRunner,
  rpcUrl: string,
  address: string,
  expectedHashValue: string,
  label: string,
  expectedSource = "manifest",
): Promise<void> {
  const code = await loadRuntimeCode(run, rpcUrl, address, label);
  let output: string;
  try {
    output = await run("cast", ["keccak", code], {});
  } catch (error) {
    throw new Error(`could not hash ${label} runtime bytecode`, {
      cause: error,
    });
  }
  const actualHash = readHash(output.trim(), `${label} runtime code hash`);
  const expectedHash = readHash(expectedHashValue, `${label} manifest code hash`);
  if (actualHash !== expectedHash) {
    throw new Error(`${label} code hash does not match ${expectedSource}: expected ${expectedHash}, got ${actualHash}`);
  }
}

async function loadRuntimeCode(run: CommandRunner, rpcUrl: string, address: string, label: string): Promise<string> {
  let output: string;
  try {
    output = await run("cast", ["rpc", "--rpc-url", rpcUrl, "eth_getCode", address, "latest"], {});
  } catch (error) {
    throw new Error(`could not read ${label} runtime bytecode at ${address}`, {
      cause: error,
    });
  }
  let value: unknown;
  try {
    value = JSON.parse(output) as unknown;
  } catch {
    throw new Error(`${label} runtime bytecode RPC output is invalid`);
  }
  if (typeof value !== "string" || !runtimeCodePattern.test(value)) {
    throw new Error(`${label} runtime bytecode is malformed`);
  }
  if (value.toLowerCase() === "0x") {
    throw new Error(`${label} has no runtime bytecode`);
  }
  return value.toLowerCase();
}

async function verifyImplementationSlot(
  run: CommandRunner,
  rpcUrl: string,
  proxy: string,
  expectedImplementation: string,
  name: string,
): Promise<void> {
  let output: string;
  try {
    output = await run(
      "cast",
      ["rpc", "--rpc-url", rpcUrl, "eth_getStorageAt", proxy, implementationSlot, "latest"],
      {},
    );
  } catch (error) {
    throw new Error(`could not read ${name} implementation slot at proxy ${proxy}`, { cause: error });
  }
  let value: unknown;
  try {
    value = JSON.parse(output) as unknown;
  } catch {
    throw new Error(`${name} implementation slot RPC output is invalid`);
  }
  const actualImplementation = readAddressResult(value, `${name} implementation slot`);
  if (actualImplementation !== expectedImplementation.toLowerCase()) {
    throw new Error(
      `${name} implementation slot does not match: expected ${expectedImplementation.toLowerCase()}, got ${actualImplementation}`,
    );
  }
}

async function verifyBeacon(
  run: CommandRunner,
  rpcUrl: string,
  name: string,
  beacon: Extract<ManifestContract, { kind: "beacon" }>,
  manifest: DeploymentManifest,
  replacements: ReadonlyMap<string, UpgradeOperation>,
): Promise<void> {
  await loadRuntimeCode(run, rpcUrl, beacon.address, name);
  const validator = manifest.contracts.Validator;
  if (validator === undefined || validator.kind !== "implementation") {
    throw new Error("manifest Validator must be an implementation for ValidatorBeacon checks");
  }
  const replacement = replacements.get("Validator");
  const expectedImplementation = replacement?.newImplementation ?? validator.implementation;
  if (replacement === undefined && beacon.implementation.toLowerCase() !== expectedImplementation.toLowerCase()) {
    throw new Error(`${name} recorded implementation does not match Validator implementation`);
  }
  await verifyAddressCall(
    run,
    rpcUrl,
    beacon.address,
    "implementation()(address)",
    expectedImplementation,
    `${name} implementation`,
  );
  const manager = manifest.contracts.AccessManager;
  const expectedOwner =
    manager === undefined ? manifest.deployer : requireStandaloneContract(manifest, "AccessManager").implementation;
  await verifyAddressCall(run, rpcUrl, beacon.address, "owner()(address)", expectedOwner, `${name} owner`);
}

async function verifyAddressCall(
  run: CommandRunner,
  rpcUrl: string,
  target: string,
  signature: string,
  expectedAddress: string,
  label: string,
): Promise<void> {
  const actualAddress = await readAddressCall(run, rpcUrl, target, signature, label);
  if (actualAddress !== expectedAddress.toLowerCase()) {
    throw new Error(`${label} does not match: expected ${expectedAddress.toLowerCase()}, got ${actualAddress}`);
  }
}

async function readAddressCall(
  run: CommandRunner,
  rpcUrl: string,
  target: string,
  signature: string,
  label: string,
): Promise<string> {
  let output: string;
  try {
    output = await run("cast", ["call", target, signature, "--rpc-url", rpcUrl], {});
  } catch (error) {
    throw new Error(`could not read ${label} from contract ${target}`, {
      cause: error,
    });
  }
  return readAddressResult(output.trim(), label);
}

async function verifyRole(
  run: CommandRunner,
  rpcUrl: string,
  contract: string,
  roleSignature: string,
  account: string,
  label: string,
): Promise<void> {
  let roleOutput: string;
  try {
    roleOutput = await run("cast", ["call", contract, roleSignature, "--rpc-url", rpcUrl], {});
  } catch (error) {
    throw new Error(`could not read ${label} role identifier from contract ${contract}`, { cause: error });
  }
  const role = readHash(roleOutput.trim(), `${label} role identifier`);

  let grantedOutput: string;
  try {
    grantedOutput = await run(
      "cast",
      ["call", contract, "hasRole(bytes32,address)(bool)", role, account, "--rpc-url", rpcUrl],
      {},
    );
  } catch (error) {
    throw new Error(`could not check ${label} role on contract ${contract}`, {
      cause: error,
    });
  }
  if (grantedOutput.trim() !== "true") {
    throw new Error(`${label} role is missing for ${account} on contract ${contract}`);
  }
}

function readAddressResult(value: unknown, path: string): string {
  if (typeof value !== "string") {
    throw new Error(`${path} must return an address`);
  }
  if (addressPattern.test(value)) {
    return value.toLowerCase();
  }
  if (/^0x0{24}[0-9a-fA-F]{40}$/.test(value)) {
    return `0x${value.slice(-40).toLowerCase()}`;
  }
  throw new Error(`${path} must return a zero-padded 20-byte address`);
}

function readManifestAddress(value: unknown, path: string): string {
  if (typeof value !== "string" || !addressPattern.test(value)) {
    throw new Error(`${path} must be a 20-byte address`);
  }
  return value.toLowerCase();
}

function requireUupsContract(manifest: DeploymentManifest, name: string) {
  const contract = manifest.contracts[name];
  if (contract === undefined || contract.kind !== "uups") {
    throw new Error(`manifest contract ${name} must be uups`);
  }
  return contract;
}

function requireBeaconContract(manifest: DeploymentManifest, name: string) {
  const contract = manifest.contracts[name];
  if (contract === undefined || contract.kind !== "beacon") {
    throw new Error(`manifest contract ${name} must be beacon`);
  }
  return contract;
}

function requireStandaloneContract(manifest: DeploymentManifest, name: string) {
  const contract = manifest.contracts[name];
  if (contract === undefined || contract.kind !== "standalone") {
    throw new Error(`manifest contract ${name} must be standalone`);
  }
  return contract;
}

function requireDependency(manifest: DeploymentManifest, name: string): string {
  const address = manifest.externalDependencies[name];
  if (address === undefined || !addressPattern.test(address)) {
    throw new Error(`manifest external dependency ${name} must be a 20-byte address`);
  }
  return address.toLowerCase();
}

function requireNonZeroDependency(manifest: DeploymentManifest, name: string): string {
  const address = requireDependency(manifest, name);
  if (address === zeroAddress) throw new Error(`manifest external dependency ${name} must be non-zero`);
  return address;
}

function collectReceiptBlocks(receipts: readonly DeploymentTransaction[]): Map<number, string> {
  if (receipts.length === 0) {
    throw new Error("at least one transaction receipt is required for Filecoin finality");
  }
  const blocks = new Map<number, string>();
  for (const receipt of receipts) {
    if (!Number.isSafeInteger(receipt.blockNumber) || receipt.blockNumber <= 0) {
      throw new Error(`receipt transaction ${receipt.hash} has invalid block number`);
    }
    const blockHash = readHash(receipt.blockHash, `receipt block ${receipt.blockNumber} hash`);
    const previousHash = blocks.get(receipt.blockNumber);
    if (previousHash !== undefined && previousHash !== blockHash) {
      throw new Error(`receipt block ${receipt.blockNumber} has conflicting hashes`);
    }
    blocks.set(receipt.blockNumber, blockHash);
  }
  return blocks;
}

async function loadFinalizedHeight(run: CommandRunner, rpcUrl: string, signal?: AbortSignal): Promise<number> {
  let output: string;
  try {
    output = await run("cast", ["rpc", "--rpc-url", rpcUrl, "Filecoin.ChainGetFinalizedTipSet"], { signal });
  } catch (error) {
    throwIfCancelled(signal);
    throw new Error("could not read Filecoin finalized height", {
      cause: error,
    });
  }

  const tipSet = parseJsonObject(output, "Filecoin finalized tipset");
  if (!Number.isSafeInteger(tipSet.Height) || (tipSet.Height as number) < 0) {
    throw new Error("Filecoin finalized tipset Height must be a non-negative integer");
  }
  return tipSet.Height as number;
}

async function verifyCanonicalBlock(
  run: CommandRunner,
  rpcUrl: string,
  height: number,
  expectedHash: string,
  signal?: AbortSignal,
): Promise<void> {
  const quantity = `0x${height.toString(16)}`;
  let output: string;
  try {
    output = await run("cast", ["rpc", "--rpc-url", rpcUrl, "eth_getBlockByNumber", quantity, "false"], { signal });
  } catch (error) {
    throwIfCancelled(signal);
    throw new Error(`could not read canonical block ${height}`, {
      cause: error,
    });
  }
  throwIfCancelled(signal);

  const block = parseJsonObject(output, `canonical block ${height}`);
  const actualHeight = readQuantity(block.number, `canonical block ${height} number`);
  if (actualHeight !== height) {
    throw new Error(`canonical block height mismatch for receipt block ${height}: got ${actualHeight}`);
  }
  const actualHash = readHash(block.hash, `canonical block ${height} hash`);
  if (actualHash !== expectedHash) {
    throw new Error(`receipt block ${height} is not canonical: expected ${expectedHash}, got ${actualHash}`);
  }
}

function parseJsonObject(text: string, path: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(text) as unknown;
  } catch {
    throw new Error(`${path} JSON is invalid`);
  }
  if (!isObject(value)) {
    throw new Error(`${path} must be an object`);
  }
  return value;
}

function throwIfCancelled(signal?: AbortSignal): void {
  if (signal?.aborted) {
    const error = new Error("Filecoin finality wait cancelled");
    error.name = "AbortError";
    throw error;
  }
}

function abortableSleep(milliseconds: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    throwIfCancelled(signal);
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", cancel);
      resolve();
    }, milliseconds);
    const cancel = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", cancel);
      const error = new Error("Filecoin finality wait cancelled");
      error.name = "AbortError";
      reject(error);
    };
    signal?.addEventListener("abort", cancel, { once: true });
  });
}

function validateRequestedHashes(hashes: readonly string[]): string[] {
  if (hashes.length === 0) {
    throw new Error("at least one transaction hash is required");
  }

  const normalized: string[] = [];
  const unique = new Set<string>();
  for (const [index, hash] of hashes.entries()) {
    if (!transactionHashPattern.test(hash)) {
      throw new Error(`transaction hash ${index} must be 32 bytes`);
    }
    const normalizedHash = hash.toLowerCase();
    if (unique.has(normalizedHash)) {
      throw new Error(`duplicate transaction hash ${normalizedHash}`);
    }
    unique.add(normalizedHash);
    normalized.push(normalizedHash);
  }
  return normalized;
}

function parseTransactionReceipt(text: string, requestedHash: string): DeploymentTransaction {
  let value: unknown;
  try {
    value = JSON.parse(text) as unknown;
  } catch {
    throw new Error(`receipt JSON for transaction ${requestedHash} is invalid`);
  }
  if (value === null) {
    throw new Error(`receipt is missing for transaction ${requestedHash}`);
  }
  if (!isObject(value)) {
    throw new Error(`receipt for transaction ${requestedHash} must be an object`);
  }

  const receiptHash = readHash(value.transactionHash, `transaction ${requestedHash} receipt hash`);

  const status = readQuantity(value.status, `transaction ${requestedHash} status`);
  if (status !== 1) {
    throw new Error(`transaction ${requestedHash} failed with status ${status}`);
  }
  const blockNumber = readQuantity(value.blockNumber, `transaction ${requestedHash} blockNumber`);
  if (blockNumber <= 0) {
    throw new Error(`transaction ${requestedHash} must have a positive block number`);
  }
  const blockHash = readHash(value.blockHash, `transaction ${requestedHash} blockHash`);
  const contractAddress = readReceiptContractAddress(value.contractAddress, requestedHash);

  return { hash: receiptHash, status, blockNumber, blockHash, contractAddress };
}

function readQuantity(value: unknown, path: string): number {
  if (typeof value !== "string" || !quantityPattern.test(value)) {
    throw new Error(`${path} must be a valid JSON-RPC hex quantity`);
  }
  const quantity = BigInt(value);
  if (quantity > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`${path} exceeds the safe integer range`);
  }
  return Number(quantity);
}

function readHash(value: unknown, path: string): string {
  if (typeof value !== "string" || !transactionHashPattern.test(value)) {
    throw new Error(`${path} must be a 32-byte hash`);
  }
  return value.toLowerCase();
}

function readReceiptContractAddress(value: unknown, transactionHash: string): string | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== "string" || !addressPattern.test(value)) {
    throw new Error(`transaction ${transactionHash} contractAddress must be null or a 20-byte address`);
  }
  return value.toLowerCase();
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

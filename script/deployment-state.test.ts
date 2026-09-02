import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  classifyDeployCanonicalState,
  classifyUpgradeCanonicalState,
  hashRawBytes,
  parseDeploymentManifest,
  parsePendingOperation,
  parseUpgradeOperations,
  renderUpgradedManifest,
} from "./deployment-state.ts";

const address = `0x${"1".repeat(40)}`;
const nextAddress = `0x${"2".repeat(40)}`;
const hash = `0x${"a".repeat(64)}`;
const nextHash = `0x${"b".repeat(64)}`;

function manifest() {
  return {
    status: "finalized",
    finalizedAt: "2026-08-05T12:00:00Z",
    deployer: address,
    release: { buildInfoSha256: hash },
    contracts: {
      Market: {
        kind: "uups",
        artifact: "src/Market.sol:Market",
        proxy: address,
        implementation: address,
        proxyCodeHash: hash,
        implementationCodeHash: hash,
      },
      Validator: {
        kind: "implementation",
        artifact: "src/Validator.sol:Validator",
        implementation: address,
        implementationCodeHash: hash,
      },
      ValidatorBeacon: {
        kind: "beacon",
        artifact: "UpgradeableBeacon",
        address,
        implementation: address,
        factoryProxy: address,
      },
    },
    externalDependencies: { FilecoinPay: address },
  };
}

function deployPending() {
  return {
    status: "pending",
    operation: "deploy",
    network: "devnet",
    chainId: 31415926,
    previousManifestSha256: null,
    release: { buildInfoSha256: hash },
    broadcastSha256: nextHash,
    result: manifest(),
    finalizedAt: null,
    resultManifestSha256: null,
  };
}

function upgradePending() {
  return {
    status: "pending",
    operation: "upgrade",
    network: "devnet",
    chainId: 31415926,
    targets: ["Market"],
    operations: [{
      target: "Market",
      kind: "uups",
      artifact: "src/Market.sol:Market",
      newImplementation: nextAddress,
      newImplementationCodeHash: nextHash,
    }],
    sourceManifestSha256: hash,
    resultManifestSha256: nextHash,
    finalizedAt: null,
    release: { buildInfoSha256: nextHash },
    broadcastSha256: hash,
  };
}

test("parses manifests and pending deploy or upgrade journals", () => {
  assert.equal(parseDeploymentManifest(JSON.stringify(manifest())).contracts.Market.kind, "uups");
  assert.equal(parsePendingOperation(JSON.stringify(deployPending())).operation, "deploy");
  assert.equal(parsePendingOperation(JSON.stringify(upgradePending())).operation, "upgrade");
});

test("rejects malformed JSON, unsupported contract kinds, and invalid hashes", () => {
  assert.throws(() => parseDeploymentManifest("{"), /manifest JSON is invalid/);
  const badKind = manifest();
  badKind.contracts.Market.kind = "proxy";
  assert.throws(() => parseDeploymentManifest(JSON.stringify(badKind)), /kind is unsupported/);
  assert.throws(() => parseUpgradeOperations(JSON.stringify([{ ...upgradePending().operations[0], newImplementationCodeHash: "bad" }])), /32-byte hash/);
});

test("rejects reserved contract keys", () => {
  const hostile = JSON.stringify(manifest()).replace('"Market":', '"__proto__":');
  assert.throws(() => parseDeploymentManifest(hostile), /reserved/);
});

test("hashes exact raw bytes", () => {
  const compact = new TextEncoder().encode('{"a":1}');
  const spaced = new TextEncoder().encode('{ "a": 1 }');
  assert.equal(hashRawBytes(compact), "0x015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862");
  assert.notEqual(hashRawBytes(compact), hashRawBytes(spaced));
});

test("renders UUPS and Validator upgrades without mutating the source", () => {
  const source = parseDeploymentManifest(JSON.stringify(manifest()));
  const uups = parsePendingOperation(JSON.stringify(upgradePending()));
  assert.equal(uups.operation, "upgrade");
  const receipts = [{ hash, status: 1, blockNumber: 10, blockHash: nextHash, contractAddress: nextAddress }];
  const finalizedAt = "2026-08-06T12:00:00Z";
  const upgraded = renderUpgradedManifest(source, uups, receipts, finalizedAt);
  assert.equal(source.contracts.Market.implementation, address);
  assert.equal(upgraded.contracts.Market.implementation, nextAddress);
  assert.deepEqual(upgraded.transactions, receipts);
  assert.equal(upgraded.finalizedAt, finalizedAt);
});

test("accepts retries only from the exact source or exact result", () => {
  const deploy = parsePendingOperation(JSON.stringify({ ...deployPending(), resultManifestSha256: nextHash }));
  const upgrade = parsePendingOperation(JSON.stringify(upgradePending()));
  assert.equal(deploy.operation, "deploy");
  assert.equal(upgrade.operation, "upgrade");
  assert.equal(classifyDeployCanonicalState(undefined, deploy), "absent");
  assert.equal(classifyDeployCanonicalState(nextHash, deploy), "result");
  assert.equal(classifyUpgradeCanonicalState(hash, upgrade), "source");
  assert.equal(classifyUpgradeCanonicalState(nextHash, upgrade), "result");
  assert.equal(classifyUpgradeCanonicalState(`0x${"c".repeat(64)}`, upgrade), "unexpected");
});

test("parses the current Calibnet manifest", async () => {
  const parsed = parseDeploymentManifest(await readFile("deployments/calibnet/latest.json", "utf8"));
  assert.equal(parsed.status, "finalized");
  assert.equal(parsed.contracts.ValidatorBeacon.kind, "beacon");
});

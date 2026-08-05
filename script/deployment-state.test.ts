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
  renderDeployManifest,
  renderUpgradedManifest,
} from "./deployment-state.ts";

const address = "0x1111111111111111111111111111111111111111";
const nextAddress = "0x2222222222222222222222222222222222222222";
const hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const nextHash = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

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
        implementation: nextAddress,
        proxyCodeHash: hash,
        implementationCodeHash: nextHash,
      },
      Validator: {
        kind: "implementation",
        artifact: "src/Validator.sol:Validator",
        implementation: address,
        implementationCodeHash: hash,
      },
      Inspector: {
        kind: "standalone",
        artifact: "src/Inspector.sol:Inspector",
        implementation: address,
        implementationCodeHash: hash,
      },
      ValidatorBeacon: {
        kind: "beacon",
        artifact: "UpgradeableBeacon",
        address,
        implementation: nextAddress,
        factoryProxy: address,
      },
    },
    externalDependencies: {
      FilecoinPay: address,
      PoRepService: address,
      MetaAllocator: address,
      TerminationOracle: address,
      Oracle: address,
      Operator: address,
    },
    transactions: [
      {
        hash,
        status: 1,
        blockNumber: 123,
        blockHash: nextHash,
        contractAddress: null,
      },
    ],
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
    operations: [
      {
        target: "Market",
        kind: "uups",
        artifact: "src/Market.sol:Market",
        newImplementation: nextAddress,
        newImplementationCodeHash: nextHash,
      },
    ],
    sourceManifestSha256: hash,
    resultManifestSha256: nextHash,
    release: { buildInfoSha256: nextHash },
    broadcastSha256: hash,
  };
}

test("parses every supported manifest contract kind", () => {
  const parsed = parseDeploymentManifest(JSON.stringify(manifest()));

  assert.equal(parsed.contracts.Market.kind, "uups");
  assert.equal(parsed.contracts.Validator.kind, "implementation");
  assert.equal(parsed.contracts.Inspector.kind, "standalone");
  assert.equal(parsed.contracts.ValidatorBeacon.kind, "beacon");
});

test("rejects malformed manifest JSON and names the document", () => {
  assert.throws(() => parseDeploymentManifest("{"), /manifest JSON is invalid/);
});

test("rejects invalid manifest fields and unknown contract kinds", () => {
  const missingDeployer = manifest();
  delete (missingDeployer as { deployer?: string }).deployer;
  assert.throws(() => parseDeploymentManifest(JSON.stringify(missingDeployer)), /manifest\.deployer/);

  const unknownKind = manifest();
  unknownKind.contracts.Market.kind = "proxy";
  assert.throws(
    () => parseDeploymentManifest(JSON.stringify(unknownKind)),
    /manifest\.contracts\.Market\.kind/,
  );
});

test("rejects a hostile __proto__ contract key", () => {
  const hostile = JSON.stringify(manifest()).replace('"Market":', '"__proto__":');

  assert.throws(() => parseDeploymentManifest(hostile), /manifest\.contracts\.__proto__/);
});

test("parses deploy and upgrade pending state with checked fields", () => {
  const deploy = parsePendingOperation(JSON.stringify(deployPending()));
  const upgrade = parsePendingOperation(JSON.stringify(upgradePending()));

  assert.equal(deploy.operation, "deploy");
  assert.equal(upgrade.operation, "upgrade");
  assert.equal(upgrade.operations[0]?.newImplementation, nextAddress);
});

test("parses pre-broadcast journals with null evidence fields", () => {
  const deploy = { ...deployPending(), broadcastSha256: null, result: null };
  const upgrade = {
    ...upgradePending(),
    operations: [],
    broadcastSha256: null,
    resultManifestSha256: null,
  };

  const parsedDeploy = parsePendingOperation(JSON.stringify(deploy));
  const parsedUpgrade = parsePendingOperation(JSON.stringify(upgrade));

  assert.equal(parsedDeploy.operation, "deploy");
  assert.equal(parsedUpgrade.operation, "upgrade");
});

test("rejects deploy rendering without completed broadcast evidence", () => {
  const missingBroadcast = parsePendingOperation(JSON.stringify({ ...deployPending(), broadcastSha256: null }));
  assert.equal(missingBroadcast.operation, "deploy");
  assert.throws(
    () => renderDeployManifest(missingBroadcast, "2026-08-05T13:00:00Z"),
    /pending\.broadcastSha256/,
  );

  const missingResultHash = parsePendingOperation(
    JSON.stringify({ ...deployPending(), resultManifestSha256: null }),
  );
  assert.equal(missingResultHash.operation, "deploy");
  assert.throws(
    () => renderDeployManifest(missingResultHash, "2026-08-05T13:00:00Z"),
    /pending\.resultManifestSha256/,
  );
});

test("rejects upgrade rendering without completed broadcast evidence", () => {
  const source = parseDeploymentManifest(JSON.stringify(manifest()));
  const missingBroadcast = parsePendingOperation(JSON.stringify({ ...upgradePending(), broadcastSha256: null }));
  assert.equal(missingBroadcast.operation, "upgrade");
  assert.throws(() => renderUpgradedManifest(source, missingBroadcast), /pending\.broadcastSha256/);

  const missingResultHash = parsePendingOperation(
    JSON.stringify({ ...upgradePending(), resultManifestSha256: null }),
  );
  assert.equal(missingResultHash.operation, "upgrade");
  assert.throws(() => renderUpgradedManifest(source, missingResultHash), /pending\.resultManifestSha256/);
});

test("rejects malformed pending fields and mismatched operation output", () => {
  const invalidDeploy = deployPending();
  invalidDeploy.chainId = 0;
  assert.throws(() => parsePendingOperation(JSON.stringify(invalidDeploy)), /pending\.chainId/);

  const invalidUpgrade = upgradePending();
  invalidUpgrade.operations[0]!.kind = "beacon";
  assert.throws(() => parsePendingOperation(JSON.stringify(invalidUpgrade)), /pending\.operations\[0\]\.kind/);
});

test("parses Forge upgrade operations and rejects an invalid operation field", () => {
  const parsed = parseUpgradeOperations(JSON.stringify(upgradePending().operations));
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0]?.target, "Market");

  const operations = upgradePending().operations;
  operations[0]!.newImplementationCodeHash = "not-a-hash";
  assert.throws(() => parseUpgradeOperations(JSON.stringify(operations)), /operations\[0\]\.newImplementationCodeHash/);
});

test("hashes raw bytes without normalizing JSON", () => {
  const compact = new TextEncoder().encode('{"a":1}');
  const spaced = new TextEncoder().encode('{ "a": 1 }');

  assert.equal(hashRawBytes(compact), "0x015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862");
  assert.notEqual(hashRawBytes(compact), hashRawBytes(spaced));
});

test("renders a finalized deploy manifest from the recorded result", () => {
  const pending = parsePendingOperation(
    JSON.stringify({ ...deployPending(), resultManifestSha256: nextHash }),
  );
  assert.equal(pending.operation, "deploy");
  const rendered = renderDeployManifest(pending, "2026-08-05T13:00:00Z");
  const result = pending.result;
  if (result === null) {
    throw new Error("test fixture result is missing");
  }

  assert.equal(rendered.status, "finalized");
  assert.equal(rendered.finalizedAt, "2026-08-05T13:00:00Z");
  assert.deepEqual(rendered.contracts, result.contracts);
});

test("renders an upgrade without mutating the source manifest", () => {
  const sourceJson = manifest();
  sourceJson.contracts.Market.implementation = address;
  sourceJson.contracts.Market.implementationCodeHash = hash;
  const source = parseDeploymentManifest(JSON.stringify(sourceJson));
  const pending = parsePendingOperation(JSON.stringify(upgradePending()));
  assert.equal(pending.operation, "upgrade");
  const rendered = renderUpgradedManifest(source, pending);

  assert.equal(source.contracts.Market.implementation, address);
  assert.equal(rendered.contracts.Market.implementation, nextAddress);
  assert.equal(rendered.release.buildInfoSha256, nextHash);
});

test("classifies deploy retry state including completed publication and unrelated state", () => {
  const pending = parsePendingOperation(JSON.stringify(deployPending()));
  assert.equal(pending.operation, "deploy");
  const withResult = { ...pending, resultManifestSha256: nextHash };

  assert.equal(classifyDeployCanonicalState(undefined, withResult), "absent");
  assert.equal(classifyDeployCanonicalState(nextHash, withResult), "result");
  assert.equal(classifyDeployCanonicalState(hash, withResult), "unexpected");

  const withPrevious = { ...withResult, previousManifestSha256: hash };
  assert.equal(classifyDeployCanonicalState(undefined, withPrevious), "unexpected");
  assert.equal(classifyDeployCanonicalState(hash, withPrevious), "source");
});

test("classifies upgrade retry state only for exact source or result", () => {
  const pending = parsePendingOperation(JSON.stringify(upgradePending()));
  assert.equal(pending.operation, "upgrade");

  assert.equal(classifyUpgradeCanonicalState(hash, pending), "source");
  assert.equal(classifyUpgradeCanonicalState(nextHash, pending), "result");
  assert.equal(classifyUpgradeCanonicalState(undefined, pending), "unexpected");
  assert.equal(classifyUpgradeCanonicalState("0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", pending), "unexpected");
});

test("parses the current Calibnet manifest", async () => {
  const source = await readFile("deployments/calibnet/latest.json", "utf8");
  const parsed = parseDeploymentManifest(source);

  assert.equal(parsed.status, "finalized");
  assert.equal(parsed.contracts.ValidatorBeacon.kind, "beacon");
});

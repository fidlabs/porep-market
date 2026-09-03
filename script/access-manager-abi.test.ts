import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const roleNames = [
  "DEFAULT_ADMIN_ROLE",
  "UPGRADER_ROLE",
  "POREP_SERVICE_ROLE",
  "ORACLE_ROLE",
  "TERMINATION_ORACLE",
  "MARKET_ROLE",
  "OPERATOR_ROLE",
];
const administration = [
  "grantRole",
  "revokeRole",
  "renounceRole",
  "getRoleAdmin",
  "hasRole",
  "defaultAdmin",
  "pendingDefaultAdmin",
  "defaultAdminDelay",
  "pendingDefaultAdminDelay",
  "defaultAdminDelayIncreaseWait",
  "beginDefaultAdminTransfer",
  "cancelDefaultAdminTransfer",
  "acceptDefaultAdminTransfer",
  "changeDefaultAdminDelay",
  "rollbackDefaultAdminDelay",
];

async function functionNames(contract: string): Promise<Set<string>> {
  const abi = JSON.parse(await readFile(new URL(`../abis/${contract}.json`, import.meta.url), "utf8"));
  return new Set(
    abi.filter((entry: { type: string }) => entry.type === "function").map((entry: { name: string }) => entry.name),
  );
}

for (const contract of [
  "PoRepMarket",
  "SPRegistry",
  "DataCapEvidenceAdapter",
  "SLIOracle",
  "SLIScorer",
  "ValidatorFactory",
  "Validator",
]) {
  test(`${contract} exposes its manager but no local role administration`, async () => {
    const names = await functionNames(contract);
    assert.ok(names.has("accessManager"));
    for (const name of [...roleNames, ...administration, "setAdmin", "setUpgraderRole", "setAccessManager"]) {
      assert.equal(names.has(name), false, `${contract} must not expose ${name}`);
    }
  });
}

test("AccessManager owns the role ABI and exposes only the narrow beacon operation", async () => {
  const names = await functionNames("AccessManager");
  for (const name of [...roleNames, ...administration, "upgradeBeacon"]) {
    assert.ok(names.has(name), `AccessManager must expose ${name}`);
  }
  assert.equal(names.has("execute"), false);
});

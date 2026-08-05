import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { networkConfigs } from "./deployment.ts";

const scriptPath = "script/deployment.ts";

function runDeploymentCommand(...args: string[]) {
  return spawnSync(process.execPath, [scriptPath, ...args], {
    encoding: "utf8",
  });
}

test("prints usage without a command", () => {
  const result = runDeploymentCommand();

  assert.equal(result.status, 1);
  assert.match(result.stderr, /^Usage: deployment.ts <command> <network> \[args\.\.\.\]$/m);
});

test("rejects unsupported commands", () => {
  const result = runDeploymentCommand("remove", "devnet");

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported command: remove/);
});

test("rejects unsupported networks", () => {
  const result = runDeploymentCommand("deploy", "localnet");

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported network: localnet/);
});

for (const command of ["deploy", "finalize-deploy", "upgrade", "finalize-upgrade", "verify"]) {
  test(`accepts supported command: ${command}`, () => {
    const result = runDeploymentCommand(command, "devnet");

    assert.equal(result.status, 1);
    assert.equal(result.stderr, `command is not implemented: ${command}\n`);
  });
}

for (const network of ["devnet", "calibnet", "mainnet"]) {
  test(`accepts supported network: ${network}`, () => {
    const result = runDeploymentCommand("verify", network);

    assert.equal(result.status, 1);
    assert.equal(result.stderr, "command is not implemented: verify\n");
  });
}

test("maps Filecoin networks to their chain IDs", () => {
  assert.deepEqual(networkConfigs, {
    devnet: { chainId: 31415926 },
    calibnet: { chainId: 314159 },
    mainnet: { chainId: 314 },
  });
});

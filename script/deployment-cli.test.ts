import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";

const scriptPath = new URL("./deployment.ts", import.meta.url);

function runDeploymentCommand(...args: string[]) {
  return spawnSync(process.execPath, [scriptPath.pathname, ...args], {
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

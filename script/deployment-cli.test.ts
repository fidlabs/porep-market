import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { installSignalHandling, networkConfigs, runProcess, writeAtomicFile } from "./deployment.ts";

const script = fileURLToPath(new URL("./deployment.ts", import.meta.url));

function temporaryDirectory(): string {
  return mkdtempSync(join(tmpdir(), "porep-deployment-cli-"));
}

function executable(directory: string, name: string, body: string): string {
  const path = join(directory, name);
  writeFileSync(path, `#!${process.execPath}\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
}

function environment(directory: string): NodeJS.ProcessEnv {
  return {
    DEPLOYMENTS_ROOT: join(directory, "deployments"),
    PENDING_ROOT_TS: join(directory, "pending-ts"),
    PENDING_ROOT: join(directory, "pending-bash"),
    RPC_DEVNET: "http://devnet.example",
    PRIVATE_KEY_DEVNET: "devnet-key",
    FILECOIN_PAY_DEVNET: `0x${"1".repeat(40)}`,
    TERMINATION_ORACLE_DEVNET: `0x${"2".repeat(40)}`,
    ORACLE_DEVNET: `0x${"3".repeat(40)}`,
    POREP_SERVICE_DEVNET: `0x${"4".repeat(40)}`,
    META_ALLOCATOR_DEVNET: `0x${"5".repeat(40)}`,
    OPERATOR_ADDR_DEVNET: `0x${"6".repeat(40)}`,
  };
}

function run(args: readonly string[], env: NodeJS.ProcessEnv = {}) {
  return spawnSync(process.execPath, [script, ...args], { encoding: "utf8", env: { ...process.env, ...env } });
}

test("rejects invalid command lines", () => {
  assert.match(run([]).stderr, /Usage: deployment.ts/);
  assert.match(run(["remove", "devnet"]).stderr, /unsupported command/);
  assert.match(run(["deploy", "localnet"]).stderr, /unsupported network/);
  assert.match(run(["deploy", "devnet", "bad"]).stderr, /unsupported deploy arguments/);
  assert.match(run(["upgrade", "devnet"]).stderr, /requires at least one target/);
  assert.match(run(["verify", "devnet", "bad"]).stderr, /does not accept arguments/);
});

test("maps the three Filecoin networks explicitly", () => {
  assert.equal(networkConfigs.devnet.chainId, 31415926);
  assert.equal(networkConfigs.calibnet.chainId, 314159);
  assert.equal(networkConfigs.mainnet.chainId, 314);
  assert.equal(networkConfigs.mainnet.rpcVariable, "RPC_MAINNET");
});

test("runs subprocesses without shell interpolation and reports failures", async () => {
  const directory = temporaryDirectory();
  try {
    const command = executable(directory, "command", "process.stdout.write(JSON.stringify(process.argv.slice(2)))");
    assert.deepEqual(JSON.parse(await runProcess(command, ["a b", "$HOME"])), ["a b", "$HOME"]);
    const failure = executable(directory, "failure", "process.stderr.write('failed'); process.exitCode = 2");
    await assert.rejects(runProcess(failure, []), /exited with code 2: failed/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("writes files atomically", () => {
  const directory = temporaryDirectory();
  try {
    const path = join(directory, "nested", "pending.json");
    writeAtomicFile(path, "{}\n");
    assert.equal(readFileSync(path, "utf8"), "{}\n");
    assert.deepEqual(readdirSync(dirname(path)), ["pending.json"]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("checks chain ID and mainnet confirmation before operating", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('314')");
    let result = run(["deploy", "devnet"], { ...environment(directory), CAST_BIN: cast });
    assert.match(result.stderr, /devnet RPC chain ID must be 31415926, got 314/);

    result = run(["verify", "mainnet"], {
      CAST_BIN: cast,
      RPC_MAINNET: "http://mainnet.example",
      CONFIRM_MAINNET: "",
      DEPLOYMENTS_ROOT: join(directory, "deployments"),
    });
    assert.match(result.stderr, /set CONFIRM_MAINNET=yes/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("refuses an unfinished TypeScript or Bash operation", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('31415926')");
    const git = executable(directory, "git", "");
    const forge = executable(directory, "forge", "process.exitCode = 99");
    const env: NodeJS.ProcessEnv = { ...environment(directory), CAST_BIN: cast, GIT_BIN: git, FORGE_BIN: forge };

    for (const pendingRoot of [env.PENDING_ROOT_TS!, env.PENDING_ROOT!]) {
      const pending = join(pendingRoot, "devnet", "pending-upgrade.json");
      mkdirSync(dirname(pending), { recursive: true });
      writeFileSync(pending, '{"status":"pending"}\n');
      const result = run(["deploy", "devnet"], env);
      assert.match(result.stderr, /pending operation already exists/);
      rmSync(pending);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("checks clean source before invoking Forge", () => {
  const directory = temporaryDirectory();
  try {
    const cast = executable(directory, "cast", "process.stdout.write('31415926')");
    const git = executable(directory, "git", "process.stdout.write(' M src/PoRepMarket.sol')");
    const marker = join(directory, "forge-ran");
    const forge = executable(directory, "forge", `require('node:fs').writeFileSync(${JSON.stringify(marker)}, '')`);
    const result = run(["deploy", "devnet"], {
      ...environment(directory),
      CAST_BIN: cast,
      GIT_BIN: git,
      FORGE_BIN: forge,
    });
    assert.match(result.stderr, /deployment source is dirty/);
    assert.equal(readdirSync(directory).includes("forge-ran"), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("SIGINT and SIGTERM share one abort signal and clean up listeners", () => {
  const before = [process.listenerCount("SIGINT"), process.listenerCount("SIGTERM")];
  const handling = installSignalHandling();
  process.emit("SIGINT");
  assert.equal(handling.signal.aborted, true);
  handling.dispose();
  assert.deepEqual([process.listenerCount("SIGINT"), process.listenerCount("SIGTERM")], before);
});

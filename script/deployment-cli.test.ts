import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { installSignalHandling, networkConfigs, runProcess, writeAtomicFile } from "./deployment.ts";

const scriptPath = fileURLToPath(new URL("./deployment.ts", import.meta.url));
const repositoryRoot = dirname(dirname(scriptPath));

function runDeploymentCommand(args: readonly string[], environment: NodeJS.ProcessEnv = {}, cwd?: string) {
  return spawnSync(process.execPath, [scriptPath, ...args], {
    cwd,
    encoding: "utf8",
    env: { ...process.env, ...environment },
  });
}

function createTemporaryDirectory(): string {
  return mkdtempSync(join(tmpdir(), "porep-deployment-cli-"));
}

function createFakeExecutable(directory: string, name: string, output = ""): string {
  const path = join(directory, name);
  writeFileSync(
    path,
    `#!${process.execPath}\n` +
      "import { appendFileSync } from 'node:fs';\n" +
      "if (process.env.FAKE_COMMAND_LOG) appendFileSync(process.env.FAKE_COMMAND_LOG, JSON.stringify(process.argv.slice(2)) + '\\n');\n" +
      "const dirtyPath = process.env.FAKE_DIRTY_PATH;\n" +
      "if (dirtyPath && process.argv.includes(dirtyPath)) process.stdout.write(' M latest.json\\n');\n" +
      `else process.stdout.write(${JSON.stringify(output)});\n`,
  );
  chmodSync(path, 0o755);
  return path;
}

function deploymentEnvironment(directory: string): NodeJS.ProcessEnv {
  return {
    PATH: `${directory}${delimiter}${process.env.PATH ?? ""}`,
    DEPLOYMENTS_ROOT: join(directory, "deployments"),
    RPC_DEVNET: "http://devnet.example",
    PRIVATE_KEY_DEVNET: "devnet-key",
    FILECOIN_PAY_DEVNET: "0x0000000000000000000000000000000000000001",
    TERMINATION_ORACLE_DEVNET: "0x0000000000000000000000000000000000000002",
    ORACLE_DEVNET: "0x0000000000000000000000000000000000000003",
    POREP_SERVICE_DEVNET: "0x0000000000000000000000000000000000000004",
    META_ALLOCATOR_DEVNET: "0x0000000000000000000000000000000000000005",
    OPERATOR_ADDR_DEVNET: "0x0000000000000000000000000000000000000006",
  };
}

function createCanonicalManifest(directory: string): string {
  const manifest = join(directory, "deployments", "devnet", "latest.json");
  mkdirSync(dirname(manifest), { recursive: true });
  writeFileSync(manifest, "{}\n");
  return manifest;
}

test("prints usage without a command", () => {
  const result = runDeploymentCommand([]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /^Usage: deployment.ts <command> <network> \[args\.\.\.\]$/m);
});

test("rejects unsupported commands", () => {
  const result = runDeploymentCommand(["remove", "devnet"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported command: remove/);
});

test("rejects unsupported networks", () => {
  const result = runDeploymentCommand(["deploy", "localnet"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported network: localnet/);
});

test("deploy accepts only its optional --fresh argument", () => {
  const result = runDeploymentCommand(["deploy", "devnet", "unexpected"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported deploy arguments: unexpected/);
});

test("upgrade requires at least one target", () => {
  const result = runDeploymentCommand(["upgrade", "devnet"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /upgrade requires at least one target/);
});

for (const command of ["finalize-deploy", "finalize-upgrade", "verify"] as const) {
  test(`${command} rejects extra arguments`, () => {
    const result = runDeploymentCommand([command, "devnet", "unexpected"]);

    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`${command} does not accept arguments`));
  });
}

test("maps Filecoin networks to their chain IDs", () => {
  assert.deepEqual(networkConfigs, {
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
  });
});

test("runs an executable with an exact argument array", async () => {
  const directory = createTemporaryDirectory();
  const commandLog = join(directory, "commands.jsonl");
  const forge = createFakeExecutable(directory, "forge", "forge output");
  const previousLog = process.env.FAKE_COMMAND_LOG;
  process.env.FAKE_COMMAND_LOG = commandLog;

  try {
    const output = await runProcess(forge, ["build", "--root", "/release", "--build-info"]);

    assert.equal(output, "forge output");
    assert.deepEqual(JSON.parse(readFileSync(commandLog, "utf8")), ["build", "--root", "/release", "--build-info"]);
  } finally {
    if (previousLog === undefined) delete process.env.FAKE_COMMAND_LOG;
    else process.env.FAKE_COMMAND_LOG = previousLog;
    rmSync(directory, { force: true, recursive: true });
  }
});

test("reports the executable exit code and stderr", async () => {
  const directory = createTemporaryDirectory();
  const forge = join(directory, "forge");
  writeFileSync(forge, `#!${process.execPath}\nprocess.stderr.write("forge failed"); process.exitCode = 2;\n`);
  chmodSync(forge, 0o755);

  try {
    await assert.rejects(runProcess(forge, ["build"]), /forge exited with code 2: forge failed/);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("deploy preflight checks the RPC chain before tracked release paths", () => {
  const directory = createTemporaryDirectory();
  const commandLog = join(directory, "commands.jsonl");
  createFakeExecutable(directory, "cast", "31415926\n");
  createFakeExecutable(directory, "git");

  try {
    const result = runDeploymentCommand(["deploy", "devnet"], {
      ...deploymentEnvironment(directory),
      FAKE_COMMAND_LOG: commandLog,
    }, directory);

    assert.equal(result.status, 1);
    assert.match(result.stderr, /deploy phase is not implemented/);
    assert.deepEqual(
      readFileSync(commandLog, "utf8")
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line)),
      [
        ["chain-id", "--rpc-url", "http://devnet.example"],
        [
          "-C",
          repositoryRoot,
          "status",
          "--porcelain",
          "--untracked-files=all",
          "--",
          "src",
          "script",
          "foundry.toml",
          "foundry.lock",
          "remappings.txt",
          "package.json",
          "package-lock.json",
          "lib",
        ],
      ],
    );
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("rejects an RPC chain mismatch before checking release paths", () => {
  const directory = createTemporaryDirectory();
  const commandLog = join(directory, "commands.jsonl");
  createFakeExecutable(directory, "cast", "314\n");
  createFakeExecutable(directory, "git");

  try {
    const result = runDeploymentCommand(["deploy", "devnet"], {
      ...deploymentEnvironment(directory),
      FAKE_COMMAND_LOG: commandLog,
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /devnet RPC chain ID must be 31415926, got 314/);
    assert.deepEqual(JSON.parse(readFileSync(commandLog, "utf8")), ["chain-id", "--rpc-url", "http://devnet.example"]);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("mainnet requires CONFIRM_MAINNET=yes after confirming its RPC chain", () => {
  const directory = createTemporaryDirectory();
  const commandLog = join(directory, "commands.jsonl");
  createFakeExecutable(directory, "cast", "314\n");

  try {
    const result = runDeploymentCommand(["verify", "mainnet"], {
      PATH: `${directory}${delimiter}${process.env.PATH ?? ""}`,
      FAKE_COMMAND_LOG: commandLog,
      RPC_MAINNET: "http://mainnet.example",
      DEPLOYMENTS_ROOT: join(directory, "deployments"),
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /set CONFIRM_MAINNET=yes before operating on mainnet/);
    assert.deepEqual(JSON.parse(readFileSync(commandLog, "utf8")), ["chain-id", "--rpc-url", "http://mainnet.example"]);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

for (const [command, arguments_] of [
  ["upgrade", ["PoRepMarket"]],
  ["finalize-upgrade", []],
  ["verify", []],
] as const) {
  test(`${command} waits for the canonical manifest cleanliness check`, () => {
    const directory = createTemporaryDirectory();
    const commandLog = join(directory, "commands.jsonl");
    const manifest = createCanonicalManifest(directory);
    createFakeExecutable(directory, "cast", "31415926\n");
    createFakeExecutable(directory, "git");

    try {
      const result = runDeploymentCommand([command, "devnet", ...arguments_], {
        ...deploymentEnvironment(directory),
        FAKE_COMMAND_LOG: commandLog,
        FAKE_DIRTY_PATH: manifest,
      });

      assert.equal(result.status, 1);
      assert.match(result.stderr, new RegExp(`canonical deployment manifest is not clean: ${manifest}`));
      assert.doesNotMatch(result.stderr, /phase is not implemented/);
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  });
}

test("writes a file atomically without leaving its temporary file behind", () => {
  const directory = createTemporaryDirectory();
  const file = join(directory, "pending.json");

  try {
    writeAtomicFile(file, '{"status":"pending"}\n');

    assert.equal(readFileSync(file, "utf8"), '{"status":"pending"}\n');
    assert.deepEqual(readdirSync(directory), ["pending.json"]);
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("SIGINT aborts the shared deployment signal and cleanup removes listeners", () => {
  const sigintListeners = process.listenerCount("SIGINT");
  const sigtermListeners = process.listenerCount("SIGTERM");
  const signalHandling = installSignalHandling();

  try {
    process.emit("SIGINT");
    assert.equal(signalHandling.signal.aborted, true);
  } finally {
    signalHandling.dispose();
  }

  assert.equal(process.listenerCount("SIGINT"), sigintListeners);
  assert.equal(process.listenerCount("SIGTERM"), sigtermListeners);
});

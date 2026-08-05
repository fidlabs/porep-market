const commands = ["deploy", "finalize-deploy", "upgrade", "finalize-upgrade", "verify"];
const networks = ["devnet", "calibnet", "mainnet"];

const usage = `Usage: deployment.ts <command> <network> [args...]
Commands: ${commands.join(", ")}
Networks: ${networks.join(", ")}`;

const [command, network] = process.argv.slice(2);

if (command === undefined || network === undefined) {
  console.error(usage);
  process.exitCode = 1;
} else if (!commands.includes(command)) {
  console.error(`unsupported command: ${command}`);
  process.exitCode = 1;
} else if (!networks.includes(network)) {
  console.error(`unsupported network: ${network}`);
  process.exitCode = 1;
} else {
  console.error(`command is not implemented: ${command}`);
  process.exitCode = 1;
}

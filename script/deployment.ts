const commands = ["deploy", "finalize-deploy", "upgrade", "finalize-upgrade", "verify"];

export const networkConfigs = {
  devnet: { chainId: 31415926 },
  calibnet: { chainId: 314159 },
  mainnet: { chainId: 314 },
} as const;

const networks = Object.keys(networkConfigs);

const usage = `Usage: deployment.ts <command> <network> [args...]
Commands: ${commands.join(", ")}
Networks: ${networks.join(", ")}`;

function main(command: string | undefined, network: string | undefined) {
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
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const [command, network] = process.argv.slice(2);
  main(command, network);
}

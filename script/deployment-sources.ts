import type { DeploymentManifest } from "./deployment-state.ts";

const erc1967ProxyArtifact =
  "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy";

export type SourceVerificationTarget = {
  label: string;
  address: string;
  artifact: string;
  verifier: "blockscout" | "sourcify";
  guessConstructorArguments: boolean;
};

export type SourceVerificationOptions = {
  chainId: number;
  root: string;
  rpcUrl: string;
  verifierUrl: string;
  runForge: (args: readonly string[]) => Promise<void>;
  confirmVerified?: (target: SourceVerificationTarget) => Promise<void>;
  progress?: (message: string) => void;
};

export function sourceVerificationTargets(manifest: DeploymentManifest): SourceVerificationTarget[] {
  const targets: SourceVerificationTarget[] = [];
  for (const [name, contract] of Object.entries(manifest.contracts)) {
    if (contract.kind === "uups") {
      targets.push({
        label: `${name} implementation`,
        address: contract.implementation,
        artifact: contract.artifact,
        verifier: "blockscout",
        guessConstructorArguments: false,
      });
      targets.push({
        label: `${name} proxy`,
        address: contract.proxy,
        artifact: erc1967ProxyArtifact,
        verifier: "blockscout",
        guessConstructorArguments: true,
      });
      continue;
    }
    targets.push({
      label: name,
      address: contract.kind === "beacon" ? contract.address : contract.implementation,
      artifact: contract.artifact,
      verifier: contract.kind === "beacon" ? "sourcify" : "blockscout",
      guessConstructorArguments: contract.kind === "standalone",
    });
  }
  return targets;
}

// Contracts carried over from an earlier release were built from sources that have since
// changed, so asking Forge to re-verify them compares the current build against on-chain
// bytecode a different build produced, and always fails. Those are skipped when Blockscout
// already holds verified source for them. Addresses this operation deployed are always
// submitted regardless, because their sources come from the build in hand and must not be
// left to whatever Blockscout may already have matched to them. Failures are collected so
// one contract cannot hide the status of the rest.
export async function verifyContractSources(
  manifest: DeploymentManifest,
  options: SourceVerificationOptions,
): Promise<void> {
  const targets = sourceVerificationTargets(manifest);
  const progress = options.progress ?? ((message: string) => console.error(message));
  const justDeployed = new Set(
    (manifest.transactions ?? [])
      .map((transaction) => transaction.contractAddress?.toLowerCase())
      .filter((address): address is string => address !== undefined && address !== null),
  );

  const failures: string[] = [];

  for (const [index, target] of targets.entries()) {
    progress(`[${index + 1}/${targets.length}] Verifying ${target.label} at ${target.address}`);
    const args = [
      "verify-contract",
      target.address,
      target.artifact,
      "--root",
      options.root,
      "--chain",
      String(options.chainId),
      "--rpc-url",
      options.rpcUrl,
    ];
    args.push("--verifier", target.verifier);
    if (target.verifier === "blockscout") {
      args.push("--verifier-url", options.verifierUrl, "--skip-is-verified-check");
    }
    args.push("--watch");
    if (target.guessConstructorArguments) args.push("--guess-constructor-args");
    try {
      if (!justDeployed.has(target.address.toLowerCase()) && (await alreadyVerified(options, target))) {
        progress("  already verified, built by an earlier release");
        continue;
      }
      await options.runForge(args);
      await options.confirmVerified?.(target);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      progress(`  FAILED ${target.label} at ${target.address}: ${message}`);
      failures.push(`${target.label} at ${target.address}: ${message}`);
    }
  }

  if (failures.length !== 0) {
    throw new Error(
      `${failures.length} of ${targets.length} contracts failed source verification:\n` +
        failures.map((failure) => `  - ${failure}`).join("\n"),
    );
  }
}

async function alreadyVerified(
  options: SourceVerificationOptions,
  target: SourceVerificationTarget,
): Promise<boolean> {
  if (!options.confirmVerified) return false;
  try {
    await options.confirmVerified(target);
    return true;
  } catch {
    return false;
  }
}

// Reads Blockscout's own verification flag rather than the contract name it reports: the
// name comes from bytecode similarity and is set even for addresses holding no verified
// source, whereas is_fully_verified is true only for an exact match against submitted
// sources. A missing record answers 404.
export async function confirmBlockscoutSource(
  verifierUrl: string,
  target: SourceVerificationTarget,
  request: typeof fetch = fetch,
): Promise<void> {
  const url = new URL(verifierUrl);
  url.pathname = `/api/v2/smart-contracts/${target.address}`;

  const response = await request(url);
  if (response.status === 404) {
    throw new Error(`Blockscout holds no verified source for ${target.label} at ${target.address}`);
  }
  if (!response.ok) throw new Error(`Blockscout source check failed with HTTP ${response.status}`);
  const body = await response.json() as { is_fully_verified?: unknown };
  if (body.is_fully_verified !== true) {
    throw new Error(
      `Blockscout did not fully verify ${target.label} at ${target.address}: is_fully_verified=${String(body.is_fully_verified)}`,
    );
  }
}

export async function confirmSourcifySource(
  chainId: number,
  target: SourceVerificationTarget,
  request: typeof fetch = fetch,
): Promise<void> {
  const url = `https://sourcify.dev/server/v2/contract/${chainId}/${target.address}?fields=all`;
  const response = await request(url);
  if (!response.ok) throw new Error(`Sourcify source check failed with HTTP ${response.status}`);
  const body = await response.json() as {
    match?: unknown;
    metadata?: { settings?: { compilationTarget?: Record<string, unknown> } };
  };
  const [path, name] = target.artifact.split(":");
  if (body.match !== "exact_match" || body.metadata?.settings?.compilationTarget?.[path] !== name) {
    throw new Error(`Sourcify did not exactly verify ${target.label} at ${target.address}`);
  }
}

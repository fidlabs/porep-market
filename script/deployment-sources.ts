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
      guessConstructorArguments: false,
    });
  }
  return targets;
}

export async function verifyContractSources(
  manifest: DeploymentManifest,
  options: SourceVerificationOptions,
): Promise<void> {
  const targets = sourceVerificationTargets(manifest);
  const progress = options.progress ?? ((message: string) => console.error(message));

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
    await options.runForge(args);
    await options.confirmVerified?.(target);
  }
}

export async function confirmBlockscoutSource(
  verifierUrl: string,
  target: SourceVerificationTarget,
  request: typeof fetch = fetch,
): Promise<void> {
  const url = new URL(verifierUrl);
  url.pathname = url.pathname.replace(/\/$/, "");
  url.search = new URLSearchParams({
    module: "contract",
    action: "getsourcecode",
    address: target.address,
  }).toString();

  const response = await request(url);
  if (!response.ok) throw new Error(`Blockscout source check failed with HTTP ${response.status}`);
  const body = await response.json() as { result?: Array<{ ContractName?: unknown }> };
  const actualName = body.result?.[0]?.ContractName;
  const expectedName = target.artifact.split(":").at(-1)!;
  if (actualName !== expectedName) {
    throw new Error(
      `Blockscout did not verify ${target.label} at ${target.address}: expected ${expectedName}, got ${String(actualName)}`,
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

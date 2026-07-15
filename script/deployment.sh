#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOYMENTS_ROOT="${DEPLOYMENTS_ROOT:-$ROOT/deployments}"
FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"
GIT_BIN="${GIT_BIN:-git}"
PENDING_ROOT="${PENDING_ROOT:-$ROOT/.deployment}"
readonly TRACKED_RELEASE_PATHS=(src script foundry.toml foundry.lock remappings.txt package.json package-lock.json lib)

die() { printf '%s\n' "$1" >&2; exit 1; }
usage() {
  cat >&2 <<'EOF'
usage:
  deployment.sh deploy <calibnet|mainnet> [--fresh]
  deployment.sh finalize-deploy <calibnet|mainnet>
  deployment.sh upgrade <calibnet|mainnet> <target> [<target> ...]
  deployment.sh finalize-upgrade <calibnet|mainnet>
  deployment.sh verify <calibnet|mainnet>
EOF
}
network_value() { case "$1:$2" in
  calibnet:chain) echo 314159 ;; mainnet:chain) echo 314 ;;
  calibnet:rpc) echo RPC_CALIBNET ;; mainnet:rpc) echo RPC_MAINNET ;;
  calibnet:key) echo PRIVATE_KEY_CALIBNET ;; mainnet:key) echo PRIVATE_KEY_MAINNET ;;
  calibnet:verifier) echo https://filecoin-testnet.blockscout.com/api/ ;;
  mainnet:verifier) echo https://filecoin.blockscout.com/api/ ;;
  *) die "unsupported network: $1" ;;
esac; }
require_var() { [[ -n "${!1:-}" ]] || die "required environment variable is unset: $1"; }
sha256_file() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
sha256_stream() { if command -v sha256sum >/dev/null; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
build_info_sha256() { printf '0x%s\n' "$(gzip -cd "$1" | sha256_stream)"; }
authenticate_build_info() {
  local file="$1" expected="$2" actual
  [[ -f "$file" ]] || die "build-info does not exist: $file"
  actual="$(build_info_sha256 "$file")" || die "could not read build-info: $file"
  [[ "$actual" == "$expected" ]] || die "build-info hash does not match: $file"
}
assert_clean_release_source() {
  [[ -z "$($GIT_BIN -C "$ROOT" status --porcelain --untracked-files=all -- "${TRACKED_RELEASE_PATHS[@]}")" ]] \
    || die "deployment source is dirty"
}
assert_clean_canonical_manifest() {
  [[ -z "$($GIT_BIN -C "$ROOT" status --porcelain --untracked-files=all -- "$1")" ]] \
    || die "canonical deployment manifest is not committed and clean"
}
assert_chain() {
  local network="$1" rpc_var expected actual
  rpc_var="$(network_value "$network" rpc)"; require_var "$rpc_var"
  expected="$(network_value "$network" chain)"
  actual="$($CAST_BIN chain-id --rpc-url "${!rpc_var}")" || die "could not read RPC chain ID"
  [[ "$actual" == "$expected" ]] || die "expected chain $expected, got $actual"
}
confirm_mainnet() {
  [[ "$1" != mainnet || "${CONFIRM_MAINNET:-}" == yes ]] || die "set CONFIRM_MAINNET=yes"
}
preflight_broadcast() {
  assert_chain "$1"
  confirm_mainnet "$1"
  assert_clean_release_source
}
preflight_finalize() {
  assert_chain "$1"
  confirm_mainnet "$1"
}
validate_upgrade_targets() {
  local manifest="$1" targets_json="$2"
  jq -e --argjson targets "$targets_json" '
    def address: type=="string" and test("^0x[0-9a-fA-F]{40}$");
    def code_hash: type=="string" and test("^0x[0-9a-f]{64}$");
    def artifact($target): {
      PoRepMarket:"src/PoRepMarket.sol:PoRepMarket", ValidatorFactory:"src/ValidatorFactory.sol:ValidatorFactory",
      DataCapEvidenceAdapter:"src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter", SPRegistry:"src/SPRegistry.sol:SPRegistry",
      SLIOracle:"src/SLIOracle.sol:SLIOracle", SLIScorer:"src/SLIScorer.sol:SLIScorer",
      Validator:"src/Validator.sol:Validator"
    }[$target];
    ($targets|type=="array" and length>0 and length==(unique|length)) and all($targets[]; . as $target
      | $manifest[0].contracts[$target] as $contract
      | artifact($target) as $artifact
      | ($artifact|type=="string") and ($contract|type=="object") and $contract.artifact==$artifact
        and ($contract.implementation|address) and ($contract.implementationCodeHash|code_hash)
        and (if $target=="Validator" then $contract.kind=="implementation"
          else $contract.kind=="uups" and ($contract.proxy|address) and ($contract.proxyCodeHash|code_hash) end))
  ' --slurpfile manifest "$manifest" -n >/dev/null
}
validate_upgrade_operations() {
  local pending="$1" manifest="$2"
  jq -e --slurpfile manifest "$manifest" '
    def address: type=="string" and test("^0x[0-9a-fA-F]{40}$");
    def code_hash: type=="string" and test("^0x[0-9a-f]{64}$");
    def artifact($target): {
      PoRepMarket:"src/PoRepMarket.sol:PoRepMarket", ValidatorFactory:"src/ValidatorFactory.sol:ValidatorFactory",
      DataCapEvidenceAdapter:"src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter", SPRegistry:"src/SPRegistry.sol:SPRegistry",
      SLIOracle:"src/SLIOracle.sol:SLIOracle", SLIScorer:"src/SLIScorer.sol:SLIScorer",
      Validator:"src/Validator.sol:Validator"
    }[$target];
    (.targets|type=="array" and length>0 and length==(unique|length))
      and (.operations|type=="array") and [.operations[].target]==.targets
      and all(.operations[]; . as $operation | $manifest[0].contracts[$operation.target] as $contract
        | artifact($operation.target) as $artifact
        | ($artifact|type=="string") and ($contract|type=="object")
          and $contract.artifact==$artifact and $operation.artifact==$artifact
          and $operation.kind==(if $operation.target=="Validator" then "beacon" else $contract.kind end)
          and ($operation.newImplementation|address) and ($operation.newImplementationCodeHash|code_hash))
  ' "$pending" >/dev/null
}

prepare_build_info() {
  local build_dir="$1" output_prefix="$2" files raw
  files=("$build_dir"/*.json); (( ${#files[@]} == 1 )) && [[ -f "${files[0]}" ]] \
    || die "Forge build must produce exactly one build-info JSON"
  raw="${files[0]}"; BUILD_INFO_SHA256="0x$(sha256_file "$raw")"
  BUILD_INFO_GZIP="$output_prefix.json.gz"; gzip -n -c "$raw" >"$BUILD_INFO_GZIP"
}

retain_build_info() {
  local source="$1" destination="$2" staged expected
  expected="0x$(basename "$destination" .json.gz)"
  authenticate_build_info "$source" "$expected"
  if [[ -e "$destination" ]]; then
    authenticate_build_info "$destination" "$expected"
    return 0
  fi
  staged="$(mktemp "$(dirname "$destination")/.build-info.XXXXXX")"
  cp "$source" "$staged"; mv "$staged" "$destination"
}

prune_build_info() {
  local network="$1" retained_hash="$2" retained file
  retained="$DEPLOYMENTS_ROOT/$network/build-info/${retained_hash#0x}.json.gz"
  for file in "$DEPLOYMENTS_ROOT/$network"/build-info/*.json.gz; do
    [[ ! -e "$file" || "$file" == "$retained" ]] || rm -f "$file"
  done
}

retain_broadcast() {
  local pending="$1" operation_root="$2" script="$3" network="$4" source='' destination relative tmp file name
  for file in "$operation_root/$script/$(network_value "$network" chain)"/run-*.json; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"
    [[ "$name" =~ ^run-[0-9]+\.json$ ]] || continue
    [[ -z "$source" ]] || die "Forge produced multiple operation broadcast files"
    source="$file"
  done
  [[ -n "$source" ]] || return 1
  destination="${pending%.json}.broadcast.json"
  tmp="$(mktemp "$(dirname "$destination")/.broadcast.XXXXXX")"
  cp "$source" "$tmp"; mv "$tmp" "$destination"
  relative=".deployment/$network/${destination##*/}"
  tmp="$pending.next"
  jq --arg path "$relative" --arg hash "0x$(sha256_file "$destination")" \
    '.broadcast={path:$path,sha256:$hash}' "$pending" >"$tmp"
  mv "$tmp" "$pending"
}

recorded_broadcast() {
  local pending="$1" network="$2" expected relative
  expected=".deployment/$network/${pending##*/}"
  expected="${expected%.json}.broadcast.json"
  relative="$(jq -er '.broadcast.path' "$pending")" || die "pending broadcast path is invalid"
  [[ "$relative" == "$expected" ]] || die "pending broadcast path is invalid"
  printf '%s/%s\n' "$(dirname "$pending")" "${relative##*/}"
}

successful_receipts() {
  local broadcast="$1" output="$2" rpc_url="$3" work hashes receipts hash receipt
  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-receipts.XXXXXX")"
  hashes="$work/hashes.txt"; receipts="$work/receipts.jsonl"
  jq -er '
    select(.transactions|type=="array" and length>0)
    | (.transactions|length) as $count
    | [.transactions[].hash | select(type=="string" and test("^0x[0-9a-fA-F]{64}$")) | ascii_downcase]
    | select(length==$count and length==(.|unique|length)) | .[]
  ' "$broadcast" >"$hashes" || { rm -r "$work"; die "broadcast transaction hashes are invalid"; }
  : >"$receipts"
  while IFS= read -r hash; do
    receipt="$($CAST_BIN rpc eth_getTransactionReceipt "$hash" --rpc-url "$rpc_url")" \
      || { rm -r "$work"; die "could not read broadcast receipt from RPC"; }
    jq -ce --arg expected "$hash" '
      def digit: if .>=48 and .<=57 then .-48 elif .>=65 and .<=70 then .-55 else .-87 end;
      def quantity: if type=="number" then . elif type=="string" and test("^0x[0-9a-fA-F]+$") then .[2:]|explode|reduce .[] as $d (0; . * 16 + ($d|digit)) else error("invalid quantity") end;
      def hash: select(type=="string" and test("^0x[0-9a-fA-F]{64}$")) | ascii_downcase;
      def address: select(type=="string" and test("^0x[0-9a-fA-F]{40}$")) | ascii_downcase;
      {hash:(.transactionHash|hash),status:(.status|quantity),blockNumber:(.blockNumber|quantity),
        blockHash:(.blockHash|hash),contractAddress:(if .contractAddress==null then null else (.contractAddress|address) end)}
      | select(.hash==$expected and .status==1 and .blockNumber>0)
    ' <<<"$receipt" >>"$receipts" || { rm -r "$work"; die "planned transaction does not have a successful consistent RPC receipt"; }
  done <"$hashes"
  jq -s 'select(length>0)' "$receipts" >"$output" \
    || { rm -r "$work"; die "planned transaction receipts are invalid"; }
  rm -r "$work"
}

publish_deploy() {
  local pending="$1" receipts="$2" network="$3" build_gzip="$4" build_hash="$5"
  local dir retained latest staged finalized_at
  dir="$DEPLOYMENTS_ROOT/$network"; mkdir -p "$dir/build-info"
  finalized_at="$(jq -er '.finalizedAt | select(type=="string" and length>0)' "$pending")"
  latest="$(mktemp "$dir/.latest.XXXXXX")"
  jq --slurpfile tx "$receipts" --arg at "$finalized_at" \
    '.result | .status="finalized" | .finalizedAt=$at | .transactions=$tx[0]' "$pending" >"$latest"
  retained="$dir/build-info/${build_hash#0x}.json.gz"
  retain_build_info "$build_gzip" "$retained"
  mv "$latest" "$dir/latest.json"
  staged="$pending.next"; jq '.status="finalized"' "$pending" >"$staged"; mv "$staged" "$pending"
  prune_build_info "$network" "$build_hash"
}

confirm_finalized_deploy() {
  local pending="$1" network="$2" latest
  latest="$DEPLOYMENTS_ROOT/$network/latest.json"; [[ -f "$latest" ]] || die "finalized deployment manifest is missing"
  jq -e --slurpfile latest "$latest" '
    .result.contracts==$latest[0].contracts
      and .result.externalDependencies==$latest[0].externalDependencies
      and .release.buildInfoSha256==$latest[0].release.buildInfoSha256
  ' "$pending" >/dev/null || die "canonical deployment differs from finalized deployment"
}

publish_upgrade() {
  local pending="$1" network="$2" build_gzip="$3" source="$4"
  local dir retained latest staged expected_hash actual_hash
  dir="$DEPLOYMENTS_ROOT/$network"; mkdir -p "$dir/build-info"
  retained="$dir/build-info/$(jq -er '.release.buildInfoSha256[2:]' "$pending").json.gz"
  retain_build_info "$build_gzip" "$retained"
  latest="$(mktemp "$dir/.latest.XXXXXX")"
  render_upgraded_manifest "$pending" "$source" "$latest"
  expected_hash="$(jq -er '.resultManifestSha256' "$pending")"
  actual_hash="0x$(sha256_file "$latest")"
  [[ "$actual_hash" == "$expected_hash" ]] || die "rendered upgrade manifest hash does not match"
  mv "$latest" "$dir/latest.json"
  staged="$pending.next"; jq '.status="finalized"' "$pending" >"$staged"; mv "$staged" "$pending"
  prune_build_info "$network" "$(jq -er '.release.buildInfoSha256' "$pending")"
}

render_upgraded_manifest() {
  local pending="$1" source="$2" output="$3"
  jq --slurpfile pending "$pending" '
    reduce $pending[0].operations[] as $operation (.;
      if $operation.target=="Validator" then
        .contracts.Validator.implementation=$operation.newImplementation
        | .contracts.Validator.implementationCodeHash=$operation.newImplementationCodeHash
        | .contracts.ValidatorBeacon.implementation=$operation.newImplementation
      else
        .contracts[$operation.target].implementation=$operation.newImplementation
        | .contracts[$operation.target].implementationCodeHash=$operation.newImplementationCodeHash
      end)
    | .release.buildInfoSha256=$pending[0].release.buildInfoSha256
  ' "$source" >"$output"
}

confirm_finalized_upgrade() {
  local pending="$1" network="$2" latest
  latest="$DEPLOYMENTS_ROOT/$network/latest.json"
  [[ -f "$latest" ]] || die "finalized deployment manifest is missing"
  [[ "0x$(sha256_file "$latest")" == "$(jq -er '.resultManifestSha256' "$pending")" ]] \
    || die "canonical manifest does not match finalized upgrade"
  prune_build_info "$network" "$(jq -er '.release.buildInfoSha256' "$pending")"
}

cmd_deploy() {
  local network="${1:-}" fresh=false rpc_var key_var suffix work build_out broadcast_root pending_dir pending forge_rc
  [[ -n "$network" ]] || { usage; exit 2; }; network_value "$network" chain >/dev/null; shift
  if [[ "${1:-}" == --fresh && $# == 1 ]]; then fresh=true; shift; fi
  (( $# == 0 )) || die "unsupported deploy argument: $1"
  [[ "$network" != mainnet || "$fresh" != true ]] || die "fresh mainnet deployment is not supported"
  [[ "$fresh" == true || ! -e "$DEPLOYMENTS_ROOT/$network/latest.json" ]] || die "canonical $network deployment already exists; pass --fresh"
  preflight_broadcast "$network"
  rpc_var="$(network_value "$network" rpc)"; key_var="$(network_value "$network" key)"; require_var "$rpc_var"; require_var "$key_var"
  suffix="$(printf '%s' "$network" | tr '[:lower:]' '[:upper:]')"; for var in FILECOIN_PAY TERMINATION_ORACLE ORACLE POREP_SERVICE META_ALLOCATOR OPERATOR_ADDR; do require_var "${var}_$suffix"; done
  pending_dir="$PENDING_ROOT/$network"; pending="$pending_dir/pending-deploy.json"
  if [[ "$fresh" != true && -e "$pending" ]] && [[ "$(jq -r '.status // empty' "$pending")" == pending ]]; then
    die "pending $network deployment already exists"
  fi
  mkdir -p "$pending_dir"
  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-deploy.XXXXXX")"; broadcast_root="$work/broadcast"
  build_out="$work/out"; "$FORGE_BIN" build --root "$ROOT" --out "$build_out" --cache-path "$work/cache" --build-info --extra-output storageLayout >/dev/null
  prepare_build_info "$build_out/build-info" "$pending_dir/pending-deploy.build-info"
  jq -n --arg network "$network" --argjson chain "$(network_value "$network" chain)" \
    --arg build "$BUILD_INFO_SHA256" \
    --arg path ".deployment/$network/pending-deploy.build-info.json.gz" \
    '{status:"pending",operation:"deploy",network:$network,chainId:$chain,
      release:{buildInfoSha256:$build},buildInfoPath:$path,result:{}}' >"$pending"
  forge_rc=0
  FOUNDRY_BROADCAST="$broadcast_root" PRIVATE_KEY="${!key_var}" RPC_URL="${!rpc_var}" DEPLOYMENT_OUTPUT="$pending" \
    BUILD_INFO_SHA256="$BUILD_INFO_SHA256" \
    FILECOIN_PAY="$(eval echo \"\$FILECOIN_PAY_$suffix\")" TERMINATION_ORACLE="$(eval echo \"\$TERMINATION_ORACLE_$suffix\")" \
    ORACLE="$(eval echo \"\$ORACLE_$suffix\")" POREP_SERVICE="$(eval echo \"\$POREP_SERVICE_$suffix\")" \
    META_ALLOCATOR="$(eval echo \"\$META_ALLOCATOR_$suffix\")" OPERATOR_ADDR="$(eval echo \"\$OPERATOR_ADDR_$suffix\")" \
    "$FORGE_BIN" script script/Deploy.s.sol:Deploy --root "$ROOT" --broadcast --rpc-url "${!rpc_var}" --private-key "${!key_var}" --gas-estimate-multiplier 100000 --slow \
    || forge_rc=$?
  retain_broadcast "$pending" "$broadcast_root" Deploy.s.sol "$network" \
    || { (( forge_rc == 0 )) && die "Forge did not produce the expected deployment broadcast"; }
  (( forge_rc == 0 )) || die "deployment broadcast failed; pending evidence was preserved"
  jq -e '.result.contracts | type=="object" and length>0' "$pending" >/dev/null \
    || die "Forge did not write deployment output"
  jq -e '.broadcast.sha256 | test("^0x[0-9a-f]{64}$")' "$pending" >/dev/null \
    || die "Forge did not write the expected deployment broadcast"
  rm -r "$work"
  printf 'deployment broadcast recorded; run: just finalize-deploy %s\n' "$network"
}

cmd_finalize_deploy() {
  local network="${1:-}" pending_dir pending build_gzip rpc_var broadcast expected_path expected_hash actual_hash work receipts blocks manifest tmp
  [[ -n "$network" && $# == 1 ]] || { usage; exit 2; }
  network_value "$network" chain >/dev/null
  pending_dir="$PENDING_ROOT/$network"; pending="$pending_dir/pending-deploy.json"
  build_gzip="$pending_dir/pending-deploy.build-info.json.gz"
  [[ -f "$pending" ]] || die "pending $network deployment does not exist"
  preflight_finalize "$network"
  jq -e --arg network "$network" --argjson chain "$(network_value "$network" chain)" \
    '.operation=="deploy" and .network==$network and .chainId==$chain' "$pending" >/dev/null \
    || die "pending deployment does not match $network"
  if [[ "$(jq -r '.status // empty' "$pending")" == finalized ]]; then
    confirm_finalized_deploy "$pending" "$network"
    prune_build_info "$network" "$(jq -er '.release.buildInfoSha256' "$pending")"
    return 0
  fi
  [[ "$(jq -r '.status // empty' "$pending")" == pending ]] || die "pending deployment has invalid status"
  jq -e '.result.release == .release' "$pending" >/dev/null || die "deployment output release differs from pending release"
  expected_path=".deployment/$network/pending-deploy.build-info.json.gz"
  [[ "$(jq -er '.buildInfoPath' "$pending")" == "$expected_path" ]] || die "pending build-info path is invalid"
  authenticate_build_info "$build_gzip" "$(jq -er '.release.buildInfoSha256' "$pending")"

  expected_path=".deployment/$network/pending-deploy.broadcast.json"
  [[ "$(jq -er '.broadcast.path' "$pending")" == "$expected_path" ]] || die "pending broadcast path is invalid"
  broadcast="$(recorded_broadcast "$pending" "$network")"
  expected_hash="$(jq -er '.broadcast.sha256' "$pending")"
  [[ -f "$broadcast" ]] || die "deployment broadcast does not exist"
  actual_hash="0x$(sha256_file "$broadcast")"
  [[ "$actual_hash" == "$expected_hash" ]] || die "deployment broadcast hash does not match pending evidence"

  rpc_var="$(network_value "$network" rpc)"; require_var "$rpc_var"
  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-finalize.XXXXXX")"
  receipts="$work/receipts.json"; successful_receipts "$broadcast" "$receipts" "${!rpc_var}"
  blocks="$work/blocks.json"; jq '[.[]|{blockNumber,blockHash}]|unique_by(.blockNumber)' "$receipts" >"$blocks"
  "${FINALITY_VERIFIER:-$ROOT/script/verify-filecoin-finality.sh}" --blocks-json "$blocks" --rpc-url "${!rpc_var}" \
    || die "finality check failed"
  manifest="$work/deployment.json"; jq '.result' "$pending" >"$manifest"
  "${LIVE_CHECKER:-$ROOT/script/deployment-live-checks.sh}" --manifest "$manifest" --rpc-url "${!rpc_var}" \
    || die "live topology check failed"

  if [[ "$(jq -r '.finalizedAt // empty' "$pending")" == '' ]]; then
    tmp="$pending.next"
    jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.finalizedAt=$at' "$pending" >"$tmp"
    mv "$tmp" "$pending"
  fi
  publish_deploy "$pending" "$receipts" "$network" "$build_gzip" "$(jq -er '.release.buildInfoSha256' "$pending")"
  rm -r "$work"
}

cmd_upgrade() {
  local network="${1:-}" targets_csv targets_json i j source rpc_var key_var pending_dir pending build_gzip storage_report
  local reference reference_hash source_hash result_hash expected_manifest work build_out broadcast_root report_hash script script_file forge_rc existing
  [[ -n "$network" ]] || { usage; exit 2; }
  network_value "$network" chain >/dev/null
  shift; (( $# > 0 )) || die "at least one upgrade target is required"; local targets=("$@")
  for (( i=0; i<${#targets[@]}; ++i )); do for (( j=0; j<i; ++j )); do [[ "${targets[$i]}" != "${targets[$j]}" ]] || die "duplicate upgrade target: ${targets[$i]}"; done; done
  targets_csv="$(IFS=,; printf '%s' "${targets[*]}")"; targets_json="$(printf '%s\n' "${targets[@]}" | jq -R . | jq -s .)"
  source="$DEPLOYMENTS_ROOT/$network/latest.json"
  [[ -f "$source" ]] || die "canonical $network deployment does not exist"
  validate_upgrade_targets "$source" "$targets_json" || die "unsupported upgrade target"
  assert_clean_canonical_manifest "$source"
  source_hash="0x$(sha256_file "$source")"
  preflight_broadcast "$network"
  rpc_var="$(network_value "$network" rpc)"; key_var="$(network_value "$network" key)"
  require_var "$rpc_var"; require_var "$key_var"

  pending_dir="$PENDING_ROOT/$network"; mkdir -p "$pending_dir"
  for existing in "$pending_dir"/pending-upgrade*.json; do
    [[ -e "$existing" ]] || continue
    [[ "$(jq -r '.status // empty' "$existing")" != pending ]] || die "pending $network upgrade already exists"
  done
  pending="$pending_dir/pending-upgrade.json"; build_gzip="$pending_dir/pending-upgrade.build-info.json.gz"; storage_report="$pending_dir/pending-upgrade.storage.txt"
  reference_hash="$(jq -er '.release.buildInfoSha256' "$source")"
  reference="$DEPLOYMENTS_ROOT/$network/build-info/${reference_hash#0x}.json.gz"
  authenticate_build_info "$reference" "$reference_hash"

  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-upgrade.XXXXXX")"; broadcast_root="$work/broadcast"
  build_out="$work/out"
  "$FORGE_BIN" build --root "$ROOT" --out "$build_out" --cache-path "$work/cache" --build-info --extra-output storageLayout >/dev/null
  prepare_build_info "$build_out/build-info" "${build_gzip%.json.gz}"
  local storage_args=() storage_target
  while IFS= read -r storage_target; do storage_args+=(--target "$storage_target"); done < <(
    jq -er '.contracts | to_entries[] | select(.value.kind=="uups" or .key=="Validator") | .key' "$source"
  )
  "${STORAGE_VALIDATOR:-$ROOT/script/validate-storage-layout.sh}" \
    --manifest "$source" "${storage_args[@]}" \
    --reference-build-info "$reference" --reference-sha256 "$reference_hash" \
    --current-build-info "$BUILD_INFO_GZIP" --current-sha256 "$BUILD_INFO_SHA256" >"$storage_report" \
    || die "storage validation failed"
  report_hash="0x$(sha256_file "$storage_report")"
  script=Upgrade.s.sol:Upgrade
  script_file="${script%%:*}"
  jq -n --arg network "$network" --argjson chain "$(network_value "$network" chain)" \
    --argjson targets "$targets_json" --arg build "$BUILD_INFO_SHA256" --arg previous "$reference_hash" \
    --arg report "$report_hash" --arg source_hash "$source_hash" \
    --arg build_path ".deployment/$network/pending-upgrade.build-info.json.gz" \
    --arg report_path ".deployment/$network/pending-upgrade.storage.txt" \
    '{status:"pending",operation:"upgrade",network:$network,chainId:$chain,targets:$targets,operations:[],
      sourceManifestSha256:$source_hash,
      release:{buildInfoSha256:$build,previousBuildInfoSha256:$previous,
        storageReportSha256:$report},buildInfoPath:$build_path,storageReportPath:$report_path}' >"$pending"
  forge_rc=0
  FOUNDRY_BROADCAST="$broadcast_root" UPGRADE_OUTPUT="$pending" DEPLOYMENT_MANIFEST="$source" UPGRADE_CONTRACT_NAMES="$targets_csv" \
    PRIVATE_KEY="${!key_var}" \
    "$FORGE_BIN" script "script/$script" --root "$ROOT" --broadcast --rpc-url "${!rpc_var}" \
      --private-key "${!key_var}" --gas-estimate-multiplier 100000 --slow \
    || forge_rc=$?
  retain_broadcast "$pending" "$broadcast_root" "$script_file" "$network" \
    || { (( forge_rc == 0 )) && die "Forge did not produce the expected upgrade broadcast"; }
  (( forge_rc == 0 )) || die "upgrade broadcast failed; pending evidence was preserved"
  jq -e --argjson targets "$targets_json" '.targets==$targets' "$pending" >/dev/null \
    && validate_upgrade_operations "$pending" "$source" || die "Forge did not write ordered upgrade operations"
  [[ "0x$(sha256_file "$source")" == "$source_hash" ]] || die "canonical deployment changed during upgrade broadcast"
  expected_manifest="$work/expected-latest.json"
  render_upgraded_manifest "$pending" "$source" "$expected_manifest"
  result_hash="0x$(sha256_file "$expected_manifest")"
  jq --arg hash "$result_hash" '.resultManifestSha256=$hash' "$pending" >"$pending.next"
  mv "$pending.next" "$pending"
  jq -e '.broadcast.sha256 | test("^0x[0-9a-f]{64}$")' "$pending" >/dev/null \
    || die "Forge did not write the expected upgrade broadcast"
  rm -r "$work"
  printf 'upgrade broadcast recorded; run: just finalize-upgrade %s\n' "$network"
}

cmd_finalize_upgrade() {
  local network="${1:-}" source pending_dir pending build_gzip storage_report
  local reference_hash reference rpc_var work report_hash script_file broadcast expected_path
  local expected_hash actual_hash source_hash source_expected result_expected receipts blocks operations tmp
  [[ -n "$network" ]] || { usage; exit 2; }
  network_value "$network" chain >/dev/null
  (( $# == 1 )) || { usage; exit 2; }
  source="$DEPLOYMENTS_ROOT/$network/latest.json"
  [[ -f "$source" ]] || die "canonical $network deployment does not exist"
  pending_dir="$PENDING_ROOT/$network"
  pending="$pending_dir/pending-upgrade.json"; build_gzip="$pending_dir/pending-upgrade.build-info.json.gz"; storage_report="$pending_dir/pending-upgrade.storage.txt"
  [[ -f "$pending" ]] || die "pending $network upgrade does not exist"
  preflight_finalize "$network"
  jq -e --arg network "$network" --argjson chain "$(network_value "$network" chain)" \
    '.operation=="upgrade" and .network==$network and .chainId==$chain' "$pending" >/dev/null \
    && validate_upgrade_operations "$pending" "$source" || die "pending upgrade does not match command"
  if [[ "$(jq -r '.status // empty' "$pending")" == finalized ]]; then
    confirm_finalized_upgrade "$pending" "$network"
    return 0
  fi
  [[ "$(jq -r '.status // empty' "$pending")" == pending ]] || die "pending upgrade has invalid status"
  source_hash="0x$(sha256_file "$source")"
  source_expected="$(jq -er '.sourceManifestSha256' "$pending")"
  result_expected="$(jq -er '.resultManifestSha256' "$pending")"
  [[ "$source_hash" == "$source_expected" || "$source_hash" == "$result_expected" ]] \
    || die "canonical deployment changed after upgrade broadcast"
  if [[ "$source_hash" == "$source_expected" ]]; then
    [[ "$(jq -er '.release.previousBuildInfoSha256' "$pending")" == "$(jq -er '.release.buildInfoSha256' "$source")" ]] \
      || die "canonical release changed after upgrade broadcast"
  fi
  [[ "$(jq -er '.buildInfoPath' "$pending")" == ".deployment/$network/pending-upgrade.build-info.json.gz" ]] \
    || die "pending build-info path is invalid"
  [[ "$(jq -er '.storageReportPath' "$pending")" == ".deployment/$network/pending-upgrade.storage.txt" ]] \
    || die "pending storage report path is invalid"
  authenticate_build_info "$build_gzip" "$(jq -er '.release.buildInfoSha256' "$pending")"
  reference_hash="$(jq -er '.release.previousBuildInfoSha256' "$pending")"
  reference="$DEPLOYMENTS_ROOT/$network/build-info/${reference_hash#0x}.json.gz"
  authenticate_build_info "$reference" "$reference_hash"
  report_hash="$(jq -er '.release.storageReportSha256' "$pending")"
  [[ -f "$storage_report" && "0x$(sha256_file "$storage_report")" == "$report_hash" ]] \
    || die "storage report hash does not match"

  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-finalize-upgrade.XXXXXX")"
  script_file=Upgrade.s.sol
  expected_path=".deployment/$network/pending-upgrade.broadcast.json"
  [[ "$(jq -er '.broadcast.path' "$pending")" == "$expected_path" ]] || die "pending broadcast path is invalid"
  broadcast="$(recorded_broadcast "$pending" "$network")"
  expected_hash="$(jq -er '.broadcast.sha256' "$pending")"
  [[ -f "$broadcast" ]] || die "upgrade broadcast does not exist"
  actual_hash="0x$(sha256_file "$broadcast")"
  [[ "$actual_hash" == "$expected_hash" ]] || die "upgrade broadcast hash does not match pending evidence"

  rpc_var="$(network_value "$network" rpc)"; require_var "$rpc_var"
  receipts="$work/receipts.json"; successful_receipts "$broadcast" "$receipts" "${!rpc_var}"
  blocks="$work/blocks.json"; jq '[.[]|{blockNumber,blockHash}]|unique_by(.blockNumber)' "$receipts" >"$blocks"
  "${FINALITY_VERIFIER:-$ROOT/script/verify-filecoin-finality.sh}" --blocks-json "$blocks" --rpc-url "${!rpc_var}" \
    || die "finality check failed"
  operations="$work/operations.json"; jq '.operations' "$pending" >"$operations"
  "${LIVE_CHECKER:-$ROOT/script/deployment-live-checks.sh}" \
    --manifest "$source" --operations "$operations" --rpc-url "${!rpc_var}" \
    || die "live topology check failed"

  if [[ "$(jq -r '.finalizedAt // empty' "$pending")" == '' ]]; then
    tmp="$pending.next"
    jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.finalizedAt=$at' "$pending" >"$tmp"
    mv "$tmp" "$pending"
  fi
  publish_upgrade "$pending" "$network" "$build_gzip" "$source"
  rm -r "$work"
}

cmd_verify() {
  local network="${1:-}" manifest chain rpc_var verifier entries entry address artifact
  [[ -n "$network" && $# == 1 ]] || { usage; exit 2; }; chain="$(network_value "$network" chain)"; rpc_var="$(network_value "$network" rpc)"; require_var "$rpc_var"
  verifier="$(network_value "$network" verifier)"
  manifest="$DEPLOYMENTS_ROOT/$network/latest.json"; [[ -f "$manifest" ]] || die "canonical $network deployment does not exist"
  assert_clean_release_source
  entries="$(mktemp "${TMPDIR:-/tmp}/porep-verify.XXXXXX")"
  jq -ce '
    (.contracts | select(type=="object")) as $contracts
    | select(all($contracts | to_entries[];
        (.value|type=="object") and (.value.kind|type=="string")
          and (if .value.kind=="beacon" then true
            else (.value.implementation|type=="string") and (.value.artifact|type=="string") end)))
    | [$contracts | to_entries[] | select(.value.kind!="beacon")]
    | select(length>0) | .[]
  ' "$manifest" >"$entries" || { rm -f "$entries"; die "verification manifest is invalid"; }
  while IFS= read -r entry; do
    address="$(jq -er '.value.implementation' <<<"$entry")"
    artifact="$(jq -er '.value.artifact' <<<"$entry")"
    "$FORGE_BIN" verify-contract "$address" "$artifact" \
      --chain "$chain" --rpc-url "${!rpc_var}" --verifier blockscout --verifier-url "$verifier" --watch
  done <"$entries"
  rm -f "$entries"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    deploy) shift; cmd_deploy "$@" ;;
    finalize-deploy) shift; cmd_finalize_deploy "$@" ;;
    upgrade) shift; cmd_upgrade "$@" ;;
    finalize-upgrade) shift; cmd_finalize_upgrade "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    *) usage; exit 2 ;;
  esac
fi

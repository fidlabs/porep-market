#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOYMENTS_ROOT="${DEPLOYMENTS_ROOT:-$ROOT/deployments}"
FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"
GIT_BIN="${GIT_BIN:-git}"
PENDING_ROOT="${PENDING_ROOT:-$ROOT/.deployment}"
readonly TRACKED_RELEASE_PATHS=(src script foundry.toml foundry.lock remappings.txt lib)

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
  [[ -z "$($GIT_BIN -C "$ROOT" status --porcelain --untracked-files=no -- "${TRACKED_RELEASE_PATHS[@]}")" ]] \
    || die "tracked deployment source is dirty"
}
assert_chain() {
  local network="$1" rpc_var expected actual
  rpc_var="$(network_value "$network" rpc)"; require_var "$rpc_var"
  expected="$(network_value "$network" chain)"
  actual="$($CAST_BIN chain-id --rpc-url "${!rpc_var}")" || die "could not read RPC chain ID"
  [[ "$actual" == "$expected" ]] || die "expected chain $expected, got $actual"
}
preflight_write() {
  assert_chain "$1"
  if [[ "$1" == mainnet ]]; then
    [[ "${CONFIRM_MAINNET:-}" == yes ]] || die "set CONFIRM_MAINNET=yes"
    assert_clean_release_source
  fi
}
assert_recorded_source() {
  local pending="$1"
  [[ "$($GIT_BIN -C "$ROOT" rev-parse HEAD)" == "$(jq -er '.release.gitCommit' "$pending")" ]] \
    || die "HEAD differs from pending Git commit"
  assert_clean_release_source
}
validate_upgrade_target() {
  case "$1" in
    PoRepMarket|ValidatorFactory|DataCapEvidenceAdapter|SPRegistry|SLIOracle|SLIScorer|Validator) ;;
    *) die "unsupported upgrade target: $1" ;;
  esac
}
validate_upgrade_operations() {
  jq -e '
    def artifact($target): {
      PoRepMarket:"src/PoRepMarket.sol:PoRepMarket", ValidatorFactory:"src/ValidatorFactory.sol:ValidatorFactory",
      DataCapEvidenceAdapter:"src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter", SPRegistry:"src/SPRegistry.sol:SPRegistry",
      SLIOracle:"src/SLIOracle.sol:SLIOracle", SLIScorer:"src/SLIScorer.sol:SLIScorer", Validator:"src/Validator.sol:Validator"
    }[$target];
    (.targets|type=="array" and length>0 and length==(unique|length)) and [.operations[].target]==.targets and all(.operations[];
      (.target|artifact(.)) != null and .kind==(if .target=="Validator" then "beacon" else "uups" end)
      and .artifact==artifact(.target) and (.newImplementation|test("^0x[0-9a-fA-F]{40}$"))
      and (.newImplementationCodeHash|test("^0x[0-9a-f]{64}$")))
  ' "$1" >/dev/null
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

latest_broadcast() {
  local dir file name id latest='' latest_id=''
  dir="${BROADCAST_ROOT:-$ROOT/broadcast}/$1/$(network_value "$2" chain)"
  [[ -d "$dir" ]] || return 0
  for file in "$dir"/run-*.json; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"
    [[ "$name" =~ ^run-([0-9]+)\.json$ ]] || continue
    id="${BASH_REMATCH[1]}"
    if [[ -z "$latest_id" || ${#id} -gt ${#latest_id} || ( ${#id} -eq ${#latest_id} && "$id" > "$latest_id" ) ]]; then
      latest="$file"
      latest_id="$id"
    fi
  done
  [[ -z "$latest" ]] || printf '%s\n' "$latest"
}

broadcast_relative_path() {
  local root="${BROADCAST_ROOT:-$ROOT/broadcast}" file="$1"
  [[ "$file" == "$root/"* ]] || die "broadcast is outside the broadcast root"
  printf 'broadcast/%s\n' "${file#"$root/"}"
}

recorded_broadcast() {
  local pending="$1" relative
  relative="$(jq -er '.broadcast.path | select(startswith("broadcast/"))' "$pending")" \
    || die "pending broadcast path is invalid"
  printf '%s/%s\n' "${BROADCAST_ROOT:-$ROOT/broadcast}" "${relative#broadcast/}"
}

bind_broadcast() {
  local pending="$1" script="$2" network="$3" broadcast relative previous tmp
  broadcast="$(latest_broadcast "$script" "$network")"
  [[ -f "$broadcast" ]] || return 0
  relative="$(broadcast_relative_path "$broadcast")"
  previous="$(jq -r '.previousBroadcastPath // empty' "$pending")"
  [[ "$relative" != "$previous" ]] || return 0
  tmp="$pending.next"
  jq --arg path "$relative" --arg hash "0x$(sha256_file "$broadcast")" \
    '.broadcast={path:$path,sha256:$hash}' "$pending" >"$tmp"
  mv "$tmp" "$pending"
}

successful_receipts() {
  local broadcast="$1" output="$2"
  jq -e '
    def digit: if .>=48 and .<=57 then .-48 elif .>=65 and .<=70 then .-55 else .-87 end;
    def quantity: if type=="number" then . elif test("^0x") then .[2:]|explode|reduce .[] as $d (0; . * 16 + ($d|digit)) else tonumber end;
    (.transactions|length) as $planned_count
    | [.transactions[].hash | select(type=="string" and test("^0x[0-9a-fA-F]{64}$")) | ascii_downcase] as $planned
    | select(($planned|length)==$planned_count and ($planned|unique|length)==$planned_count)
    | (.pending // []) as $raw_pending
    | [$raw_pending[] | select(type=="string" and test("^0x[0-9a-fA-F]{64}$")) | ascii_downcase] as $pending
    | select(($pending|length)==($raw_pending|length) and ($pending|unique|length)==($pending|length))
    | select((($pending-$planned)|length)==0)
    | [.receipts[] | {hash:(.transactionHash|ascii_downcase),status:(.status|quantity),
         blockNumber:(.blockNumber|quantity),blockHash:(.blockHash|ascii_downcase),
         contractAddress:(if .contractAddress==null then null else (.contractAddress|ascii_downcase) end)}]
    | select(length>0 and all(.[]; (.hash|test("^0x[0-9a-f]{64}$")) and .status==1
        and .blockNumber>0 and (.blockHash|test("^0x[0-9a-f]{64}$"))))
    | group_by(.hash)
    | select(length==$planned_count and all(.[]; (unique|length)==1))
    | map(.[0])
    | ([.[].hash]) as $observed
    | select((($planned-$observed)|sort)==($pending|sort))
    | select(group_by(.blockNumber) | all(.[]; ([.[].blockHash]|unique|length)==1))
  ' "$broadcast" >"$output" || die "every broadcast transaction must have one successful receipt"
}

publish_deploy() {
  local pending="$1" receipts="$2" network="$3" build_gzip="$4" build_hash="$5"
  local dir without_id canonical history id retained staged latest staged_pending finalized_at
  dir="$DEPLOYMENTS_ROOT/$network"; mkdir -p "$dir/history" "$dir/build-info"
  finalized_at="$(jq -er '.finalizedAt | select(type=="string" and length>0)' "$pending")"
  without_id="$(mktemp "$dir/.deployment.XXXXXX")"
  canonical="$(mktemp "$dir/.deployment.XXXXXX")"
  jq --slurpfile tx "$receipts" --arg at "$finalized_at" \
    '.result | .status="finalized" | .finalizedAt=$at | .transactions=$tx[0]' "$pending" >"$without_id"
  id="0x$(sha256_file "$without_id")"
  jq --arg id "$id" '.deploymentId=$id' "$without_id" >"$canonical"
  rm -f "$without_id"

  history="$dir/history/$id.json"
  if [[ -e "$history" ]]; then
    cmp -s "$canonical" "$history" || die "deployment history differs: $id"
  else
    staged="$(mktemp "$dir/history/.deployment.XXXXXX")"
    cp "$canonical" "$staged"; mv "$staged" "$history"
  fi

  retained="$dir/build-info/${build_hash#0x}.json.gz"
  retain_build_info "$build_gzip" "$retained"
  latest="$(mktemp "$dir/.latest.XXXXXX")"
  cp "$canonical" "$latest"; mv "$latest" "$dir/latest.json"
  rm -f "$canonical"

  staged_pending="$pending.next"
  jq --arg id "$id" '.status="finalized" | .deploymentId=$id' "$pending" >"$staged_pending"
  mv "$staged_pending" "$pending"
}

confirm_finalized_deploy() {
  local pending="$1" network="$2" id history latest
  id="$(jq -er '.deploymentId' "$pending")"
  history="$DEPLOYMENTS_ROOT/$network/history/$id.json"
  latest="$DEPLOYMENTS_ROOT/$network/latest.json"
  [[ -f "$history" && -f "$latest" ]] || die "finalized deployment artifacts are missing"
  [[ "$(jq -er '.deploymentId' "$history")" == "$id" ]] || die "deployment history ID does not match"
  [[ "$(jq -er '.deploymentId' "$latest")" == "$id" ]] || die "latest deployment ID does not match"
}

publish_upgrade() {
  local pending="$1" receipts="$2" network="$3" build_gzip="$4" source="$5"
  local dir without_id canonical record id retained latest staged
  dir="$DEPLOYMENTS_ROOT/$network"; mkdir -p "$dir/upgrades" "$dir/build-info"
  without_id="$(mktemp "$dir/.upgrade.XXXXXX")"
  canonical="$(mktemp "$dir/.upgrade.XXXXXX")"
  jq --slurpfile tx "$receipts" '
    {operation:"upgrade",sourceDeploymentId:.sourceDeploymentId,finalizedAt:.finalizedAt,
      operations:.operations,transactions:$tx[0]}
  ' "$pending" >"$without_id"
  id="0x$(sha256_file "$without_id")"
  jq --arg id "$id" '.upgradeId=$id' "$without_id" >"$canonical"
  rm -f "$without_id"

  record="$dir/upgrades/$id.json"
  if [[ -e "$record" ]]; then
    cmp -s "$canonical" "$record" || die "upgrade history differs: $id"
  else
    staged="$(mktemp "$dir/upgrades/.upgrade.XXXXXX")"
    cp "$canonical" "$staged"; mv "$staged" "$record"
  fi
  rm -f "$canonical"

  retained="$dir/build-info/$(jq -er '.release.buildInfoSha256[2:]' "$pending").json.gz"
  retain_build_info "$build_gzip" "$retained"
  latest="$(mktemp "$dir/.latest.XXXXXX")"; cp "$source" "$latest"
  jq --slurpfile operations <(jq '.operations' "$pending") '
    reduce $operations[0][] as $operation (.;
      if $operation.target=="Validator" then
        .contracts.Validator.implementation=$operation.newImplementation
        | .contracts.Validator.implementationCodeHash=$operation.newImplementationCodeHash
        | .contracts.ValidatorBeacon.implementation=$operation.newImplementation
      else
        .contracts[$operation.target].implementation=$operation.newImplementation
        | .contracts[$operation.target].implementationCodeHash=$operation.newImplementationCodeHash
      end)
  ' "$latest" >"$latest.next"
  mv "$latest.next" "$latest"
  jq --arg commit "$(jq -er '.release.gitCommit' "$pending")" \
    --arg hash "$(jq -er '.release.buildInfoSha256' "$pending")" \
    '.release.gitCommit=$commit | .release.buildInfoSha256=$hash' "$latest" >"$latest.next"
  mv "$latest.next" "$latest"
  mv "$latest" "$dir/latest.json"

  staged="$pending.next"
  jq --arg id "$id" '.status="finalized" | .upgradeId=$id' "$pending" >"$staged"
  mv "$staged" "$pending"
}

confirm_finalized_upgrade() {
  local pending="$1" network="$2" source id record latest
  id="$(jq -er '.upgradeId' "$pending")"
  record="$DEPLOYMENTS_ROOT/$network/upgrades/$id.json"
  latest="$DEPLOYMENTS_ROOT/$network/latest.json"
  [[ -f "$record" && -f "$latest" ]] || die "finalized upgrade artifacts are missing"
  [[ "$(jq -er '.upgradeId' "$record")" == "$id" ]] || die "upgrade history ID does not match"
  source="$(jq -er '.sourceDeploymentId' "$pending")"
  [[ "$(jq -er '.deploymentId' "$latest")" == "$source" ]] || die "canonical deployment changed"
  jq -e --slurpfile latest "$latest" '
    all(.operations[]; . as $operation | if $operation.target=="Validator" then
      $latest[0].contracts.Validator.implementation==$operation.newImplementation and $latest[0].contracts.ValidatorBeacon.implementation==$operation.newImplementation
    else $latest[0].contracts[$operation.target].implementation==$operation.newImplementation end)
  ' "$pending" >/dev/null || die "canonical implementations do not match finalized upgrade"
}

cmd_deploy() {
  local network="${1:-}" fresh=false rpc_var key_var suffix work build_out commit pending_dir pending forge_rc previous
  [[ -n "$network" ]] || { usage; exit 2; }; network_value "$network" chain >/dev/null; shift
  if [[ "${1:-}" == --fresh && $# == 1 ]]; then fresh=true; shift; fi
  (( $# == 0 )) || die "unsupported deploy argument: $1"
  [[ "$network" != mainnet || "$fresh" != true ]] || die "fresh mainnet deployment is not supported"
  [[ "$fresh" == true || ! -e "$DEPLOYMENTS_ROOT/$network/latest.json" ]] || die "canonical $network deployment already exists; pass --fresh"
  preflight_write "$network"
  rpc_var="$(network_value "$network" rpc)"; key_var="$(network_value "$network" key)"; require_var "$rpc_var"; require_var "$key_var"
  suffix="$(printf '%s' "$network" | tr '[:lower:]' '[:upper:]')"; for var in FILECOIN_PAY TERMINATION_ORACLE ORACLE POREP_SERVICE META_ALLOCATOR OPERATOR_ADDR; do require_var "${var}_$suffix"; done
  pending_dir="$PENDING_ROOT/$network"; pending="$pending_dir/pending-deploy.json"
  if [[ -e "$pending" ]] && [[ "$(jq -r '.status // empty' "$pending")" == pending ]]; then
    die "pending $network deployment already exists"
  fi
  mkdir -p "$pending_dir"
  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-deploy.XXXXXX")"
  build_out="$work/out"; "$FORGE_BIN" build --root "$ROOT" --out "$build_out" --cache-path "$work/cache" --build-info >/dev/null
  prepare_build_info "$build_out/build-info" "$pending_dir/pending-deploy.build-info"; commit="$($GIT_BIN -C "$ROOT" rev-parse HEAD)"
  previous="$(latest_broadcast Deploy.s.sol "$network")"
  [[ -z "$previous" ]] || previous="$(broadcast_relative_path "$previous")"
  jq -n --arg network "$network" --argjson chain "$(network_value "$network" chain)" \
    --arg commit "$commit" --arg build "$BUILD_INFO_SHA256" \
    --arg path ".deployment/$network/pending-deploy.build-info.json.gz" --arg previous "$previous" \
    '{status:"pending",operation:"deploy",network:$network,chainId:$chain,
      release:{gitCommit:$commit,buildInfoSha256:$build},buildInfoPath:$path,
      previousBroadcastPath:$previous,result:{}}' >"$pending"
  forge_rc=0
  PRIVATE_KEY="${!key_var}" RPC_URL="${!rpc_var}" DEPLOYMENT_OUTPUT="$pending" \
    GIT_COMMIT="$commit" BUILD_INFO_SHA256="$BUILD_INFO_SHA256" \
    FILECOIN_PAY="$(eval echo \"\$FILECOIN_PAY_$suffix\")" TERMINATION_ORACLE="$(eval echo \"\$TERMINATION_ORACLE_$suffix\")" \
    ORACLE="$(eval echo \"\$ORACLE_$suffix\")" POREP_SERVICE="$(eval echo \"\$POREP_SERVICE_$suffix\")" \
    META_ALLOCATOR="$(eval echo \"\$META_ALLOCATOR_$suffix\")" OPERATOR_ADDR="$(eval echo \"\$OPERATOR_ADDR_$suffix\")" \
    "$FORGE_BIN" script script/Deploy.s.sol:Deploy --root "$ROOT" --broadcast --rpc-url "${!rpc_var}" --private-key "${!key_var}" --gas-estimate-multiplier 100000 --slow \
    || forge_rc=$?
  bind_broadcast "$pending" Deploy.s.sol "$network"
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
  preflight_write "$network"
  jq -e --arg network "$network" --argjson chain "$(network_value "$network" chain)" \
    '.operation=="deploy" and .network==$network and .chainId==$chain' "$pending" >/dev/null \
    || die "pending deployment does not match $network"
  assert_recorded_source "$pending"
  if [[ "$(jq -r '.status // empty' "$pending")" == finalized ]]; then
    confirm_finalized_deploy "$pending" "$network"
    return 0
  fi
  [[ "$(jq -r '.status // empty' "$pending")" == pending ]] || die "pending deployment has invalid status"
  jq -e '.result.release == .release' "$pending" >/dev/null || die "deployment output release differs from pending release"
  expected_path=".deployment/$network/pending-deploy.build-info.json.gz"
  [[ "$(jq -er '.buildInfoPath' "$pending")" == "$expected_path" ]] || die "pending build-info path is invalid"
  authenticate_build_info "$build_gzip" "$(jq -er '.release.buildInfoSha256' "$pending")"

  if [[ "$(jq -r '.broadcast.path // empty' "$pending")" == '' ]]; then bind_broadcast "$pending" Deploy.s.sol "$network"; fi
  expected_path="^broadcast/Deploy\\.s\\.sol/$(network_value "$network" chain)/run-[0-9]+\\.json$"
  jq -e --arg pattern "$expected_path" '.broadcast.path | test($pattern)' "$pending" >/dev/null \
    || die "pending broadcast path is invalid"
  broadcast="$(recorded_broadcast "$pending")"
  expected_hash="$(jq -er '.broadcast.sha256' "$pending")"
  [[ -f "$broadcast" ]] || die "deployment broadcast does not exist"
  actual_hash="0x$(sha256_file "$broadcast")"
  [[ "$actual_hash" == "$expected_hash" ]] || die "deployment broadcast hash does not match pending evidence"

  rpc_var="$(network_value "$network" rpc)"; require_var "$rpc_var"
  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-finalize.XXXXXX")"
  receipts="$work/receipts.json"; successful_receipts "$broadcast" "$receipts"
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
  local reference reference_hash work build_out commit report_hash script script_file forge_rc existing expected_result previous
  [[ -n "$network" ]] || { usage; exit 2; }
  network_value "$network" chain >/dev/null
  shift; (( $# > 0 )) || die "at least one upgrade target is required"; local targets=("$@")
  for (( i=0; i<${#targets[@]}; ++i )); do validate_upgrade_target "${targets[$i]}"; for (( j=0; j<i; ++j )); do [[ "${targets[$i]}" != "${targets[$j]}" ]] || die "duplicate upgrade target: ${targets[$i]}"; done; done
  targets_csv="$(IFS=,; printf '%s' "${targets[*]}")"; targets_json="$(printf '%s\n' "${targets[@]}" | jq -R . | jq -s .)"
  source="$DEPLOYMENTS_ROOT/$network/latest.json"
  [[ -f "$source" ]] || die "canonical $network deployment does not exist"
  preflight_write "$network"
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

  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-upgrade.XXXXXX")"
  build_out="$work/out"
  "$FORGE_BIN" build --root "$ROOT" --out "$build_out" --cache-path "$work/cache" --build-info >/dev/null
  prepare_build_info "$build_out/build-info" "${build_gzip%.json.gz}"
  commit="$($GIT_BIN -C "$ROOT" rev-parse HEAD)"
  "${STORAGE_VALIDATOR:-$ROOT/script/validate-storage-layout.sh}" \
    --manifest "$source" \
    --reference-build-info "$reference" --reference-sha256 "$reference_hash" \
    --current-build-info "$BUILD_INFO_GZIP" --current-sha256 "$BUILD_INFO_SHA256" >"$storage_report" \
    || die "storage validation failed"
  report_hash="0x$(sha256_file "$storage_report")"
  script=Upgrade.s.sol:Upgrade
  script_file="${script%%:*}"
  previous="$(latest_broadcast "$script_file" "$network")"
  [[ -z "$previous" ]] || previous="$(broadcast_relative_path "$previous")"
  jq -n --arg network "$network" --argjson chain "$(network_value "$network" chain)" \
    --argjson targets "$targets_json" --arg source "$(jq -er '.deploymentId' "$source")" \
    --arg commit "$commit" --arg build "$BUILD_INFO_SHA256" --arg previous "$reference_hash" \
    --arg report "$report_hash" --arg previous_broadcast "$previous" \
    --arg build_path ".deployment/$network/pending-upgrade.build-info.json.gz" \
    --arg report_path ".deployment/$network/pending-upgrade.storage.txt" \
    '{status:"pending",operation:"upgrade",network:$network,chainId:$chain,targets:$targets,operations:[],
      sourceDeploymentId:$source,
      release:{gitCommit:$commit,buildInfoSha256:$build,previousBuildInfoSha256:$previous,
        storageReportSha256:$report},buildInfoPath:$build_path,storageReportPath:$report_path,
      previousBroadcastPath:$previous_broadcast,result:{}}' >"$pending"
  forge_rc=0
  UPGRADE_OUTPUT="$pending" DEPLOYMENT_MANIFEST="$source" UPGRADE_CONTRACT_NAMES="$targets_csv" \
    PRIVATE_KEY="${!key_var}" \
    "$FORGE_BIN" script "script/$script" --root "$ROOT" --broadcast --rpc-url "${!rpc_var}" \
      --private-key "${!key_var}" --gas-estimate-multiplier 100000 --slow \
    || forge_rc=$?
  bind_broadcast "$pending" "$script_file" "$network"
  (( forge_rc == 0 )) || die "upgrade broadcast failed; pending evidence was preserved"
  jq -e --argjson targets "$targets_json" '.targets==$targets' "$pending" >/dev/null && validate_upgrade_operations "$pending" || die "Forge did not write ordered upgrade operations"
  jq -e '.broadcast.sha256 | test("^0x[0-9a-f]{64}$")' "$pending" >/dev/null \
    || die "Forge did not write the expected upgrade broadcast"
  rm -r "$work"
  printf 'upgrade broadcast recorded; run: just finalize-upgrade %s\n' "$network"
}

cmd_finalize_upgrade() {
  local network="${1:-}" source pending_dir pending build_gzip storage_report
  local reference_hash reference rpc_var work rerun_report report_hash script_file broadcast expected_path
  local expected_hash actual_hash receipts blocks operations tmp
  [[ -n "$network" ]] || { usage; exit 2; }
  network_value "$network" chain >/dev/null
  (( $# == 1 )) || { usage; exit 2; }
  source="$DEPLOYMENTS_ROOT/$network/latest.json"
  [[ -f "$source" ]] || die "canonical $network deployment does not exist"
  pending_dir="$PENDING_ROOT/$network"
  pending="$pending_dir/pending-upgrade.json"; build_gzip="$pending_dir/pending-upgrade.build-info.json.gz"; storage_report="$pending_dir/pending-upgrade.storage.txt"
  [[ -f "$pending" ]] || die "pending $network upgrade does not exist"
  preflight_write "$network"
  jq -e --arg network "$network" --argjson chain "$(network_value "$network" chain)" \
    '.operation=="upgrade" and .network==$network and .chainId==$chain' "$pending" >/dev/null && validate_upgrade_operations "$pending" \
    || die "pending upgrade does not match command"
  assert_recorded_source "$pending"
  if [[ "$(jq -r '.status // empty' "$pending")" == finalized ]]; then
    confirm_finalized_upgrade "$pending" "$network"
    return 0
  fi
  [[ "$(jq -r '.status // empty' "$pending")" == pending ]] || die "pending upgrade has invalid status"
  [[ "$(jq -er '.sourceDeploymentId' "$pending")" == "$(jq -er '.deploymentId' "$source")" ]] \
    || die "canonical deployment changed after upgrade broadcast"
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
  rerun_report="$work/storage.txt"
  "${STORAGE_VALIDATOR:-$ROOT/script/validate-storage-layout.sh}" \
    --manifest "$source" \
    --reference-build-info "$reference" --reference-sha256 "$reference_hash" \
    --current-build-info "$build_gzip" --current-sha256 "$(jq -er '.release.buildInfoSha256' "$pending")" \
    >"$rerun_report" || die "storage validation failed"
  [[ "0x$(sha256_file "$rerun_report")" == "$report_hash" ]] || die "storage validation report changed"

  script_file=Upgrade.s.sol
  if [[ "$(jq -r '.broadcast.path // empty' "$pending")" == '' ]]; then bind_broadcast "$pending" "$script_file" "$network"; fi
  expected_path="^broadcast/${script_file//./\\.}/$(network_value "$network" chain)/run-[0-9]+\\.json$"
  jq -e --arg pattern "$expected_path" '.broadcast.path | test($pattern)' "$pending" >/dev/null \
    || die "pending broadcast path is invalid"
  broadcast="$(recorded_broadcast "$pending")"
  expected_hash="$(jq -er '.broadcast.sha256' "$pending")"
  [[ -f "$broadcast" ]] || die "upgrade broadcast does not exist"
  actual_hash="0x$(sha256_file "$broadcast")"
  [[ "$actual_hash" == "$expected_hash" ]] || die "upgrade broadcast hash does not match pending evidence"

  receipts="$work/receipts.json"; successful_receipts "$broadcast" "$receipts"
  blocks="$work/blocks.json"; jq '[.[]|{blockNumber,blockHash}]|unique_by(.blockNumber)' "$receipts" >"$blocks"
  rpc_var="$(network_value "$network" rpc)"; require_var "$rpc_var"
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
  publish_upgrade "$pending" "$receipts" "$network" "$build_gzip" "$source"
  rm -r "$work"
}

cmd_verify() {
  local network="${1:-}" manifest chain rpc_var verifier name address artifact
  local names=(PoRepMarket ValidatorFactory DataCapEvidenceAdapter SPRegistry SLIOracle SLIScorer Validator)
  [[ -n "$network" && $# == 1 ]] || { usage; exit 2; }; chain="$(network_value "$network" chain)"; rpc_var="$(network_value "$network" rpc)"; require_var "$rpc_var"
  verifier="$(network_value "$network" verifier)"
  manifest="$DEPLOYMENTS_ROOT/$network/latest.json"; [[ -f "$manifest" ]] || die "canonical $network deployment does not exist"
  for name in "${names[@]}"; do
    address="$(jq -er --arg name "$name" '.contracts[$name].implementation' "$manifest")"
    artifact="$(jq -er --arg name "$name" '.contracts[$name].artifact' "$manifest")"
    "$FORGE_BIN" verify-contract "$address" "$artifact" \
      --chain "$chain" --rpc-url "${!rpc_var}" --verifier blockscout --verifier-url "$verifier" --watch
  done
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

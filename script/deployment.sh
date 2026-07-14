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
assert_recorded_source() {
  local pending="$1"
  [[ "$($GIT_BIN -C "$ROOT" rev-parse HEAD)" == "$(jq -er '.release.gitCommit' "$pending")" ]] \
    || die "HEAD differs from pending Git commit"
}
authenticate_implementation_builds() {
  local manifest="$1" build_info="$2" excluded_json="${3:-[]}" entries entry name artifact address expected source_path contract bytecode actual
  entries="$(mktemp "${TMPDIR:-/tmp}/porep-implementations.XXXXXX")"
  jq -ce --argjson excluded "$excluded_json" '
    [.contracts | to_entries[] | . as $entry | select(.value.kind!="beacon" and ($excluded|index($entry.key)|not))]
    | select(length>0 and all(.[].value;
        (.artifact|type=="string" and test("^[^:]+:[^:]+$"))
          and (.implementation|type=="string" and test("^0x[0-9a-fA-F]{40}$"))
          and (.implementationCodeHash|type=="string" and test("^0x[0-9a-f]{64}$"))))
    | .[]
  ' "$manifest" >"$entries" || { rm -f "$entries"; die "implementation evidence is invalid"; }
  while IFS= read -r entry; do
    name="$(jq -er '.key' <<<"$entry")"; artifact="$(jq -er '.value.artifact' <<<"$entry")"
    address="$(jq -er '.value.implementation' <<<"$entry")"; expected="$(jq -er '.value.implementationCodeHash' <<<"$entry")"
    source_path="${artifact%:*}"; contract="${artifact#*:}"
    bytecode="$(gzip -cd "$build_info" | jq -er --arg source "$source_path" --arg contract "$contract" --arg address "${address#0x}" '
      .output.contracts[$source][$contract].evm.deployedBytecode as $bytecode
      | select(($bytecode.object|type)=="string" and ($bytecode.object|test("^[0-9a-fA-F]+$")))
      | (($address|ascii_downcase|[range(0;64-length)]|map("0")|join("")) + ($address|ascii_downcase)) as $replacement
      | reduce ([($bytecode.immutableReferences // {})[][]?.start] | sort)[] as $start
          ($bytecode.object; .[0:($start*2)] + $replacement + .[($start*2+64):])
    ')" || { rm -f "$entries"; die "artifact is absent from retained build-info: $name"; }
    actual="$($CAST_BIN keccak "0x$bytecode")" || { rm -f "$entries"; die "could not hash artifact: $name"; }
    [[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" == "$expected" ]] \
      || { rm -f "$entries"; die "implementation does not match retained build-info: $name"; }
  done <"$entries"
  rm -f "$entries"
}
authenticate_source_deployment() {
  local source="$1" network="$2" id history history_hash build_hash build_info
  id="$(jq -er '.deploymentId | select(test("^0x[0-9a-f]{64}$"))' "$source")" \
    || die "source deployment ID is invalid"
  history="$DEPLOYMENTS_ROOT/$network/history/$id.json"
  [[ -f "$history" ]] || die "source deployment history does not exist"
  [[ "$(jq -er '.deploymentId' "$history")" == "$id" ]] || die "source deployment history ID does not match"
  history_hash="0x$(jq 'del(.deploymentId)' "$history" | sha256_stream)"
  [[ "$history_hash" == "$id" ]] || die "source deployment history hash does not match"
  jq -e --slurpfile history "$history" '
    def static:
      del(.release,.status,.finalizedAt,.transactions)
      | .contracts |= with_entries(.value |= del(.implementation,.implementationCodeHash));
    static == ($history[0] | static)
  ' "$source" >/dev/null || die "source deployment topology does not match deployment history"

  build_hash="$(jq -er '.release.buildInfoSha256 | select(test("^0x[0-9a-f]{64}$"))' "$source")" \
    || die "source build-info hash is invalid"
  build_info="$DEPLOYMENTS_ROOT/$network/build-info/${build_hash#0x}.json.gz"
  authenticate_build_info "$build_info" "$build_hash"
  authenticate_implementation_builds "$source" "$build_info"
}
validate_upgrade_targets() {
  local manifest="$1" targets_json="$2"
  jq -e --argjson targets "$targets_json" '
    def address: type=="string" and test("^0x[0-9a-fA-F]{40}$");
    def code_hash: type=="string" and test("^0x[0-9a-f]{64}$");
    ($targets|type=="array" and length>0 and length==(unique|length)) and all($targets[]; . as $target
      | $manifest[0].contracts[$target] as $contract
      | ($contract|type=="object") and ($contract.artifact|type=="string" and length>0)
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
    (.targets|type=="array" and length>0 and length==(unique|length))
      and (.operations|type=="array") and [.operations[].target]==.targets
      and all(.operations[]; . as $operation | $manifest[0].contracts[$operation.target] as $contract
        | ($contract|type=="object") and $operation.artifact==$contract.artifact
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
  local broadcast="$1" output="$2" rpc_url="$3" work observed hash
  local transaction receipt transactions receipts
  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-receipts.XXXXXX")"
  observed="$work/observed.txt"
  jq -er 'select(.transactions|type=="array") | select(.receipts|type=="array") | select(.pending|type=="array")
    | [.receipts[].transactionHash] as $hashes
    | [$hashes[] | select(type=="string" and test("^0x[0-9a-fA-F]{64}$")) | ascii_downcase]
    | select(length==($hashes|length) and length>0 and (unique|length)==length) | .[]' "$broadcast" >"$observed" \
    || { rm -r "$work"; die "broadcast transaction hashes are invalid"; }
  transactions="$work/transactions.jsonl"; receipts="$work/receipts.jsonl"
  : >"$transactions"; : >"$receipts"
  while IFS= read -r hash; do
    transaction="$($CAST_BIN rpc eth_getTransactionByHash "$hash" --rpc-url "$rpc_url")" \
      || { rm -r "$work"; die "could not read broadcast transaction from RPC"; }
    receipt="$($CAST_BIN rpc eth_getTransactionReceipt "$hash" --rpc-url "$rpc_url")" \
      || { rm -r "$work"; die "could not read broadcast receipt from RPC"; }
    jq -cn --arg observed "$hash" --argjson value "$transaction" '{observed:$observed,value:$value}' >>"$transactions" \
      || { rm -r "$work"; die "RPC transaction is malformed"; }
    jq -cn --arg observed "$hash" --argjson value "$receipt" '{observed:$observed,value:$value}' >>"$receipts" \
      || { rm -r "$work"; die "RPC receipt is malformed"; }
  done <"$observed"
  jq -s '.' "$transactions" >"$work/transactions.json" || { rm -r "$work"; die "RPC transaction is malformed"; }
  jq -s '.' "$receipts" >"$work/receipts.json" || { rm -r "$work"; die "RPC receipt is malformed"; }
  jq -e --slurpfile rpc_transactions "$work/transactions.json" --slurpfile rpc_receipts "$work/receipts.json" '
    def digit: if .>=48 and .<=57 then .-48 elif .>=65 and .<=70 then .-55 else .-87 end;
    def quantity: if type=="number" then . elif type=="string" and test("^0x[0-9a-fA-F]+$") then .[2:]|explode|reduce .[] as $d (0; . * 16 + ($d|digit)) else error("invalid quantity") end;
    def hex_quantity: select(type=="string" and test("^0x[0-9a-fA-F]+$")) | ascii_downcase | sub("^0x0+"; "0x") | if .=="0x" then "0x0" else . end;
    def hash: select(type=="string" and test("^0x[0-9a-fA-F]{64}$")) | ascii_downcase;
    def address: select(type=="string" and test("^0x[0-9a-fA-F]{40}$")) | ascii_downcase;
    def envelope: {from:(.from|address),nonce:(.nonce|hex_quantity),to:(if .to==null then null else (.to|address) end),
      input:(.input|select(type=="string" and test("^0x([0-9a-fA-F]{2})*$"))|ascii_downcase),value:(.value|hex_quantity)};
    (.transactions|length) as $planned_count
    | [.transactions[] | {hash:(.hash|hash),envelope:(.transaction|envelope)}] as $planned
    | select(($planned|length)==$planned_count and ([$planned[].hash]|unique|length)==$planned_count
        and ([$planned[].envelope]|unique|length)==$planned_count)
    | (.pending // []) as $raw_pending
    | [$raw_pending[] | hash] as $pending
    | select(($pending|length)==($raw_pending|length) and ($pending|unique|length)==($pending|length))
    | select((($pending-[$planned[].hash])|length)==0)
    | [$rpc_transactions[0][] | .observed as $observed | .value
        | {observed:$observed,hash:(.hash|hash),envelope:(.|envelope),blockNumber:(.blockNumber|quantity),blockHash:(.blockHash|hash)}] as $transactions
    | [$rpc_receipts[0][] | .observed as $observed | .value
        | {observed:$observed,hash:(.transactionHash|hash),status:(.status|quantity),blockNumber:(.blockNumber|quantity),
          blockHash:(.blockHash|hash),contractAddress:(if .contractAddress==null then null else (.contractAddress|address) end)}] as $receipts
    | select(($transactions|length)==$planned_count and ($receipts|length)==$planned_count)
    | select(all($transactions[]; .observed==.hash) and all($receipts[]; .observed==.hash))
    | select(([$transactions[].hash]|unique|length)==$planned_count and ([$receipts[].hash]|unique|length)==$planned_count)
    | select(all($transactions[]; . as $transaction | any($receipts[]; .hash==$transaction.hash and .blockNumber==$transaction.blockNumber and .blockHash==$transaction.blockHash)))
    | select(all($receipts[]; .status==1 and .blockNumber>0))
    | select(all($transactions[]; . as $transaction
        | if any($planned[]; .hash==$transaction.hash) then
            any($planned[]; .hash==$transaction.hash and .envelope==$transaction.envelope)
          else
            ([ $planned[] | select(.envelope==$transaction.envelope and (.hash as $original | ($pending|index($original))!=null)) ] | length)==1
          end))
    | select([$transactions[].envelope]|unique|length==$planned_count)
    | select($receipts | group_by(.blockNumber) | all(.[]; ([.[].blockHash]|unique|length)==1))
    | [$receipts[] | del(.observed)]
  ' "$broadcast" >"$output" || { rm -r "$work"; die "every planned transaction must have one successful consistent RPC receipt"; }
  rm -r "$work"
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
      release:.release,operations:.operations,transactions:$tx[0]}
  ' "$pending" >"$without_id"
  id="0x$(sha256_file "$without_id")"
  jq --arg id "$id" '.upgradeId=$id' "$without_id" >"$canonical"
  rm -f "$without_id"

  record="$dir/upgrades/$id.json"
  retained="$dir/build-info/$(jq -er '.release.buildInfoSha256[2:]' "$pending").json.gz"
  retain_build_info "$build_gzip" "$retained"
  if [[ -e "$record" ]]; then
    cmp -s "$canonical" "$record" || die "upgrade history differs: $id"
  else
    staged="$(mktemp "$dir/upgrades/.upgrade.XXXXXX")"
    cp "$canonical" "$staged"; mv "$staged" "$record"
  fi
  rm -f "$canonical"

  latest="$(mktemp "$dir/.latest.XXXXXX")"
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
    | .release.gitCommit=$pending[0].release.gitCommit
    | .release.buildInfoSha256=$pending[0].release.buildInfoSha256
  ' "$source" >"$latest"
  mv "$latest" "$dir/latest.json"

  staged="$pending.next"
  jq --arg id "$id" '.status="finalized" | .upgradeId=$id' "$pending" >"$staged"
  mv "$staged" "$pending"
}

confirm_finalized_upgrade() {
  local pending="$1" network="$2" source id record latest record_hash build_hash build_info
  id="$(jq -er '.upgradeId | select(test("^0x[0-9a-f]{64}$"))' "$pending")" \
    || die "upgrade history ID is invalid"
  record="$DEPLOYMENTS_ROOT/$network/upgrades/$id.json"
  latest="$DEPLOYMENTS_ROOT/$network/latest.json"
  [[ -f "$record" && -f "$latest" ]] || die "finalized upgrade artifacts are missing"
  [[ "$(jq -er '.upgradeId' "$record")" == "$id" ]] || die "upgrade history ID does not match"
  record_hash="0x$(jq 'del(.upgradeId)' "$record" | sha256_stream)"
  [[ "$record_hash" == "$id" ]] || die "upgrade history hash does not match"
  source="$(jq -er '.sourceDeploymentId' "$pending")"
  [[ "$(jq -er '.sourceDeploymentId' "$record")" == "$source" ]] \
    || die "upgrade history source does not match"
  [[ "$(jq -er '.deploymentId' "$latest")" == "$source" ]] || die "canonical deployment changed"
  authenticate_source_deployment "$latest" "$network"
  build_hash="$(jq -er '.release.buildInfoSha256' "$record")"
  [[ "$build_hash" == "$(jq -er '.release.buildInfoSha256' "$latest")" ]] \
    || die "canonical release does not match finalized upgrade"
  build_info="$DEPLOYMENTS_ROOT/$network/build-info/${build_hash#0x}.json.gz"
  authenticate_build_info "$build_info" "$build_hash"
  jq -e --slurpfile latest "$latest" --slurpfile record "$record" '
    .operations==$record[0].operations
      and all(.operations[]; . as $operation | if $operation.target=="Validator" then
        $latest[0].contracts.Validator.implementation==$operation.newImplementation
          and $latest[0].contracts.Validator.implementationCodeHash==$operation.newImplementationCodeHash
          and $latest[0].contracts.ValidatorBeacon.implementation==$operation.newImplementation
      else
        $latest[0].contracts[$operation.target].implementation==$operation.newImplementation
          and $latest[0].contracts[$operation.target].implementationCodeHash==$operation.newImplementationCodeHash
      end)
  ' "$pending" >/dev/null || die "canonical implementations do not match finalized upgrade"
}

cmd_deploy() {
  local network="${1:-}" fresh=false rpc_var key_var suffix work build_out broadcast_root commit pending_dir pending forge_rc
  [[ -n "$network" ]] || { usage; exit 2; }; network_value "$network" chain >/dev/null; shift
  if [[ "${1:-}" == --fresh && $# == 1 ]]; then fresh=true; shift; fi
  (( $# == 0 )) || die "unsupported deploy argument: $1"
  [[ "$network" != mainnet || "$fresh" != true ]] || die "fresh mainnet deployment is not supported"
  [[ "$fresh" == true || ! -e "$DEPLOYMENTS_ROOT/$network/latest.json" ]] || die "canonical $network deployment already exists; pass --fresh"
  preflight_broadcast "$network"
  rpc_var="$(network_value "$network" rpc)"; key_var="$(network_value "$network" key)"; require_var "$rpc_var"; require_var "$key_var"
  suffix="$(printf '%s' "$network" | tr '[:lower:]' '[:upper:]')"; for var in FILECOIN_PAY TERMINATION_ORACLE ORACLE POREP_SERVICE META_ALLOCATOR OPERATOR_ADDR; do require_var "${var}_$suffix"; done
  pending_dir="$PENDING_ROOT/$network"; pending="$pending_dir/pending-deploy.json"
  if [[ -e "$pending" ]] && [[ "$(jq -r '.status // empty' "$pending")" == pending ]]; then
    die "pending $network deployment already exists"
  fi
  mkdir -p "$pending_dir"
  work="$(mktemp -d "${TMPDIR:-/tmp}/porep-deploy.XXXXXX")"; broadcast_root="$work/broadcast"
  build_out="$work/out"; "$FORGE_BIN" build --root "$ROOT" --out "$build_out" --cache-path "$work/cache" --build-info --extra-output storageLayout >/dev/null
  prepare_build_info "$build_out/build-info" "$pending_dir/pending-deploy.build-info"; commit="$($GIT_BIN -C "$ROOT" rev-parse HEAD)"
  jq -n --arg network "$network" --argjson chain "$(network_value "$network" chain)" \
    --arg commit "$commit" --arg build "$BUILD_INFO_SHA256" \
    --arg path ".deployment/$network/pending-deploy.build-info.json.gz" \
    '{status:"pending",operation:"deploy",network:$network,chainId:$chain,
      release:{gitCommit:$commit,buildInfoSha256:$build},buildInfoPath:$path,result:{}}' >"$pending"
  forge_rc=0
  FOUNDRY_BROADCAST="$broadcast_root" PRIVATE_KEY="${!key_var}" RPC_URL="${!rpc_var}" DEPLOYMENT_OUTPUT="$pending" \
    GIT_COMMIT="$commit" BUILD_INFO_SHA256="$BUILD_INFO_SHA256" \
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
  authenticate_implementation_builds "$manifest" "$build_gzip"
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
  local reference reference_hash work build_out broadcast_root commit report_hash script script_file forge_rc existing
  [[ -n "$network" ]] || { usage; exit 2; }
  network_value "$network" chain >/dev/null
  shift; (( $# > 0 )) || die "at least one upgrade target is required"; local targets=("$@")
  for (( i=0; i<${#targets[@]}; ++i )); do for (( j=0; j<i; ++j )); do [[ "${targets[$i]}" != "${targets[$j]}" ]] || die "duplicate upgrade target: ${targets[$i]}"; done; done
  targets_csv="$(IFS=,; printf '%s' "${targets[*]}")"; targets_json="$(printf '%s\n' "${targets[@]}" | jq -R . | jq -s .)"
  source="$DEPLOYMENTS_ROOT/$network/latest.json"
  [[ -f "$source" ]] || die "canonical $network deployment does not exist"
  validate_upgrade_targets "$source" "$targets_json" || die "unsupported upgrade target"
  authenticate_source_deployment "$source" "$network"
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
  authenticate_implementation_builds "$source" "$BUILD_INFO_GZIP" "$targets_json"
  commit="$($GIT_BIN -C "$ROOT" rev-parse HEAD)"
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
    --argjson targets "$targets_json" --arg source "$(jq -er '.deploymentId' "$source")" \
    --arg commit "$commit" --arg build "$BUILD_INFO_SHA256" --arg previous "$reference_hash" \
    --arg report "$report_hash" \
    --arg build_path ".deployment/$network/pending-upgrade.build-info.json.gz" \
    --arg report_path ".deployment/$network/pending-upgrade.storage.txt" \
    '{status:"pending",operation:"upgrade",network:$network,chainId:$chain,targets:$targets,operations:[],
      sourceDeploymentId:$source,
      release:{gitCommit:$commit,buildInfoSha256:$build,previousBuildInfoSha256:$previous,
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
  jq -e '.broadcast.sha256 | test("^0x[0-9a-f]{64}$")' "$pending" >/dev/null \
    || die "Forge did not write the expected upgrade broadcast"
  rm -r "$work"
  printf 'upgrade broadcast recorded; run: just finalize-upgrade %s\n' "$network"
}

cmd_finalize_upgrade() {
  local network="${1:-}" source pending_dir pending build_gzip storage_report
  local reference_hash reference rpc_var work report_hash script_file broadcast expected_path
  local expected_hash actual_hash receipts blocks operations tmp
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
  assert_recorded_source "$pending"
  if [[ "$(jq -r '.status // empty' "$pending")" == finalized ]]; then
    confirm_finalized_upgrade "$pending" "$network"
    return 0
  fi
  [[ "$(jq -r '.status // empty' "$pending")" == pending ]] || die "pending upgrade has invalid status"
  [[ "$(jq -er '.sourceDeploymentId' "$pending")" == "$(jq -er '.deploymentId' "$source")" ]] \
    || die "canonical deployment changed after upgrade broadcast"
  authenticate_source_deployment "$source" "$network"
  [[ "$(jq -er '.release.previousBuildInfoSha256' "$pending")" == "$(jq -er '.release.buildInfoSha256' "$source")" ]] \
    || die "canonical release changed after upgrade broadcast"
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
  publish_upgrade "$pending" "$receipts" "$network" "$build_gzip" "$source"
  rm -r "$work"
}

cmd_verify() {
  local network="${1:-}" manifest chain rpc_var verifier entries entry address artifact build_hash build_info
  [[ -n "$network" && $# == 1 ]] || { usage; exit 2; }; chain="$(network_value "$network" chain)"; rpc_var="$(network_value "$network" rpc)"; require_var "$rpc_var"
  verifier="$(network_value "$network" verifier)"
  manifest="$DEPLOYMENTS_ROOT/$network/latest.json"; [[ -f "$manifest" ]] || die "canonical $network deployment does not exist"
  [[ "$($GIT_BIN -C "$ROOT" rev-parse HEAD)" == "$(jq -er '.release.gitCommit' "$manifest")" ]] \
    || die "HEAD differs from deployment Git commit"
  assert_clean_release_source
  build_hash="$(jq -er '.release.buildInfoSha256 | select(test("^0x[0-9a-f]{64}$"))' "$manifest")" \
    || die "deployment build-info hash is invalid"
  build_info="$DEPLOYMENTS_ROOT/$network/build-info/${build_hash#0x}.json.gz"
  authenticate_build_info "$build_info" "$build_hash"
  authenticate_source_deployment "$manifest" "$network"
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

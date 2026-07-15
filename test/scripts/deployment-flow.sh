#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export DEPLOYMENTS_ROOT="$tmp/deployments"
export PENDING_ROOT="$tmp/pending"
export BROADCAST_ROOT="$tmp/broadcast"
export FLOW_LOG="$tmp/flow.log"
export FORGE_LOG="$tmp/forge.log"
export RPC_CALIBNET=rpc
export PRIVATE_KEY_CALIBNET=key
export FILECOIN_PAY_CALIBNET=0x1
export TERMINATION_ORACLE_CALIBNET=0x2
export ORACLE_CALIBNET=0x3
export POREP_SERVICE_CALIBNET=0x4
export META_ALLOCATOR_CALIBNET=0x5
export OPERATOR_ADDR_CALIBNET=0x6

export TEST_TX_HASH="0x$(printf 'a%.0s' {1..64})"
export TEST_BLOCK_HASH="0x$(printf 'b%.0s' {1..64})"
export TEST_ADDRESS="0x$(printf '1%.0s' {1..40})"
export TEST_UPGRADE_ADDRESS="0x$(printf '2%.0s' {1..40})"
export TEST_UPGRADE_CODE_HASH="0x$(printf '2%.0s' {1..64})"
export TEST_FROM="0x$(printf '3%.0s' {1..40})"
export TEST_TO="0x$(printf '4%.0s' {1..40})"
export TEST_INPUT=0x1234
export TEST_VALUE=0x5
export TEST_NONCE=0x7
export RPC_DATA="$tmp/rpc-data.json"
export RPC_LOG="$tmp/rpc.log"
export TEST_BUILD_INFO="$tmp/current-deployment-build.json"
jq -n --arg object 01 --argjson empty '{}' '
  {output:{contracts:{
    "src/PoRepMarket.sol":{PoRepMarket:{evm:{deployedBytecode:{object:$object,immutableReferences:$empty}}}},
    "src/ValidatorFactory.sol":{ValidatorFactory:{evm:{deployedBytecode:{object:$object,immutableReferences:$empty}}}},
    "src/DataCapEvidenceAdapter.sol":{DataCapEvidenceAdapter:{evm:{deployedBytecode:{object:$object,immutableReferences:$empty}}}},
    "src/SPRegistry.sol":{SPRegistry:{evm:{deployedBytecode:{object:$object,immutableReferences:$empty}}}},
    "src/SLIOracle.sol":{SLIOracle:{evm:{deployedBytecode:{object:$object,immutableReferences:$empty}}}},
    "src/SLIScorer.sol":{SLIScorer:{evm:{deployedBytecode:{object:$object,immutableReferences:$empty}}}},
    "src/Validator.sol":{Validator:{evm:{deployedBytecode:{object:$object,immutableReferences:$empty}}}}
  }}}
' >"$TEST_BUILD_INFO"

cat >"$tmp/cast" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == chain-id ]]; then
  printf '314159\n'
  exit 0
fi
if [[ "${1:-}" == keccak ]]; then
  if [[ "${2:-}" == 0x02 ]]; then printf '0x%s\n' "$(printf '3%.0s' {1..64})"
  else printf '%s\n' "$TEST_UPGRADE_CODE_HASH"
  fi
  exit 0
fi
[[ "${1:-}" == rpc && $# == 5 && "${4:-}" == --rpc-url ]] || exit 2
hash="$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')"
printf '%s %s\n' "$2" "$hash" >>"$RPC_LOG"
jq -c --arg method "$2" --arg hash "$hash" '.[$method][$hash]' "$RPC_DATA"
EOF
cat >"$tmp/git" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != -C ]] || shift 2
case "${1:-}" in
  status)
    if [[ "${TEST_CANONICAL_DIRTY:-0}" == 1 && "$*" == *deployments/calibnet/latest.json* ]]; then
      printf '%s\n' ' M deployments/calibnet/latest.json'
    elif [[ "${TEST_GIT_UNTRACKED:-0}" == 1 ]]; then printf '%s\n' '?? src/NewContract.sol'
    elif [[ "${TEST_GIT_DIRTY:-0}" != 0 ]]; then printf '%s\n' ' M src/PoRepMarket.sol'
    fi
    ;;
  *) exit 2 ;;
esac
EOF
cat >"$tmp/forge" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FORGE_LOG"
if [[ "$1" == build ]]; then
  while (( $# )); do
    if [[ "$1" == --out ]]; then
      mkdir -p "$2/build-info"
      cp "$TEST_BUILD_INFO" "$2/build-info/build.json"
      exit 0
    fi
    shift
  done
  exit 2
fi

printf 'broadcast\n' >>"$FLOW_LOG"
if [[ "$*" == *Upgrade.s.sol* ]]; then
  script=Upgrade.s.sol
else
  script=Deploy.s.sol
fi
mkdir -p "$FOUNDRY_BROADCAST/$script/314159"
jq -n --arg hash "$TEST_TX_HASH" --arg block "$TEST_BLOCK_HASH" \
  --arg from "$TEST_FROM" --arg to "$TEST_TO" --arg input "$TEST_INPUT" \
  --arg value "$TEST_VALUE" --arg nonce "$TEST_NONCE" '
  {transactions:[{hash:$hash,transaction:{from:$from,nonce:$nonce,to:$to,input:$input,value:$value}}],
    receipts:[{transactionHash:$hash,status:"0x1",blockNumber:"0x2",blockHash:$block,contractAddress:null}],pending:[$hash]}
' >"$FOUNDRY_BROADCAST/$script/314159/run-200.json"
cp "$FOUNDRY_BROADCAST/$script/314159/run-200.json" "$FOUNDRY_BROADCAST/$script/314159/run-latest.json"

if [[ "$script" != Deploy.s.sol ]]; then
  jq --arg names "$UPGRADE_CONTRACT_NAMES" --arg implementation "$TEST_UPGRADE_ADDRESS" --arg code_hash "$TEST_UPGRADE_CODE_HASH" '
    ($names | split(",")) as $targets | .operations=[$targets[] | {target:.,kind:(if .=="Validator" then "beacon" else "uups" end),artifact:("src/" + . + ".sol:" + .),newImplementation:$implementation,newImplementationCodeHash:$code_hash}]
  ' "$UPGRADE_OUTPUT" >"$UPGRADE_OUTPUT.next"
  mv "$UPGRADE_OUTPUT.next" "$UPGRADE_OUTPUT"
  exit 0
fi

build_hash="$(jq -r .release.buildInfoSha256 "$DEPLOYMENT_OUTPUT")"
jq --arg build "$build_hash" --arg i "$TEST_ADDRESS" --arg code_hash "$TEST_UPGRADE_CODE_HASH" '
  .result={status:"pending",deployer:$i,release:{buildInfoSha256:$build},
    contracts:{
      PoRepMarket:{kind:"uups",artifact:"src/PoRepMarket.sol:PoRepMarket",proxy:$i,implementation:$i,proxyCodeHash:$code_hash,implementationCodeHash:$code_hash},
      ValidatorFactory:{kind:"uups",artifact:"src/ValidatorFactory.sol:ValidatorFactory",proxy:$i,implementation:$i,proxyCodeHash:$code_hash,implementationCodeHash:$code_hash},
      DataCapEvidenceAdapter:{kind:"uups",artifact:"src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter",proxy:$i,implementation:$i,proxyCodeHash:$code_hash,implementationCodeHash:$code_hash},
      SPRegistry:{kind:"uups",artifact:"src/SPRegistry.sol:SPRegistry",proxy:$i,implementation:$i,proxyCodeHash:$code_hash,implementationCodeHash:$code_hash},
      SLIOracle:{kind:"uups",artifact:"src/SLIOracle.sol:SLIOracle",proxy:$i,implementation:$i,proxyCodeHash:$code_hash,implementationCodeHash:$code_hash},
      SLIScorer:{kind:"uups",artifact:"src/SLIScorer.sol:SLIScorer",proxy:$i,implementation:$i,proxyCodeHash:$code_hash,implementationCodeHash:$code_hash},
      Validator:{kind:"implementation",artifact:"src/Validator.sol:Validator",implementation:$i,implementationCodeHash:$code_hash},
      ValidatorBeacon:{kind:"beacon",artifact:"lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon",address:$i,implementation:$i,factoryProxy:$i}
    },externalDependencies:{FilecoinPay:"0x1",PoRepService:"0x4",MetaAllocator:"0x5",
      TerminationOracle:"0x2",Oracle:"0x3",Operator:"0x6"}}
' "$DEPLOYMENT_OUTPUT" >"$DEPLOYMENT_OUTPUT.next"
mv "$DEPLOYMENT_OUTPUT.next" "$DEPLOYMENT_OUTPUT"
EOF
cat >"$tmp/finality" <<'EOF'
#!/usr/bin/env bash
printf 'finality\n' >>"$FLOW_LOG"
[[ "${FINALITY_READY:-0}" == 1 ]]
EOF
cat >"$tmp/live" <<'EOF'
#!/usr/bin/env bash
printf 'live\n' >>"$FLOW_LOG"
EOF
cat >"$tmp/storage" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STORAGE_LOG"
printf '%s: valid\n' PoRepMarket ValidatorFactory DataCapEvidenceAdapter SPRegistry SLIOracle SLIScorer Validator
EOF
chmod +x "$tmp/cast" "$tmp/git" "$tmp/forge" "$tmp/finality" "$tmp/live" "$tmp/storage"

export CAST_BIN="$tmp/cast"
export GIT_BIN="$tmp/git"
export FORGE_BIN="$tmp/forge"
export FINALITY_VERIFIER="$tmp/finality"
export LIVE_CHECKER="$tmp/live"
export STORAGE_VALIDATOR="$tmp/storage"
export STORAGE_LOG="$tmp/storage.log"

write_rpc_evidence() {
  local observed_hash="$1" receipt_hash="${2:-$1}"
  jq -n --arg observed "$(printf '%s' "$observed_hash" | tr '[:upper:]' '[:lower:]')" \
    --arg receipt_hash "$receipt_hash" --arg block "$TEST_BLOCK_HASH" '
    {eth_getTransactionReceipt:{($observed):{transactionHash:$receipt_hash,status:"0x1",blockNumber:"0x2",blockHash:$block,
      contractAddress:null}}}
  ' >"$RPC_DATA"
  : >"$RPC_LOG"
}

write_rpc_evidence "$TEST_TX_HASH"
source "$ROOT/script/deployment.sh"

names=(PoRepMarket ValidatorFactory DataCapEvidenceAdapter SPRegistry SLIOracle SLIScorer Validator)
printf '{"output":{"contracts":{}}}\n' >"$tmp/reference.json"
cp "$tmp/reference.json" "$tmp/current.json"
printf '{"contracts":{}}\n' >"$tmp/storage-manifest.json"
for name in "${names[@]}"; do
  artifact="src/$name.sol:$name"
  source_path="${artifact%%:*}"
  jq --arg source "$source_path" --arg name "$name" \
    '.output.contracts[$source][$name].storageLayout={storage:[],types:{}}' \
    "$tmp/reference.json" >"$tmp/reference.next"
  mv "$tmp/reference.next" "$tmp/reference.json"
  jq --arg source "$source_path" --arg name "$name" \
    '.output.contracts[$source][$name].storageLayout={storage:[],types:{}}' \
    "$tmp/current.json" >"$tmp/current.next"
  mv "$tmp/current.next" "$tmp/current.json"
  jq --arg name "$name" --arg artifact "$artifact" '.contracts[$name].artifact=$artifact' \
    "$tmp/storage-manifest.json" >"$tmp/storage-manifest.next"
  mv "$tmp/storage-manifest.next" "$tmp/storage-manifest.json"
done
gzip -n -c "$tmp/reference.json" >"$tmp/reference.json.gz"
gzip -n -c "$tmp/current.json" >"$tmp/current.json.gz"
reference_hash="0x$(sha256_file "$tmp/reference.json")"
current_hash="0x$(sha256_file "$tmp/current.json")"
jq '.contracts.PoRepMarket.artifact=null' "$tmp/storage-manifest.json" >"$tmp/tampered-storage-manifest.json"
if "$ROOT/script/validate-storage-layout.sh" \
  --manifest "$tmp/tampered-storage-manifest.json" --target PoRepMarket \
  --reference-build-info "$tmp/reference.json.gz" --reference-sha256 "$reference_hash" \
  --current-build-info "$tmp/current.json.gz" --current-sha256 "$current_hash" >/dev/null 2>&1; then
  fail 'invalid selected artifact was accepted'
fi
printf ' ' >>"$tmp/reference.json"
gzip -n -c "$tmp/reference.json" >"$tmp/reference.json.gz"
if "$ROOT/script/validate-storage-layout.sh" \
  --manifest "$tmp/storage-manifest.json" --target PoRepMarket \
  --reference-build-info "$tmp/reference.json.gz" --reference-sha256 "$reference_hash" \
  --current-build-info "$tmp/current.json.gz" --current-sha256 "$current_hash" >/dev/null 2>&1; then
  fail 'changed reference build-info was accepted'
fi

mkdir -p "$BROADCAST_ROOT/Deploy.s.sol/314159"
printf '{}\n' >"$BROADCAST_ROOT/Deploy.s.sol/314159/run-latest.json"
mkdir -p "$PENDING_ROOT/calibnet"
printf '{"status":"pending","operation":"deploy","network":"calibnet","chainId":314159,"stale":true}\n' \
  >"$PENDING_ROOT/calibnet/pending-deploy.json"
cmd_deploy calibnet --fresh
pending="$PENDING_ROOT/calibnet/pending-deploy.json"
broadcast="$PENDING_ROOT/calibnet/pending-deploy.broadcast.json"

jq -e '.status=="pending" and .operation=="deploy" and .network=="calibnet"
  and .chainId==314159 and .result.status=="pending"
  and (.stale // false)==false
  and .broadcast.path==".deployment/calibnet/pending-deploy.broadcast.json"
  and (.broadcast.sha256|test("^0x[0-9a-f]{64}$"))' "$pending" >/dev/null
[[ ! -e "$DEPLOYMENTS_ROOT/calibnet/latest.json" ]] || fail 'deploy published canonical state'
[[ "$(cat "$FLOW_LOG")" == broadcast ]] || fail 'deploy ran finalization checks'

cp "$broadcast" "$tmp/good-broadcast.json"
jq 'del(.broadcast)' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
missing_binding_hash="$(sha256_file "$pending")"
printf '{}\n' >"$BROADCAST_ROOT/Deploy.s.sol/314159/run-300.json"
: >"$FLOW_LOG"
if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail 'deploy finalized without recorded broadcast binding'; fi
[[ "$(sha256_file "$pending")" == "$missing_binding_hash" ]] || fail 'binding failure mutated pending deployment'
[[ ! -s "$FLOW_LOG" ]] || fail 'binding failure reached finality check'
[[ ! -e "$DEPLOYMENTS_ROOT/calibnet/latest.json" ]] || fail 'binding failure published latest'
cp "$tmp/good-broadcast.json" "$broadcast"
jq --arg path ".deployment/calibnet/pending-deploy.broadcast.json" --arg hash "0x$(sha256_file "$broadcast")" \
  '.broadcast={path:$path,sha256:$hash}' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

cp "$tmp/good-broadcast.json" "$broadcast"
jq --arg hash "0x$(sha256_file "$broadcast")" '.broadcast.sha256=$hash' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
for receipt_case in missing failed wrong-hash; do
  write_rpc_evidence "$TEST_TX_HASH"
  case "$receipt_case" in
    missing) jq '.eth_getTransactionReceipt[]=null' "$RPC_DATA" >"$RPC_DATA.next" ;;
    failed) jq '.eth_getTransactionReceipt[].status="0x0"' "$RPC_DATA" >"$RPC_DATA.next" ;;
    wrong-hash) jq '.eth_getTransactionReceipt[].transactionHash="0x'"$(printf 'e%.0s' {1..64})"'"' "$RPC_DATA" >"$RPC_DATA.next" ;;
  esac
  mv "$RPC_DATA.next" "$RPC_DATA"
  : >"$FLOW_LOG"
  if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail "$receipt_case receipt finalized"; fi
  [[ ! -s "$FLOW_LOG" ]] || fail "$receipt_case receipt reached finality check"
done

duplicate="$tmp/duplicate-transactions.json"
jq '.transactions += [.transactions[0]]' "$broadcast" >"$duplicate"
write_rpc_evidence "$TEST_TX_HASH"
if (successful_receipts "$duplicate" "$tmp/duplicate-receipts.json" rpc) 2>/dev/null; then
  fail 'duplicate transaction hash was accepted'
fi
malformed="$tmp/malformed-transactions.json"
jq '.transactions += [{hash:"invalid"}]' "$broadcast" >"$malformed"
if (successful_receipts "$malformed" "$tmp/malformed-receipts.json" rpc) 2>/dev/null; then
  fail 'malformed transaction hash was omitted'
fi

write_rpc_evidence "$TEST_TX_HASH"
: >"$FLOW_LOG"
if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail 'deploy finalized before Filecoin finality'; fi
[[ "$(cat "$FLOW_LOG")" == finality ]] || fail 'deploy finalizer order is wrong'

: >"$FLOW_LOG"
FINALITY_READY=1 cmd_finalize_deploy calibnet
latest="$DEPLOYMENTS_ROOT/calibnet/latest.json"
build_hash="$(jq -r '.release.buildInfoSha256[2:]' "$latest")"
[[ -f "$DEPLOYMENTS_ROOT/calibnet/build-info/$build_hash.json.gz" ]] || fail 'build-info was not retained'
[[ "$(find "$DEPLOYMENTS_ROOT/calibnet/build-info" -name '*.json.gz' | wc -l | tr -d ' ')" == 1 ]] \
  || fail 'superseded build-info was retained'
[[ "$(tr '\n' ' ' <"$FLOW_LOG")" == 'finality live ' ]] || fail 'deploy finalizer order is wrong'

latest_hash="$(sha256_file "$latest")"
FINALITY_READY=1 cmd_finalize_deploy calibnet
[[ "$(sha256_file "$latest")" == "$latest_hash" ]] || fail 'second deploy finalizer rewrote latest'

if (TEST_CANONICAL_DIRTY=1 cmd_upgrade calibnet PoRepMarket) 2>"$tmp/error"; then
  fail 'upgrade accepted an uncommitted canonical manifest'
fi
grep -q 'canonical deployment manifest is not committed and clean' "$tmp/error" \
  || fail 'dirty canonical manifest rejection was unclear'

source_hash="$(sha256_file "$latest")"
: >"$FLOW_LOG"
: >"$STORAGE_LOG"
cmd_upgrade calibnet PoRepMarket SPRegistry Validator
pending="$PENDING_ROOT/calibnet/pending-upgrade.json"
for target in DataCapEvidenceAdapter PoRepMarket SLIOracle SLIScorer SPRegistry Validator ValidatorFactory; do
  [[ "$(cat "$STORAGE_LOG")" == *"--target $target"* ]] || fail "upgrade skipped $target storage validation"
done
jq -e '.status=="pending" and .operation=="upgrade" and .targets==["PoRepMarket","SPRegistry","Validator"]
  and .broadcast.path==".deployment/calibnet/pending-upgrade.broadcast.json"
  and (.sourceManifestSha256|test("^0x[0-9a-f]{64}$"))
  and (.resultManifestSha256|test("^0x[0-9a-f]{64}$"))
  and (.release.storageReportSha256|test("^0x[0-9a-f]{64}$"))
  and [.operations[].target]==.targets and [.operations[].kind]==["uups","uups","beacon"]' "$pending" >/dev/null
[[ "$(sha256_file "$latest")" == "$source_hash" ]] || fail 'upgrade broadcast changed latest'
[[ "$(cat "$FLOW_LOG")" == broadcast ]] || fail 'upgrade broadcast ran finalization checks'

: >"$FLOW_LOG"
if (cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'upgrade finalized before Filecoin finality'; fi
[[ "$(cat "$FLOW_LOG")" == finality ]] || fail 'upgrade finalizer order is wrong'

jq 'del(.broadcast)' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
: >"$FLOW_LOG"
if (cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'upgrade finalized without recorded broadcast binding'; fi
[[ ! -s "$FLOW_LOG" ]] || fail 'upgrade binding failure reached finality check'
jq --arg path ".deployment/calibnet/pending-upgrade.broadcast.json" \
  --arg hash "0x$(sha256_file "$PENDING_ROOT/calibnet/pending-upgrade.broadcast.json")" \
  '.broadcast={path:$path,sha256:$hash}' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

jq '.targets += [.targets[0]] | .operations += [.operations[0]]' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'duplicate upgrade target finalized'; fi
jq 'del(.targets[-1], .operations[-1])' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

jq '.operations[0].artifact="src/Tampered.sol:Tampered"' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
cp "$latest" "$tmp/canonical-artifact.json"
jq '.contracts.PoRepMarket.artifact="src/Tampered.sol:Tampered"' "$latest" >"$latest.next"
mv "$latest.next" "$latest"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'paired artifact mutation finalized'; fi
cp "$tmp/canonical-artifact.json" "$latest"
jq '.operations[0].artifact="src/PoRepMarket.sol:PoRepMarket"' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

cp "$latest" "$tmp/pre-upgrade-latest.json"
jq '.externalDependencies.FilecoinPay="0x9999999999999999999999999999999999999999"' "$latest" >"$latest.next"
mv "$latest.next" "$latest"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'upgrade finalized from a changed source manifest'; fi
cp "$tmp/pre-upgrade-latest.json" "$latest"

jq '.release.buildInfoSha256="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$latest" >"$latest.next"
mv "$latest.next" "$latest"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'upgrade finalized after canonical release changed'; fi
cp "$tmp/pre-upgrade-latest.json" "$latest"

: >"$FLOW_LOG"
: >"$STORAGE_LOG"
render_upgraded_manifest "$pending" "$latest" "$latest.next"
mv "$latest.next" "$latest"
[[ "$(jq -r .status "$pending")" == pending ]] || fail 'crash simulation finalized pending state'
FINALITY_READY=1 cmd_finalize_upgrade calibnet
[[ ! -s "$STORAGE_LOG" ]] || fail 'upgrade finalization reran storage validation'
[[ "$(jq -r .contracts.PoRepMarket.implementation "$latest")" == "$TEST_UPGRADE_ADDRESS" ]] \
  || fail 'finalizer did not update selected implementation'
[[ "$(jq -r .contracts.SPRegistry.implementation "$latest")" == "$TEST_UPGRADE_ADDRESS" ]] \
  || fail 'finalizer did not update second implementation'
[[ "$(jq -r .contracts.Validator.implementation "$latest")" == "$TEST_UPGRADE_ADDRESS" ]] \
  || fail 'finalizer did not update Validator implementation'
[[ "$(tr '\n' ' ' <"$FLOW_LOG")" == 'finality live ' ]] || fail 'upgrade finalizer order is wrong'
[[ "$(find "$DEPLOYMENTS_ROOT/calibnet/build-info" -name '*.json.gz' | wc -l | tr -d ' ')" == 1 ]] \
  || fail 'upgrade retained superseded build-info'

latest_hash="$(sha256_file "$latest")"
FINALITY_READY=1 cmd_finalize_upgrade calibnet
[[ "$(sha256_file "$latest")" == "$latest_hash" ]] || fail 'second upgrade finalizer rewrote latest'

cp "$latest" "$tmp/finalized-latest.json"
jq '.contracts.PoRepMarket.implementationCodeHash="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "$latest" >"$latest.next"
mv "$latest.next" "$latest"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then
  fail 'finalized upgrade replay accepted changed canonical implementation'
fi
cp "$tmp/finalized-latest.json" "$latest"

printf 'deployment flow: PASS\n'

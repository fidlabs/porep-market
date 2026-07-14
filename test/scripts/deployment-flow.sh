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
  rev-parse) printf '%s\n' "${TEST_GIT_COMMIT:-1111111111111111111111111111111111111111}" ;;
  status)
    if [[ "${TEST_GIT_UNTRACKED:-0}" == 1 ]]; then printf '%s\n' '?? src/NewContract.sol'
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
    receipts:[{transactionHash:$hash,status:"0x1",blockNumber:"0x2",blockHash:$block,contractAddress:null}],pending:[]}
' >"$FOUNDRY_BROADCAST/$script/314159/run-200.json"
cp "$FOUNDRY_BROADCAST/$script/314159/run-200.json" "$FOUNDRY_BROADCAST/$script/314159/run-latest.json"

if [[ "$script" != Deploy.s.sol ]]; then
  jq --arg names "$UPGRADE_CONTRACT_NAMES" --arg implementation "$TEST_UPGRADE_ADDRESS" --arg code_hash "$TEST_UPGRADE_CODE_HASH" '
    ($names | split(",")) as $targets | .operations=[$targets[] | {target:.,kind:(if .=="Validator" then "beacon" else "uups" end),artifact:("src/" + . + ".sol:" + .),newImplementation:$implementation,newImplementationCodeHash:$code_hash}]
  ' "$UPGRADE_OUTPUT" >"$UPGRADE_OUTPUT.next"
  mv "$UPGRADE_OUTPUT.next" "$UPGRADE_OUTPUT"
  exit 0
fi

git_commit="$(jq -r .release.gitCommit "$DEPLOYMENT_OUTPUT")"
build_hash="$(jq -r .release.buildInfoSha256 "$DEPLOYMENT_OUTPUT")"
jq --arg git "$git_commit" --arg build "$build_hash" --arg i "$TEST_ADDRESS" --arg code_hash "$TEST_UPGRADE_CODE_HASH" '
  .result={status:"pending",deployer:$i,release:{gitCommit:$git,buildInfoSha256:$build},
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
  local observed_hash="$1" transaction_hash="${2:-$1}" receipt_hash="${3:-$1}"
  jq -n --arg observed "$(printf '%s' "$observed_hash" | tr '[:upper:]' '[:lower:]')" \
    --arg transaction_hash "$transaction_hash" --arg receipt_hash "$receipt_hash" \
    --arg from "$TEST_FROM" --arg to "$TEST_TO" --arg input "$TEST_INPUT" \
    --arg value "$TEST_VALUE" --arg nonce "$TEST_NONCE" --arg block "$TEST_BLOCK_HASH" '
    {eth_getTransactionByHash:{($observed):{hash:$transaction_hash,from:$from,nonce:$nonce,to:$to,input:$input,value:$value,
      blockNumber:"0x2",blockHash:$block}},
     eth_getTransactionReceipt:{($observed):{transactionHash:$receipt_hash,status:"0x1",blockNumber:"0x2",blockHash:$block,
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
cmd_deploy calibnet --fresh
pending="$PENDING_ROOT/calibnet/pending-deploy.json"
broadcast="$PENDING_ROOT/calibnet/pending-deploy.broadcast.json"

jq -e '.status=="pending" and .operation=="deploy" and .network=="calibnet"
  and .chainId==314159 and .result.status=="pending"
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

replacement_hash="0x$(printf 'f%.0s' {1..64})"
jq --arg replacement "$replacement_hash" \
  '.pending=[.transactions[0].hash] | .receipts=[{transactionHash:$replacement,status:"0x1",blockNumber:"0x2",blockHash:.receipts[0].blockHash,contractAddress:null}]' \
  "$broadcast" >"$broadcast.next"
mv "$broadcast.next" "$broadcast"
jq --arg hash "0x$(sha256_file "$broadcast")" '.broadcast.sha256=$hash' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
write_rpc_evidence "$replacement_hash"
: >"$FLOW_LOG"
if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail 'replacement transaction finalized before Filecoin finality'; fi
[[ "$(cat "$FLOW_LOG")" == finality ]] || fail 'matching replacement transaction was rejected'
[[ "$(sort "$RPC_LOG" | uniq -c | tr -s ' ' | sed 's/^ //')" == $'1 eth_getTransactionByHash '"$replacement_hash"$'\n1 eth_getTransactionReceipt '"$replacement_hash" ]] \
  || fail 'replacement hash was not fetched exactly once per RPC method'

jq --arg from "0x$(printf '9%.0s' {1..40})" '.eth_getTransactionByHash[].from=$from' "$RPC_DATA" >"$RPC_DATA.next"
mv "$RPC_DATA.next" "$RPC_DATA"
: >"$FLOW_LOG"
if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail 'unrelated replacement transaction finalized'; fi
[[ ! -s "$FLOW_LOG" ]] || fail 'unrelated replacement transaction reached finality check'

jq '.pending=[]' "$broadcast" >"$broadcast.next"
mv "$broadcast.next" "$broadcast"
jq --arg hash "0x$(sha256_file "$broadcast")" '.broadcast.sha256=$hash' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
write_rpc_evidence "$replacement_hash"
: >"$FLOW_LOG"
if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail 'replacement without original pending hash finalized'; fi
[[ ! -s "$FLOW_LOG" ]] || fail 'unauthorized replacement reached finality check'

cp "$tmp/good-broadcast.json" "$broadcast"
jq --arg hash "0x$(sha256_file "$broadcast")" '.broadcast.sha256=$hash' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
write_rpc_evidence "$TEST_TX_HASH"
for null_case in eth_getTransactionByHash eth_getTransactionReceipt; do
  jq --arg method "$null_case" '.[$method][]=null' "$RPC_DATA" >"$RPC_DATA.next"
  mv "$RPC_DATA.next" "$RPC_DATA"
  : >"$FLOW_LOG"
  if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail "null $null_case response finalized"; fi
  [[ ! -s "$FLOW_LOG" ]] || fail "null $null_case response reached finality check"
  write_rpc_evidence "$TEST_TX_HASH"
done
for rpc_case in malformed-transaction failed-receipt malformed-receipt conflicting-receipt wrong-transaction-hash wrong-receipt-hash; do
  case "$rpc_case" in
    malformed-transaction) jq '.eth_getTransactionByHash[].nonce="wat"' "$RPC_DATA" >"$RPC_DATA.next" ;;
    failed-receipt) jq '.eth_getTransactionReceipt[].status="0x0"' "$RPC_DATA" >"$RPC_DATA.next" ;;
    malformed-receipt) jq '.eth_getTransactionReceipt[].blockNumber="wat"' "$RPC_DATA" >"$RPC_DATA.next" ;;
    conflicting-receipt) jq '.eth_getTransactionReceipt[].blockHash="0x'"$(printf 'e%.0s' {1..64})"'"' "$RPC_DATA" >"$RPC_DATA.next" ;;
    wrong-transaction-hash) jq '.eth_getTransactionByHash[].hash="0x'"$(printf 'e%.0s' {1..64})"'"' "$RPC_DATA" >"$RPC_DATA.next" ;;
    wrong-receipt-hash) jq '.eth_getTransactionReceipt[].transactionHash="0x'"$(printf 'e%.0s' {1..64})"'"' "$RPC_DATA" >"$RPC_DATA.next" ;;
  esac
  mv "$RPC_DATA.next" "$RPC_DATA"
  : >"$FLOW_LOG"
  if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail "$rpc_case finalized"; fi
  [[ ! -s "$FLOW_LOG" ]] || fail "$rpc_case reached finality check"
  write_rpc_evidence "$TEST_TX_HASH"
done

large_value="$tmp/large-value.json"
jq '.transactions[0].transaction.value="0x1000000000000000"' "$broadcast" >"$large_value"
write_rpc_evidence "$TEST_TX_HASH"
jq '.eth_getTransactionByHash[].value="0x1000000000000001"' "$RPC_DATA" >"$RPC_DATA.next"
mv "$RPC_DATA.next" "$RPC_DATA"
if (successful_receipts "$large_value" "$tmp/large-value-receipts.json" rpc) 2>/dev/null; then
  fail 'distinct arbitrary-width transaction values were treated as equal'
fi
write_rpc_evidence "$TEST_TX_HASH"
keyed_broadcast="$tmp/keyed-broadcast.json"
jq '.transactions={key:.transactions[0]}' "$broadcast" >"$keyed_broadcast"
if (successful_receipts "$keyed_broadcast" "$tmp/keyed-receipts.json" rpc) 2>/dev/null; then
  fail 'keyed transaction object was accepted as an array'
fi
invalid_extra="$tmp/invalid-extra-receipt.json"
jq '.receipts += [{transactionHash:"invalid"}]' "$broadcast" >"$invalid_extra"
if (successful_receipts "$invalid_extra" "$tmp/invalid-extra-receipts.json" rpc) 2>/dev/null; then
  fail 'invalid extra receipt was ignored'
fi
duplicate_receipt="$tmp/duplicate-receipt.json"
jq '.receipts += [.receipts[0]]' "$broadcast" >"$duplicate_receipt"
if (successful_receipts "$duplicate_receipt" "$tmp/duplicate-receipts.json" rpc) 2>/dev/null; then
  fail 'duplicate receipt hash was silently deduplicated'
fi
keyed_receipts="$tmp/keyed-receipts-broadcast.json"
jq '.receipts={key:.receipts[0]}' "$broadcast" >"$keyed_receipts"
if (successful_receipts "$keyed_receipts" "$tmp/keyed-receipt-output.json" rpc) 2>/dev/null; then
  fail 'keyed receipt object was accepted as an array'
fi
keyed_pending="$tmp/keyed-pending.json"
jq '.pending={}' "$broadcast" >"$keyed_pending"
if (successful_receipts "$keyed_pending" "$tmp/keyed-pending-output.json" rpc) 2>/dev/null; then
  fail 'keyed pending object was accepted as an array'
fi
ambiguous="$tmp/ambiguous-planned-envelope.json"
second_hash="0x$(printf 'c%.0s' {1..64})"
jq --arg hash "$second_hash" '
  .transactions += [{hash:$hash,transaction:.transactions[0].transaction}]
  | .receipts += [{transactionHash:$hash,status:"0x1",blockNumber:"0x2",blockHash:.receipts[0].blockHash,contractAddress:null}]
' "$broadcast" >"$ambiguous"
jq --arg hash "$second_hash" --arg from "$TEST_FROM" --arg to "$TEST_TO" --arg input "$TEST_INPUT" --arg value "$TEST_VALUE" --arg nonce "$TEST_NONCE" --arg block "$TEST_BLOCK_HASH" '
  .eth_getTransactionByHash[$hash]={hash:$hash,from:$from,nonce:$nonce,to:$to,input:$input,value:$value,blockNumber:"0x2",blockHash:$block}
  | .eth_getTransactionReceipt[$hash]={transactionHash:$hash,status:"0x1",blockNumber:"0x2",blockHash:$block,contractAddress:null}
' "$RPC_DATA" >"$RPC_DATA.next"
mv "$RPC_DATA.next" "$RPC_DATA"
if (successful_receipts "$ambiguous" "$tmp/ambiguous-receipts.json" rpc) 2>/dev/null; then
  fail 'duplicate planned transaction envelopes were accepted'
fi
write_rpc_evidence "$TEST_TX_HASH"
swapped="$tmp/swapped-planned-envelopes.json"
jq --arg hash "$second_hash" '
  .transactions += [{hash:$hash,transaction:(.transactions[0].transaction | .nonce="0x8")}]
  | .receipts += [{transactionHash:$hash,status:"0x1",blockNumber:"0x2",blockHash:.receipts[0].blockHash,contractAddress:null}]
  | .pending=[.transactions[].hash]
' "$broadcast" >"$swapped"
jq --arg first "$TEST_TX_HASH" --arg second "$second_hash" --arg from "$TEST_FROM" --arg to "$TEST_TO" --arg input "$TEST_INPUT" --arg value "$TEST_VALUE" --arg block "$TEST_BLOCK_HASH" '
  .eth_getTransactionByHash={
    ($first):{hash:$first,from:$from,nonce:"0x8",to:$to,input:$input,value:$value,blockNumber:"0x2",blockHash:$block},
    ($second):{hash:$second,from:$from,nonce:"0x7",to:$to,input:$input,value:$value,blockNumber:"0x2",blockHash:$block}}
  | .eth_getTransactionReceipt={
    ($first):{transactionHash:$first,status:"0x1",blockNumber:"0x2",blockHash:$block,contractAddress:null},
    ($second):{transactionHash:$second,status:"0x1",blockNumber:"0x2",blockHash:$block,contractAddress:null}}
' "$RPC_DATA" >"$RPC_DATA.next"
mv "$RPC_DATA.next" "$RPC_DATA"
if (successful_receipts "$swapped" "$tmp/swapped-receipts.json" rpc) 2>/dev/null; then
  fail 'exact planned hashes accepted swapped transaction envelopes'
fi
write_rpc_evidence "$TEST_TX_HASH"

conflicting="$tmp/conflicting-blocks.json"
second_block="0x$(printf 'd%.0s' {1..64})"
jq --arg hash "$second_hash" --arg block "$second_block" \
  '.transactions += [{hash:$hash,transaction:(.transactions[0].transaction | .nonce="0x8")}] | .receipts += [{transactionHash:$hash,status:"0x1",blockNumber:"0x2",blockHash:$block,contractAddress:null}]' \
  "$broadcast" >"$conflicting"
jq --arg hash "$second_hash" --arg block "$second_block" --arg from "$TEST_FROM" --arg to "$TEST_TO" --arg input "$TEST_INPUT" --arg value "$TEST_VALUE" '
  .eth_getTransactionByHash[$hash]={hash:$hash,from:$from,nonce:"0x8",to:$to,input:$input,value:$value,blockNumber:"0x2",blockHash:$block}
  | .eth_getTransactionReceipt[$hash]={transactionHash:$hash,status:"0x1",blockNumber:"0x2",blockHash:$block,contractAddress:null}
' "$RPC_DATA" >"$RPC_DATA.next"
mv "$RPC_DATA.next" "$RPC_DATA"
if (successful_receipts "$conflicting" "$tmp/conflicting-receipts.json" rpc) 2>/dev/null; then
  fail 'conflicting block hashes were accepted'
fi

: >"$FLOW_LOG"
FINALITY_READY=1 cmd_finalize_deploy calibnet
latest="$DEPLOYMENTS_ROOT/calibnet/latest.json"
deployment_id="$(jq -r .deploymentId "$latest")"
[[ -f "$DEPLOYMENTS_ROOT/calibnet/history/$deployment_id.json" ]] || fail 'history was not published'
build_hash="$(jq -r '.release.buildInfoSha256[2:]' "$latest")"
[[ -f "$DEPLOYMENTS_ROOT/calibnet/build-info/$build_hash.json.gz" ]] || fail 'build-info was not retained'
[[ "$(tr '\n' ' ' <"$FLOW_LOG")" == 'finality live ' ]] || fail 'finalizer order is wrong'

latest_hash="$(sha256_file "$latest")"
history_hash="$(sha256_file "$DEPLOYMENTS_ROOT/calibnet/history/$deployment_id.json")"
FINALITY_READY=1 cmd_finalize_deploy calibnet
[[ "$(sha256_file "$latest")" == "$latest_hash" ]] || fail 'second finalizer rewrote latest'
[[ "$(sha256_file "$DEPLOYMENTS_ROOT/calibnet/history/$deployment_id.json")" == "$history_hash" ]] \
  || fail 'second finalizer rewrote history'

source_hash="$(sha256_file "$latest")"
fixture_hash="0x$(sha256_file "$TEST_BUILD_INFO")"
gzip -n -c "$TEST_BUILD_INFO" >"$DEPLOYMENTS_ROOT/calibnet/build-info/${fixture_hash#0x}.json.gz"
jq --arg hash "$fixture_hash" '.release.buildInfoSha256=$hash' "$latest" >"$latest.next"; mv "$latest.next" "$latest"
source_hash="$(sha256_file "$latest")"

cp "$TEST_BUILD_INFO" "$tmp/inconsistent-build.json"
jq '.output.contracts["src/SPRegistry.sol"].SPRegistry.evm.deployedBytecode.object="02"' \
  "$TEST_BUILD_INFO" >"$tmp/inconsistent-build.next"
mv "$tmp/inconsistent-build.next" "$TEST_BUILD_INFO"
if (cmd_upgrade calibnet PoRepMarket) 2>"$tmp/error"; then
  fail 'partial upgrade accepted changed unselected implementation'
fi
grep -q 'implementation does not match retained build-info: SPRegistry' "$tmp/error" \
  || fail 'partial-upgrade build mismatch was unclear'
cp "$tmp/inconsistent-build.json" "$TEST_BUILD_INFO"

: >"$FLOW_LOG"
: >"$STORAGE_LOG"
cmd_upgrade calibnet PoRepMarket SPRegistry Validator
pending="$PENDING_ROOT/calibnet/pending-upgrade.json"
for target in DataCapEvidenceAdapter PoRepMarket SLIOracle SLIScorer SPRegistry Validator ValidatorFactory; do
  [[ "$(cat "$STORAGE_LOG")" == *"--target $target"* ]] || fail "upgrade skipped $target storage validation"
done
jq -e '.status=="pending" and .operation=="upgrade" and .targets==["PoRepMarket","SPRegistry","Validator"]
  and .broadcast.path==".deployment/calibnet/pending-upgrade.broadcast.json"
  and (.release.storageReportSha256|test("^0x[0-9a-f]{64}$"))
  and [.operations[].target]==.targets and [.operations[].kind]==["uups","uups","beacon"]' "$pending" >/dev/null
[[ "$(sha256_file "$latest")" == "$source_hash" ]] || fail 'upgrade broadcast changed latest'
[[ "$(cat "$FLOW_LOG")" == broadcast ]] || fail 'upgrade broadcast ran finalization checks'

: >"$FLOW_LOG"
if (cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'upgrade finalized before Filecoin finality'; fi
[[ "$(cat "$FLOW_LOG")" == finality ]] || fail 'upgrade finalizer order is wrong'
[[ "$(sha256_file "$latest")" == "$source_hash" ]] || fail 'early upgrade finalizer changed latest'

jq 'del(.broadcast)' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
missing_binding_hash="$(sha256_file "$pending")"
mkdir -p "$BROADCAST_ROOT/Upgrade.s.sol/314159"
printf '{}\n' >"$BROADCAST_ROOT/Upgrade.s.sol/314159/run-300.json"
: >"$FLOW_LOG"
if (cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'upgrade finalized without recorded broadcast binding'; fi
[[ "$(sha256_file "$pending")" == "$missing_binding_hash" ]] || fail 'upgrade binding failure mutated pending'
[[ ! -s "$FLOW_LOG" ]] || fail 'upgrade binding failure reached finality check'
jq --arg path ".deployment/calibnet/pending-upgrade.broadcast.json" --arg hash "0x$(sha256_file "$PENDING_ROOT/calibnet/pending-upgrade.broadcast.json")" \
  '.broadcast={path:$path,sha256:$hash}' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

jq '.targets += [.targets[0]] | .operations += [.operations[0]]' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'duplicate upgrade target finalized'; fi
jq 'del(.targets[-1], .operations[-1])' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

jq '.operations[0].artifact="src/Tampered.sol:Tampered"' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'tampered upgrade operation finalized'; fi
jq '.operations[0].artifact="src/PoRepMarket.sol:PoRepMarket"' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

cp "$latest" "$tmp/authentic-latest.json"
jq '.contracts.PoRepMarket.artifact="src/Tampered.sol:Tampered"' "$latest" >"$latest.next"
mv "$latest.next" "$latest"
jq '.operations[0].artifact="src/Tampered.sol:Tampered"' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'tampered source deployment finalized'; fi
cp "$tmp/authentic-latest.json" "$latest"
jq '.operations[0].artifact="src/PoRepMarket.sol:PoRepMarket"' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

jq '.release.gitCommit="2222222222222222222222222222222222222222" | .release.buildInfoSha256="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$latest" >"$latest.next"
mv "$latest.next" "$latest"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'tampered source deployment release finalized'; fi
cp "$tmp/authentic-latest.json" "$latest"

: >"$STORAGE_LOG"
if (TEST_GIT_COMMIT=2222222222222222222222222222222222222222 FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then
  fail 'upgrade finalized from a different Git commit'
fi
[[ ! -s "$STORAGE_LOG" ]] || fail 'commit mismatch reran storage validation'

: >"$FLOW_LOG"
TEST_GIT_DIRTY=1 FINALITY_READY=1 cmd_finalize_upgrade calibnet
[[ ! -s "$STORAGE_LOG" ]] || fail 'upgrade finalization reran storage validation'
[[ "$(jq -r .contracts.PoRepMarket.implementation "$latest")" == "$TEST_UPGRADE_ADDRESS" ]] \
  || fail 'finalizer did not update selected implementation'
[[ "$(jq -r .contracts.SPRegistry.implementation "$latest")" == "$TEST_UPGRADE_ADDRESS" ]] || fail 'finalizer did not update second implementation'
[[ "$(jq -r .contracts.Validator.implementation "$latest")" == "$TEST_UPGRADE_ADDRESS" ]] || fail 'finalizer did not update Validator implementation'
upgrade_id="$(jq -r .upgradeId "$pending")"
record="$DEPLOYMENTS_ROOT/calibnet/upgrades/$upgrade_id.json"
[[ -f "$record" ]] || fail 'upgrade record was not published'
jq -e --arg previous "$fixture_hash" '
  .release.previousBuildInfoSha256==$previous
    and (.release.storageReportSha256|test("^0x[0-9a-f]{64}$"))
' "$record" >/dev/null || fail 'upgrade record omitted storage validation provenance'
[[ "$(tr '\n' ' ' <"$FLOW_LOG")" == 'finality live ' ]] || fail 'upgrade finalizer order is wrong'

latest_hash="$(sha256_file "$latest")"
record_hash="$(sha256_file "$record")"
FINALITY_READY=1 cmd_finalize_upgrade calibnet
[[ "$(sha256_file "$latest")" == "$latest_hash" ]] || fail 'second upgrade finalizer rewrote latest'
[[ "$(sha256_file "$record")" == "$record_hash" ]] || fail 'second upgrade finalizer rewrote record'

cp "$latest" "$tmp/finalized-latest.json"
jq '.contracts.PoRepMarket.implementationCodeHash="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "$latest" >"$latest.next"
mv "$latest.next" "$latest"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then
  fail 'finalized upgrade replay accepted tampered canonical evidence'
fi
cp "$tmp/finalized-latest.json" "$latest"

cp "$record" "$tmp/finalized-record.json"
jq '.transactions[0].status=0' "$record" >"$record.next"
mv "$record.next" "$record"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then
  fail 'finalized upgrade replay accepted tampered upgrade history'
fi
cp "$tmp/finalized-record.json" "$record"

printf 'deployment flow: PASS\n'
